from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import zipfile
from xml.etree import ElementTree as ET

from papershelf_pipeline.contracts import PipelineError, sha256, write_json
from papershelf_pipeline.presentation import (
    _lines, _make_plan, _paginate, _validate_plan, create_presentation, presentation_status,
)


class FixtureProvider:
    base_url = 'http://fixture.invalid/v1'
    model = 'synthetic'
    key_env = 'TEST_KEY'

    def __init__(self):
        self.calls = []

    def json(self, system, user):
        payload = json.loads(user)
        self.calls.append(payload)
        blocks = payload['source_blocks']
        return {'slides': [{'title': '合成数据与适用条件', 'section': '方法与结果',
                            'points': [{'text': block['text'], 'source_ids': [block['id']],
                                        'evidence': [{'block_id': block['id'], 'quote': block['text']}]} for block in blocks]}],
                'coverage': [{'block_id': block['id'], 'action': 'used', 'reason': '保留合成数据与限定条件。'} for block in blocks]}


class PresentationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = {'path': str(self.root / 'synthetic.md'), 'sha256': 'f' * 64,
                       'blocks': [{'id': 'main-p1-b1', 'page': 1, 'document': 'main',
                                   'text': 'Sample A was measured at 298 K. k = 2 s^-1. All 1500 measurements were retained.'},
                                  {'id': 'main-p2-b1', 'page': 2, 'document': 'main',
                                   'text': '仅为合成测试。结果不能作为科学验收，也不能推广到未测量的温度。'}],
                       'figure_inventory': []}
        self.request = {'mode': 'llm', 'title': '合成文献汇报', 'provider': {'model': 'synthetic'},
                        'presentation': {'chunk_characters': 500}}

    def tearDown(self):
        self.temp.cleanup()

    def test_reject_unknown_or_fabricated_source_and_missing_coverage(self):
        provider = FixtureProvider()
        valid = provider.json('', json.dumps({'source_blocks': self.source['blocks']}))
        _validate_plan(valid, self.source['blocks'])
        for corruption in ('unknown_id', 'false_quote', 'missing_block', 'false_context'):
            value = copy.deepcopy(valid)
            if corruption == 'unknown_id':
                value['slides'][0]['points'][0]['source_ids'] = ['invented']
            elif corruption == 'false_quote':
                value['slides'][0]['points'][0]['evidence'][0]['quote'] = 'k = 500 s^-1'
            elif corruption == 'missing_block':
                value['coverage'].pop()
            else:
                value['coverage'][0]['action'] = 'context'
            with self.subTest(corruption=corruption), self.assertRaises(PipelineError):
                _validate_plan(value, self.source['blocks'])

    def test_every_source_character_reaches_model_and_long_block_is_not_cut(self):
        self.source['blocks'][0]['text'] = 'This long block retains all experimental conditions. ' * 100
        self.source['blocks'].append({'id': 'main-p3-b1', 'page': 3, 'document': 'main', 'text': 'Final observations. ' * 80})
        provider = FixtureProvider()
        slides, coverage = _make_plan(self.source, self.request, self.root, provider, lambda _: None)
        received = [block for call in provider.calls for block in call['source_blocks']]
        self.assertEqual([(b['id'], b['text']) for b in received], [(b['id'], b['text']) for b in self.source['blocks']])
        self.assertEqual(len(coverage), 3)
        self.assertEqual(len(provider.calls), 3)
        known = {block['id']: block for block in self.source['blocks']}
        pages = _paginate(slides, known)
        self.assertGreater(len(pages), 5)
        rendered = ''.join(line for page in pages for line, role in page['lines'] if role == 'body')
        self.assertEqual(''.join(' '.join(block['text'].split()) for block in self.source['blocks']), rendered)

    def test_offline_never_calls_provider_and_preserves_complete_text(self):
        provider = FixtureProvider()
        slides, coverage = _make_plan(self.source, {'mode': 'offline'}, self.root, provider, lambda _: None)
        self.assertFalse(provider.calls)
        self.assertEqual([s['points'][0]['text'] for s in slides], [b['text'] for b in self.source['blocks']])
        self.assertTrue(all(row['action'] == 'used' for row in coverage))

    def test_resume_requires_source_provider_payload_and_response_hash_match(self):
        first = self.root / 'first' / 'presentation'
        first.mkdir(parents=True)
        provider = FixtureProvider()
        _make_plan(self.source, self.request, first, provider, lambda _: None)
        resumed = self.root / 'second' / 'presentation'
        resumed.mkdir(parents=True)
        fresh = FixtureProvider()
        _make_plan(self.source, {**self.request, 'resume_from': str(first.parent)}, resumed, fresh, lambda _: None)
        self.assertFalse(fresh.calls)
        self.assertTrue(json.loads((resumed / 'part-0001.cache.json').read_text())['reused'])
        for variation in ('source', 'provider', 'response', 'valid_but_uncited'):
            directory = self.root / variation
            directory.mkdir()
            source = copy.deepcopy(self.source)
            request = {**self.request, 'resume_from': str(first.parent)}
            if variation == 'source':
                source['sha256'] = 'a' * 64
            elif variation == 'provider':
                request['provider'] = {'model': 'changed'}
            elif variation == 'response':
                (first / 'part-0001.json').write_text('{}')
            else:
                response = FixtureProvider().json('', json.dumps({'source_blocks': self.source['blocks']}))
                response['coverage'] = []
                write_json(first / 'part-0001.json', response)
                receipt = json.loads((first / 'part-0001.cache.json').read_text())
                receipt['response_sha256'] = sha256(first / 'part-0001.json')
                write_json(first / 'part-0001.cache.json', receipt)
            provider = FixtureProvider()
            _make_plan(source, request, directory, provider, lambda _: None)
            self.assertEqual(len(provider.calls), 1, variation)

    def test_bad_config_is_a_pipeline_error_before_creating_outputs(self):
        with self.assertRaisesRegex(PipelineError, 'presentation'):
            create_presentation(self.source, {}, {'presentation': 'invalid'}, self.root)
        self.assertFalse((self.root / 'presentation').exists())

    @unittest.skipUnless(presentation_status()['ready'], 'PPT Master source and export dependencies required')
    def test_real_native_export_notes_citations_manifest_and_original_image_bytes(self):
        from PIL import Image
        image = self.root / 'synthetic-figure.png'
        Image.new('RGB', (1800, 900), (248, 248, 240)).save(image)
        self.source['figure_inventory'] = [{'id': 'synthetic-f1', 'page': 1, 'document_id': 'main',
                                           'label': 'Figure 1', 'caption': 'Synthetic blank image for integrity verification.',
                                           'image_path': str(image), 'source': 'test_fixture', 'rect': [0, 0, 180, 90]}]
        request = {'mode': 'offline', 'title': 'Synthetic <script>not executed</script>', 'citation': 'Test fixture, 2026'}
        artifacts = create_presentation(self.source, {}, request, self.root)
        for path in artifacts.values():
            self.assertTrue(Path(path).is_file())
        manifest = json.loads(Path(artifacts['presentation_manifest']).read_text())
        self.assertEqual(manifest['processed_blocks'], 2)
        self.assertEqual(manifest['slide_count'], 4)
        self.assertGreater(manifest['editable_text_runs'], 12)
        self.assertFalse(manifest['scientific_acceptance'])
        self.assertEqual(manifest['figures'][0]['sha256'], sha256(image))
        preview = Path(artifacts['presentation_preview']).read_text()
        self.assertNotIn('<script>not executed</script>', preview)
        self.assertIn('Content-Security-Policy', preview)
        self.assertIn('data:image/png;base64,', preview)
        outline = Path(artifacts['presentation_outline']).read_text()
        for block in self.source['blocks']:
            self.assertIn(block['text'], outline)
        with zipfile.ZipFile(artifacts['presentation']) as package:
            media = [package.read(name) for name in package.namelist() if name.startswith('ppt/media/')]
            self.assertIn(image.read_bytes(), media)
            self.assertIn(b'All 1500 measurements were retained.', package.read('ppt/notesSlides/notesSlide2.xml'))
            self.assertIn(b'main-p1-b1', package.read('ppt/slides/slide2.xml'))
            # Actual native title frames must allow CJK substitution without a
            # viewer moving the final character to a second line. Tight glyph
            # bounds (about 374 px for this title) failed in LibreOffice.
            ns = {'p': 'http://schemas.openxmlformats.org/presentationml/2006/main',
                  'a': 'http://schemas.openxmlformats.org/drawingml/2006/main'}
            page = ET.fromstring(package.read('ppt/slides/slide2.xml'))
            shapes = page.findall('.//p:sp', ns)
            title = next(shape for shape in shapes if '原文研读' in ''.join(node.text or '' for node in shape.findall('.//a:t', ns)))
            self.assertEqual(''.join(node.text or '' for node in title.findall('.//a:t', ns)), '原文研读 · 第 1 页')
            self.assertGreater(int(title.find('p:spPr/a:xfrm/a:ext', ns).get('cx')) / 9525, 1100)
            self.assertEqual(title.find('.//a:rPr', ns).get('sz'), '3300')
            self.assertEqual(title.find('.//a:ea', ns).get('typeface'), 'Microsoft YaHei')
            footer = next(shape for shape in shapes if shape.find('p:nvSpPr/p:cNvPr', ns).get('name') == 'draft-label')
            number = next(shape for shape in shapes if shape.find('p:nvSpPr/p:cNvPr', ns).get('name') == 'page-number')
            footer_right = int(footer.find('p:spPr/a:xfrm/a:off', ns).get('x')) + int(footer.find('p:spPr/a:xfrm/a:ext', ns).get('cx'))
            self.assertLess(footer_right, int(number.find('p:spPr/a:xfrm/a:off', ns).get('x')))
        report = json.loads((self.root / 'presentation/delivery-check.json').read_text())
        self.assertEqual(report['status'], 'passed')
        self.assertTrue((self.root / 'presentation/validation/svg_quality_report.json').is_file())
        receipt = json.loads((self.root / 'presentation/layout-adjustments.json').read_text())
        self.assertTrue(any(row['shape'] == 'title-0' for row in receipt['adjustments']))


if __name__ == '__main__':
    unittest.main()

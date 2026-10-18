from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock

from papershelf_pipeline.contracts import PipelineError, read_json
from papershelf_pipeline.selective import make_extraction


class ExtractionProvider:
    def __init__(self, change=None):
        self.requests = []
        self.change = change

    def json(self, system, serialized):
        request = json.loads(serialized)
        self.requests.append((system, request))
        records = []
        for block in request['source_blocks']:
            records.append({'label': block['id'], 'values': {
                'temperature': {'value': 25, 'status': 'supported', 'unit': '°C',
                    'evidence': [{'block_id': block['id'], 'page': block['page'], 'quote': '25 °C'}]}}})
        result = {'records': records, 'warnings': []}
        if self.change:
            self.change(result)
        return result


class SelectiveExtractionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = {'sha256': 'source-hash', 'document_set_sha256': 'document-set-hash',
            'blocks': [{'id': f'p{number}', 'page': number,
                        'document': 'supplement' if number == 3 else 'main',
                        'text': f'Sample {number} was measured at 25 °C. ' + 'Complete input. ' * 140}
                       for number in range(1, 4)]}
        self.request = {'mode': 'llm', 'fields': [{'name': 'temperature', 'type': 'number', 'unit': 'K'}],
                        'chunk_characters': 2000, 'provider': {'model': 'test', 'base_url': 'https://example.invalid/v1'}}

    def generate(self, provider, name='current', request=None):
        directory = self.root / name
        directory.mkdir()
        result = make_extraction(self.source, request or self.request, directory, provider, lambda _: None)
        return result, directory

    def test_all_source_blocks_are_submitted_without_learning_or_unit_conversion(self):
        provider = ExtractionProvider()
        result, directory = self.generate(provider)
        submitted = [block for _, request in provider.requests for block in request['source_blocks']]
        self.assertEqual(submitted, self.source['blocks'])
        self.assertEqual(result['coverage']['input_source_ids'], ['p1', 'p2', 'p3'])
        self.assertEqual(len(provider.requests), 3)
        self.assertEqual(len(result['records']), 3)
        for record in result['records']:
            self.assertEqual(record['values']['temperature']['value'], 25)
            self.assertEqual(record['values']['temperature']['unit'], '°C')
        self.assertTrue(any('no conversion was applied' in warning for warning in result['warnings']))
        for system, request in provider.requests:
            self.assertEqual(set(request['schema']), {'records', 'warnings'})
            self.assertIn('不要生成译文', system)
            self.assertNotIn('paragraphs', request)
        self.assertFalse((directory / 'learning.json').exists())
        self.assertFalse((directory / 'chunks').exists())
        receipts = list((directory / 'extraction-chunks').glob('chunk-*.json'))
        self.assertEqual(len(receipts), 3)
        self.assertTrue(all(read_json(path)['status'] == 'completed' for path in receipts))

    def test_invalid_quotes_types_and_pages_are_rejected_and_preserved(self):
        changes = {
            'quote': lambda output: output['records'][0]['values']['temperature']['evidence'][0].update(quote='99 °C'),
            'type': lambda output: output['records'][0]['values']['temperature'].update(value='25'),
            'page': lambda output: output['records'][0]['values']['temperature']['evidence'][0].update(page=99),
            'outside_chunk': lambda output: output['records'][0]['values']['temperature']['evidence'][0].update(block_id='p2', page=2),
        }
        for name, change in changes.items():
            with self.subTest(name=name):
                provider = ExtractionProvider(change)
                with self.assertRaises(PipelineError):
                    self.generate(provider, name)
                receipt = read_json(self.root / name / 'extraction-chunks' / 'chunk-0001.json')
                self.assertEqual(receipt['status'], 'failed')
                self.assertIn('response', receipt)
                self.assertEqual(len(provider.requests), 1)

    def test_unrequested_learning_output_is_rejected(self):
        with self.assertRaisesRegex(PipelineError, '只允许 records 与 warnings'):
            self.generate(ExtractionProvider(lambda output: output.update(paragraphs=[])))

    def test_offline_and_no_fields_never_call_provider(self):
        provider = Mock()
        offline = {**self.request, 'mode': 'offline'}
        result, directory = self.generate(provider, 'offline', offline)
        self.assertIsNone(result['records'][0]['values']['temperature']['value'])
        self.assertEqual(result['coverage']['input_source_ids'], [])
        self.assertFalse((directory / 'extraction-chunks').exists())
        empty, _ = self.generate(provider, 'empty', {**self.request, 'fields': []})
        self.assertEqual(empty['records'], [])
        provider.json.assert_not_called()

    def test_resume_revalidates_receipts_and_does_not_read_legacy_learning_cache(self):
        first, previous = self.generate(ExtractionProvider(), 'previous')
        (previous / 'chunks').mkdir()
        (previous / 'chunks' / 'chunk-0001.json').write_text('not valid learning data')
        provider = Mock()
        result, current = self.generate(provider, request={**self.request, 'resume_from': str(previous)})
        provider.json.assert_not_called()
        self.assertEqual(result['records'], first['records'])
        self.assertEqual(result['coverage']['reused_chunks'], 3)
        self.assertEqual(read_json(current / 'extraction-chunks' / 'chunk-0001.json')['resumed_from'],
                         str((previous / 'extraction-chunks' / 'chunk-0001.json').resolve()))
        # A matching hash alone never makes an altered quote trusted.
        receipt_path = previous / 'extraction-chunks' / 'chunk-0001.json'
        receipt = read_json(receipt_path)
        receipt['response']['records'][0]['values']['temperature']['evidence'][0]['quote'] = 'fabricated'
        receipt_path.write_text(json.dumps(receipt))
        repaired_provider = ExtractionProvider()
        repaired, _ = self.generate(repaired_provider, 'repaired', {**self.request, 'resume_from': str(previous)})
        self.assertEqual(len(repaired_provider.requests), 1)
        self.assertEqual(repaired['coverage']['reused_chunks'], 2)

    def test_changed_provider_schema_or_source_cannot_reuse_receipts(self):
        _, previous = self.generate(ExtractionProvider(), 'previous')
        variants = {
            'provider': {**self.request, 'provider': {**self.request['provider'], 'model': 'different'}},
            'schema': {**self.request, 'fields': [{**self.request['fields'][0], 'description': 'Changed meaning'}]},
        }
        for name, request in variants.items():
            with self.subTest(name=name):
                provider = ExtractionProvider()
                result, _ = self.generate(provider, name, {**request, 'resume_from': str(previous)})
                self.assertEqual(len(provider.requests), 3)
                self.assertEqual(result['coverage']['reused_chunks'], 0)
        self.source = copy.deepcopy(self.source)
        self.source['document_set_sha256'] = 'changed-document-set'
        provider = ExtractionProvider()
        result, _ = self.generate(provider, 'source', {**self.request, 'resume_from': str(previous)})
        self.assertEqual(len(provider.requests), 3)
        self.assertEqual(result['coverage']['reused_chunks'], 0)


if __name__ == '__main__':
    unittest.main()

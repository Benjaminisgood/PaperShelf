from __future__ import annotations

import base64
import copy
import json
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from papershelf_pipeline.contracts import PipelineCancelled, PipelineError, read_json, sha256, write_json
from papershelf_pipeline.pipeline import run
from papershelf_pipeline.revision import revise


class EditingProvider:
    def __init__(self, config):
        self.calls = 0
        self.usage = {}

    def json(self, system, user):
        self.calls += 1
        self.usage['total_tokens'] = self.calls * 10
        request = json.loads(user)
        if 'reading_groups' in request:
            return {'clean_reading': [{'id': group['id'], 'source_ids': group['source_ids'], 'text': group['text'],
                                      'translation': '完整直译：' + group['text'], 'editing_notes': [],
                                      'translation_units': [{'unit_id': unit['id'], 'translation': '完整直译：' + unit['text']}
                                                            for unit in group.get('translation_units', [])]}
                                     for group in request['reading_groups']]}
        if 'items' in request:
            output = {key: [] for key in ('thematic_sections', 'methods', 'findings', 'critique', 'transfer', 'quiz', 'glossary')}
            output['coverage'] = []
            for item in request['items']:
                output[item['section']].append(copy.deepcopy(item['value']))
                output['coverage'].append({'input_id': item['input_id'], 'action': 'retained', 'reason': '完整保留测试来源与条件。'})
            return output
        if 'overview' in request.get('schema', {}):
            return {
                'overview': '完整文献报告了测量条件，解读时保留温度与证据边界。',
                'reading_route': ['核对原始测量条件。'],
                'reviewed_gaps': [
                    {'input_gap_id': gap['id'], 'text': gap['text'], 'source_ids': [],
                     'status': 'process_note', 'reason': '测试草稿中的离线处理提示属于流程说明，不是科学证据缺口。'}
                    for gap in request['gap_drafts']
                ],
            }
        raise AssertionError('Unexpected model request')


class RevisionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paper = self.root / 'paper.md'
        self.paper.write_text('The temperature was 300 K. All measured reaction rates are retained.\n\nS + MAP3K → S + MAP3K ∗\n')
        self.supplement = self.root / 'supplement.md'
        self.supplement.write_text('The supplementary measurements confirm the reported condition.\n')
        self.runs = self.root / 'runs'
        with patch('papershelf_pipeline.pipeline.progress'):
            self.original = run({'source_path': str(self.paper), 'supplementary_paths': [str(self.supplement)],
                                 'output_root': str(self.runs), 'title': 'Revision fixture', 'mode': 'offline',
                                 'fields': [{'name': 'temperature', 'type': 'number', 'unit': 'K'}]})
        self.previous = Path(self.original['run_dir'])
        self.preview = self.previous / 'custom-page-assets' / 'page.png'
        self.preview.parent.mkdir()
        self.preview.write_bytes(base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jF1sAAAAASUVORK5CYII='))
        self.external_crop = self.root / 'outside-crop.png'
        self.external_crop.write_bytes(self.preview.read_bytes())
        source = read_json(self.previous / 'source.json')
        source['figures'] = [{'page': 1, 'path': str(self.preview), 'width': 1, 'height': 1, 'caption': 'Original page', 'kind': 'page_preview'}]
        crop = {'id': 'figure-1', 'page': 1, 'image_path': str(self.external_crop), 'width': 1, 'height': 1,
                'label': 'Figure 1', 'kind': 'fig', 'caption': 'Fixture crop', 'rect': [0, 0, 1, 1], 'confidence': 1.0}
        source['figure_crops'] = [crop]
        source['figure_inventory'] = [crop]
        source['figure_coverage'] = 'test_fixture'
        write_json(self.previous / 'source.json', source)
        write_json(self.previous / 'figures.json', {'items': [crop], 'documents': source['documents'], 'custom': {'path': str(self.preview)}})
        (self.previous / 'markitdown.md').write_text('![page](custom-page-assets/page.png)\n![crop](../../outside-crop.png)\n')
        learning = read_json(self.previous / 'learning.json')
        identifier = source['blocks'][0]['id']
        learning['reading_coverage'] = {'main_source_ids': ['STALE'], 'reading_groups': 999}
        learning['methods'] = [{'title': 'Measurement conditions', 'body': 'The temperature was 300 K.', 'source_ids': [identifier], 'kind': 'source'}]
        write_json(self.previous / 'learning.json', learning)
        self.original['metrics'] = {'pages': 999, 'provider_calls': 999, 'records': 999, 'obsolete_count': 999}
        (self.previous / 'paper2agent').mkdir()
        (self.previous / 'paper2agent' / 'task.txt').write_text('Preserved upstream task')
        write_json(self.previous / 'paper2agent.json', {'workdir': str(self.previous / 'paper2agent'), 'status': 'prepared'})
        write_json(self.previous / 'graphiti.json', {'status': 'ingested', 'source_path': str(self.previous / 'reading-content.md')})
        self.original['artifacts'].update(upstream_paper2agent=str(self.previous / 'paper2agent.json'), graphiti=str(self.previous / 'graphiti.json'))
        write_json(self.previous / 'manifest.json', self.original)
        self.snapshot = self.snapshot_run()

    def tearDown(self):
        self.temp.cleanup()

    def snapshot_run(self):
        return {str(path.relative_to(self.previous)): sha256(path) for path in self.previous.rglob('*') if path.is_file()}

    def revisions(self):
        return [path for path in self.runs.iterdir() if path.is_dir() and path != self.previous]

    def perform(self, **kwargs):
        with patch('papershelf_pipeline.provider.Provider', EditingProvider):
            return revise(self.previous / 'manifest.json', provider_config={'model': 'fixture', 'base_url': 'http://fixture.invalid'},
                          progress=lambda message: None, **kwargs)

    def test_complete_revision_recomputes_mode_coverage_metrics_and_resources(self):
        result = self.perform()
        directory = Path(result['run_dir'])
        source = read_json(result['artifacts']['source'])
        learning = read_json(result['artifacts']['learning'])
        self.assertEqual(result['status'], 'completed')
        self.assertEqual(learning['mode'], 'llm')
        self.assertNotIn('这是离线来源资料包', learning['overview'])
        self.assertEqual(learning['reading_coverage']['main_source_ids'], [i for g in source['reading_main_blocks'] for i in g['source_ids']])
        coverage = learning['reading_coverage']
        self.assertCountEqual(coverage['main_source_ids'] + coverage['auxiliary_source_ids'] + coverage['excluded_source_ids'], [b['id'] for b in source['blocks']])
        self.assertEqual(result['metrics']['pages'], 2)
        self.assertEqual(result['metrics']['reading_groups'], len(source['reading_main_blocks']))
        self.assertGreaterEqual(result['metrics']['provider_calls'], 2)
        self.assertEqual(result['metrics']['provider_usage']['total_tokens'], result['metrics']['provider_calls'] * 10)
        self.assertNotIn('obsolete_count', result['metrics'])
        self.assertEqual(read_json(result['artifacts']['extraction']), read_json(self.previous / 'extraction.json'))
        self.assertEqual(self.snapshot_run(), self.snapshot)
        for key, value in result['artifacts'].items():
            self.assertTrue(Path(value).is_file(), key)
            self.assertTrue(Path(value).is_relative_to(directory), (key, value))
            self.assertEqual(directory / result['portable_artifacts'][key], Path(value))
        for key in ('source.json', 'learning.json', 'extraction.json', 'manifest.json', 'request.json'):
            self.assertEqual((directory / 'draft' / key).read_bytes(), (self.previous / key).read_bytes())
        inventory = read_json(result['artifacts']['figure_inventory'])
        self.assertNotIn(str(self.previous), json.dumps(inventory))
        self.assertTrue(Path(inventory['items'][0]['image_path']).is_file())
        self.assertTrue(Path(inventory['custom']['path']).is_file())
        self.assertTrue(all(Path(doc['path']).is_relative_to(directory) for doc in inventory['documents']))
        self.assertEqual(read_json(result['artifacts']['upstream_paper2agent'])['workdir'], str(directory / 'paper2agent'))
        prior_graph_input = Path(read_json(result['artifacts']['graphiti'])['source_path'])
        self.assertTrue(prior_graph_input.is_relative_to(directory / 'draft'))
        self.assertEqual(prior_graph_input.read_bytes(), (self.previous / 'reading-content.md').read_bytes())
        self.assertTrue(result['extraction_reused'])
        self.assertFalse(coverage['human_scientific_acceptance'])

    def test_edition_and_agent_work_after_old_run_and_inputs_are_removed_and_new_run_is_moved(self):
        result = self.perform()
        moved = self.root / 'moved-edition'
        shutil.move(result['run_dir'], moved)
        shutil.rmtree(self.previous)
        self.paper.unlink()
        self.supplement.unlink()
        self.external_crop.unlink()
        for relative in result['portable_artifacts'].values():
            self.assertTrue((moved / relative).is_file(), relative)
        for markdown in ('learning.md', 'markitdown.md'):
            content = (moved / markdown).read_text()
            for target in re.findall(r'!\[[^\]]*\]\(([^)]+)\)', content):
                self.assertTrue((moved / target).is_file(), target)
        process = subprocess.run([sys.executable, str(moved / 'agent' / 'run.py'), '--query', 'temperature'], capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertIn('300 K', json.loads(process.stdout)['answer'])
        html = (moved / result['portable_artifacts']['html']).read_text()
        self.assertIn('data:image/png;base64,', html)

    def test_failure_preserves_previous_run_and_records_failed_revision(self):
        with patch('papershelf_pipeline.synthesis.polish_reading', side_effect=PipelineError('fixture failure')):
            with self.assertRaisesRegex(PipelineError, 'fixture failure.*manifest.json'):
                self.perform()
        receipt = read_json(self.revisions()[0] / 'manifest.json')
        self.assertEqual(receipt['status'], 'failed')
        self.assertTrue(Path(receipt['artifacts']['source']).is_file())
        self.assertEqual(read_json(self.runs / 'index.json')['runs'][-1]['status'], 'failed')
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_cancellation_retains_partial_outputs_and_restores_signal_handler(self):
        previous_handler = signal.getsignal(signal.SIGTERM)
        def cancel_after_polish(source, learning, provider, directory, progress):
            (directory / 'chunks' / 'completed-part.json').write_text('{}')
            raise PipelineCancelled('fixture cancel')
        with patch('papershelf_pipeline.synthesis.polish_reading', side_effect=cancel_after_polish):
            with self.assertRaises(PipelineCancelled):
                self.perform()
        directory = self.revisions()[0]
        self.assertEqual(read_json(directory / 'manifest.json')['status'], 'cancelled')
        self.assertTrue((directory / 'chunks' / 'completed-part.json').is_file())
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous_handler)
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_changed_main_or_supplement_refuses_revision_before_provider_or_output(self):
        for source_file in (self.paper, self.supplement):
            original = source_file.read_bytes()
            source_file.write_text('Modified source')
            with self.subTest(path=source_file), patch('papershelf_pipeline.provider.Provider') as provider:
                with self.assertRaisesRegex(PipelineError, '改变'):
                    revise(self.previous / 'manifest.json')
                provider.assert_not_called()
                self.assertFalse(self.revisions())
            source_file.write_bytes(original)
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_sigterm_is_recorded_as_cancelled_and_does_not_escape_to_original_handler(self):
        previous_handler = signal.getsignal(signal.SIGTERM)
        with patch('papershelf_pipeline.synthesis.polish_reading', side_effect=lambda *args: signal.raise_signal(signal.SIGTERM)):
            with self.assertRaises(PipelineCancelled):
                self.perform()
        self.assertEqual(read_json(self.revisions()[0] / 'manifest.json')['status'], 'cancelled')
        self.assertEqual(signal.getsignal(signal.SIGTERM), previous_handler)
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_source_changed_during_model_work_cannot_publish_completed_receipt(self):
        from papershelf_pipeline.synthesis import polish_reading
        def change_after_polish(*args):
            value = polish_reading(*args)
            self.paper.write_text('Changed while model was running')
            return value
        with patch('papershelf_pipeline.synthesis.polish_reading', side_effect=change_after_polish):
            with self.assertRaisesRegex(PipelineError, '改变'):
                self.perform()
        self.assertEqual(read_json(self.revisions()[0] / 'manifest.json')['status'], 'failed')
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_failed_or_cancelled_parent_is_never_treated_as_completed_draft(self):
        for status in ('failed', 'cancelled', 'running'):
            write_json(self.previous / 'manifest.json', {**self.original, 'status': status})
            with self.subTest(status=status), self.assertRaisesRegex(PipelineError, '完成或恢复'):
                self.perform()
            self.assertFalse(self.revisions())

    def test_missing_referenced_image_is_a_failed_revision_not_a_silent_omission(self):
        self.preview.unlink()
        with self.assertRaisesRegex(PipelineError, '图像资源缺失'):
            self.perform()
        self.assertEqual(read_json(self.revisions()[0] / 'manifest.json')['status'], 'failed')
        self.assertTrue((self.revisions()[0] / 'source.json').is_file())

    def test_editorial_constraints_are_copied_source_bound_and_audited(self):
        source = read_json(self.previous / 'source.json')
        correction = self.root / 'corrections.json'
        bundle = {'source_sha256': source['sha256'], 'reviewer': 'fixture source review', 'semantic_constraints': [
            {'source_ids': [source['blocks'][0]['id']], 'instruction': 'Preserve the reported temperature.',
             'verification': {'pages': [1], 'page_image_sha256': {'1': sha256(self.preview)}, 'method': 'fixture page inspection'}}]}
        bundle['reading_notes'] = [{'source_ids': [source['blocks'][0]['id']], 'text': 'Source-bound scientific caveat.',
                                    'verification': copy.deepcopy(bundle['semantic_constraints'][0]['verification'])}]
        write_json(correction, bundle)
        result = self.perform(editorial_corrections_path=correction)
        self.assertEqual(read_json(result['artifacts']['source'])['editorial_review_context'], bundle)
        self.assertEqual(read_json(result['artifacts']['editorial_corrections_input']), bundle)
        self.assertFalse(read_json(result['artifacts']['editorial_review'])['human_scientific_acceptance'])
        self.assertEqual(self.snapshot_run(), self.snapshot)
        # The UI's ordinary revise command passes no review path. It must not
        # silently discard verified source notes on the next edition.
        with patch('papershelf_pipeline.provider.Provider', EditingProvider):
            repeated = revise(result['manifest_path'], progress=lambda message: None)
        self.assertEqual(read_json(repeated['artifacts']['editorial_corrections_input']), bundle)
        updated = read_json(repeated['artifacts']['learning'])
        self.assertEqual(len(updated['clean_reading'][0]['editorial_notes']), 1)
        self.assertIn('Source-bound scientific caveat.', Path(repeated['artifacts']['paragraph_markdown']).read_text())
        # Reuse is subject to fresh page verification, not blind inheritance.
        repeated_source = read_json(repeated['artifacts']['source'])
        Path(repeated_source['figures'][0]['path']).write_bytes(b'changed page')
        with patch('papershelf_pipeline.provider.Provider', EditingProvider), self.assertRaisesRegex(PipelineError, '页图'):
            revise(repeated['manifest_path'], progress=lambda message: None)

    def test_editorial_only_creates_portable_exact_revision_without_provider_or_reprojection(self):
        parent = self.perform()
        directory = Path(parent['run_dir'])
        before = {str(p.relative_to(directory)): sha256(p) for p in directory.rglob('*') if p.is_file()}
        source = read_json(parent['artifacts']['source'])
        item = read_json(parent['artifacts']['learning'])['clean_reading'][0]
        corrected = item['translation'].replace('完整直译：', '核对译文：')
        units = [{**u, 'translation': u['translation'].replace('完整直译：', '核对译文：')} for u in item['translation_units']]
        review = self.root / 'exact-review.json'
        write_json(review, {'source_sha256': source['sha256'], 'reviewer': 'fixture', 'content_corrections': [
            {'id': 'verified-translation', 'section': 'clean_reading', 'reading_group_id': item['id'], 'field': 'translation',
             'source_ids': item['source_ids'], 'original': item['translation'], 'corrected': corrected, 'why': 'Fixture source review',
             'required_follow_through': {'translation_units_original': item['translation_units'], 'translation_units_corrected': units},
             'verification': {'pages': [1], 'page_image_sha256': {'1': sha256(source['figures'][0]['path'])}, 'method': 'fixture page inspection'}}]})
        with patch('papershelf_pipeline.provider.Provider', side_effect=AssertionError('No provider allowed')), \
             patch('papershelf_pipeline.reading.apply_reading_layer', side_effect=AssertionError('No regrouping allowed')), \
             patch('papershelf_pipeline.synthesis.consolidate_learning', side_effect=AssertionError('No synthesis allowed')):
            result = revise(parent['manifest_path'], editorial_corrections_path=review, editorial_only=True, progress=lambda _: None)
        self.assertEqual(result['status'], 'completed')
        self.assertEqual(result['revision_kind'], 'source_reviewed_revision')
        self.assertEqual(result['metrics']['provider_calls'], 0)
        self.assertEqual(result['metrics']['provider_usage'], {})
        self.assertEqual(read_json(result['artifacts']['source'])['blocks'], source['blocks'])
        self.assertEqual(read_json(result['artifacts']['source'])['reading_main_blocks'], source['reading_main_blocks'])
        edited = read_json(result['artifacts']['learning'])
        self.assertEqual(edited['clean_reading'][0]['translation'], corrected)
        self.assertEqual(edited['paragraphs'][0]['explanation'], corrected)
        for key in ('html', 'markdown', 'paragraph_markdown'):
            self.assertIn('核对译文', Path(result['artifacts'][key]).read_text())
        for key, path in result['artifacts'].items():
            self.assertEqual(result['artifact_sha256'][key], sha256(path))
            self.assertTrue(Path(path).is_relative_to(result['run_dir']))
        self.assertEqual(before, {str(p.relative_to(directory)): sha256(p) for p in directory.rglob('*') if p.is_file()})
        self.assertEqual(self.snapshot_run(), self.snapshot)
        # Strict mismatches create a failed new receipt, never change the parent.
        bundle = read_json(review)
        bundle['content_corrections'][0]['original'] = 'stale translation'
        write_json(review, bundle)
        with patch('papershelf_pipeline.provider.Provider', side_effect=AssertionError('No provider allowed')), self.assertRaisesRegex(PipelineError, '未匹配'):
            revise(parent['manifest_path'], editorial_corrections_path=review, editorial_only=True, progress=lambda _: None)
        self.assertEqual(before, {str(p.relative_to(directory)): sha256(p) for p in directory.rglob('*') if p.is_file()})

    def test_editorial_only_requires_explicit_review_and_complete_existing_reading(self):
        with patch('papershelf_pipeline.provider.Provider') as provider:
            with self.assertRaisesRegex(PipelineError, '明确提供'):
                revise(self.previous / 'manifest.json', editorial_only=True)
            self.assertFalse(self.revisions())
            review = self.root / 'review.json'
            write_json(review, {})
            with self.assertRaisesRegex(PipelineError, '已有完整'):
                revise(self.previous / 'manifest.json', editorial_only=True, editorial_corrections_path=review)
            provider.assert_not_called()
        self.assertEqual(self.snapshot_run(), self.snapshot)

    def test_ai_revision_uses_latest_visible_cards_without_resurrecting_old_drafts(self):
        learning = read_json(self.previous / 'learning.json')
        source_id = learning['methods'][0]['source_ids'][0]
        learning['methods'][0]['body'] = 'Discarded inaccurate draft'
        learning['consolidated'] = {'methods': [{'title': 'Reviewed method', 'body': 'The temperature was 300 K.',
                                               'source_ids': [source_id], 'kind': 'source'}]}
        write_json(self.previous / 'learning.json', learning)
        result = self.perform()
        updated = read_json(result['artifacts']['learning'])
        self.assertEqual(updated['consolidated']['methods'][0]['body'], 'The temperature was 300 K.')
        self.assertEqual(read_json(Path(result['run_dir']) / 'draft' / 'learning.json')['methods'][0]['body'], 'Discarded inaccurate draft')
        self.assertEqual(read_json(self.previous / 'learning.json'), learning)


if __name__ == '__main__':
    unittest.main()

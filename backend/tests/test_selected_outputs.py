"""Selected outputs must not trigger unrelated generation, exports or services."""
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from papershelf_pipeline.contracts import PipelineError, read_json
from papershelf_pipeline.pipeline import run
from papershelf_pipeline.summary_review import review_summary


class SelectedOutputsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.paper = self.root / 'paper.md'
        self.paper.write_text('Sample A: temperature 25 °C. All 1500 measurements are retained.\n\nThe rate is 2 s^-1.\n')
        self.request = {'source_path': str(self.paper), 'output_root': str(self.root / 'runs'),
                        'title': 'Synthetic source', 'reference_id': 'synthetic', 'mode': 'offline',
                        'fields': [{'name': 'temperature', 'type': 'number', 'unit': 'K'}]}

    def test_source_and_agent_are_local_even_with_ai_mode_and_broken_provider(self):
        for target in ('source', 'agent'):
            with self.subTest(target=target), patch('papershelf_pipeline.pipeline.Provider', side_effect=AssertionError('Unexpected provider')), patch('papershelf_pipeline.integrations.graphiti_ingest', side_effect=AssertionError('Unexpected graph')):
                receipt = run({**self.request, 'mode': 'llm', 'outputs': [target], 'provider': {}, 'graphiti': {'enabled': True}})
            self.assertEqual(receipt['outputs'], [target])
            self.assertEqual(receipt['metrics']['provider_calls'], 0)
            self.assertEqual(receipt['mode'], 'offline')
            artifacts = receipt['artifacts']
            self.assertNotIn('html', artifacts)
            self.assertNotIn('markdown', artifacts)
            self.assertNotIn('learning', artifacts)
            self.assertNotIn('extraction', artifacts)
            self.assertNotIn('csv', artifacts)
            self.assertEqual('agent' in artifacts, target == 'agent')
            self.assertIn('1500', Path(artifacts['source_markdown']).read_text())

    def test_reading_targets_publish_only_requested_format(self):
        for target, present, absent in [('guide', 'html', 'markdown'), ('markdown', 'markdown', 'html')]:
            with self.subTest(target=target):
                receipt = run({**self.request, 'outputs': [target]})
                artifacts = receipt['artifacts']
                self.assertIn(present, artifacts)
                for key in (absent, 'extraction', 'csv', 'graph', 'agent', 'presentation'):
                    self.assertNotIn(key, artifacts)
                self.assertFalse((Path(receipt['run_dir']) / ('learning.md' if absent == 'markdown' else 'learning.html')).exists())
                saved = read_json(Path(receipt['run_dir']) / 'request.json')
                self.assertEqual(saved['fields'], [])
                self.assertEqual(read_json(Path(receipt['run_dir']) / 'extraction.json')['fields'], [])
                fulltext = Path(artifacts['source_markdown']).read_text()
                self.assertNotIn('(learning.md)' if absent == 'markdown' else '(learning.html)', fulltext)

    def test_dataset_does_not_generate_a_learning_bundle(self):
        receipt = run({**self.request, 'outputs': ['dataset']})
        self.assertIn('csv', receipt['artifacts'])
        self.assertIn('graph', receipt['artifacts'])
        for key in ('learning', 'html', 'markdown', 'agent', 'presentation'):
            self.assertNotIn(key, receipt['artifacts'])
        self.assertFalse((Path(receipt['run_dir']) / 'learning.json').exists())

    def test_invalid_outputs_rejected_before_creating_run(self):
        for outputs in ([], ['all'], ['guide', 'guide'], 'guide', [None]):
            with self.subTest(outputs=outputs), self.assertRaises(PipelineError):
                run({**self.request, 'outputs': outputs})
        self.assertFalse((self.root / 'runs').exists())

    def test_failure_receipt_retains_selected_output_for_retry(self):
        with patch('papershelf_pipeline.pipeline.Provider', side_effect=PipelineError('Model unavailable')):
            with self.assertRaises(PipelineError):
                run({**self.request, 'outputs': ['presentation'], 'mode': 'llm'})
        receipts = list((self.root / 'runs').glob('*/manifest.json'))
        self.assertEqual(len(receipts), 1)
        saved = read_json(receipts[0])
        self.assertEqual(saved['outputs'], ['presentation'])
        self.assertEqual(saved['status'], 'failed')

    def test_reading_retry_reaches_changed_provider_with_or_without_source_checkpoint(self):
        for before_source in (False, True):
            with self.subTest(before_source=before_source):
                output_root = self.root / ('before-source' if before_source else 'after-source')
                request = {**self.request, 'output_root': str(output_root), 'outputs': ['guide'],
                           'mode': 'llm', 'provider': {'base_url': 'https://old.invalid/v1', 'model': 'test'}}
                old_provider = Mock()
                old_provider.json.side_effect = PipelineError('Old provider HTTP 404')
                initial = patch('papershelf_pipeline.pipeline.Provider', side_effect=PipelineError('Missing provider configuration')) if before_source else patch('papershelf_pipeline.pipeline.Provider', return_value=old_provider)
                with initial, self.assertRaises(PipelineError):
                    run(request)
                old_manifest = next(output_root.glob('*/manifest.json'))
                self.assertEqual((old_manifest.parent / 'source.json').exists(), not before_source)
                original = old_manifest.read_bytes()
                new_provider = Mock()
                new_provider.json.side_effect = PipelineError('New provider reached')
                with patch('papershelf_pipeline.pipeline.Provider', return_value=new_provider):
                    with self.assertRaisesRegex(PipelineError, 'New provider reached'):
                        run({**request, 'resume_from': str(old_manifest.parent),
                             'provider': {'base_url': 'https://fixed.invalid/v1', 'model': 'test'}})
                self.assertGreater(new_provider.json.call_count, 0)
                self.assertEqual(old_manifest.read_bytes(), original)
                self.assertEqual(len(list(output_root.glob('*/manifest.json'))), 2)

    def test_summary_revision_retains_selected_format_without_creating_agent(self):
        for target in ('guide', 'markdown'):
            receipt = run({**self.request, 'outputs': [target]})
            learning = read_json(receipt['artifacts']['learning'])
            source = read_json(receipt['artifacts']['source'])
            correction = self.root / 'correction.json'
            correction.write_text(json.dumps([{'field': 'overview', 'original': learning['overview'],
                'corrected': 'Synthetic review overview.', 'source_sha256': source['sha256'],
                'source_ids': [source['blocks'][0]['id']], 'actor': 'test', 'reason': 'Synthetic correction'}]))
            revised = review_summary(receipt['manifest_path'], correction)
            self.assertEqual(revised['outputs'], [target])
            self.assertNotIn('agent', revised['artifacts'])
            self.assertNotIn('markdown' if target == 'guide' else 'html', revised['artifacts'])
            self.assertEqual(read_json(receipt['artifacts']['learning'])['overview'], learning['overview'])


if __name__ == '__main__':
    unittest.main()

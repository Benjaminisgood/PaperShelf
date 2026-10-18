from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from papershelf_pipeline.contracts import PipelineError, read_json, sha256, write_json
from papershelf_pipeline.pipeline import run
from papershelf_pipeline.summary_review import corrected_paragraphs, corrected_summary, review_summary


class SummaryReviewTests(unittest.TestCase):
    def setUp(self):
        self.source = {'sha256': 'exact-pdf', 'blocks': [{'id': 'p1-g1'}]}
        self.learning = {'overview': '原文未注明单位。', 'reading_route': ['查看已实施的UQ结果。']}
        self.edit = {'field': 'reading_route', 'source_sha256': 'exact-pdf', 'source_ids': ['p1-g1'],
                     'original': self.learning['reading_route'], 'corrected': ['区分噪声敏感性与尚未实施的UQ扩展。'],
                     'actor': 'Codex QA', 'reason': '原文仅把贝叶斯估计作为后续扩展。'}

    def test_stale_hash_value_or_source_cannot_change_learning(self):
        for fault in ('hash', 'original', 'source', 'field', 'type'):
            with self.subTest(fault=fault):
                edit = copy.deepcopy(self.edit)
                if fault == 'hash': edit['source_sha256'] = 'different'
                elif fault == 'original': edit['original'] = ['other version']
                elif fault == 'source': edit['source_ids'] = ['nonexistent']
                elif fault == 'field': edit['field'] = 'paragraphs'
                else: edit['corrected'] = 'not a list'
                with self.assertRaises(PipelineError): corrected_summary(self.learning, self.source, [edit])
        self.assertEqual(self.learning['reading_route'], ['查看已实施的UQ结果。'])

    def test_verified_math_glyph_review_survives_whitespace_normalization(self):
        source = {'sha256': 'exact-pdf', 'blocks': [{'id': 'p7-g259', 'text': '\t\n',
                  'source_role_hint': 'whitespace', 'source_anchor': '', 'layout_observations': [
                      {'source_sha256': 'exact-pdf', 'source_ids': ['p7-g259'],
                       'observation': '原PDF中为矩阵右方括号。'}]}]}
        paragraph = {'source_id': 'p7-g259', 'source_anchor': '', 'key_sentence': '',
                     'explanation': '原版面中的空白间隔。', 'reasoning': '版面标记。'}
        original = {'paragraphs': [paragraph]}
        edits = [{'source_sha256': 'exact-pdf', 'source_ids': ['p7-g259'], 'field': field,
                  'original': paragraph[field], 'corrected': value, 'actor': 'Codex QA',
                  'reason': '原PDF核验该控制字形属于矩阵。'} for field, value in (
                      ('explanation', 'Eq19矩阵右侧的闭合方括号。'), ('reasoning', '属于矩阵公式标点。'))]
        result = corrected_paragraphs(original, source, edits)
        self.assertEqual(result['paragraphs'][0]['explanation'], edits[0]['corrected'])
        self.assertEqual(result['paragraphs'][0]['reasoning'], edits[1]['corrected'])
        self.assertEqual(original['paragraphs'][0]['explanation'], edits[0]['original'])
        # Without verified layout evidence, model text cannot override blank-layout handling.
        source['blocks'][0]['layout_observations'] = []
        with self.assertRaises(PipelineError): corrected_paragraphs(original, source, edits)

    def test_reexport_is_new_run_without_provider_and_keeps_old_artifacts(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paper = root / 'paper.md'; paper.write_text('The time step is 0.4 time unit.')
            original = run({'source_path': str(paper), 'output_root': str(root / 'runs'), 'mode': 'offline'})
            old = Path(original['run_dir']); before = {p.relative_to(old): sha256(p) for p in old.rglob('*') if p.is_file()}
            source = read_json(old / 'source.json'); learning = read_json(old / 'learning.json')
            edit = {**self.edit, 'field': 'overview', 'source_sha256': source['sha256'],
                    'source_ids': [source['blocks'][0]['id']], 'original': learning['overview'],
                    'corrected': '原文只报告0.4 time unit，未指明秒或无量纲。'}
            correction_path = root / 'review.json'; write_json(correction_path, [edit])
            with patch('papershelf_pipeline.provider.Provider', side_effect=AssertionError('No model request allowed')):
                reviewed = review_summary(old / 'manifest.json', correction_path)
            new = Path(reviewed['run_dir']); self.assertNotEqual(new, old)
            self.assertEqual(before, {p.relative_to(old): sha256(p) for p in old.rglob('*') if p.is_file()})
            self.assertEqual(read_json(new / 'learning-before-summary-review.json'), learning)
            self.assertEqual(read_json(new / 'learning.json')['overview'], edit['corrected'])
            for key in ('html', 'markdown'):
                self.assertIn(edit['corrected'], Path(reviewed['artifacts'][key]).read_text())
            audit = read_json(new / 'summary-review.json')
            self.assertEqual(audit['corrections'][0], edit); self.assertEqual(audit['provider_calls'], 0)
            self.assertFalse(audit['human_scientific_acceptance'])
            self.assertEqual(read_json(new / 'extraction.json'), read_json(old / 'extraction.json'))
            self.assertEqual(read_json(new / 'agent/extraction.json'), read_json(old / 'extraction.json'))
            for key, path in reviewed['artifacts'].items():
                self.assertTrue(Path(path).is_relative_to(new))
                self.assertEqual(sha256(path), reviewed['artifact_sha256'][key])
            self.assertEqual(read_json(new.parent / 'index.json')['runs'][-1]['run_id'], reviewed['run_id'])
            # A modified published input cannot silently become a new reviewed output.
            (old / 'learning.json').write_text('{}')
            with self.assertRaises(PipelineError): review_summary(old / 'manifest.json', correction_path)


if __name__ == '__main__':
    unittest.main()

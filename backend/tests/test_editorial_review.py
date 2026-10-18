import copy
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError, sha256, write_json, read_json
from papershelf_pipeline.editorial_review import load_editorial_review, apply_editorial_review
from papershelf_pipeline.rendering import render_guide


class EditorialReviewTests(unittest.TestCase):
    def test_exact_content_correction_updates_the_consolidated_body_visible_to_readers(self):
        source = {'sha256': 'hash', 'path': 'paper.pdf', 'engine': 'fixture', 'pages': [{'page': 1, 'text': 'Evidence'}],
                  'figures': [], 'blocks': [{'id': 'a', 'page': 1, 'text': 'Evidence'}]}
        claim = {'title': 'Claim', 'body': 'Incorrect original claim', 'source_ids': ['a'], 'kind': 'uncertain'}
        learning = {'mode': 'llm', 'title': 'Review', 'overview': 'Overview', 'paragraphs': [], 'gaps': [],
                    **{key: [] for key in ('methods', 'findings', 'transfer', 'equations', 'figures_tables', 'quiz', 'glossary')},
                    'critique': [copy.deepcopy(claim)], 'consolidated': {'critique': [copy.deepcopy(claim)]}}
        bundle = {'reviewer': 'fixture', 'content_corrections': [{'section': 'critique', 'field': 'body',
                  'original': claim['body'], 'corrected': 'Corrected source-bound claim', 'source_ids': ['a'], 'why': 'Original evidence'}]}
        with tempfile.TemporaryDirectory() as name:
            apply_editorial_review(learning, source, bundle, Path(name))
            artifacts = render_guide(source, learning, {'records': []}, Path(name), [])
            for key in ('html', 'markdown'):
                visible = Path(artifacts[key]).read_text()
                self.assertIn('Corrected source-bound claim', visible)
                self.assertNotIn('Incorrect original claim', visible)
        record = learning['editorial_review']['records'][0]
        self.assertEqual(record['status'], 'applied_exact_match')
        self.assertEqual(record['locations'], ['critique[0].body', 'consolidated.critique[0].body'])
        self.assertEqual(record['source_ids'], ['a'])

    def test_resolving_main_formula_does_not_clear_same_number_supplement_warning(self):
        source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1}, {'id': 's-a', 'page': 1, 'document_id': 's1'}]}
        main_note = '公式 Eq. 1（来源 a）包含未可靠映射字形。'
        supplement_note = '公式 Eq. 1（来源 s-a）包含未可靠映射字形。'
        supplement = {'label': 'Eq. 1', 'latex': 'raw SI', 'source_ids': ['s-a']}
        learning = {'equations': [], 'unresolved_equations': [{'label': 'Eq. 1', 'latex': 'raw main', 'source_ids': ['a']}, copy.deepcopy(supplement)],
                    'gaps': [main_note, supplement_note]}
        bundle = {'reviewer': 'fixture', 'equations': [{'equation': {'label': 'Eq. 1', 'latex': 'main=1', 'source_ids': ['a']}, 'verification': {}}]}
        with tempfile.TemporaryDirectory() as name:
            apply_editorial_review(learning, source, bundle, Path(name))
        self.assertEqual(learning['unresolved_equations'], [supplement])
        self.assertEqual(learning['gaps'], [supplement_note])
        self.assertEqual(len(learning['process_notes']), 1)
        self.assertTrue(learning['process_notes'][0].startswith(main_note))
        self.assertNotIn('s-a', learning['process_notes'][0])

    def test_restored_first_equation_precedes_existing_later_equations(self):
        for shared_context in (False, True):
            with self.subTest(shared_context=shared_context):
                source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1}, {'id': 'b', 'page': 2}, {'id': 's-a', 'page': 1, 'document_id': 's1'}]}
                later_ids = ['a'] if shared_context else ['b']
                learning = {'equations': [{'label': 'Eq. 2', 'latex': 'later=2', 'source_ids': later_ids},
                                          {'label': 'Eq. 1', 'latex': 'supplement=1', 'source_ids': ['s-a']}],
                            'unresolved_equations': [{'label': 'Eq. 1', 'latex': 'raw first', 'source_ids': ['a']}]}
                bundle = {'reviewer': 'fixture', 'equations': [{'equation': {'label': 'Eq. 1', 'latex': 'first=1', 'source_ids': ['a']}, 'verification': {}}]}
                with tempfile.TemporaryDirectory() as name:
                    apply_editorial_review(learning, source, bundle, Path(name))
                self.assertEqual([item['latex'] for item in learning['equations']], ['first=1', 'later=2', 'supplement=1'])
                self.assertEqual(learning['equations'][-1]['source_ids'], ['s-a'])

    def test_embedded_supplement_equation_numbers_do_not_replace_main_equations(self):
        source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1}, {'id': 'b', 'page': 9}]}
        learning = {'equations': [{'label': 'Eq. 1', 'latex': 'main', 'source_ids': ['a']},
                                  {'label': 'S1 (Fragment)', 'latex': 'fragment', 'source_ids': ['b']}]}
        bundle = {'reviewer': 'test', 'equations': [{'equation': {'label': 'S1', 'latex': 'complete SI', 'source_ids': ['b']},
                   'replace_labels': ['S1 (Fragment)'], 'verification': {}}]}
        with tempfile.TemporaryDirectory() as name:
            apply_editorial_review(learning, source, bundle, Path(name))
        self.assertEqual([(e['label'], e['latex']) for e in learning['equations']], [('Eq. 1', 'main'), ('S1', 'complete SI')])

    def test_rejects_changed_source_or_page_evidence_before_rewriting(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            page = root / 'page.jpg'
            page.write_bytes(b'reviewed page fixture')
            source = {'sha256': 'source-hash', 'blocks': [{'id': 'p1-g1', 'page': 1, 'text': 'raw equation'}],
                      'figures': [{'page': 1, 'path': str(page)}]}
            verification = {'pages': [1], 'page_image_sha256': {'1': sha256(page)}, 'method': 'fixture source review'}
            bundle = {'source_sha256': 'source-hash', 'reviewer': 'test', 'equations': [
                {'equation': {'label': 'Eq. 1', 'latex': 'x=1', 'meaning': 'original', 'symbols': [], 'source_ids': ['p1-g1']}, 'verification': verification}]}
            path = root / 'review.json'
            write_json(path, bundle)
            self.assertEqual(load_editorial_review(path, source), bundle)
            with self.assertRaises(PipelineError):
                load_editorial_review(path, {**source, 'sha256': 'changed'})
            page.write_bytes(b'other page')
            with self.assertRaises(PipelineError):
                load_editorial_review(path, source)

    def test_duplicate_formula_replacement_and_exact_prose_edits_keep_audit(self):
        source = {'sha256': 'source-hash', 'blocks': [{'id': 'a', 'page': 1, 'text': 'original'}]}
        learning = {'equations': [{'label': 'Eq. (1)', 'latex': 'bad one', 'source_ids': ['a']}, {'label': '式 1', 'latex': 'bad two', 'source_ids': ['a']}],
                    'critique': [{'body': 'old claim', 'source_ids': ['a']}]}
        original = copy.deepcopy(learning)
        bundle = {'reviewer': 'test', 'equations': [{'equation': {'label': 'Eq. 1', 'latex': 'x=1', 'meaning': 'original notation', 'symbols': [], 'source_ids': ['a']}, 'why': 'page review', 'verification': {}}],
                  'content_corrections': [{'section': 'critique', 'field': 'body', 'source_ids': ['a'], 'original': 'different draft', 'corrected': 'new claim', 'why': 'not matched'}]}
        with tempfile.TemporaryDirectory() as name:
            artifacts = apply_editorial_review(learning, source, bundle, Path(name))
            self.assertEqual(len(learning['equations']), 1)
            self.assertEqual(learning['equations'][0]['latex'], 'x=1')
            self.assertEqual(learning['critique'][0]['body'], 'old claim')
            self.assertEqual(read_json(artifacts['editorial_review_draft']), original)
            receipt = read_json(artifacts['editorial_review'])
            self.assertEqual(len(receipt['records'][0]['original']), 2)
            self.assertFalse(receipt['human_scientific_acceptance'])


if __name__ == '__main__':
    unittest.main()

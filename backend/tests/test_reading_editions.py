import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.reading_editions import render_reading_editions


class ReadingEditionTests(unittest.TestCase):
    def test_clean_fulltext_retains_numeric_conditions_and_provenance_separately(self):
        source = {'blocks': [
            {'id': 'p1-g1', 'page': 1, 'text': 'Copy-\nright', 'include_in_reading': False, 'reading_role': 'publisher_notice'},
            {'id': 'p2-g1', 'page': 2, 'text': 'measure-\nments at 0.4 time unit'},
            {'id': 'p3-g1', 'page': 3, 'text': 'with 1%, 5%, and 9% noise.'},
        ]}
        learning = {'title': 'Example', 'clean_reading': [{'id': 'p2-g1', 'source_ids': ['p2-g1', 'p3-g1'], 'text': 'Measurements at 0.4 time unit with 1%, 5%, and 9% noise.', 'kind': 'body', 'editing_notes': ['Restored paragraph continuation.']}], 'paragraphs': []}
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory / 'source.md').write_text('untouched original')
            artifacts = render_reading_editions(source, learning, directory)
            text = Path(artifacts['source_markdown']).read_text()
            self.assertIn('0.4 time unit with 1%, 5%, and 9% noise.', text)
            self.assertNotIn('Copy-', text)
            self.assertNotIn('measure-\nments', text)
            self.assertIn('source-index.md#src-p3-g1', text)
            self.assertIn('Copy-\nright', Path(artifacts['source_index']).read_text())
            self.assertEqual(Path(artifacts['raw_source_markdown']).read_text(), 'untouched original')

    def test_all_nonprose_document_does_not_fall_back_to_noisy_raw_body(self):
        source = {'blocks': [{'id': 'p1-g1', 'page': 1, 'text': 'Licensed material', 'include_in_reading': False}], 'reading_main_blocks': []}
        with tempfile.TemporaryDirectory() as name:
            artifacts = render_reading_editions(source, {'title': 'Empty', 'paragraphs': []}, Path(name))
            self.assertNotIn('Licensed material', Path(artifacts['source_markdown']).read_text())
            self.assertIn('Licensed material', Path(artifacts['source_index']).read_text())

    def test_equation_fragments_preserved_in_linked_appendix(self):
        block = {'id': 'p1-g1', 'page': 1, 'text': 'k =\nA exp(-Ea/RT)', 'reading_main': False}
        source = {'blocks': [block], 'reading_main_blocks': [], 'reading_fragments': [{**block, 'source_ids': ['p1-g1']}]}
        with tempfile.TemporaryDirectory() as name:
            artifacts = render_reading_editions(source, {'title': 'Formula', 'paragraphs': []}, Path(name))
            self.assertIn('layout-fragments.md', Path(artifacts['source_markdown']).read_text())
            self.assertIn(block['text'], Path(artifacts['layout_fragments']).read_text())

    def test_only_page_reviewed_equations_rejoin_original_language_reading_order(self):
        source = {'blocks': [{'id': 'a', 'page': 1, 'text': 'Before'}, {'id': 'b', 'page': 1, 'text': 'garbled formula'}, {'id': 'c', 'page': 1, 'text': 'After'}]}
        learning = {'title': 'Formula', 'paragraphs': [], 'clean_reading': [
            {'id': 'a', 'source_ids': ['a'], 'text': 'Before'}, {'id': 'c', 'source_ids': ['c'], 'text': 'After'}],
            'equations': [{'label': 'Eq. 1', 'latex': 'k=A', 'source_ids': ['b'], 'editorial_verification': {'human_scientific_acceptance': False}},
                          {'label': 'Eq. 2', 'latex': 'invented', 'source_ids': ['b']}]}
        with tempfile.TemporaryDirectory() as name:
            artifacts = render_reading_editions(source, learning, Path(name))
            text = Path(artifacts['source_markdown']).read_text()
            self.assertLess(text.index('Before'), text.index('k=A'))
            self.assertLess(text.index('k=A'), text.index('After'))
            self.assertNotIn('invented', text)
            self.assertIn('garbled formula', Path(artifacts['source_index']).read_text())

    def test_supplement_heading_precedes_its_first_formula_even_without_supplement_prose(self):
        for with_supplement_prose in (False, True):
            with self.subTest(with_supplement_prose=with_supplement_prose):
                blocks = [{'id': 'main-prose', 'page': 1, 'text': 'Main prose.'},
                          {'id': 'main-eq', 'page': 1, 'text': 'Main raw formula'},
                          {'id': 's-eq', 'page': 1, 'document_id': 's1', 'document': 'SI.pdf', 'text': 'Supplement raw formula'}]
                groups = [{'id': 'main-prose', 'source_ids': ['main-prose'], 'text': 'Main prose.'}]
                if with_supplement_prose:
                    blocks.append({'id': 's-prose', 'page': 1, 'document_id': 's1', 'document': 'SI.pdf', 'text': 'Supplement prose.'})
                    groups.append({'id': 's-prose', 'source_ids': ['s-prose'], 'text': 'Supplement prose.'})
                learning = {'title': 'Paper and supplement', 'paragraphs': [], 'clean_reading': groups,
                            'equations': [{'label': 'Eq. 1', 'latex': 'SI=1', 'source_ids': ['s-eq'], 'editorial_verification': {'human_scientific_acceptance': False}},
                                          {'label': 'Eq. 1', 'latex': 'main=1', 'source_ids': ['main-eq'], 'editorial_verification': {'human_scientific_acceptance': False}}]}
                with tempfile.TemporaryDirectory() as name:
                    artifacts = render_reading_editions({'blocks': blocks}, learning, Path(name))
                    text = Path(artifacts['source_markdown']).read_text()
                    raw = Path(artifacts['source_index']).read_text()
                    self.assertLess(text.index('main=1'), text.index('## 补充材料：SI.pdf'))
                    self.assertLess(text.index('## 补充材料：SI.pdf'), text.index('SI=1'))
                    self.assertEqual(text.count('## 补充材料：SI.pdf'), 1)
                    if with_supplement_prose:
                        self.assertLess(text.index('SI=1'), text.index('Supplement prose.'))
                    for block in blocks:
                        self.assertIn('source-index.md#src-' + block['id'], text)
                        self.assertIn(block['text'], raw)


if __name__ == '__main__':
    unittest.main()

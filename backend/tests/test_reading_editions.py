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


if __name__ == '__main__':
    unittest.main()

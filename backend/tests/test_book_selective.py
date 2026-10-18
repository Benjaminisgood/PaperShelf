"""Chapter packages must honor the requested format and retain valid local links."""
from __future__ import annotations

import copy
import re
import tempfile
import unittest
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import unquote, urlsplit

from papershelf_pipeline.book import render_book
from papershelf_pipeline.contracts import PipelineError, read_json
from papershelf_pipeline.rendering import render_guide


class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        self.links.extend(value for key, value in attrs if key == 'href' and value)


class SelectiveBookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = {
            'path': str(self.root/'book.pdf'), 'sha256': 'a'*64,
            'document_set_sha256': 'b'*64, 'engine': 'fixture',
            'documents': [{'id': 'main', 'name': 'book.pdf', 'page_count': 2}],
            'pages': [{'document_id': 'main', 'page': 1}, {'document_id': 'main', 'page': 2}],
            'blocks': [{'id': f'b{page}', 'document_id': 'main', 'document': 'book.pdf',
                        'page': page, 'text': f'Complete chapter text {page}.'} for page in [1, 2]],
            'figures': [],
        }
        self.learning = {
            'title': 'Selective chapter test', 'mode': 'offline', 'overview': 'Full book overview',
            'paragraphs': [{'source_id': f'b{page}', 'explanation': f'Complete chapter text {page}.'} for page in [1, 2]],
            **{key: [] for key in ['methods', 'findings', 'critique', 'transfer', 'equations', 'figures_tables', 'glossary', 'gaps']},
            'quiz': [{'question': 'Compare both chapters', 'answer': 'Read both source pages.', 'source_ids': ['b1', 'b2']}],
        }
        self.extraction = {'records': []}
        self.config = {'chapters': [{'title': 'First [chapter]', 'start_page': 1, 'end_page': 1},
                                    {'title': 'Second chapter', 'start_page': 2, 'end_page': 2}]}

    def render(self, formats=None, *, full_guide=True):
        source, learning, extraction = copy.deepcopy((self.source, self.learning, self.extraction))
        if full_guide:
            render_guide(source, learning, extraction, self.root, [], formats=formats)
        return render_book(source, learning, extraction, self.config, self.root, [], formats=formats)

    def assert_valid_local_links(self, formats):
        for kind in formats:
            suffix = 'html' if kind == 'html' else 'md'
            for path in self.root.rglob(f'*.{suffix}'):
                if kind == 'html':
                    parser = Links()
                    parser.feed(path.read_text())
                    links = parser.links
                else:
                    links = re.findall(r'\]\(([^)]+)\)', path.read_text())
                for link in links:
                    target = urlsplit(link)
                    if target.scheme or not target.path:
                        continue
                    self.assertTrue((path.parent/unquote(target.path)).is_file(), (path, link))

    def test_html_only_has_no_markdown_files_or_links(self):
        result = self.render({'html'})
        self.assertEqual(Path(result['html']).name, 'index.html')
        self.assertNotIn('markdown', result)
        self.assertFalse(list(self.root.rglob('*.md')))
        self.assert_valid_local_links({'html'})
        self.assertIn('../chapter-002/learning.html#src-b2', (self.root/'chapters/chapter-001/learning.html').read_text())
        book = read_json(result['book_manifest'])
        self.assertEqual(sum(chapter['source_blocks'] for chapter in book['chapters']), 2)
        self.assertTrue(all(set(chapter['artifacts']) == {'html'} for chapter in book['chapters']))

    def test_markdown_only_has_own_index_and_chapter_backlinks(self):
        result = self.render({'markdown'})
        self.assertEqual(Path(result['markdown']).name, 'index.md')
        self.assertEqual(result['book_index'], result['markdown'])
        self.assertNotIn('html', result)
        self.assertFalse(list(self.root.rglob('*.html')))
        self.assert_valid_local_links({'markdown'})
        self.assertIn(r'First \[chapter\]', Path(result['markdown']).read_text())
        book = read_json(result['book_manifest'])
        for chapter in book['chapters']:
            self.assertTrue(chapter['file'].endswith('.md'))
            self.assertEqual(set(chapter['artifacts']), {'markdown'})
            text = Path(chapter['artifacts']['markdown']).read_text()
            self.assertIn('[← 返回全书目录](../../index.md)', text)
            self.assertIn(f'Complete chapter text {chapter["start_page"]}.', text)
            other_page = 2 if chapter['start_page'] == 1 else 1
            self.assertNotIn(f'Complete chapter text {other_page}.', text)

    def test_default_keeps_both_formats_with_valid_indexes(self):
        result = self.render()
        self.assertEqual(Path(result['html']).name, 'index.html')
        self.assertEqual(Path(result['markdown']).name, 'index.md')
        self.assertTrue(Path(result['full_html']).is_file())
        self.assertTrue(Path(result['full_markdown']).is_file())
        self.assert_valid_local_links({'html', 'markdown'})

    def test_book_without_complete_guide_omits_dangling_links(self):
        result = self.render({'html', 'markdown'}, full_guide=False)
        self.assertNotIn('full_html', result)
        self.assertNotIn('full_markdown', result)
        self.assert_valid_local_links({'html', 'markdown'})

    def test_invalid_format_is_rejected_before_creating_chapters(self):
        for formats in [set(), {'presentation'}]:
            with self.assertRaises(PipelineError):
                render_book(self.source, self.learning, self.extraction, self.config, self.root, [], formats=formats)
        self.assertFalse((self.root/'chapters').exists())


if __name__ == '__main__':
    unittest.main()

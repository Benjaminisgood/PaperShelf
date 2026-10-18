import copy
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from papershelf_pipeline.paragraphs import group_page_blocks, validate_grouping


def line(text, x, y, width=220, size=10, font='Body', direction=(1, 0)):
    box = [x, y, x + width, y + size]
    return {'bbox': box, 'dir': direction, 'spans': [
        {'text': text, 'bbox': box, 'size': size, 'font': font,
         'flags': 0, 'origin': [x, y + size * .8]}]}


def fixture(*line_groups):
    blocks, raw = [], []
    for index, lines in enumerate(line_groups):
        boxes = [item['bbox'] for item in lines]
        box = [min(b[0] for b in boxes), min(b[1] for b in boxes),
               max(b[2] for b in boxes), max(b[3] for b in boxes)]
        text = ''.join(''.join(s['text'] for s in item['spans']) + '\n' for item in lines)
        blocks.append({'type': 0, 'number': index, 'bbox': box, 'lines': lines})
        raw.append({'id': f'b{index}', 'block_number': index, 'text': text, 'bbox': box})
    page = SimpleNamespace(rect=SimpleNamespace(width=600, height=800),
                           get_text=lambda *args, **kwargs: {'blocks': blocks})
    return page, raw


class ParagraphTests(unittest.TestCase):
    def test_wrapped_single_line_blocks_keep_last_short_line_and_hyphens(self):
        page, raw = fixture([line('The complete original paragraph begins here with chem-', 40, 40, 500)],
                            [line('ical systems.', 40, 56, 70)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['text'], ''.join(item['text'] for item in raw))
        self.assertEqual(result[0]['raw_block_ids'], ['b0', 'b1'])

    def test_two_columns_read_in_column_order_without_cross_merges(self):
        page, raw = fixture([line('Left first paragraph starts here', 40, 40)],
                            [line('Right first paragraph starts here', 320, 40)],
                            [line('and keeps all its original lines.', 40, 56)],
                            [line('and retains the right column.', 320, 56)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 2)
        self.assertEqual(result[0]['raw_block_ids'], ['b0', 'b2'])
        self.assertEqual(result[1]['raw_block_ids'], ['b1', 'b3'])

    def test_mixed_column_block_splits_while_retaining_exact_offsets(self):
        page, raw = fixture([line('Main right paragraph starts here', 320, 40),
                             line('and remains in this column.', 320, 56),
                             line('Department at a different column', 40, 56, size=8),
                             line('Address and contact information', 40, 68, size=8)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 2)
        self.assertIn('Department', result[0]['text'])
        self.assertNotIn('Department', result[1]['text'])
        self.assertTrue(all(item['raw_block_ids'] == ['b0'] for item in result))
        validate_grouping(result, raw)

    def test_justified_word_fragments_remain_in_their_full_paragraph(self):
        page, raw = fixture([line('The complete preceding line belongs here', 40, 40),
                             line('pathway', 40, 56, 35),
                             line('is', 83, 56, 8),
                             line('modeled', 99, 56, 35),
                             line('using', 142, 56, 25),
                             line('the', 175, 56, 15),
                             line('following', 198, 56, 40),
                             line('equations.', 40, 72, 50)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]['text'], raw[0]['text'])
        self.assertEqual(len(result[0]['lines']), 8)

    def test_same_raw_block_does_not_join_aligned_columns_across_gutter(self):
        lines = []
        for y in (40, 56, 72):
            lines.extend([line('The left column with enough words', 40, y, 249),
                          line('The right column with enough words', 300, y, 249)])
        page, raw = fixture(lines)
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 2)
        self.assertNotIn('right', result[0]['text'])
        self.assertNotIn('left', result[1]['text'])

    def test_centered_multiline_title_does_not_absorb_authors(self):
        page, raw = fixture([line('Autonomous Discovery of Chemical Reactions', 60, 40, 480, 16, 'Title')],
                            [line('Using Neural Networks', 190, 59, 220, 16, 'Title')],
                            [line('First Author and Second Author', 200, 86, 200, 11, 'Authors')],
                            [line('Body prose starts with ordinary text', 40, 130, 500, 10)],
                            [line('and continues with the complete source.', 40, 146, 450, 10)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 3)
        self.assertEqual(len(result[0]['lines']), 2)
        self.assertEqual(result[1]['raw_block_ids'], ['b2'])

    def test_indented_new_paragraph_and_heading_are_separate(self):
        page, raw = fixture([line('One paragraph finishes with a sentence.', 40, 40, 210)],
                            [line('The next paragraph is indented here', 52, 56, 208)],
                            [line('and continues at the left margin.', 40, 72, 210)],
                            [line('1 Introduction', 40, 88, 120)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 3)
        self.assertEqual(result[1]['raw_block_ids'], ['b1', 'b2'])

    def test_rotated_margins_and_numeric_rows_do_not_become_prose(self):
        page, raw = fixture([line('A scientific paragraph starts here', 40, 40)],
                            [line('with one complete line after it.', 40, 56)],
                            [line('Licence printed along the page margin', 5, 40, 10, direction=(0, -1))],
                            [line('1.0 2.0 3.0', 40, 90, 200)],
                            [line('4.0 5.0 6.0', 40, 106, 200)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 4)
        self.assertIn('Licence', result[-1]['text'])
        self.assertEqual(result[-1]['source_role_hint'], 'marginal')
        self.assertEqual(sum('1.0' in p['text'] and '4.0' in p['text'] for p in result), 0)

    def test_role_hint_distinguishes_page_numbers_whitespace_and_body_digits(self):
        page, raw = fixture([line('7', 300, 760, 6)],
                            [line('8', 300, 20, 6)],
                            [line('1', 300, 400, 6)],
                            [line(' ', 40, 780, 4)])
        result = group_page_blocks(page, raw)
        by_text = {p['text'].strip(): p for p in result}
        self.assertEqual(by_text['7']['source_role_hint'], 'page_number')
        self.assertEqual(by_text['8']['source_role_hint'], 'page_number')
        self.assertNotIn('source_role_hint', by_text['1'])
        self.assertEqual(by_text['']['source_role_hint'], 'whitespace')

    def test_mismatch_falls_back_to_complete_raw_block(self):
        page, raw = fixture([line('Original PDF text.', 40, 40)])
        raw[0]['text'] = 'Unmatched raw text\nwith all of its lines.\n'
        result = group_page_blocks(page, raw)
        self.assertEqual(result[0]['text'], raw[0]['text'])
        self.assertTrue(result[0]['lines'][0]['fallback'])
        self.assertTrue(result[0]['grouping_notes'])

    def test_duplicate_extraction_uses_original_block_number(self):
        page, raw = fixture([line('Same overprinted source.', 40, 40)],
                            [line('Same overprinted source.', 40, 40)])
        result = group_page_blocks(page, raw)
        self.assertEqual(len(result), 2)
        self.assertFalse(any(l.get('fallback') for p in result for l in p['lines']))

    def test_validation_rejects_duplicate_omitted_modified_and_invalid_slices(self):
        page, raw = fixture([line('The original full text.', 40, 40)])
        paragraphs = group_page_blocks(page, raw)
        for mutation in ('duplicate', 'omit', 'modified', 'negative'):
            result = copy.deepcopy(paragraphs)
            if mutation == 'duplicate': result += copy.deepcopy(result)
            elif mutation == 'omit': result = []
            elif mutation == 'modified': result[0]['text'] = 'Different text'
            else: result[0]['lines'][0]['start'] = -1
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                validate_grouping(result, raw)

    def test_real_papers_preserve_all_raw_characters_and_critical_layouts(self):
        import pymupdf
        root = Path(__file__).resolve().parents[2] / 'Examples'
        paths = [root / '2002.09062.pdf', root / 'd2cp05083h.pdf']
        if not all(path.is_file() for path in paths):
            self.skipTest('Optional real-paper layout fixtures are absent.')
        pages = 0
        for path in paths:
            with pymupdf.open(path) as doc:
                for page in doc:
                    raw = [{'id': f'p{page.number + 1}-b{i}', 'text': item[4],
                            'bbox': list(item[:4]), 'block_number': item[5]}
                           for i, item in enumerate(page.get_text('blocks', sort=True))
                           if item[6] == 0 and item[4].strip()]
                    result = group_page_blocks(page, raw)
                    validate_grouping(result, raw)
                    self.assertEqual(sum(len(p['text']) for p in result), sum(len(b['text']) for b in raw))
                    if page.number == 1 and path.stem == '2002.09062':
                        abstract = next(p for p in result if p['text'].startswith('Abstract:'))
                        self.assertTrue(abstract['text'].endswith('ical systems. \n'))
                        self.assertEqual(len(abstract['lines']), 17)
                        self.assertNotIn('Introduction', abstract['text'])
                        footer = next(p for p in result if p['text'].strip() == '1')
                        self.assertEqual(footer['source_role_hint'], 'page_number')
                    if page.number == 1 and path.stem == 'd2cp05083h':
                        abstract = next(p for p in result if p['text'].startswith('Chemical reaction neural network'))
                        self.assertNotIn('DOI:', abstract['text'])
                        self.assertIn('global uncertainty quantification.', abstract['text'])
                        uq = next(p for p in result if p['text'].startswith('Uncertainty quantification (UQ)'))
                        self.assertNotIn('Department', uq['text'])
                        self.assertGreater(uq['bbox'][0], 300)
                    if page.number == 7 and path.stem == 'd2cp05083h':
                        paragraph = next(p for p in result if p['text'].startswith('In this section, we demonstrate the B-CRNN on catalytic'))
                        normalized = ' '.join(paragraph['text'].split())
                        self.assertIn('pathway is modeled using the following reaction rate equations.', normalized)
                        training = next(p for p in result if p['text'].startswith('The reactions can be categorized'))
                        self.assertIn('sampled within [0.1, 1] and with 5% Gaussian noise subsequently added.', ' '.join(training['text'].split()))
                    pages += 1
        self.assertEqual(pages, 41)


if __name__ == '__main__':
    unittest.main()

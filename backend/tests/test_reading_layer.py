"""Reading usability checks are separate from exact raw coverage checks."""
import copy
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from papershelf_pipeline.reading import apply_reading_layer, clean_reading_text


def block(identifier, text, page=1, box=(40, 100, 280, 180), size=10, **extra):
    return {'id': identifier, 'page': page, 'text': text, 'bbox': list(box),
            'lines': [{'text': text, 'font_size': size, 'direction': [1, 0]}], **extra}


def source(*blocks):
    return {'blocks': list(blocks), 'raw_blocks': copy.deepcopy(list(blocks)),
            'pages': [{'page': page, 'width': 600, 'height': 800} for page in sorted({b['page'] for b in blocks})]}


class ReadingLayerTests(unittest.TestCase):
    def test_document_evidence_repairs_soft_wraps_but_preserves_compounds(self):
        value, edits, notes = clean_reading_text('A chem-\nical model uses time-\nresolved and unknown-\ncompound data .\nThe ﬁnal result.',
                                               {'chemical': 2}, {'time-resolved': 1})
        self.assertEqual(value, 'A chemical model uses time-resolved and unknown-compound data. The final result.')
        self.assertTrue(any(e.get('basis') == 'unbroken_spelling_elsewhere_in_document' for e in edits))
        self.assertTrue(any('unknown-compound' in note for note in notes))
        self.assertFalse(any('time-resolved' in note for note in notes))

    def test_unknown_equation_font_is_visible_without_guessing_a_minus_or_unit(self):
        value, _, notes = clean_reading_text('kcal mol\x031\nr ¼ k', prose=False)
        self.assertEqual(value, 'kcal mol⟦U+0003⟧1\nr ¼ k')
        self.assertTrue(notes)
        self.assertNotIn('−1', value)

    def test_source_raw_text_ids_and_all_slices_are_unchanged(self):
        original = source(block('a', 'A chemical reaction follows this model.\n'), block('b', 'Another chem-\nical paragraph follows here.\n', box=(40, 220, 280, 250)))
        frozen = copy.deepcopy(original)
        result = apply_reading_layer(original)
        self.assertEqual(result['raw_blocks'], frozen['raw_blocks'])
        for old, new in zip(frozen['blocks'], result['blocks']):
            for key in old: self.assertEqual(new[key], old[key])
        self.assertEqual(result['blocks'][1]['reading_text'], 'Another chemical paragraph follows here.')
        self.assertEqual(result['reading_blocks'][1]['source_ids'], ['b'])
        self.assertEqual(apply_reading_layer(copy.deepcopy(result)), result, 'Projection must be repeatable')

    def test_repeated_page_furniture_is_excluded_but_captions_and_sections_remain(self):
        values = []
        for p in range(1, 4):
            values += [block(f'h{p}', 'Journal of Example Research', p, (40, 20, 280, 30)),
                       block(f'c{p}', 'Table 2 Continued measurements', p, (40, 45, 280, 65)),
                       block(f's{p}', '2 Methods', p, (40, 75, 280, 95)),
                       block(f'b{p}', 'The complete scientific text remains available here.', p),
                       block(f'f{p}', f'Journal Example 2026 | {p}', p, (40, 765, 280, 780))]
        result = apply_reading_layer(source(*values))
        self.assertEqual({b['id'] for b in result['reading_excluded']}, {f'{prefix}{p}' for prefix in ('h', 'f') for p in range(1, 4)})
        self.assertTrue(all(b['include_in_reading'] for b in result['blocks'] if b['id'][0] in ('c', 's')))
        self.assertEqual(result['blocks'][1]['reading_role'], 'caption')

    def test_repository_cover_detected_from_metadata_structure_not_institution(self):
        result = apply_reading_layer(source(block('cover', 'Some University Repository\nCitation: Example\nPublished Version: DOI\nPermanent Link: URI\nTerms of use: CC\n'),
                                            block('science', 'Abstract\nThe chemical reaction model follows the available observations.', 2)))
        self.assertEqual(result['reading_excluded'][0]['kind'], 'repository_cover')
        self.assertEqual(result['reading_blocks'][0]['source_ids'], ['science'])

    def test_cross_column_continuation_skips_affiliation_but_not_captions(self):
        result = apply_reading_layer(source(
            block('left', 'Previous approaches identify these pathways but these\n', box=(40, 620, 280, 680)),
            block('affiliation', 'Department of Engineering, Example University. E-mail: author@example.test', box=(40, 700, 280, 720), size=7),
            block('right', 'techniques are limited to simple systems and require prior knowledge.\n', box=(320, 360, 560, 450))))
        self.assertEqual(result['reading_blocks'][0]['source_ids'], ['left', 'right'])
        self.assertIn('but these techniques', result['reading_blocks'][0]['text'])
        blocked = source(block('a', 'This sentence refers to the\n', box=(40, 100, 280, 180)),
                         block('fig', 'Figure 1 The model overview.', box=(40, 181, 280, 190)),
                         block('b', 'following process and its outcomes.\n', box=(40, 191, 280, 230)))
        self.assertEqual(len(apply_reading_layer(blocked)['reading_blocks']), 3)

    def test_cross_page_sentence_joins_with_original_ids_and_page_range(self):
        result = apply_reading_layer(source(
            block('a', 'In many complex systems there is limited prior\n', box=(40, 670, 560, 740)),
            block('footer', '1\n', box=(300, 770, 308, 780), source_role_hint='page_number'),
            block('b', 'knowledge of the reaction mechanism available from data.\n', page=2, box=(40, 40, 560, 140))))
        joined = result['reading_blocks'][0]
        self.assertEqual(joined['id'], 'a')
        self.assertEqual(joined['source_ids'], ['a', 'b'])
        self.assertEqual(joined['pages'], [1, 2])
        self.assertEqual(joined['text'], 'In many complex systems there is limited prior knowledge of the reaction mechanism available from data.')

    def test_complete_sentences_indent_and_document_boundaries_are_not_joined(self):
        cases = [source(block('a', 'A complete sentence appears here.'), block('b', 'another sentence starts a new paragraph.', box=(40, 182, 280, 230))),
                 source(block('a', 'A complete clause ends with no mark'), block('b', 'another paragraph begins with indentation.', box=(55, 182, 280, 230))),
                 source(block('a', 'A main document ends with no mark'), block('b', 'another document must stay separately indexed.', box=(40, 182, 280, 230), document_id='s1'))]
        for value in cases:
            with self.subTest(value=value): self.assertEqual(len(apply_reading_layer(value)['reading_blocks']), 2)

    def test_references_are_labeled_and_supplement_science_is_not_lost(self):
        result = apply_reading_layer(source(block('h', 'References'), block('r', '1 A. Author, A detailed title, Journal, 2024.'),
                                            block('s', 'Supporting Information'), block('b', 'Here are the complete experimental conditions and results.')))
        by_id = {b['id']: b for b in result['blocks']}
        self.assertEqual(by_id['r']['reading_role'], 'reference')
        self.assertEqual(by_id['b']['reading_role'], 'body')
        self.assertEqual(len(result['reading_excluded']), 0)

    def test_equation_fragments_are_evidence_not_main_reading_paragraphs(self):
        result = apply_reading_layer(source(block('eq', '𝑑[A]\n'), block('num', '(3)\n'),
                                            block('label', 'Ground Truth\n'), block('body', 'The model predicts the measured reaction rate.')))
        self.assertEqual([b['id'] for b in result['reading_main_blocks']], ['body'])
        self.assertEqual({b['id'] for b in result['reading_fragments']}, {'eq', 'num', 'label'})
        self.assertEqual(result['reading_excluded'], [])
        self.assertTrue(all(b['include_in_reading'] and not b['reading_main'] for b in result['reading_fragments']))

    def test_repeated_scientific_table_labels_are_not_mistaken_for_headers(self):
        values = [block(f'e{page}', 'Equation', page, (40, 20, 100, 30)) for page in range(1, 4)]
        values += [block(f's{page}', ';', page, (250, 20, 255, 30)) for page in range(1, 4)]
        result = apply_reading_layer(source(*values))
        self.assertFalse(result['reading_excluded'])

    def test_multiline_bibliography_keeps_entries_separate(self):
        result = apply_reading_layer(source(block('h', 'References', box=(40, 40, 280, 50)),
                                            block('r1', '(1) Doe, J. A Source Title. Journal', box=(40, 100, 280, 110)),
                                            block('r2', '2025, 12, 10–19. DOI: 10.1234/example.', box=(40, 112, 280, 125)),
                                            block('r3', '(2) Smith, K. Another Source.', box=(40, 127, 280, 140))))
        self.assertEqual([b['source_ids'] for b in result['reading_blocks']], [['h'], ['r1', 'r2'], ['r3']])

    def test_bibliography_institute_and_supporting_for_are_not_affiliation_or_reference_leaks(self):
        result = apply_reading_layer(source(block('h', 'References'), block('r', 'Institute, 2025, 3, 1–12. Another citation follows.'),
                                            block('s', 'Supporting Information for'), block('b', 'The experimental conditions below belong to supplementary science.')))
        by_id = {b['id']: b for b in result['blocks']}
        self.assertEqual(by_id['r']['reading_role'], 'reference')
        self.assertTrue(by_id['r']['include_in_reading'])
        self.assertEqual(by_id['s']['reading_role'], 'heading')
        self.assertEqual(by_id['b']['reading_role'], 'body')

    def test_alternating_journal_page_number_placement_has_same_footer_signature(self):
        values = [block(f'f{p}', (f'{p} | Journal Example 2025' if p % 2 else f'Journal Example 2025 | {p}'), p, (40, 765, 280, 780)) for p in range(1, 7)]
        values += [block(f'b{p}', 'Scientific content remains on this page.', p, (40, 200, 280, 300)) for p in range(1, 7)]
        result = apply_reading_layer(source(*values))
        self.assertEqual(len(result['reading_excluded']), 6)

    def test_repeated_page_only_paragraph_is_not_deleted_as_running_header(self):
        values = [block(f'p{p}', f'Chapter content page {p}. Every paragraph is retained.', p, (50, 60, 480, 72)) for p in range(1, 5)]
        result = apply_reading_layer(source(*values))
        self.assertEqual(len(result['reading_main_blocks']), 4)
        self.assertFalse(result['reading_excluded'])

    def test_short_plain_text_and_bold_pdf_headings_remain_main_reading(self):
        plain = {'id': 'plain', 'page': 1, 'text': 'Small textual input.'}
        heading = block('heading', 'Reaction kinetics', box=(40, 120, 280, 140))
        heading['lines'][0]['font_flags'] = 16
        result = apply_reading_layer(source(plain, heading))
        self.assertEqual([b['kind'] for b in result['reading_main_blocks']], ['body', 'heading'])

    def test_short_scientific_statements_remain_in_main_english_text(self):
        sentences = ['No catalyst was used.', 'The temperature was 300 K.', 'Conversion reached 95%.',
                     'The reaction stopped.', 'Therefore, the hypothesis failed.', 'No catalyst was used', 'Conversion reached 95%',
                     'CO formed.', 'No CO formed.', 'H2 increased.', 'CO did not form']
        result = apply_reading_layer(source(*[block(str(i), text, box=(40, 100 + i * 45, 280, 130 + i * 45)) for i, text in enumerate(sentences)]))
        self.assertEqual([b['text'] for b in result['reading_main_blocks']], sentences)
        self.assertFalse(result['reading_excluded'])
        self.assertFalse(result['reading_fragments'])

    def test_verified_blank_glyph_stays_visible_in_formula_evidence_without_guessing(self):
        observation = {'source_ids': ['glyph'], 'kind': 'layout_verification', 'observation': '原页显示一个矩阵边界字形，文本层为空白。'}
        result = apply_reading_layer(source(block('glyph', '\t\n', source_role_hint='whitespace', layout_observations=[observation])))
        self.assertFalse(result['reading_excluded'])
        fragment = result['reading_fragments'][0]
        self.assertEqual(fragment['source_ids'], ['glyph'])
        self.assertEqual(fragment['kind'], 'equation_fragment')
        self.assertIn('未映射字形', fragment['text'])
        self.assertEqual(fragment['layout_observations'], [observation])
        self.assertEqual(result['blocks'][0]['text'], '\t\n')

    def test_rotated_scientific_axis_is_preserved_but_license_notice_is_separate(self):
        result = apply_reading_layer(source(
            block('axis', 'Reaction rate (mol/s)', source_role_hint='marginal'),
            block('license', 'This article is licensed under a Creative Commons Attribution licence.', source_role_hint='marginal')))
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['axis'])
        self.assertEqual(result['reading_fragments'][0]['text'], 'Reaction rate (mol/s)')
        self.assertEqual(result['reading_excluded'][0]['source_ids'], ['license'])

    def test_short_equation_functions_are_not_mistaken_for_short_prose(self):
        result = apply_reading_layer(source(block('ln', 'ln 𝑘= ln 𝐴+ 𝑏ln 𝑇−'),
                                            block('exp', '𝑟= exp(ln𝑘+ 𝑣𝐴ln[𝐴] + 𝑣𝐵ln[𝐵]) (3)')))
        self.assertFalse(result['reading_main_blocks'])
        self.assertEqual(len(result['reading_fragments']), 2)

    def test_standalone_equations_and_reactions_keep_all_symbols_out_of_prose(self):
        expressions = ['pðyjDÞ ¼ pðDjyÞpðyÞ', 'qðyjYÞ log qðyjYÞ', 'Y? ¼ arg min',
                       'TG þ ROH!', 'kr ES !', 'S + MAP3K →S + MAP3K ∗',
                       'MAP3K\x04 þ MAP2K! MAP3K\x04 þ MAP2K\x04',
                       'Loss = MAE(Y(t), Ydata(t)) (8)', 'y = ODESolve(CRNN(Y), Y0) (7)']
        result = apply_reading_layer(source(*[block(str(i), text) for i, text in enumerate(expressions)]))
        self.assertFalse(result['reading_main_blocks'])
        self.assertFalse(result['reading_excluded'])
        self.assertEqual([b['text'] for b in result['blocks']], expressions)
        self.assertEqual([g['source_ids'] for g in result['reading_fragments']], [[str(i)] for i in range(len(expressions))])
        self.assertTrue(all(g['kind'] == 'equation_fragment' for g in result['reading_fragments']))
        self.assertIn('¼', result['reading_fragments'][0]['text'])
        self.assertIn('⟦U+0004⟧', result['reading_fragments'][6]['text'])

    def test_explanatory_math_sentences_and_exclamations_remain_main(self):
        sentences = ['The temperature was T = 300 K.', 'where r = k[A] describes the reaction rate.',
                     'L(y) = log p(y), where y is the position variable.', 'We consider A → B.',
                     'No CO!', 'CO formed!', 'Conversion reached 95%!', '反应速率为 r = k[A]。']
        result = apply_reading_layer(source(*[block(str(i), text, box=(40, 100 + i * 45, 280, 130 + i * 45)) for i, text in enumerate(sentences)]))
        self.assertEqual([g['text'] for g in result['reading_main_blocks']], sentences)
        self.assertFalse(result['reading_fragments'])
        self.assertFalse(result['reading_excluded'])

    def test_display_formula_does_not_join_following_explanation(self):
        result = apply_reading_layer(source(block('eq', 'LðyÞ ¼ logðpðDjyÞpðyÞÞ;', box=(40, 100, 280, 115)),
                                            block('explain', 'where y is the position of the particle.', box=(40, 116, 280, 140))))
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['explain']])
        self.assertEqual([g['source_ids'] for g in result['reading_fragments']], [['eq']])

    def test_caption_scalar_continuation_after_equals_retains_both_source_ids(self):
        caption = block('caption', 'Figure 5. Learned weights after pruning with threshold =\n',
                        box=(54.72, 368.44, 552.91, 402.36), size=12)
        value = block('value', '0.01.\n', box=(54.72, 409.86, 81.74, 423.14), size=12)
        original = source(caption, value)
        raw = copy.deepcopy(original)
        result = apply_reading_layer(original)
        self.assertEqual(len(result['reading_main_blocks']), 1)
        self.assertFalse(result['reading_fragments'])
        joined = result['reading_main_blocks'][0]
        self.assertEqual(joined['source_ids'], ['caption', 'value'])
        self.assertEqual(joined['kind'], 'caption')
        self.assertTrue(joined['text'].endswith('threshold = 0.01.'))
        self.assertEqual(joined['joins'][0]['basis'], 'numeric_continuation_after_equals_and_matching_layout')
        self.assertTrue(result['blocks'][1]['reading_main'])
        self.assertEqual(result['blocks'][1]['reading_role'], 'caption')
        self.assertEqual(result['raw_blocks'], raw['raw_blocks'])
        self.assertEqual([b['text'] for b in result['blocks']], [b['text'] for b in raw['blocks']])
        self.assertEqual(apply_reading_layer(copy.deepcopy(result)), result)

    def test_body_scalar_continuation_keeps_sign_exponent_and_percent(self):
        for value in ('-1.2e-3.', '5%.'):
            with self.subTest(value=value):
                result = apply_reading_layer(source(block('body', 'The measured value =', box=(40, 100, 280, 120)),
                                                    block('value', value, box=(40, 124, 90, 135))))
                self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['body', 'value']])
                self.assertTrue(result['reading_main_blocks'][0]['text'].endswith('= ' + value))

    def test_axis_ticks_and_separate_numeric_blocks_do_not_merge_into_captions(self):
        cases = [block('value', '0.01.', box=(70, 124, 100, 135)),
                 block('value', '0.01.', box=(40, 160, 80, 172)),
                 block('value', '0.01.', box=(40, 124, 80, 135), size=7),
                 block('value', '0.01.', page=2, box=(40, 124, 80, 135)),
                 block('value', '0.01.', box=(40, 124, 80, 135), document_id='s1'),
                 block('value', '0.01.', box=(40, 124, 80, 135), source_role_hint='marginal'),
                 block('value', '0.01 0.1 1', box=(40, 124, 80, 135))]
        for value in cases:
            with self.subTest(value=value):
                result = apply_reading_layer(source(block('caption', 'Figure 1. Threshold =', box=(40, 100, 280, 120)), value))
                self.assertEqual(result['reading_main_blocks'][0]['source_ids'], ['caption'])
                self.assertTrue(any(g['source_ids'] == ['value'] for g in result['reading_fragments']))
        result = apply_reading_layer(source(block('caption', 'Figure 1. Complete caption.', box=(40, 100, 280, 120)),
                                           block('value', '0.01.', box=(40, 124, 80, 135))))
        self.assertEqual(result['reading_main_blocks'][0]['source_ids'], ['caption'])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['value'])

    def test_attested_split_word_crosses_inline_formula_fragments_without_losing_them(self):
        result = apply_reading_layer(source(
            block('word', 'A chemical reaction is explicitly named here.', box=(40, 40, 280, 60)),
            block('a', 'The resulting model contains another chem-\n', box=(40, 100, 280, 120)),
            block('glyph', '∑\n', box=(190, 118, 197, 127)),
            block('b', 'ical reaction that follows the rate law.', box=(40, 130, 280, 150))))
        joined = next(b for b in result['reading_main_blocks'] if b['id'] == 'a')
        self.assertEqual(joined['source_ids'], ['a', 'b'])
        self.assertIn('another chemical reaction', joined['text'])
        self.assertEqual(joined['linked_layout_source_ids'], ['glyph'])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['glyph'])

    def test_run_in_headings_join_capitalized_names_only_on_a_tight_next_line(self):
        cases = [('2.2.1 Hamiltonian Monte Carlo. The Hamiltonian Monte',
                  'Carlo (HMC) method constructs a Markov chain.', 'Monte Carlo (HMC)'),
                 ('2.2.2 Variational inference. Rather than sampling a',
                  'Markov chain, the method approximates the posterior.', 'sampling a Markov chain')]
        for first, second, phrase in cases:
            with self.subTest(first=first):
                result = apply_reading_layer(source(block('a', first, box=(52, 200, 280, 210)),
                                                    block('b', second, box=(40, 213, 280, 260))))
                self.assertEqual(result['reading_main_blocks'][0]['source_ids'], ['a', 'b'])
                self.assertIn(phrase, result['reading_main_blocks'][0]['text'])
        separated = apply_reading_layer(source(block('a', cases[0][0], box=(52, 200, 280, 210)),
                                              block('b', cases[0][1], box=(40, 245, 280, 280))))
        self.assertEqual(len(separated['reading_main_blocks']), 2)

    def test_two_column_page_rollover_crosses_a_bottom_float_without_merging_its_caption(self):
        original = source(block('a', 'With an appropriate differential equation solver, we can', box=(320, 480, 560, 510)),
                          block('fig', 'Figure 1. An overview of the reaction network.', box=(40, 650, 560, 700), size=8),
                          block('b', 'generate an estimated trajectory for the concentration.', page=2, box=(40, 50, 280, 100)))
        frozen = copy.deepcopy(original)
        result = apply_reading_layer(original)
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a', 'b'], ['fig']])
        self.assertIn('we can generate', result['reading_main_blocks'][0]['text'])
        self.assertEqual(result['reading_main_blocks'][0]['linked_caption_source_ids'], ['fig'])
        self.assertEqual(result['raw_blocks'], frozen['raw_blocks'])
        self.assertEqual([b['text'] for b in result['blocks']], [b['text'] for b in frozen['blocks']])

    def test_page_and_column_rollover_can_continue_below_a_top_float(self):
        page = apply_reading_layer(source(
            block('a', 'The regularization prevents the distribution from being totally', box=(320, 680, 560, 720)),
            block('fig', 'Figure 2. Illustration of the two methods.', page=2, box=(40, 210, 280, 280), size=8),
            block('b', 'dissimilar to the prior distribution.', page=2, box=(40, 325, 280, 355))))
        self.assertEqual([g['source_ids'] for g in page['reading_main_blocks']], [['a', 'b'], ['fig']])
        column = apply_reading_layer(source(
            block('a', 'Mean field approximation applies, i.e., the Gaussian', box=(40, 380, 280, 490)),
            block('fig', 'Figure 4. Estimates of the parameter distributions.', box=(320, 210, 560, 250), size=8),
            block('b', 'distributions of the parameters are independent.', box=(320, 275, 560, 300))))
        self.assertEqual([g['source_ids'] for g in column['reading_main_blocks']], [['a', 'b'], ['fig']])

    def test_float_does_not_license_a_complete_sentence_or_different_document_join(self):
        for suffix, document in [('.', 'main'), ('', 'supplement')]:
            with self.subTest(suffix=suffix, document=document):
                result = apply_reading_layer(source(
                    block('a', 'The previous explanation ends here' + suffix, box=(320, 680, 560, 720)),
                    block('fig', 'Figure 2. A different illustration.', page=2, box=(40, 210, 280, 280), size=8),
                    block('b', 'another explanation begins here.', page=2, box=(40, 325, 280, 355), document_id=document)))
                self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a'], ['fig'], ['b']])

    def test_inline_fraction_fragments_have_a_position_marker_and_literal_prose_tail(self):
        original = source(
            block('a', 'The neuron inputs are concentrations in', box=(40, 100, 550, 140), size=12),
            block('numerator', '𝑑[A]', box=(425, 146, 442, 155), size=8),
            block('b', 'the logarithmic scale, and the outputs are species rates [', box=(40, 150, 420, 163), size=12),
            block('denominator', '𝑑𝑡 ], in ', box=(450, 150, 495, 169), size=12),
            block('c', 'short, the concentration derivatives. The weights encode reaction orders.', box=(40, 175, 550, 220), size=12))
        frozen = copy.deepcopy(original)
        result = apply_reading_layer(original)
        group = result['reading_main_blocks'][0]
        self.assertEqual(group['source_ids'], ['a', 'b', 'c'])
        self.assertIn('concentrations in the logarithmic scale', group['text'])
        self.assertIn('[⟦inline formula⟧], in short,', group['text'])
        self.assertEqual(group['linked_layout_source_ids'], ['numerator', 'denominator'])
        self.assertEqual([g['source_ids'] for g in result['reading_fragments']], [['numerator'], ['denominator']])
        projection = group['inline_projections'][0]
        self.assertEqual(projection['layout_source_ids'], ['numerator', 'denominator'])
        tail = projection['literal_prose_tail']
        raw = next(b['text'] for b in frozen['blocks'] if b['id'] == tail['source_id'])
        self.assertEqual(raw[tail['raw_start']:tail['raw_end']].strip(), tail['text'])
        self.assertEqual(tail['text'], '], in')
        self.assertNotIn('d[A]/dt', group['text'])
        self.assertEqual(result['raw_blocks'], frozen['raw_blocks'])
        assigned = [i for g in result['reading_blocks'] + result['reading_excluded'] for i in g['source_ids']]
        self.assertCountEqual(assigned, [b['id'] for b in frozen['blocks']])
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual(apply_reading_layer(copy.deepcopy(result)), result)

    def test_display_math_between_prose_does_not_become_an_inline_formula(self):
        result = apply_reading_layer(source(
            block('a', 'The reaction rate is given by', box=(40, 100, 280, 120)),
            block('eq', 'r = k[A]', box=(40, 124, 280, 138)),
            block('b', 'where the parameter follows the temperature law.', box=(40, 144, 280, 180))))
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a'], ['b']])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['eq'])

    def test_inline_reaction_can_resume_on_the_same_line_then_wrap_an_acronym(self):
        left = block('a', 'We consider the reversible reaction E þ S Ð', box=(40, 100, 210, 115))
        left['lines'][0]['bbox'] = [180, 100, 210, 115]
        original = source(left, block('rate', 'kr ES', box=(205, 100, 225, 118)),
                          block('b', '. The results of', box=(230, 101, 290, 112)),
                          block('c', 'CRNN with and without the constraint are compared.', box=(40, 125, 290, 155)))
        result = apply_reading_layer(original)
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a', 'b', 'c']])
        self.assertIn('⟦inline formula⟧. The results of CRNN', result['reading_main_blocks'][0]['text'])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['rate'])
        self.assertEqual(result['reading_main_blocks'][0]['linked_layout_source_ids'], ['rate'])

    def test_caption_inline_reaction_and_wrapped_panel_conditions_are_one_caption(self):
        caption = block('a', 'Figure 7. Predictions with 4 standard deviations for reaction E þ S Ð',
                        box=(40, 100, 560, 132), size=8)
        caption['lines'][0]['bbox'] = [40, 124, 100, 132]
        original = source(caption, block('rate', 'kf', box=(94, 119, 99, 126), size=5),
                          block('b', 'kr ES. Dots indicate synthetic measurements with 5% Gaussian noise. Initial conditions are [6.46, 7.57, 0, 0]',
                                box=(94, 124, 560, 139), size=8),
                          block('c', '(a) and [1.78, 4.68, 0] (b).', box=(40, 139, 160, 147), size=8))
        before = copy.deepcopy(original)
        result = apply_reading_layer(original)
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a', 'b', 'c']])
        group = result['reading_main_blocks'][0]
        self.assertEqual(group['kind'], 'caption')
        self.assertIn('[6.46, 7.57, 0, 0] (a) and [1.78, 4.68, 0] (b).', group['text'])
        self.assertEqual(group['linked_layout_source_ids'], ['rate'])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['rate'])
        self.assertTrue(all(b['reading_role'] == 'caption' for b in result['blocks'] if b['id'] in {'a', 'b', 'c'}))
        self.assertEqual(result['raw_blocks'], before['raw_blocks'])
        self.assertEqual([b['text'] for b in result['blocks']], [b['text'] for b in before['blocks']])
        self.assertEqual(apply_reading_layer(copy.deepcopy(result)), result)

    def test_caption_does_not_absorb_rotated_axes_or_a_different_font(self):
        for metadata in ({'size': 10}, {'size': 8, 'source_role_hint': 'marginal'}):
            with self.subTest(metadata=metadata):
                caption = block('a', 'Figure 7. Predictions for the hypothetical reaction E þ S Ð',
                                box=(40, 100, 560, 132), size=8)
                caption['lines'][0]['bbox'] = [40, 124, 100, 132]
                result = apply_reading_layer(source(caption, block('rate', 'kf', box=(94, 119, 99, 126), size=5),
                                                    block('b', 'kr ES. Dots indicate synthetic measurements with Gaussian noise.',
                                                          box=(94, 124, 560, 139), **metadata)))
                self.assertEqual(result['reading_main_blocks'][0]['source_ids'], ['a'])
                self.assertTrue(any(g['source_ids'] == ['b'] for g in result['reading_blocks']))

    def test_inline_prose_on_same_baseline_does_not_cross_documents(self):
        left = block('a', 'We consider a reaction E þ S Ð', box=(40, 100, 210, 115))
        left['lines'][0]['bbox'] = [180, 100, 210, 115]
        result = apply_reading_layer(source(left, block('rate', 'kr ES', box=(205, 100, 225, 118)),
                                           block('b', '. The results follow.', box=(230, 101, 290, 112), document_id='supplement')))
        self.assertEqual([g['source_ids'] for g in result['reading_main_blocks']], [['a'], ['b']])

    def test_where_symbol_prefix_and_subscript_are_linked_without_guessing_greek_letters(self):
        original = source(block('symbol', 'where ~yi\n', box=(320, 100, 355, 112)),
                          block('a', 'j is the ith sample of parameters from the jth', box=(353, 103, 560, 114)),
                          block('b', 'model. The prior has a Poisson distribution.', box=(320, 117, 560, 145)))
        frozen = copy.deepcopy(original)
        result = apply_reading_layer(original)
        group = result['reading_main_blocks'][0]
        self.assertEqual(group['source_ids'], ['a', 'b'])
        self.assertTrue(group['text'].startswith('where ⟦inline symbol: ~yi j⟧ is the ith sample'))
        self.assertNotIn('θ', group['text'])
        self.assertEqual(group['linked_layout_source_ids'], ['symbol'])
        self.assertEqual(result['reading_fragments'][0]['source_ids'], ['symbol'])
        projection = group['inline_projections'][0]
        raw_by_id = {b['id']: b['text'] for b in frozen['blocks']}
        for literal in [projection['literal_prose_prefix']] + projection['literal_symbol_parts']:
            self.assertEqual(raw_by_id[literal['source_id']][literal['raw_start']:literal['raw_end']], literal['text'])
        self.assertEqual([b['text'] for b in result['blocks']], [b['text'] for b in frozen['blocks']])
        self.assertEqual(result['raw_blocks'], frozen['raw_blocks'])
        self.assertEqual(apply_reading_layer(copy.deepcopy(result)), result)

    def test_where_prefix_requires_encoded_symbol_matching_baseline_and_document(self):
        for text, box, document in [('where z', (320, 100, 355, 112), 'main'),
                                    ('where ~yi', (320, 80, 355, 92), 'main'),
                                    ('where ~yi', (320, 100, 355, 112), 'supplement')]:
            with self.subTest(text=text, box=box, document=document):
                result = apply_reading_layer(source(block('symbol', text, box=box, document_id=document),
                                                    block('a', 'j is the ith sample from the model.', box=(353, 103, 560, 114))))
                group = next(g for g in result['reading_main_blocks'] if g['id'] == 'a')
                self.assertTrue(group['text'].startswith('j is'))
                self.assertNotIn('inline_projections', group)

    def test_duplicate_source_ids_fail_instead_of_silently_aliasing(self):
        with self.assertRaises(ValueError): apply_reading_layer(source(block('same', 'First complete source paragraph.'), block('same', 'Second complete source paragraph.')))


if __name__ == '__main__': unittest.main()

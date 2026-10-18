import copy
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError, sha256, write_json, read_json
from papershelf_pipeline.editorial_review import load_editorial_review, apply_editorial_review
from papershelf_pipeline.rendering import render_guide
from papershelf_pipeline.reading_editions import render_reading_editions


class EditorialReviewTests(unittest.TestCase):
    def reading_fixture(self):
        source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1, 'text': 'W 2 R.'}]}
        units = [{'unit_id': 'a:u1', 'translation': 'W 2 R。'}]
        item = {'id': 'a', 'source_ids': ['a'], 'text': 'W 2 R.', 'translation': 'W 2 R。',
                'translation_units': units, 'editing_notes': ['Retained extracted glyph.'],
                'validation': {'numeric_tokens': 'identical', 'units': 'identical', 'source_mapping': 'complete'},
                'translation_validation': {'numeric_tokens': 'identical', 'sentence_units': 'complete'}}
        learning = {'clean_reading': [item], 'paragraphs': [{'source_id': 'a', 'source_ids': ['a'], 'explanation': 'W 2 R。'}]}
        corrections = []
        for field, corrected in [('text', 'W ∈ R.'), ('translation', 'W ∈ R。')]:
            follow = {'editing_notes_original': item['editing_notes'], 'editing_notes_corrected': ['Membership glyph verified against source page.']}
            if field == 'translation':
                follow.update(translation_units_original=units, translation_units_corrected=[{'unit_id': 'a:u1', 'translation': corrected}])
            corrections.append({'id': 'review-' + field, 'section': 'clean_reading', 'reading_group_id': 'a',
                                'field': field, 'original': item[field], 'corrected': corrected, 'source_ids': ['a'],
                                'why': 'Membership symbol, not a numerical value.', 'verification': {},
                                'required_follow_through': follow})
        return source, learning, {'reviewer': 'fixture', 'source_sha256': 'hash', 'content_corrections': corrections}

    def test_reading_revision_synchronizes_translation_and_preserves_validation_provenance(self):
        source, learning, bundle = self.reading_fixture()
        before = copy.deepcopy(learning)
        with tempfile.TemporaryDirectory() as name:
            outputs = apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)
            self.assertEqual(read_json(outputs['editorial_review_draft']), before)
            item = learning['clean_reading'][0]
            self.assertEqual(item['text'], 'W ∈ R.')
            self.assertEqual(item['translation'], 'W ∈ R。')
            self.assertEqual(item['translation_units'], [{'unit_id': 'a:u1', 'translation': 'W ∈ R。'}])
            self.assertEqual(item['validation_before_editorial_review']['numeric_tokens'], 'identical')
            self.assertEqual(item['translation_validation']['numeric_tokens'], 'source_reviewed_correction')
            self.assertEqual(item['reading_validation_before_editorial_review']['numeric_tokens'], 'identical')
            self.assertEqual(item['validation']['inline_markers'], 'source_reviewed_correction')
            self.assertEqual(item['validation']['source_mapping'], 'complete')
            self.assertEqual(learning['paragraphs'][0]['explanation'], item['translation'])
            self.assertEqual(learning['paragraphs'][0]['translation_units'], item['translation_units'])
            self.assertEqual(learning['paragraphs'][0]['translation_validation'], item['translation_validation'])
            self.assertTrue(all(not mark['human_scientific_acceptance'] for mark in item['source_reviewed_corrections']))
            # Exact replay is idempotent, including note and sentence metadata.
            repeat = copy.deepcopy(item)
            apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)
            self.assertEqual(learning['clean_reading'][0], repeat)
            self.assertTrue(all(record['status'] == 'already_applied' for record in learning['editorial_review']['records']))
            self.assertEqual(source['blocks'][0]['text'], 'W 2 R.')

    def test_reading_revision_rejects_stale_values_or_inconsistent_sentence_units(self):
        for fault, expected in [('original', '未匹配'), ('missing_units', 'translation_units'),
                                ('unit_id', '单元ID'), ('translation', '不一致'), ('stale_units', '原值不匹配')]:
            source, learning, bundle = self.reading_fixture()
            correction = bundle['content_corrections'][1]
            if fault == 'original':
                correction['original'] = 'unrelated draft'
            elif fault == 'missing_units':
                correction['required_follow_through'].pop('translation_units_corrected')
            elif fault == 'unit_id':
                correction['required_follow_through']['translation_units_corrected'][0]['unit_id'] = 'invented'
            elif fault == 'translation':
                correction['corrected'] = 'different translation'
            else:
                learning['clean_reading'][0]['translation_units'] = [{'unit_id': 'a:u1', 'translation': 'changed draft'}]
            with self.subTest(fault=fault), tempfile.TemporaryDirectory() as name, self.assertRaisesRegex(PipelineError, expected):
                apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)

    def test_annotation_only_revision_removes_misplaced_note_without_changing_prose(self):
        source, learning, _ = self.reading_fixture()
        original = copy.deepcopy(learning)
        bundle = {'source_sha256': 'hash', 'reviewer': 'fixture', 'annotation_corrections': [
            {'id': 'notes', 'field': 'editing_notes', 'reading_group_id': 'a', 'source_ids': ['a'],
             'original': original['clean_reading'][0]['editing_notes'], 'corrected': [], 'why': 'Unrelated annotation', 'verification': {}}]}
        with tempfile.TemporaryDirectory() as name:
            artifacts = apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)
            self.assertEqual(read_json(artifacts['editorial_review_draft']), original)
            self.assertEqual(learning['clean_reading'][0]['editing_notes'], [])
            for key in ('text', 'translation', 'translation_units', 'translation_validation'):
                self.assertEqual(learning['clean_reading'][0][key], original['clean_reading'][0][key])
            self.assertEqual(learning['editorial_review']['records'][0]['status'], 'applied_exact_match')
            apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)
            self.assertEqual(learning['editorial_review']['records'][0]['status'], 'already_applied')
            learning['clean_reading'][0]['editing_notes'] = ['new scientific caveat']
            with self.assertRaisesRegex(PipelineError, '未匹配'):
                apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)

    def test_source_quotes_and_annotation_shape_are_validated(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            page = root / 'page.png'
            page.write_bytes(b'page fixture')
            source, _, bundle = self.reading_fixture()
            source['figures'] = [{'page': 1, 'path': str(page)}]
            verification = {'pages': [1], 'page_image_sha256': {'1': sha256(page)}, 'method': 'fixture source review'}
            for correction in bundle['content_corrections']:
                correction['verification'] = verification
                correction['source_evidence'] = [{'block_id': 'a', 'page': 1, 'quote': 'W 2 R.'}]
            path = root / 'review.json'
            write_json(path, bundle)
            self.assertEqual(load_editorial_review(path, source), bundle)
            bundle['content_corrections'][0]['source_evidence'][0]['quote'] = 'invented source'
            write_json(path, bundle)
            with self.assertRaisesRegex(PipelineError, '逐字来源'):
                load_editorial_review(path, source)
            bundle['content_corrections'] = []
            bundle['annotation_corrections'] = [{'reading_group_id': 'a', 'field': 'editing_notes', 'source_ids': ['a'],
                                                'original': [], 'corrected': 'not an array', 'why': 'fixture', 'verification': verification}]
            write_json(path, bundle)
            with self.assertRaisesRegex(PipelineError, '文字数组'):
                load_editorial_review(path, source)

    def test_inline_repair_accepts_only_existing_linked_layout_evidence(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            page = root / 'page.png'
            page.write_bytes(b'page fixture')
            source, _, bundle = self.reading_fixture()
            source['blocks'].extend([{'id': 'math', 'page': 1, 'text': '∈'}, {'id': 'unrelated', 'page': 1, 'text': 'Other formula'}])
            source['figures'] = [{'page': 1, 'path': str(page)}]
            source['reading_main_blocks'] = [{'id': 'a', 'source_ids': ['a'], 'linked_layout_source_ids': ['math']}]
            for item in bundle['content_corrections']:
                item['verification'] = {'pages': [1], 'page_image_sha256': {'1': sha256(page)}, 'method': 'fixture source review'}
                item['additional_evidence_source_ids'] = ['math']
                item['source_evidence'] = [{'block_id': 'math', 'page': 1, 'quote': '∈'}]
            path = root / 'review.json'
            write_json(path, bundle)
            self.assertEqual(load_editorial_review(path, source), bundle)
            bundle['content_corrections'][0]['additional_evidence_source_ids'].append('unrelated')
            write_json(path, bundle)
            with self.assertRaisesRegex(PipelineError, '无关片段'):
                load_editorial_review(path, source)

    def test_thematic_correction_matches_paragraph_evidence_and_keeps_precise_location(self):
        source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1}, {'id': 'b', 'page': 2}]}
        learning = {'thematic_sections': [{'title': 'Topic', 'paragraphs': [
            {'text': 'Old claim', 'source_ids': ['a']}, {'text': 'Old claim', 'source_ids': ['b']}]}]}
        bundle = {'reviewer': 'fixture', 'content_corrections': [
            {'section': 'thematic_paragraphs', 'field': 'text', 'source_ids': ['a'], 'original': 'Old claim',
             'corrected': 'Source-reviewed claim', 'why': 'Source evidence'}]}
        with tempfile.TemporaryDirectory() as name:
            apply_editorial_review(learning, source, bundle, Path(name), require_exact=True)
        self.assertEqual(learning['thematic_sections'][0]['paragraphs'][0]['text'], 'Source-reviewed claim')
        self.assertEqual(learning['thematic_sections'][0]['paragraphs'][1]['text'], 'Old claim')
        self.assertEqual(learning['thematic_sections'][0]['source_ids'], ['a', 'b'])
        self.assertEqual(learning['editorial_review']['records'][0]['locations'], ['thematic_sections[0].paragraphs[0].text'])

    def test_corrected_card_citations_require_full_source_evidence_and_replay_exactly(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            page = root / 'page.png'
            page.write_bytes(b'reviewed page')
            source = {'sha256': 'hash', 'blocks': [{'id': 'a', 'page': 1, 'text': 'Method.'},
                                                  {'id': 'b', 'page': 1, 'text': 'Total duration was 491 s.'}],
                      'figures': [{'page': 1, 'path': str(page)}]}
            learning = {'findings': [{'title': 'Old title', 'body': 'Old duration', 'source_ids': ['a']}]}
            bundle = {'source_sha256': 'hash', 'reviewer': 'fixture', 'content_corrections': []}
            for field, old, new in [('body', 'Old duration', 'Total duration was 491 s.'), ('title', 'Old title', 'Timing')]:
                bundle['content_corrections'].append({'section': 'findings', 'field': field, 'original': old, 'corrected': new,
                    'source_ids': ['a'], 'corrected_source_ids': ['a', 'b'], 'why': 'Restore complete timing evidence',
                    'source_evidence': [{'block_id': 'b', 'page': 1, 'quote': 'Total duration was 491 s.'}],
                    'verification': {'pages': [1], 'page_image_sha256': {'1': sha256(page)}, 'method': 'fixture review'}})
            path = root / 'review.json'
            write_json(path, bundle)
            loaded = load_editorial_review(path, source)
            apply_editorial_review(learning, source, loaded, root, require_exact=True)
            self.assertEqual(learning['findings'], [{'title': 'Timing', 'body': 'Total duration was 491 s.', 'source_ids': ['a', 'b']}])
            apply_editorial_review(learning, source, loaded, root, require_exact=True)
            self.assertTrue(all(r['status'] == 'already_applied' for r in learning['editorial_review']['records']))
            bundle['content_corrections'][0]['source_evidence'] = []
            write_json(path, bundle)
            with self.assertRaisesRegex(PipelineError, '新增学习条目引用'):
                load_editorial_review(path, source)

    def test_source_bound_caveat_is_visible_beside_original_and_translation_without_rewriting(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            page = root / 'page.jpg'
            page.write_bytes(b'reviewed source page')
            source = {'sha256': 'source-hash', 'path': 'paper.pdf', 'engine': 'fixture',
                      'pages': [{'page': 1, 'text': 'Original convention.'}], 'reading_blocks': [],
                      'blocks': [{'id': 'a', 'page': 1, 'text': 'Original convention.'},
                                 {'id': 'b', 'page': 1, 'text': 'Another passage.'}],
                      'figures': [{'page': 1, 'path': str(page)}]}
            learning = {'mode': 'llm', 'title': 'Paper', 'overview': 'Overview', 'gaps': [],
                        **{key: [] for key in ('methods', 'findings', 'transfer', 'equations', 'figures_tables', 'quiz', 'glossary', 'critique')},
                        'clean_reading': [{'id': 'a', 'source_ids': ['a'], 'text': 'Original convention.'},
                                          {'id': 'b', 'source_ids': ['b'], 'text': 'Another passage.'}],
                        'paragraphs': [{'source_id': 'a', 'source_ids': ['a'], 'explanation': '原文表述。'}]}
            note = {'text': 'The source convention differs from U < 0.', 'source_ids': ['a'],
                    'verification': {'pages': [1], 'page_image_sha256': {'1': sha256(page)}, 'method': 'fixture source review'}}
            bundle = {'source_sha256': source['sha256'], 'reviewer': 'test', 'reading_notes': [note]}
            review = root / 'review.json'
            write_json(review, bundle)
            original_source = copy.deepcopy(source)
            artifacts = apply_editorial_review(learning, source, load_editorial_review(review, source), root)
            self.assertEqual(source, original_source)
            self.assertEqual(learning['clean_reading'][0]['text'], 'Original convention.')
            self.assertEqual(learning['paragraphs'][0]['explanation'], '原文表述。')
            self.assertNotIn('editorial_notes', learning['clean_reading'][1])
            self.assertFalse(learning['clean_reading'][0]['editorial_notes'][0]['human_scientific_acceptance'])
            self.assertEqual(read_json(artifacts['editorial_review_draft'])['clean_reading'][0]['text'], 'Original convention.')
            outputs = render_reading_editions(source, learning, root)
            for key in ('source_markdown', 'paragraph_markdown'):
                self.assertIn(note['text'], Path(outputs[key]).read_text())
            # The fixture has no image metadata; its bytes are evidence only.
            source['figures'] = []
            html = render_guide(source, learning, {'records': []}, root, [])
            self.assertIn('U &lt; 0', Path(html['html']).read_text())
            source['figures'] = original_source['figures']
            page.write_bytes(b'changed source page')
            with self.assertRaises(PipelineError):
                load_editorial_review(review, source)

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
            conflicting = copy.deepcopy(bundle)
            other = copy.deepcopy(conflicting['equations'][0])
            other['equation']['label'] = 'S1'
            other['replace_labels'] = ['Eq. 1']
            conflicting['equations'].append(other)
            write_json(path, conflicting)
            with self.assertRaisesRegex(PipelineError, '别名'):
                load_editorial_review(path, source)
            write_json(path, bundle)
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

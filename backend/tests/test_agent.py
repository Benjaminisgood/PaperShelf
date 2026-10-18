from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from papershelf_pipeline.agent import answer, search, _fuse_matches, _page_context
from papershelf_pipeline.contracts import PipelineError


class AgentEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.manifest = self.root / 'agent.json'
        self.blocks = [
            {'id':'p1-g1', 'page':1, 'text':'Case I: Results and figures. Case I is the first example.'},
            {'id':'p2-g2', 'page':2, 'text':'Simulated concentration profiles were evenly spaced with a time step of 0.4 time unit. The physical unit was unspecified.'},
            {'id':'p3-g3', 'page':3, 'text':'The rate constant was measured at fixed temperature.'},
        ]
        (self.root / 'source.json').write_text(json.dumps({'blocks':self.blocks}))
        (self.root / 'extraction.json').write_text('{}')
        self.manifest.write_text(json.dumps({'name':'A kinetics paper', 'source_path':'source.json', 'extraction_path':'extraction.json'}))

    def tearDown(self):
        self.temporary.cleanup()

    def diagnostics(self):
        return [json.loads(line) for line in (self.root / 'agent-diagnostics.jsonl').read_text().splitlines()]

    def test_chinese_query_expands_even_with_incidental_english_match(self):
        provider = Mock()
        provider.json.side_effect = [
            {'queries':['What was the simulated time step?', 'time unit physical unit']},
            {'answer':'时间间隔为0.4 time unit，物理单位未指定 [p2-g2]。', 'source_ids':['p2-g2']},
        ]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'Case I 的模拟时间步长和物理单位是什么？', 'llm', limit=1)
        self.assertEqual(result['citations'][0]['block_id'], 'p2-g2')
        self.assertEqual(result['citations'][0]['text'], self.blocks[1]['text'])
        request = json.loads(provider.json.call_args_list[1].args[1])
        self.assertEqual(request['evidence'][0]['text'], self.blocks[1]['text'])
        diagnostic = self.diagnostics()[0]
        self.assertEqual(diagnostic['initial_match_count'], 1)
        self.assertEqual(diagnostic['expansion_query_count'], 2)

    def test_pure_chinese_query_repairs_only_missing_citations_with_full_evidence(self):
        provider = Mock()
        query = '第一个合成反应案例的模拟时间步长是多少？原文是否明确给出了秒这一物理单位？'
        first_response = {'answer':'没有引用的回答，私密文本must-not-log-this', 'source_ids':[]}
        provider.json.side_effect = [
            {'queries':['simulation time step', 'physical unit']}, first_response,
            {'answer':'原文报告0.4 time unit，未给出具体物理单位 [p2-g2]。', 'source_ids':['p2-g2']},
        ]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, query, 'llm', provider_config={'api_key':'must-not-log-this'})
        self.assertEqual(len(result['citations']), 1)
        initial = json.loads(provider.json.call_args_list[1].args[1])
        retry = json.loads(provider.json.call_args_list[2].args[1])
        self.assertEqual(retry['question'], query)
        self.assertEqual(retry['evidence'], initial['evidence'])
        self.assertEqual(retry['previous_response'], first_response)
        self.assertIn('不能猜ID', retry['validation_feedback'])
        diagnostic_text = (self.root / 'agent-diagnostics.jsonl').read_text()
        self.assertNotIn('must-not-log-this', diagnostic_text)
        self.assertNotIn(query, diagnostic_text)
        self.assertEqual([item['status'] for item in self.diagnostics()[1:]], ['missing_citations','accepted'])

    def test_repeated_missing_citations_fails_after_one_repair(self):
        provider = Mock()
        provider.json.return_value = {'answer':'尚不能确定。','source_ids':[]}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            with self.assertRaisesRegex(PipelineError, '修正后仍未提供'):
                answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 2)
        self.assertEqual([item['status'] for item in self.diagnostics()[1:]], ['missing_citations','missing_citations'])

    def test_missing_inline_citation_can_be_repaired_without_inventing_one_locally(self):
        provider = Mock()
        provider.json.side_effect = [
            {'answer':'The step is 0.4 time unit.','source_ids':['p2-g2']},
            {'answer':'The step is 0.4 time unit [p2-g2].','source_ids':['p2-g2']},
        ]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 2)
        self.assertEqual(result['answer'], 'The step is 0.4 time unit [p2-g2].')

    def test_persistently_invalid_sources_are_rejected_after_one_repair(self):
        for response in [
            {'answer':'Claim [invented-secret-id].','source_ids':[]},
            {'answer':'Claim [p2-g2].','source_ids':['invented-secret-id']},
            {'answer':'Claim [p2-g2].','source_ids':[{'id':'p2-g2'}]},
            {'answer':'Claim [p2-g2].','source_ids':'p2-g2'},
            {'answer':'','source_ids':[]},
        ]:
            with self.subTest(response=response):
                provider = Mock()
                provider.json.return_value = response
                with patch('papershelf_pipeline.agent.Provider', return_value=provider):
                    with self.assertRaises(PipelineError):
                        answer(self.manifest, 'time step rate constant', 'llm')
                self.assertEqual(provider.json.call_count, 1 if not response['answer'] else 2)
        self.assertNotIn('invented-secret-id', (self.root / 'agent-diagnostics.jsonl').read_text())

    def test_unknown_citation_can_be_corrected_only_by_model_with_same_evidence(self):
        provider = Mock()
        wrong = {'answer':'原文报告一个时间间隔 [p99-g999]。','source_ids':['p99-g999']}
        corrected = {'answer':'原文报告0.4 time unit [p2-g2]。','source_ids':['p2-g2']}
        provider.json.side_effect = [wrong, corrected]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 2)
        first = json.loads(provider.json.call_args_list[0].args[1])
        retry = json.loads(provider.json.call_args_list[1].args[1])
        self.assertEqual(retry['evidence'], first['evidence'])
        self.assertEqual(retry['previous_response'], wrong)
        self.assertEqual(retry['allowed_source_ids'], [item['block_id'] for item in first['evidence']])
        self.assertEqual(retry['validation_error'], 'invalid_citations')
        self.assertEqual(result['answer'], corrected['answer'])
        self.assertEqual(result['citations'][0]['text'], self.blocks[1]['text'])
        self.assertEqual([item['status'] for item in self.diagnostics()[1:]], ['invalid_citations','accepted'])

    def test_protocol_placeholder_with_other_valid_citations_requires_model_repair(self):
        provider = Mock()
        wrong = {'answer':'无法判断该结论 [block_id]。原文报告时间间隔 [p2-g2]。','source_ids':['p2-g2']}
        corrected = {'answer':'原文报告0.4 time unit [p2-g2]。','source_ids':['p2-g2']}
        provider.json.side_effect = [wrong, corrected]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 2)
        self.assertEqual(result['answer'], corrected['answer'])
        retry = json.loads(provider.json.call_args_list[1].args[1])
        self.assertEqual(retry['previous_response'], wrong)
        self.assertEqual(retry['validation_error'], 'invalid_citations')

    def test_persistent_protocol_placeholders_are_rejected_including_numbered_variants(self):
        for placeholder in ['block_id','source_id','block_id1','source_id_2','BLOCK_ID_3','source_ids','见block_id',
                            'block_id, p2-g2','source_id: missing','block_id: p99-g999']:
            with self.subTest(placeholder=placeholder):
                provider = Mock()
                provider.json.return_value = {'answer':f'Claim [{placeholder}] and [p2-g2].','source_ids':['p2-g2']}
                with patch('papershelf_pipeline.agent.Provider', return_value=provider):
                    with self.assertRaises(PipelineError):
                        answer(self.manifest, 'time step', 'llm')
                self.assertEqual(provider.json.call_count, 2)

    def test_math_brackets_and_grouped_citations_are_distinguished(self):
        provider = Mock()
        provider.json.return_value = {'answer':'区间[0, 50]不自动代表95%；浓度[A]与变量[x_1, x_2]是数学记号 [p2-g2, p3-g3]。', 'source_ids':['p2-g2','p3-g3']}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'time step rate constant', 'llm')
        self.assertEqual(provider.json.call_count, 1)
        self.assertEqual({item['block_id'] for item in result['citations']}, {'p2-g2','p3-g3'})
        self.assertEqual(result['answer'], provider.json.return_value['answer'])

    def test_source_list_mismatch_repairs_once_with_identical_evidence(self):
        provider = Mock()
        provider.json.side_effect = [
            {'answer':'Claim [p2-g2].','source_ids':['p2-g2','p3-g3']},
            {'answer':'Claim [p2-g2].','source_ids':['p2-g2']},
        ]
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'time step rate constant', 'llm')
        self.assertEqual(provider.json.call_count, 2)
        first = json.loads(provider.json.call_args_list[0].args[1])
        retry = json.loads(provider.json.call_args_list[1].args[1])
        self.assertEqual(first['evidence'], retry['evidence'])
        self.assertEqual(result['citations'][0]['block_id'], 'p2-g2')

    def test_decorated_groups_are_accepted_but_unknown_identifier_is_rejected(self):
        provider = Mock()
        for text in ['Claim [p2-g2 and p3-g3].', 'Claim [见 p2-g2] and [p3-g3].',
                     'Claim [p2-g2 & p3-g3].', 'Claim [证据：p2-g2；以及p3-g3].',
                     'Claim [block_id: p2-g2] and [source_id: p3-g3].',
                     'Claim [source_ids：p2-g2, p3-g3].']:
            with self.subTest(text=text):
                provider.reset_mock()
                provider.json.return_value = {'answer':text,'source_ids':['p2-g2','p3-g3']}
                with patch('papershelf_pipeline.agent.Provider', return_value=provider):
                    result = answer(self.manifest, 'time step rate constant', 'llm')
                self.assertEqual(provider.json.call_count, 1)
                self.assertEqual(result['answer'], text)
        provider.reset_mock()
        provider.json.return_value = {'answer':'Claim [见p99-g999；p2-g2].','source_ids':['p2-g2']}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            with self.assertRaises(PipelineError):
                answer(self.manifest, 'time step rate constant', 'llm')
        self.assertEqual(provider.json.call_count, 2)

    def test_llm_receives_complete_same_page_context_in_source_order(self):
        blocks = [
            {'id':'p1-g1','page':1,'text':'Front matter.'},
            {'id':'p8-g77','page':8,'text':'3.1 Case I: First synthetic example.\n'},
            {'id':'p8-g100','page':8,'text':'Intermediate original paragraph. ' * 300},
            {'id':'p8-g87','page':8,'document_id':'main','text':'The simulation time step is 0.4 time unit.\n'},
            {'id':'p9-g101','page':9,'text':'A different page.'},
            {'id':'s1-p8-g1','page':8,'document_id':'s1','text':'A supplemental page with the same number.'},
        ]
        source_path = self.root / 'source.json'
        source_path.write_text(json.dumps({'blocks':blocks,'outline':[]}))
        original_source = source_path.read_bytes()
        provider = Mock()
        provider.json.return_value = {'answer':'The Case I heading precedes the reported time step [p8-g77][p8-g87].',
                                      'source_ids':['p8-g77','p8-g87']}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            result = answer(self.manifest, 'simulation time step', 'llm', limit=1)
        self.assertEqual(provider.json.call_count, 1)
        request = json.loads(provider.json.call_args.args[1])
        evidence = request['evidence']
        self.assertEqual([item['block_id'] for item in evidence], ['p8-g77','p8-g100','p8-g87'])
        self.assertEqual([item['text'] for item in evidence], [item['text'] for item in blocks[1:4]])
        self.assertEqual([item['source_block_order'] for item in evidence], [2,3,4])
        self.assertEqual([item['page_block_order'] for item in evidence], [1,2,3])
        self.assertEqual([item['retrieval_match'] for item in evidence], [False,False,True])
        self.assertTrue(all(item['document_id'] == 'main' for item in evidence))
        self.assertEqual(request['allowed_source_ids'], ['p8-g77','p8-g100','p8-g87'])
        self.assertIn('未推断章节', request['evidence_context']['scope'])
        self.assertEqual([item['block_id'] for item in result['citations']], ['p8-g77','p8-g87'])
        self.assertEqual(source_path.read_bytes(), original_source)
        diagnostic = self.diagnostics()[0]
        self.assertEqual(diagnostic['retrieved_ids'], ['p8-g87'])
        self.assertEqual(diagnostic['evidence_ids'], ['p8-g77','p8-g100','p8-g87'])

    def test_supplement_page_context_excludes_same_numbered_main_page(self):
        source = {'blocks':[
            {'id':'p2-g1','page':2,'text':'Main document.'},
            {'id':'s1-p2-g1','document_id':'s1','page':2,'text':'Supplement heading.'},
            {'id':'s1-p2-g2','document_id':'s1','page':2,'text':'Supplement paragraph.'},
            {'id':'s2-p2-g1','document_id':'s2','page':2,'text':'Different supplement.'},
        ]}
        evidence = _page_context(source, [source['blocks'][2]])
        self.assertEqual([item['block_id'] for item in evidence], ['s1-p2-g1','s1-p2-g2'])
        self.assertEqual([item['text'] for item in evidence], ['Supplement heading.','Supplement paragraph.'])
        self.assertEqual([item['page_block_order'] for item in evidence], [1,2])

    def test_persistent_list_mismatch_is_not_accepted(self):
        provider = Mock()
        provider.json.return_value = {'answer':'Claim [p2-g2].','source_ids':['p2-g2','p3-g3']}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            with self.assertRaises(PipelineError):
                answer(self.manifest, 'time step rate constant', 'llm')
        self.assertEqual(provider.json.call_count, 2)

    def test_english_and_offline_paths_do_not_expand_unnecessarily(self):
        provider = Mock()
        provider.json.return_value = {'answer':'0.4 time unit [p2-g2].','source_ids':['p2-g2']}
        with patch('papershelf_pipeline.agent.Provider', return_value=provider) as constructor:
            result = answer(self.manifest, 'time step', 'offline')
            constructor.assert_not_called()
            self.assertIn(self.blocks[1]['text'], result['answer'])
            answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 1)

    def test_rank_fusion_does_not_compare_raw_scores_across_queries(self):
        high_score = {'id':'unrelated','score':9999}
        target = {'id':'relevant','score':0.1}
        result = _fuse_matches([[high_score], [target], [target]], 1)
        self.assertEqual(result[0]['id'], 'relevant')

    def test_provider_failure_is_logged_without_body_or_retry(self):
        provider = Mock()
        provider.json.side_effect = PipelineError('must-not-log-provider-body')
        with patch('papershelf_pipeline.agent.Provider', return_value=provider):
            with self.assertRaises(PipelineError):
                answer(self.manifest, 'time step', 'llm')
        self.assertEqual(provider.json.call_count, 1)
        self.assertEqual(self.diagnostics()[-1]['event'], 'provider_failure')
        self.assertNotIn('must-not-log-provider-body', (self.root / 'agent-diagnostics.jsonl').read_text())

    def test_english_inflection_and_question_words_do_not_hide_caption_evidence(self):
        source = {'blocks':[
            {'id':'caption','page':1,'text':'The shaded region indicates 4 standard deviation intervals.'},
            {'id':'prose','page':2,'text':'In the paper we discuss what the model is and how the predictions are evaluated.'},
        ]}
        singular = search(source, 'standard deviation interval', 1)
        plural = search(source, 'What are the standard deviations of the intervals in the paper?', 1)
        self.assertEqual(singular[0]['id'], 'caption')
        self.assertEqual(plural[0]['id'], 'caption')
        self.assertEqual(plural[0]['text'], source['blocks'][0]['text'])

    def test_fusion_keeps_each_subquestion_top_evidence(self):
        def ranked(*identifiers):
            return [{'id':identifier,'score':1} for identifier in identifiers]
        result = _fuse_matches([
            ranked('overview','common-a','common-b','special'),
            ranked('overview','common-a','common-b'),
            ranked('special','common-a','common-b'),
        ], 3)
        self.assertIn('special', [item['id'] for item in result])
        self.assertIn('overview', [item['id'] for item in result])

    def test_real_paper_captions_survive_plural_and_multiquery_retrieval(self):
        source = json.loads((Path(__file__).parent / 'fixtures/agent-bcrnn-retrieval.json').read_text())
        captions = {'p5-g202','p7-g246','p8-g309','p9-g350','p10-g366'}
        queries = ['What standard deviations are displayed in prediction intervals?',
                   'standard deviation interval', 'uncertainty prediction confidence']
        rankings = [search(source, query, 8) for query in queries]
        self.assertGreaterEqual(len({item['id'] for item in rankings[0]} & captions), 3)
        self.assertIn(rankings[1][0]['id'], captions)
        combined = _fuse_matches(rankings, 8)
        found = [item for item in combined if item['id'] in captions]
        self.assertTrue(found)
        original = {item['id']:item['text'] for item in source['blocks']}
        self.assertTrue(all(item['text'] == original[item['id']] for item in found))
        self.assertTrue(all('4 standard deviation' in item['text'] for item in found))


if __name__ == '__main__':
    unittest.main()

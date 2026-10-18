from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError, write_json
from papershelf_pipeline.generation import make_learning, prompt_block, translation_units, validate_chunk, validate_paragraph
from papershelf_pipeline.learning_review import apply_corrections, load_corrections
from test_pipeline import chunk_response


class MappingTests(unittest.TestCase):
    def setUp(self):
        self.blocks = [
            {'id':'p1-g1','page':1,'text':'The rate is 2 mol/s.','source_anchor':'The rate is 2 mol/s.'},
            {'id':'p1-g2','page':1,'text':'The temperature is 25 C.','source_anchor':'The temperature is 25 C.'},
        ]

    def test_swapped_anchor_and_fake_missing_text_rejected(self):
        result = chunk_response({'source_blocks':self.blocks})
        wrong = copy.deepcopy(result)
        wrong['paragraphs'][0]['source_anchor'] = self.blocks[1]['source_anchor']
        with self.assertRaisesRegex(PipelineError,'source_anchor'):
            validate_chunk(wrong,self.blocks,[])
        wrong = copy.deepcopy(result)
        wrong['paragraphs'][0]['explanation'] = '输入未提供此块文本，无法译述。'
        with self.assertRaisesRegex(PipelineError,'占位'):
            validate_chunk(wrong,self.blocks,[])
        wrong['paragraphs'][0]['explanation'] = '该块的原文缺失，无法处理。'
        with self.assertRaisesRegex(PipelineError,'占位'):
            validate_chunk(wrong,self.blocks,[])

    def test_verbatim_fragment_is_preserved_but_not_called_sentence(self):
        result = chunk_response({'source_blocks':self.blocks})
        result['paragraphs'][0]['key_sentence'] = 'The rate is'
        validated = validate_chunk(result,self.blocks,[])
        self.assertEqual(validated['paragraphs'][0]['key_sentence'],'')
        self.assertEqual(validated['paragraphs'][0]['incomplete_key_excerpt'],'The rate is')
        self.assertTrue(any('p1-g1' in gap for gap in validated['gaps']))
        result['paragraphs'][0]['key_sentence'] = 'The rate is 3 mol/s.'
        with self.assertRaisesRegex(PipelineError,'来源不符'):
            validate_chunk(result,self.blocks,[])

    def test_targeted_paragraph_repair_keeps_valid_scientific_sections(self):
        blocks = self.blocks
        calls = []
        class Provider:
            def json(self,system,prompt):
                request = json.loads(prompt)
                calls.append(request)
                if 'source_blocks' in request:
                    result = chunk_response(request)
                    if len(calls)==1:
                        result['paragraphs'][0]['source_anchor'] = blocks[1]['source_anchor']
                    return result
                return {'overview':'完整概览','reading_route':['核对原文']}
        with tempfile.TemporaryDirectory() as directory:
            source = {'path':'test.md','blocks':blocks}
            learning,_ = make_learning(source,{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual([block['id'] for block in calls[1]['source_blocks']],['p1-g1'])
        self.assertEqual([paragraph['source_id'] for paragraph in learning['paragraphs']],['p1-g1','p1-g2'])
        self.assertEqual(len(learning['findings']),1)

    def test_missing_paragraphs_are_filled_without_regenerating_valid_paragraphs(self):
        calls = []
        class Provider:
            def json(self,system,prompt):
                request = json.loads(prompt)
                calls.append(request)
                if 'source_blocks' in request:
                    result = chunk_response(request)
                    if len(calls)==1:
                        result['paragraphs'] = result['paragraphs'][:1]
                    return result
                return {'overview':'完整概览','reading_route':['核对完整来源与条件']}
        with tempfile.TemporaryDirectory() as directory:
            learning,_ = make_learning({'path':'test.md','blocks':self.blocks},{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual([block['id'] for block in calls[1]['source_blocks']],['p1-g2'])
        self.assertEqual(len(learning['paragraphs']),2)

    def test_resume_rejects_old_layout_even_when_pdf_hash_matches(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = Path(directory)/'previous'
            current = Path(directory)/'current'
            previous.mkdir(); current.mkdir()
            source = {'path':'test.pdf','document_set_sha256':'same-pdf','block_layout':'semantic-v1','blocks':self.blocks}
            old_source = copy.deepcopy(source)
            old_source['block_layout'] = 'raw-lines-v1'
            request = {'mode':'llm','fields':[],'resume_from':str(previous)}
            write_json(previous/'request.json',request)
            write_json(previous/'source.json',old_source)
            with self.assertRaisesRegex(PipelineError,'来源段落分组'):
                make_learning(source,request,current,None,lambda _:None)

    def test_nonresearch_document_can_have_explicitly_empty_scientific_sections(self):
        class Provider:
            def json(self,system,prompt):
                request = json.loads(prompt)
                if 'source_blocks' not in request:
                    return {'overview':'这是一份活动通知，来源不包含实验方法或研究结果。','reading_route':['核对完整来源与条件']}
                result = chunk_response(request)
                for key in ('methods','findings','critique','transfer','equations','quiz','glossary'):
                    result[key] = []
                return result
        source = {'path':'notice.md','blocks':[{'id':'p1-b1','page':1,'text':'Welcome to the seminar.'}]}
        with tempfile.TemporaryDirectory() as directory:
            learning,_ = make_learning(source,{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual(learning['methods'],[])
        self.assertEqual(len(learning['paragraphs']),1)
        self.assertTrue(any('实验或模型方法' in gap for gap in learning['gaps']))

    def test_long_prose_requires_every_sentence_and_rebuilds_full_translation(self):
        text=' '.join(f'The experiment number {index} used all concentration measurements to infer the complete reaction network and its uncertainty.' for index in range(10))
        block={'id':'p1-g1','page':1,'text':text,'source_anchor':text[:96]}
        units=translation_units(block)
        self.assertEqual(''.join(unit['text'] for unit in units),text)
        self.assertEqual(len(units),10)
        result=chunk_response({'source_blocks':[prompt_block(block)]})
        result['paragraphs'][0]['explanation']='仅前一句摘要。'
        validated=validate_chunk(result,[block],[])
        self.assertIn('experiment number 9',validated['paragraphs'][0]['explanation'])
        result['paragraphs'][0]['translation_units'].pop()
        with self.assertRaisesRegex(PipelineError,'逐句译述单元不完整'):
            validate_chunk(result,[block],[])

    def test_key_only_repair_never_rewrites_complete_explanation(self):
        original='完整译述：速率是2 mol/s，保持原来的完整解释。'
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt)
                calls.append(request)
                if 'key_sentence_corrections' in request.get('schema',{}):
                    return {'key_sentence_corrections':[{'source_id':'p1-g1','key_sentence':'The rate is 2 mol/s.'}]}
                if 'source_blocks' in request:
                    result=chunk_response(request)
                    result['paragraphs'][0].update(explanation=original,key_sentence='The rate is 999 mol/s.')
                    return result
                return {'overview':'完整概览','reading_route':['核对完整来源与条件']}
        with tempfile.TemporaryDirectory() as directory:
            learning,_=make_learning({'path':'test.md','blocks':self.blocks[:1]},{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual(learning['paragraphs'][0]['explanation'],original)
        self.assertIn('key_sentence_corrections',calls[1]['schema'])

    def test_failed_optional_quote_is_removed_with_diagnostic_and_never_displayed(self):
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt)
                if 'key_sentence_corrections' in request.get('schema',{}):
                    return {'key_sentence_corrections':[{'source_id':'p1-g1','key_sentence':'The rate is 999 mol/s.'}]}
                if 'source_blocks' in request:
                    result=chunk_response(request)
                    result['paragraphs'][0]['key_sentence']='The rate is 999 mol/s.'
                    return result
                return {'overview':'完整概览','reading_route':['核对完整来源与条件']}
        with tempfile.TemporaryDirectory() as directory:
            learning,_=make_learning({'path':'test.md','blocks':self.blocks[:1]},{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual(learning['paragraphs'][0]['key_sentence'],'')
        self.assertEqual(learning['paragraphs'][0]['rejected_key_sentence'],'The rate is 999 mol/s.')
        self.assertTrue(any('已从学习稿移除' in gap for gap in learning['gaps']))

    def test_review_correction_requires_exact_original_and_keeps_preceding_version(self):
        result=chunk_response({'source_blocks':self.blocks})
        source={'path':'paper.pdf','blocks':self.blocks}
        correction={'paper':'paper','chunk':1,'section':'methods','field':'body','source_ids':['p1-g1'],'original':result['methods'][0]['body'],'corrected':'原文只明确给出速率。','reason':'不加入未引用条件。'}
        with tempfile.TemporaryDirectory() as directory:
            chunks=Path(directory)/'chunks'; chunks.mkdir()
            corrected=apply_corrections(result,source,1,[correction],chunks,[])
            self.assertEqual(corrected['methods'][0]['body'],correction['corrected'])
            self.assertTrue((chunks/'chunk-0001-before-review.json').is_file())
            correction['original']='wrong original'
            correction['corrected']='different correction'
            with self.assertRaisesRegex(PipelineError,'唯一'):
                apply_corrections(result,source,1,[correction],chunks,[])

    def test_multiple_chunks_key_repair_does_not_overwrite_editorial_corrections(self):
        blocks=[{'id':f'p1-g{index}','page':1,'text':('The complete reaction experiment retained every measured concentration and uncertainty. '*30).strip()} for index in (1,2,3)]
        class Provider:
            first_calls=0
            def json(self,system,prompt):
                request=json.loads(prompt)
                if 'key_sentence_corrections' in request.get('schema',{}):
                    return {'key_sentence_corrections':[{'source_id':block['id'],'key_sentence':'Still not in the source.'} for block in request['source_blocks']]}
                if set(request.get('schema',{}))=={'equations','gaps'}:
                    return {'equations':chunk_response(request)['equations'],'gaps':[]}
                if 'source_blocks' in request:
                    result=chunk_response(request)
                    if request['source_blocks'][0]['id']=='p1-g1':
                        self.first_calls+=1
                        result['paragraphs'][0]['key_sentence']='A fabricated sentence.'
                        if self.first_calls==1:
                            result['paragraphs'][0]['translation_units']=[]
                            result['equations'][0]['symbols']=[]
                    return result
                return {'overview':'全部分块的概览','reading_route':['核对完整来源与条件']}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            corrections=[{'paper':'paper','chunk':2,'section':'methods','field':'body','source_ids':['p1-g2'],'original':'在 25 °C 下测定速率。','corrected':'原文保留全部浓度测量。','reason':'不加入原文未给出的温度。'}]
            write_json(root/'corrections.json',corrections)
            learning,_=make_learning({'path':'paper.pdf','blocks':blocks},{'mode':'llm','fields':[],'chunk_characters':2000,'review_corrections_path':str(root/'corrections.json')},root,Provider(),lambda _:None)
            self.assertEqual(len(learning['paragraphs']),3)
            self.assertEqual(learning['methods'][1]['body'],'原文保留全部浓度测量。')
            self.assertTrue((root/'chunks/chunk-0003.json').exists())

    def test_log_form_reuses_only_same_numbered_definition_with_its_sources(self):
        result=chunk_response({'source_blocks':self.blocks})
        result['equations']=[{'label':'2','latex':'r=kC','symbols':[{'symbol':'k','meaning':'已提供的速率常数定义'}],'source_ids':['p1-g1']},
                             {'label':'2 (log form)','latex':'r=exp(ln k + ln C)','symbols':[],'source_ids':['p1-g2']}]
        valid=validate_chunk(result,self.blocks,[])
        equation=valid['equations'][1]
        self.assertEqual(equation['symbols'],valid['equations'][0]['symbols'])
        self.assertEqual(equation['source_ids'],['p1-g2','p1-g1'])
        self.assertEqual(equation['symbols_inherited_from']['label'],'2')

    def test_unrequested_fields_are_quarantined_but_requested_evidence_remains_strict(self):
        result=chunk_response({'source_blocks':self.blocks})
        result['records']=[{'label':'sample','values':{'unexpected':{'value':999,'evidence':[]}}}]
        valid=validate_chunk(result,self.blocks,[])
        self.assertEqual(valid['records'][0]['values'],{})
        self.assertEqual(valid['rejected_fields'][0]['model_output']['value'],999)
        fields=[{'name':'rate','type':'number'}]
        result['records'][0]['values']['rate']={'value':2,'status':'supported','evidence':[{'block_id':'p1-g1','page':1,'quote':'A fabricated numeric quote'}]}
        with self.assertRaisesRegex(PipelineError,'证据引文'):
            validate_chunk(result,self.blocks,fields)

    def test_editorial_unit_correction_recomposes_explanation_and_keeps_coverage(self):
        block={'id':'p1-g1','page':1,'text':('The network has weights and biases that encode kinetic parameters. '*12).strip()}
        response=chunk_response({'source_blocks':[prompt_block(block)]})
        original=response['paragraphs'][0]['translation_units']
        corrected=copy.deepcopy(original);corrected[0]['translation']='神经网络的权重和偏置编码动力学参数。'
        correction={'paper':'paper','chunk':1,'section':'paragraphs','field':'translation_units','source_ids':['p1-g1'],'original':original,'corrected':corrected,'reason':'将神经网络biases准确译为偏置。'}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'chunks').mkdir();write_json(root/'review.json',[correction])
            loaded=load_corrections({'review_corrections_path':str(root/'review.json')})
            result=apply_corrections(response,{'path':'paper.pdf','blocks':[block]},1,loaded,root/'chunks',[])
            validate_chunk(result,[block],[])
        self.assertTrue(result['paragraphs'][0]['explanation'].startswith('神经网络的权重和偏置'))
        self.assertEqual(len(result['paragraphs'][0]['translation_units']),len(translation_units(block)))

    def test_ellipsis_evidence_expands_only_ordered_verbatim_segments_in_one_block(self):
        block={'id':'p8-g78','page':8,'text':'The first network comprises five species. Since the rate constants have no temperature dependence, mass action applies.'}
        fields=[{'name':'study_system','type':'string'}]
        result=chunk_response({'source_blocks':[block]})
        original='The first network... Since the rate constants have no temperature dependence'
        result['records']=[{'values':{'study_system':{'value':'First network','status':'supported','evidence':[{'block_id':block['id'],'page':7,'quote':original}]}}}]
        valid=validate_chunk(result,[block],fields)
        evidence=valid['records'][0]['values']['study_system']['evidence'][0]
        self.assertEqual(evidence['quote'],block['text'])
        self.assertEqual(evidence['original_quote'],original)
        self.assertEqual(evidence['page'],8)
        self.assertEqual(evidence['original_page'],7)
        for quote in ('Since the rate constants... The first network','The second network... mass action applies','The first network... A fabricated ending'):
            wrong=copy.deepcopy(result)
            wrong['records'][0]['values']['study_system']['evidence'][0]={'block_id':block['id'],'page':8,'quote':quote}
            with self.assertRaisesRegex(PipelineError,'证据引文'):
                validate_chunk(wrong,[block],fields)

    def test_canonical_page_repair_requires_matching_quote_and_preserves_fact(self):
        fields=[{'name':'rate','type':'number'}]
        result=chunk_response({'source_blocks':self.blocks})
        result['records']=[{'values':{'rate':{'value':2,'status':'supported','evidence':[{'block_id':'p1-g1','page':42,'quote':'The rate is 2 mol/s.'}]}}}]
        valid=validate_chunk(result,self.blocks,fields)
        cell=valid['records'][0]['values']['rate']
        self.assertEqual(cell['value'],2)
        self.assertEqual(cell['evidence'][0]['page'],1)
        self.assertEqual(cell['evidence'][0]['original_page'],42)
        wrong=copy.deepcopy(result)
        wrong['records'][0]['values']['rate']['evidence'][0]={'block_id':'p1-g1','page':42,'quote':'The rate is 3 mol/s.'}
        with self.assertRaisesRegex(PipelineError,'证据引文'):
            validate_chunk(wrong,self.blocks,fields)
        self.assertEqual(wrong['records'][0]['values']['rate']['evidence'][0]['page'],42)

    def test_calculation_and_analysis_repairs_keep_good_translations(self):
        calls=[]
        block=self.blocks[0]
        original='完整译文不可因计算修复而改写。'
        calculation={'title':'速率校验','expression':'total = rate; total','variables':[{'name':'rate','value':2,'unit':'mol/s',
            'evidence':[{'block_id':block['id'],'page':1,'quote':block['text']}]}],'source_ids':[block['id']]}
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                if set(request.get('schema',{}))=={'methods','gaps'}:
                    return {'methods':[{'title':'来源数据','body':'原文速率为2 mol/s。','source_ids':[block['id']]}],'gaps':[]}
                if set(request.get('schema',{}))=={'calculations','gaps'}:
                    fixed=copy.deepcopy(calculation);fixed['expression']='rate'
                    return {'calculations':[fixed],'gaps':[]}
                if 'source_blocks' in request:
                    result=chunk_response(request)
                    result['paragraphs'][0]['explanation']=original
                    result['methods'][0]['source_ids']=['nonexistent-neighbor']
                    result['calculations']=[copy.deepcopy(calculation)]
                    return result
                return {'overview':'已校验的概览','reading_route':['核对完整来源与条件']}
        with tempfile.TemporaryDirectory() as directory:
            learning,_=make_learning({'path':'test.md','blocks':[block]},{'mode':'llm','fields':[]},Path(directory),Provider(),lambda _:None)
        self.assertEqual(learning['paragraphs'][0]['explanation'],original)
        self.assertEqual(learning['calculations'][0]['computed_value'],2)
        self.assertEqual(set(calls[1]['schema']),{'methods','gaps'})
        self.assertEqual(set(calls[2]['schema']),{'calculations','gaps'})

    def test_reviewed_chunk_summary_is_used_for_final_synthesis(self):
        original=chunk_response({'source_blocks':self.blocks})['summary']
        corrected='速率来自本段原文，概览必须保留经审阅的表述。'
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                return chunk_response(request) if 'source_blocks' in request else {'overview':request['summaries'][0]['summary'],'reading_route':['核对完整来源与条件']}
        correction={'paper':'paper','chunk':1,'section':'summary','field':'text','source_ids':['p1-g1'],
            'original':original,'corrected':corrected,'reason':'避免综合概览延续已纠正的旧摘要表述。'}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);write_json(root/'review.json',[correction])
            learning,_=make_learning({'path':'paper.pdf','blocks':self.blocks},{'mode':'llm','fields':[],
                'review_corrections_path':str(root/'review.json')},root,Provider(),lambda _:None)
        self.assertEqual(learning['overview'],corrected)
        self.assertEqual(calls[-1]['summaries'][0]['summary'],corrected)

    def test_prose_linewrap_evidence_keeps_hyphen_and_rejects_math_or_changed_words(self):
        fields=[{'name':'study_system','type':'string'}]
        block={'id':'p6-g226','page':6,'text':'The system converts large triglyceride molecules into methyl ester mole-\ncules using this reaction.'}
        def candidate(quote):
            result=chunk_response({'source_blocks':[block]})
            result['records']=[{'values':{'study_system':{'value':'biodiesel','status':'supported','evidence':[{'block_id':block['id'],'page':6,'quote':quote}]}}}]
            return result
        quote='The system converts large triglyceride molecules into methyl ester mole-cules using this reaction.'
        valid=validate_chunk(candidate(quote),[block],fields)
        evidence=valid['records'][0]['values']['study_system']['evidence'][0]
        self.assertEqual(evidence['quote'],block['text'])
        self.assertEqual(evidence['original_quote'],quote)
        with self.assertRaisesRegex(PipelineError,'证据引文'):
            validate_chunk(candidate(quote.replace('mole-cules','molecules')),[block],fields)
        block['text']='x-\ny and 2-\n3 are mathematical expressions.'
        with self.assertRaisesRegex(PipelineError,'证据引文'):
            validate_chunk(candidate('x-y and 2-3 are mathematical expressions.'),[block],fields)

    def test_four_real_prose_truncations_rejected_without_rejecting_math_fragments(self):
        cases=json.loads((Path(__file__).parent/'fixtures/truncated_prose.json').read_text())
        self.assertEqual(len(cases),4)
        for case in cases:
            with self.subTest(source_id=case['block']['id']),self.assertRaisesRegex(PipelineError,'明显过短'):
                validate_paragraph(case['truncated_paragraph'],case['block'])
        block={'id':'p4-g86','page':4,'text':'p(y|D) = p(D|y)p(y)'}
        validate_paragraph({'source_id':block['id'],'explanation':'贝叶斯后验公式的分子片段；分母另列。','key_sentence':''},block)

    def test_overview_repairs_only_summary_and_saves_every_invalid_response(self):
        calls=[]
        class Provider:
            overviews=0
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append((system,request))
                if 'source_blocks' in request:return chunk_response(request)
                self.overviews+=1
                if self.overviews==1:return {'summary':'错误的键'}
                if self.overviews==2:return {'overview':'概览','reading_route':'错误的字符串'}
                return {'overview':'已修正概览','reading_route':['逐段核对完整原文']}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            learning,_=make_learning({'path':'paper.md','blocks':self.blocks},{'mode':'llm','fields':[]},root,Provider(),lambda _:None)
            self.assertEqual(len(list((root/'chunks').glob('overview-attempt-*.json'))),3)
            self.assertIn('reading_route',json.loads((root/'chunks/overview-attempt-2.json').read_text())['error'])
            self.assertEqual(learning['reading_route'],['逐段核对完整原文'])
        self.assertEqual(sum('source_blocks' in request for _,request in calls),1)
        self.assertNotIn('逐段处理每一个',calls[-1][0])

    def test_overview_exhaustion_never_returns_fake_success_or_discards_chunks(self):
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt)
                return chunk_response(request) if 'source_blocks' in request else {'overview':''}
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            with self.assertRaisesRegex(PipelineError,'综合概览未通过'):
                make_learning({'path':'paper.md','blocks':self.blocks},{'mode':'llm','fields':[]},root,Provider(),lambda _:None)
            self.assertTrue((root/'chunks/chunk-0001.json').is_file())
            self.assertEqual(len(list((root/'chunks').glob('overview-attempt-*.json'))),3)

    def test_real_meta_comments_cannot_replace_prose_translation(self):
        cases=json.loads((Path(__file__).parent/'fixtures/translation_meta_comments.json').read_text())
        self.assertEqual(len(cases),2)
        for case in cases:
            with self.subTest(source_id=case['block']['id']),self.assertRaisesRegex(PipelineError,'元说明'):
                validate_paragraph(case['paragraph'],case['block'])


if __name__=='__main__':
    unittest.main()

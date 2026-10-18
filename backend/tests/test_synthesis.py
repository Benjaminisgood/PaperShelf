from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError
from papershelf_pipeline.generation import make_learning, canonicalize_evidence, translation_units, validate_paragraph
from papershelf_pipeline.synthesis import reading_groups, validate_reading, consolidate_learning, separate_process_notes, polish_reading, polish_translation_units, validate_polished_translation, literal_author_names, quarantine_equations, refresh_grounded_frontmatter, sentence_parts
from test_pipeline import chunk_response


class SynthesisTests(unittest.TestCase):
    def setUp(self):
        self.blocks = [
            {'id':'p1-b1','page':1,'text':'The reaction proceeds at 25 °C.','reading_role':'body'},
            {'id':'p1-b2','page':1,'text':'The rate constant is 2 s^-1.','reading_role':'body'},
            {'id':'p1-b3','page':1,'text':'r = kC (1)','reading_role':'equation_fragment'},
            {'id':'p1-b4','page':1,'text':'Downloaded on 2026','reading_role':'publisher_notice'},
        ]
        group = {'id':'p1-b1','source_ids':['p1-b1','p1-b2'],'text':'The reaction proceeds at 25 °C. The rate constant is 2 s^-1.', 'kind':'body','page':1,'pages':[1], 'reading_main':True}
        fragment = {'id':'p1-b3','source_ids':['p1-b3'],'text':'r = kC (1)','kind':'equation_fragment','page':1,'pages':[1],'reading_main':False}
        self.source = {'path':'paper.pdf','blocks':self.blocks,'reading_blocks':[group,fragment], 'reading_main_blocks':[group], 'reading_fragments':[fragment], 'reading_excluded':[{'id':'p1-b4'}], 'layout_observations':[{'source_ids':['p1-b3'],'kind':'source_conflict','observation':'式中符号须核对。'}]}
        self.groups = reading_groups(self.source)
        self.reading = {'clean_reading':[{'id':group['id'],'source_ids':group['source_ids'],'text':group['text'],'editing_notes':[]}], 'thematic_sections':[{'title':'条件与速率之间的关系','paragraphs':[{'text':'温度限定了速率常数的适用条件，因此应先核对测量环境，再讨论模型与观测之间的联系。','source_ids':['p1-b1','p1-b2'],'kind':'source'}]}]}

    def test_main_reading_uses_full_prose_groups_without_equation_cards(self):
        self.assertEqual([g['id'] for g in self.groups],['p1-b1'])
        value = validate_reading(copy.deepcopy(self.reading),self.groups,self.blocks)
        self.assertEqual(value['clean_reading'][0]['source_ids'],['p1-b1','p1-b2'])
        self.assertEqual(value['clean_reading'][0]['status'],'ai_edited_unreviewed')
        self.assertEqual(value['thematic_sections'][0]['source_ids'],['p1-b1','p1-b2'])

    def test_no_numeric_unit_or_mapping_loss_allowed_in_full_text(self):
        for original,replacement in [('25','26'),('°C','K'),('2 s^-1','2 s^-2')]:
            with self.subTest(original=original):
                value=copy.deepcopy(self.reading)
                value['clean_reading'][0]['text']=value['clean_reading'][0]['text'].replace(original,replacement)
                with self.assertRaises(PipelineError): validate_reading(value,self.groups,self.blocks)
        value=copy.deepcopy(self.reading)
        value['clean_reading'][0]['source_ids']=['p1-b1']
        with self.assertRaises(PipelineError): validate_reading(value,self.groups,self.blocks)

    def test_negative_numeric_sign_is_part_of_preserved_value(self):
        group={'id':'p1-b1','source_ids':['p1-b1'],'text':'The activation energy is -25 kcal mol^-1.', 'kind':'body','page':1,'pages':[1]}
        value=copy.deepcopy(self.reading)
        value['clean_reading']=[{'id':'p1-b1','source_ids':['p1-b1'],'text':'The activation energy is 25 kcal mol^-1.','editing_notes':[]}]
        with self.assertRaisesRegex(PipelineError,'数字'): validate_reading(value,[group],self.blocks)

    def test_equation_cleanup_cannot_change_sign(self):
        group={'id':'p1-b3','source_ids':['p1-b3'],'text':'H = K - L (1)','kind':'equation','page':1,'pages':[1]}
        value={'clean_reading':[{'id':'p1-b3','source_ids':['p1-b3'],'text':'H = K + L (1)','editing_notes':[]}],'thematic_sections':[]}
        with self.assertRaisesRegex(PipelineError,'公式'): validate_reading(value,[group],self.blocks)

    def test_bad_hmc_convention_rejected_from_teaching(self):
        value=copy.deepcopy(self.reading)
        value['thematic_sections'][0]['paragraphs'][0]['text']='HMC 中势能 L = log posterior，所以 H = K + L。'
        with self.assertRaisesRegex(PipelineError,'负号'): validate_reading(value,self.groups,self.blocks)
        value['thematic_sections'][0]['paragraphs'][0]['text'] += ' 此处与负对数后验约定存在符号疑点，应保留原式并核对。'
        validate_reading(value,self.groups,self.blocks)

    def test_consolidation_cannot_drop_source_or_borrow_unseen_source(self):
        learning={'thematic_sections':self.reading['thematic_sections'],'methods':[],'findings':[],'critique':[],'transfer':[],'quiz':[],'glossary':[]}
        class BadProvider:
            def __init__(self, identifier): self.identifier=identifier
            def json(self, system, prompt):
                output=chunk_response(json.loads(prompt))
                output['thematic_sections'][0]['paragraphs'][0]['source_ids']=[self.identifier]
                return output
        for identifier in ['p1-b1','p1-b3']:
            with tempfile.TemporaryDirectory() as folder:
                root=Path(folder); (root/'chunks').mkdir()
                with self.assertRaises(PipelineError): consolidate_learning(copy.deepcopy(learning),self.source,BadProvider(identifier),root,lambda _:None)
                self.assertTrue((root/'chunks/consolidation-1-invalid-3.json').is_file())

    def test_process_notes_do_not_swallow_scientific_source_doubts(self):
        value={'gaps':['本块的势能符号存在冲突，需对照原式。','字段证据覆盖校验不等于科学验收。','原文未说明 time unit 的物理单位。']}
        separate_process_notes(value)
        self.assertEqual(len(value['gaps']),2)
        self.assertEqual(len(value['process_notes']),1)

    def test_consolidation_can_correct_a_wrong_citation_with_verifiable_evidence(self):
        learning={'findings':[{'title':'速率参数','body':'草稿挂错来源。','source_ids':['p1-b1'],'kind':'source'}]}
        class Provider:
            def json(inner,system,prompt):
                request=json.loads(prompt);output=chunk_response(request)
                if 'items' in request:
                    output['findings'][0]['source_ids']=['p1-b2']
                    output['findings'][0]['body']='速率常数为2 s^-1。'
                    output['coverage'][0]['citation_correction']={'original_source_ids':['p1-b1'],'corrected_source_ids':['p1-b2'],'reason':'原引用仅含温度；第二段明确给出速率常数。','evidence':[{'block_id':'p1-b2','page':1,'quote':self.blocks[1]['text']}]}
                return output
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'chunks').mkdir()
            consolidate_learning(learning,self.source,Provider(),root,lambda _:None)
        self.assertEqual(learning['consolidated']['findings'][0]['source_ids'],['p1-b2'])
        correction=learning['consolidation_review']['coverage'][0]['citation_correction']
        self.assertEqual(correction['original_source_ids'],['p1-b1'])
        self.assertEqual(correction['evidence'][0]['quote'],self.blocks[1]['text'])

    def test_consolidation_empty_sections_use_empty_schema_and_report_all_extras(self):
        learning={'methods':[{'title':'条件','body':'完整保留条件。','source_ids':['p1-b1'],'kind':'source'}]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);output=chunk_response(request)
                if 'items' in request:
                    calls.append(request)
                    if len(calls)==1:
                        output['findings']=[{'title':'多余结果','body':'不属于本批。','source_ids':['p1-b1']}]
                        output['glossary']=[{'term':'多余术语','definition':'不属于本批。','source_ids':['p1-b1']}]
                return output
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'chunks').mkdir()
            consolidate_learning(learning,self.source,Provider(),root,lambda _:None)
        self.assertEqual(calls[0]['allowed_sections'],['methods'])
        self.assertTrue(all(calls[0]['schema'][key]==[] for key in calls[0]['empty_sections']))
        self.assertIn('findings',calls[1]['validation_error'])
        self.assertIn('glossary',calls[1]['validation_error'])

    def test_consolidation_feedback_identifies_all_bad_sources_and_excluded_input_ids(self):
        learning={'methods':[{'title':'条件','body':'完整保留条件。','source_ids':['p1-b1'],'kind':'source'}],
                  'findings':[{'title':'结果','body':'完整保留结果。','source_ids':['p1-b2'],'kind':'source'}]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);output=chunk_response(request)
                if 'items' in request:
                    calls.append(request)
                    if len(calls)==1:
                        output['methods'][0]['source_ids']=['invented-method-source']
                        output['findings'][0]['source_ids']=['invented-finding-source']
                        for row in output['coverage']:
                            row.update(action='excluded',reason='重复内容，试图排除。')
                return output
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'chunks').mkdir()
            consolidate_learning(learning,self.source,Provider(),root,lambda _:None)
        error=calls[1]['validation_error']
        for expected in ('methods[0]','findings[0]','invented-method-source','invented-finding-source','coverage methods-1','coverage findings-1','重复内容，试图排除。'):
            self.assertIn(expected,error)

    def test_consolidation_feedback_lists_all_missing_coverage_and_quote_evidence(self):
        learning={'methods':[{'title':'条件','body':'完整条件。','source_ids':['p1-b1'],'kind':'source'}],
                  'findings':[{'title':'结果','body':'完整结果。','source_ids':['p1-b2'],'kind':'source'}],
                  'transfer':[{'title':'迁移','body':'迁移范围。','source_ids':['p1-b1'],'kind':'inference'}]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);output=chunk_response(request)
                if 'items' in request:
                    calls.append(request)
                    if len(calls)==1:
                        output['methods'][0]['source_ids']=['p1-b2']
                        output['findings'][0]['source_ids']=['p1-b1']
                        row=next(row for row in output['coverage'] if row['input_id']=='transfer-1')
                        row['citation_correction']={'original_source_ids':['p1-b1'],'corrected_source_ids':['p1-b1','p1-b2'],'reason':'补充确切条件。','evidence':[{'block_id':'p1-b1','page':1,'quote':'The reaction proceeds at 25 °C.'}]}
                return output
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'chunks').mkdir()
            consolidate_learning(learning,self.source,Provider(),root,lambda _:None)
        error=calls[1]['validation_error']
        for expected in ('methods-1','findings-1','coverage transfer-1',"缺少ID=['p1-b1']","缺少ID=['p1-b2']","缺少['p1-b2']"):
            self.assertIn(expected,error)

    def test_consolidation_resume_revalidates_completed_batch_with_identical_input(self):
        initial={'methods':[{'title':'条件','body':'完整保留条件。','source_ids':['p1-b1'],'kind':'source'}]}
        for changed in (False,True):
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as folder:
                base=Path(folder);prior=base/'prior';current=base/'current'
                (prior/'chunks').mkdir(parents=True);(current/'chunks').mkdir(parents=True)
                (prior/'source.json').write_text(json.dumps(self.source))
                (prior/'chunks/chunk-0001.json').write_text(json.dumps(initial))
                class InitialProvider:
                    def json(self,system,prompt):return chunk_response(json.loads(prompt))
                consolidate_learning(copy.deepcopy(initial),self.source,InitialProvider(),prior,lambda _:None)
                (current/'request.json').write_text(json.dumps({'resume_from':str(prior)}))
                active=copy.deepcopy(self.source)
                if changed:active['editorial_review_context']={'semantic_constraints':[]}
                calls=[]
                class Provider:
                    def json(self,system,prompt):
                        request=json.loads(prompt)
                        if 'items' in request:calls.append(request)
                        return chunk_response(request)
                consolidate_learning(copy.deepcopy(initial),active,Provider(),current,lambda _:None)
                self.assertEqual(len(calls),int(changed))
                saved=json.loads((current/'chunks/consolidation-1.json').read_text())
                self.assertEqual(bool(saved['_resumed_from']),not changed)

    def test_grounded_gap_review_resolves_later_provided_evidence_without_losing_draft(self):
        learning={'overview':'旧概览','reading_route':['旧路线'],'gaps':['局部草稿声称未报告速率常数。']}
        class Provider:
            def json(inner,system,prompt):
                request=json.loads(prompt);output=chunk_response(request)
                output['reviewed_gaps']=[{'input_gap_id':'gap-001','text':'速率常数在后文明确给出。','source_ids':['p1-b2'],'status':'resolved','reason':'第二段报告2 s^-1，不能保留局部缺失声明。'}]
                return output
        with tempfile.TemporaryDirectory() as folder:
            refresh_grounded_frontmatter(learning,self.source,Provider(),Path(folder),lambda _:None)
        self.assertEqual(learning['gaps'],[])
        self.assertEqual(learning['gaps_drafts'],['局部草稿声称未报告速率常数。'])
        self.assertEqual(learning['reviewed_gaps'][0]['source_ids'],['p1-b2'])

    def test_scientific_sentence_splitter_keeps_references_and_all_characters(self):
        text='Typical loss curves are presented in Fig. S1. The law follows Eq. A. Dr. Smith et al. Report it as No. A, e.g. Data from Fig. 7b. Next we compare the methods.'
        parts=sentence_parts(text)
        self.assertEqual(''.join(parts),text)
        self.assertIn('Fig. S1.',parts[0])
        self.assertFalse(any(part.strip()=='S1.' for part in parts))
        self.assertTrue(any(part.strip().startswith('Next') for part in parts))
        self.assertTrue(any('Dr. Smith et al. Report' in part for part in parts))

    def test_cached_abbreviation_units_merge_only_with_proven_reference_coverage(self):
        text=('We compare the methods using fully preserved measurements and independent validation conditions. '*7+'Typical loss curves are presented in Fig. S1. The training converges after all experiments are processed.')
        block={'id':'p13-g171','page':13,'text':text}
        old=translation_units(block,legacy_sentence_boundaries=True)
        actual=[{'unit_id':unit['id'],'translation':'完整译文：'+unit['text']} for unit in old]
        split=next(i for i,unit in enumerate(old) if unit['text'].strip()=='S1.')
        actual[split-1]['translation']='典型损失曲线见图 S1。'
        actual[split]['translation']=''
        paragraph={'source_id':block['id'],'explanation':'','translation_units':actual,'key_sentence':''}
        validate_paragraph(paragraph,block)
        self.assertTrue(paragraph['translation_units_original'])
        self.assertEqual(len(paragraph['translation_units']),len(translation_units(block)))
        bad={'source_id':block['id'],'explanation':'','translation_units':copy.deepcopy(actual),'key_sentence':''}
        bad['translation_units'][split-1]['translation']='典型损失曲线见图。'
        with self.assertRaises(PipelineError):validate_paragraph(bad,block)

    def test_recorded_reading_quote_restores_exact_raw_without_accepting_arbitrary_text(self):
        from papershelf_pipeline.reading import clean_reading_text
        raw='The reaction converts triglyceride (TG) molecules into methyl ester mole-\ncules.'
        reading,edits,notes=clean_reading_text(raw,{'molecules':1},{})
        block={'id':'p6-g226','page':6,'text':raw,'reading_text':reading,'reading_edits':edits,'reading_role':'body'}
        evidence={'block_id':block['id'],'page':6,'quote':'triglyceride (TG) molecules into methyl ester molecules'}
        canonicalize_evidence(evidence,block)
        self.assertEqual(evidence['quote'],raw)
        self.assertIn('original_quote',evidence)
        false_projection={**block,'reading_text':'A fabricated temperature of 100 K was measured.'}
        fabricated={'block_id':block['id'],'page':6,'quote':false_projection['reading_text']}
        canonicalize_evidence(fabricated,false_projection)
        self.assertNotEqual(fabricated['quote'],raw)
        self.assertNotIn('quote_correction_reason',fabricated)

    def test_grounded_overview_and_figures_keep_raw_sources_and_drafts(self):
        source=copy.deepcopy(self.source)
        source['editorial_review_context']={'source_sha256':'fixture-hash','notes':['保留原文条件。']}
        figure={'label':'Figure 1','reading':'旧图表草稿。','source_ids':['p1-b1','p1-b2'],'page':1}
        learning={'overview':'旧概览夸大了结果。','reading_route':['旧路线。'],'figures_tables':[figure]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                output=chunk_response(request)
                if 'figure_drafts' in request:
                    output['figures_tables'][0]['reading']='依据原文说明条件与速率关系；未提供图像，不能独立确认视觉细节。'
                return output
        with tempfile.TemporaryDirectory() as folder:
            refresh_grounded_frontmatter(learning,source,Provider(),Path(folder),lambda _:None)
            self.assertTrue((Path(folder)/'chunks/grounded-overview.json').is_file())
            self.assertTrue((Path(folder)/'chunks/grounded-figures-001.json').is_file())
        self.assertEqual([b['text'] for b in calls[0]['source_evidence']],[b['text'] for b in source['blocks']])
        self.assertEqual(calls[0]['editorial_review_context'],source['editorial_review_context'])
        self.assertEqual(learning['overview_draft'],'旧概览夸大了结果。')
        self.assertEqual(learning['figures_tables_drafts'],[figure])
        self.assertEqual(learning['figures_tables'][0]['source_ids'],figure['source_ids'])
        self.assertEqual(learning['figures_tables'][0]['page'],1)
        self.assertIn('未提供图像',learning['figures_tables'][0]['reading'])

    def test_pdf_math_glyphs_are_quarantined_with_complete_evidence(self):
        corrupt={'label':'8','latex':'log pðDjyÞ / 1','meaning':'旧PDF提取式','symbols':[{'symbol':'p','meaning':'概率'}], 'source_ids':['p1-b1','p1-b2']}
        trusted={'label':'1','latex':r'\frac{dY}{dt}=S r(Y)','meaning':'浓度变化率','symbols':[{'symbol':'Y','meaning':'浓度'}], 'source_ids':['p1-b2']}
        learning={'equations':[copy.deepcopy(corrupt),copy.deepcopy(trusted)]}
        self.assertEqual(quarantine_equations(learning,self.source),1)
        self.assertEqual(learning['equations'],[trusted])
        unresolved=learning['unresolved_equations'][0]
        self.assertEqual(unresolved['latex'],corrupt['latex'])
        self.assertEqual(unresolved['source_ids'],corrupt['source_ids'])
        self.assertEqual([item['text'] for item in unresolved['source_text']],[block['text'] for block in self.blocks[:2]])
        self.assertEqual(unresolved['reconstruction_status'],'unresolved')
        invalid={'equations':[{**corrupt,'source_ids':['invented']}]}
        self.assertEqual(quarantine_equations(invalid,self.source),0)
        self.assertEqual(len(invalid['equations']),1)

    def test_verified_cross_chunk_conflict_gets_both_canonical_evidence_texts(self):
        text='The model describes the reaction and must be checked against measurements. '*28
        blocks=[{'id':f'p{i}-b1','page':i,'text':text,'reading_role':'body'} for i in (1,2)]
        main=[{'id':b['id'],'source_ids':[b['id']],'text':b['text'],'kind':'body','page':b['page'],'pages':[b['page']]} for b in blocks]
        note={'kind':'source_conflict','source_ids':['p1-b1','p2-b1'],'observation':'图注与下一页正文顺序存在冲突，须并列核对。'}
        source={'path':'paper.pdf','blocks':blocks,'reading_main_blocks':main,'layout_observations':[note]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                if any(key in request for key in ('source_blocks','reading_groups','items')):
                    output=chunk_response(request)
                    if 'source_blocks' in request:
                        output['critique'][0]['source_ids']=['p1-b1','p2-b1']
                    return output
                return chunk_response(request)
        with tempfile.TemporaryDirectory() as folder:
            learning,_=make_learning(source,{'mode':'llm','fields':[],'chunk_characters':2000},Path(folder),Provider(),lambda _:None)
        first=calls[0]
        self.assertEqual(len(first['source_blocks']),1)
        self.assertEqual([b['id'] for b in first['evidence_blocks']],['p1-b1','p2-b1'])
        self.assertEqual(first['verified_layout_observations'],[note])
        self.assertEqual(learning['reading_coverage']['canonical_blocks'],2)
        self.assertEqual(learning['reading_coverage']['auxiliary_source_ids'],[])

    def test_consolidation_receives_complete_deduplicated_canonical_evidence(self):
        source=copy.deepcopy(self.source)
        source['blocks'][0]['text']='RAW scientific evidence with original line breaks.\n'*700+'UNIQUE END OF RAW EVIDENCE'
        unrelated={'source_ids':['p1-b4'],'observation':'Unrelated publisher note.'}
        source['layout_observations'].append(unrelated)
        learning={'thematic_sections':copy.deepcopy(self.reading['thematic_sections']), 'methods':[{'title':'条件','body':'完整保留条件。','source_ids':['p1-b1','p1-b3'],'kind':'source'}]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt); calls.append((system,request))
                return chunk_response(request)
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'chunks').mkdir()
            consolidate_learning(learning,source,Provider(),root,lambda _:None)
        system,request=calls[0]
        self.assertNotIn('source_blocks',request)
        self.assertEqual([b['id'] for b in request['source_evidence']],['p1-b1','p1-b2','p1-b3','p1-b4'])
        self.assertEqual(request['source_evidence'][0]['text'],source['blocks'][0]['text'])
        self.assertTrue(request['source_evidence'][0]['text'].endswith('UNIQUE END OF RAW EVIDENCE'))
        self.assertEqual(request['verified_layout_observations'],source['layout_observations'])
        self.assertIn('addresses the curse of dimensionality',system)
        self.assertIn('to improve generalizability',system)
        self.assertIn('may/could/potential',system)
        self.assertEqual(learning['consolidation_review']['source_evidence_contract'],'canonical-fulltext-v1')

    def test_dedicated_bilingual_polish_repairs_words_and_replaces_summary_translation(self):
        text=('The model is designed to improve predict-ability under challen-ging conditions. '
              'In this equation, Y(t) is the species concentration vector, whereas its derivative is the rate of change in concentration. '
              'A is the pre-exponential factor, T is absolute temperature, b is the temperature exponent, Ea is activation energy, and R is the gas constant.')
        group={'id':'p3-g63','source_ids':['p3-g63'],'text':text,'kind':'body','page':3,'pages':[3]}
        raw=text.replace('predict-ability','predict-\nability').replace('challen-ging','challen-\nging')
        constraint={'id':'source-definition','source_ids':[group['id']],'instruction':'Preserve the source definition; explain any ambiguity beside the original.'}
        source={'blocks':[{'id':group['id'],'page':3,'text':raw}], 'reading_main_blocks':[group], 'editorial_review_context':{'semantic_constraints':[constraint,{'id':'other','source_ids':['other'],'instruction':'Unrelated.'}]}}
        draft={'source_id':group['id'],'explanation':'定义参数并说明方程。'}
        learning={'paragraphs':[draft], 'clean_reading':[]}
        translations=['该模型的设计旨在改善困难条件下的预测能力。', '在该方程中，Y(t)是物种浓度向量，其导数则是浓度的变化速率。', 'A是指前因子，T是绝对温度，b是温度指数，Ea是活化能，R是气体常数。']
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                units=request['reading_groups'][0]['translation_units']
                return {'clean_reading':[{'id':group['id'],'source_ids':group['source_ids'],'text':text.replace('predict-ability','predictability').replace('challen-ging','challenging'), 'translation':'', 'translation_units':[{'unit_id':unit['id'], 'translation':('本段介绍模型的用途。' if len(calls)==1 and i==0 else translations[i])} for i,unit in enumerate(units)], 'editing_notes':['修复确定的英文词内断行。']}]}
        with tempfile.TemporaryDirectory() as folder:
            polished=polish_reading(source,learning,Provider(),Path(folder),lambda _:None)
            self.assertTrue((Path(folder)/'chunks/polish-0001-invalid-1.json').is_file())
        self.assertEqual(len(calls),2)
        self.assertEqual(calls[0]['source_evidence'][0]['text'],raw)
        self.assertEqual(calls[0]['reading_groups'][0]['editorial_constraints'],[constraint])
        self.assertEqual(set(calls[0]['schema']),{'clean_reading'})
        self.assertEqual(''.join(unit['text'] for unit in polish_translation_units(group)),text)
        self.assertIn('predictability',polished[0]['text'])
        self.assertNotIn('predict-ability',polished[0]['text'])
        self.assertEqual(learning['paragraphs_drafts'],[draft])
        self.assertEqual(learning['paragraphs'][0]['explanation'],'\n\n'.join(translations))
        self.assertEqual(learning['paragraphs'][0]['key_sentence'],'')
        self.assertFalse(learning['reading_polish_review']['human_scientific_acceptance'])

    def test_polish_preserves_literal_author_byline_without_guessing_chinese_identity(self):
        group={'id':'authors','text':'Weiqi Ji, Sili Deng*','kind':'body'}
        self.assertEqual(literal_author_names(group),['Weiqi Ji','Sili Deng'])
        with self.assertRaisesRegex(PipelineError,'作者Latin姓名'):
            validate_polished_translation({'translation':'季伟奇，邓思立*'},group)
        validate_polished_translation({'translation':'Weiqi Ji，Sili Deng*'},group)
        self.assertEqual(literal_author_names({'text':'Chemical Reaction Neural Network, Bayesian Inference','kind':'title'}),[])

    def test_reading_rejects_claimed_word_repair_not_applied_to_text(self):
        text='The differ-ences arise from generat-ing samples.'
        group={'id':'p1-b1','source_ids':['p1-b1'],'text':text,'kind':'body','page':1,'pages':[1]}
        item={'id':group['id'],'source_ids':group['source_ids'],'text':text,'editing_notes':["修复断词：differ-ences -> differences, generat-ing -> generating。"]}
        with self.assertRaisesRegex(PipelineError,'声称已将 differ-ences|声称已将 generat-ing'):
            validate_reading({'clean_reading':[item]},[group],[],check_themes=False)
        item['text']=text.replace('differ-ences','differences').replace('generat-ing','generating')
        validate_reading({'clean_reading':[item]},[group],[],check_themes=False)
        item['text']=text
        item['editing_notes']=['尚未修复 differ-ences 为 differences，仍待核对。']
        validate_reading({'clean_reading':[item]},[group],[],check_themes=False)

    def test_inline_formula_projection_remains_an_unresolved_literal_marker(self):
        text='The vector ⟦inline formula⟧ contains ⟦inline symbol: ~yi j⟧.'
        group={'id':'g1','source_ids':['g1'],'text':text,'kind':'body','page':1,'pages':[1]}
        item={'id':'g1','source_ids':['g1'],'text':text,'translation':'向量⟦inline formula⟧包含⟦inline symbol: ~yi j⟧。','editing_notes':[]}
        validate_reading({'clean_reading':[item]},[group],[],check_themes=False)
        validate_polished_translation(item,group)
        changed={**item,'text':text.replace('⟦inline symbol: ~yi j⟧','theta')}
        with self.assertRaisesRegex(PipelineError,'inline'):
            validate_reading({'clean_reading':[changed]},[group],[],check_themes=False)
        with self.assertRaisesRegex(PipelineError,'inline'):
            validate_polished_translation({**item,'translation':'向量和theta。'},group)

    def test_polish_retries_only_invalid_groups_with_complete_linked_evidence(self):
        groups=[{'id':'g1','source_ids':['g1'],'text':'The value is unity.','kind':'body','page':1,'pages':[1],
                 'linked_layout_source_ids':['fragment'],'inline_projections':[{'literal_prose_tail':{'source_id':'fragment','text':'in'}}]},
                {'id':'g2','source_ids':['g2'],'text':'The other value is 2.','kind':'body','page':1,'pages':[1]}]
        source={'blocks':[{'id':g['id'],'page':1,'text':g['text']} for g in groups]+[{'id':'fragment','page':1,'text':'[equation], in'}],'reading_main_blocks':groups}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                return {'clean_reading':[{'id':g['id'],'source_ids':g['source_ids'],'text':g['text'],'translation':('数值为1。' if len(calls)==1 else '数值为一。') if g['id']=='g1' else '另一个数值为2。','editing_notes':[]} for g in request['reading_groups']]}
        with tempfile.TemporaryDirectory() as folder:
            polished=polish_reading(source,{'clean_reading':[]},Provider(),Path(folder),lambda _:None)
        self.assertEqual([[g['id'] for g in request['reading_groups']] for request in calls],[['g1','g2'],['g1']])
        self.assertEqual([b['id'] for b in calls[1]['source_evidence']],['g1','fragment'])
        self.assertEqual(calls[1]['reading_groups'][0]['inline_projections'],groups[0]['inline_projections'])
        self.assertIn("新增{'1': 1}",calls[1]['validation_errors']['g1'])
        self.assertEqual(polished[1]['translation'],'另一个数值为2。')

    def test_polish_resume_revalidates_cache_and_rejects_changed_complete_input(self):
        group={'id':'g1','source_ids':['g1'],'text':'The value is 2.','kind':'body','page':1,'pages':[1]}
        source={'blocks':[{'id':'g1','page':1,'text':group['text']}],'reading_main_blocks':[group]}
        item={'id':'g1','source_ids':['g1'],'text':group['text'],'translation':'数值为2。','editing_notes':[]}
        for change in ('none','context','evidence','group','draft','invalid'):
            with self.subTest(change=change), tempfile.TemporaryDirectory() as folder:
                base=Path(folder);prior=base/'prior';current=base/'current'
                (prior/'chunks').mkdir(parents=True);current.mkdir()
                (prior/'source.json').write_text(json.dumps(source))
                (prior/'chunks/chunk-0001.json').write_text(json.dumps({'clean_reading':[]}))
                cached=copy.deepcopy(item)
                if change=='invalid':cached['translation']='数值为3。'
                (prior/'chunks/polish-0001.json').write_text(json.dumps({'clean_reading':[cached]}))
                (current/'request.json').write_text(json.dumps({'resume_from':str(prior)}))
                active=copy.deepcopy(source);learning={'clean_reading':[]};calls=[]
                if change=='context':active['editorial_review_context']={'semantic_constraints':[]}
                if change=='evidence':active['blocks'][0]['text']='The exact value is 2.'
                if change=='group':active['reading_main_blocks'][0]['reading_notes']=['Source reading projection changed.']
                if change=='draft':learning['clean_reading']=[item]
                class Provider:
                    def json(self,system,prompt):
                        calls.append(json.loads(prompt));return {'clean_reading':[copy.deepcopy(item)]}
                polish_reading(active,learning,Provider(),current,lambda _:None)
                self.assertEqual(len(calls),0 if change=='none' else 1)
                saved=json.loads((current/'chunks/polish-0001.json').read_text())
                self.assertEqual(bool(saved['resumed_from']),change in {'none','invalid'})
                self.assertEqual(len(saved['input_sha256']),64)

    def test_polish_unit_retry_removes_obsolete_metadata_but_keeps_full_draft(self):
        text=('Gaussian distribution is only assumed on W and k. The Bayesian model results are illustrated in the figure. '
              'The concentration remains almost constant and unity because the species is a pure catalyst.')
        group={'id':'g1','source_ids':['g1'],'text':text,'kind':'body','page':1,'pages':[1]}
        source={'blocks':[{'id':'g1','page':1,'text':text}],'reading_main_blocks':[group]}
        units=polish_translation_units(group)
        good=[{'unit_id':u['id'],'translation':'完整直译：'+u['text']} for u in units]
        old=good+[{'unit_id':'g1-t999','translation':'不应存在的旧单元。'}]
        draft={'id':'g1','source_ids':['g1'],'text':text,'translation':'完整旧译文供逐句比对。','translation_units':old,'editing_notes':[]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt);calls.append(request)
                return {'clean_reading':[{**draft,'translation_units':old if len(calls)==1 else good}]}
        with tempfile.TemporaryDirectory() as folder:
            polish_reading(source,{'clean_reading':[draft]},Provider(),Path(folder),lambda _:None)
            invalid=json.loads((Path(folder)/'chunks/polish-0001-invalid-1.json').read_text())
            self.assertEqual(invalid['provider_response']['clean_reading'][0]['translation_units'],old)
        self.assertEqual(len(calls),2)
        self.assertNotIn('translation_units',calls[0]['existing_reading'][0])
        self.assertNotIn('translation_units',calls[1]['invalid_reading'][0])
        self.assertEqual(calls[1]['invalid_reading'][0]['translation'],draft['translation'])
        self.assertIn('expected=',calls[1]['validation_errors']['g1'])
        self.assertIn('g1-t999',calls[1]['validation_errors']['g1'])
        self.assertEqual(draft['translation_units'],old)

    def test_raw_evidence_cannot_override_clean_paragraph_anchor(self):
        # The real CRNN extraction contains punctuation whitespace that the
        # reading layer removes. The same ID must never expose two anchors or
        # two competing translation-unit partitions to the model.
        raw = ('Environmental , biological and chemical processes are described by a model whose assumptions must be checked against observations. ' * 9).strip()
        clean = raw.replace(' ,', ',')
        block={'id':'p2-g15','page':2,'text':raw,'source_anchor':raw[:96],'reading_role':'body'}
        group={'id':block['id'],'source_ids':[block['id']],'text':clean,'kind':'body','page':2,'pages':[2],'reading_main':True}
        source={'path':'crnn.pdf','blocks':[block],'reading_blocks':[group],'reading_main_blocks':[group]}
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt); calls.append(request)
                if 'source_blocks' in request or 'items' in request or 'reading_groups' in request:
                    output=chunk_response(request)
                    if 'source_blocks' in request:
                        # This simulates the observed model selecting the last
                        # available anchor for an otherwise identical source ID.
                        candidates=request['source_blocks']+request.get('evidence_blocks',[])
                        anchors={item['id']:item['source_anchor'] for item in candidates if 'source_anchor' in item}
                        for paragraph in output['paragraphs']:
                            paragraph['source_anchor']=anchors[paragraph['source_id']]
                    return output
                return chunk_response(request)
        with tempfile.TemporaryDirectory() as folder:
            learning,_=make_learning(source,{'mode':'llm','fields':[]},Path(folder),Provider(),lambda _:None)
        self.assertEqual(len(calls),5)
        first=calls[0]
        self.assertEqual(first['source_blocks'][0]['source_anchor'],clean[:96])
        self.assertTrue(first['source_blocks'][0]['translation_units'])
        evidence=first['evidence_blocks'][0]
        self.assertEqual(set(evidence),{'id','page','document','text','verified_layout_observations'})
        self.assertEqual(evidence['text'],raw)
        self.assertEqual(learning['paragraphs'][0]['source_anchor'],clean[:96])
        self.assertEqual(learning['clean_reading'][0]['text'],clean)
        self.assertEqual(source['blocks'][0]['text'],raw)

    def test_generation_supplies_canonical_fragments_and_layout_evidence(self):
        source=copy.deepcopy(self.source)
        calls=[]
        class Provider:
            def json(self,system,prompt):
                request=json.loads(prompt); calls.append(request)
                if 'source_blocks' in request or 'items' in request or 'reading_groups' in request:
                    output=chunk_response(request)
                    if 'source_blocks' in request:
                        output['equations'][0]['source_ids']=['p1-b3']
                        output['thematic_sections'][0]['paragraphs'][0]['source_ids']=['p1-b1','p1-b2']
                    return output
                return chunk_response(request)
        with tempfile.TemporaryDirectory() as folder:
            learning,_=make_learning(source,{'mode':'llm','fields':[],'chunk_characters':5000},Path(folder),Provider(),lambda _:None)
        first=calls[0]
        self.assertEqual([b['id'] for b in first['source_blocks']],['p1-b1'])
        self.assertEqual([b['id'] for b in first['evidence_blocks']],['p1-b1','p1-b2','p1-b3'])
        self.assertEqual(first['verified_layout_observations'],source['layout_observations'])
        self.assertEqual(learning['reading_coverage']['excluded_source_ids'],['p1-b4'])
        self.assertEqual(learning['reading_coverage']['auxiliary_source_ids'],['p1-b3'])
        self.assertEqual(learning['paragraphs'][0]['source_ids'],['p1-b1','p1-b2'])
        self.assertEqual(source['blocks'],self.source['blocks'])
        self.assertEqual(len(learning['clean_reading']),1)
        self.assertTrue(learning['consolidated']['methods'])


if __name__=='__main__': unittest.main()

from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError
from papershelf_pipeline.generation import make_learning
from papershelf_pipeline.synthesis import reading_groups, validate_reading, consolidate_learning, separate_process_notes
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
                if 'source_blocks' in request or 'items' in request:
                    output=chunk_response(request)
                    if 'source_blocks' in request:
                        # This simulates the observed model selecting the last
                        # available anchor for an otherwise identical source ID.
                        candidates=request['source_blocks']+request.get('evidence_blocks',[])
                        anchors={item['id']:item['source_anchor'] for item in candidates if 'source_anchor' in item}
                        for paragraph in output['paragraphs']:
                            paragraph['source_anchor']=anchors[paragraph['source_id']]
                    return output
                return {'overview':'先核对模型假设与适用条件。','reading_route':['按研究问题组织原文证据。']}
        with tempfile.TemporaryDirectory() as folder:
            learning,_=make_learning(source,{'mode':'llm','fields':[]},Path(folder),Provider(),lambda _:None)
        self.assertEqual(len(calls),3)
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
                return {'overview':'先核对条件，再理解速率模型。','reading_route':['条件、机制与证据依次核对。']}
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

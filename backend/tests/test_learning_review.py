from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from papershelf_pipeline.contracts import PipelineError, read_json, sha256, write_json
from papershelf_pipeline.dataset import validate_extraction
from papershelf_pipeline.learning_review import apply_extraction_review
from papershelf_pipeline.pipeline import run


class ExtractionReviewTests(unittest.TestCase):
    def setUp(self):
        self.source={'path':'paper.pdf','sha256':'verified-sha','blocks':[{'id':'p1-g1','page':1,'text':'The rate is 2 mol/s.'}]}
        self.cell={'value':None,'status':'not_found','evidence':[],'notes':'模型未提取'}
        self.extraction={'schema_version':1,'fields':[{'name':'rate','type':'number'}],
            'records':[{'id':'chunk-1-record-1','values':{'rate':copy.deepcopy(self.cell)}}]}
        self.correction={'paper':'paper','source_sha256':'verified-sha','record_id':'chunk-1-record-1','field':'rate',
            'original':copy.deepcopy(self.cell),'corrected':{'value':2,'status':'supported','unit':'mol/s',
                'evidence':[{'block_id':'p1-g1','page':1,'quote':'The rate is 2 mol/s.'}]},
            'reason':'原文明确报告该字段，补齐模型遗漏。','actor':'Codex QA'}

    def apply(self,root,correction=None):
        write_json(root/'corrections.json',[correction or self.correction])
        return apply_extraction_review(self.extraction,self.source,{'extraction_corrections_path':str(root/'corrections.json')},root)

    def test_exact_source_review_keeps_original_and_hash_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            result=self.apply(root)
            self.assertEqual(result['records'][0]['values']['rate']['value'],2)
            self.assertIsNone(self.extraction['records'][0]['values']['rate']['value'])
            self.assertEqual(read_json(root/'extraction-before-review.json'),self.extraction)
            event=result['review_history'][0]
            self.assertEqual(event['actor'],'Codex QA')
            self.assertEqual(event['before'],self.cell)
            self.assertEqual(len(event['event_sha256']),64)
            self.assertFalse(result['review_provenance']['human_scientific_acceptance'])
            validate_extraction(result,self.source)

    def test_stale_original_source_or_bad_evidence_cannot_publish_review(self):
        for key in ('original','source_sha256','quote','page','value'):
            with self.subTest(key=key),tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                correction=copy.deepcopy(self.correction)
                if key=='original': correction['original']['notes']='wrong run'
                elif key=='source_sha256': correction[key]='different-file'
                elif key in ('quote','page'): correction['corrected']['evidence'][0][key]='wrong' if key=='quote' else 2
                else: correction['corrected']['value']='wrong type'
                with self.assertRaises(PipelineError): self.apply(root,correction)
                self.assertFalse((root/'extraction-review.json').exists())

    def test_pipeline_exports_and_agent_all_use_same_reviewed_extraction(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);source=root/'paper.md';source.write_text('The rate is 2 mol/s.',encoding='utf-8')
            correction=copy.deepcopy(self.correction)
            correction['source_sha256']=sha256(source)
            correction['record_id']='source-record'
            correction['original']={'value':None,'status':'not_found','evidence':[],'notes':'离线模式未推断字段值'}
            correction['corrected']['evidence'][0]['block_id']='p1-b1'
            correction['corrected']['notes']='来自独立来源复核的值'
            addition={'paper':'paper','source_sha256':sha256(source),'operation':'add_record','actor':'Codex QA',
                'reason':'从来源中独立核对条件行，保留原泛化记录。','retain_original_record_id':'source-record',
                'original_record_notice':'原泛化摘要保留，不与条件行重复计数。',
                'record':{'id':'review-condition','label':'已核对的条件','values':{'rate':copy.deepcopy(correction['corrected'])}}}
            write_json(root/'review.json',[correction,addition])
            manifest=run({'mode':'offline','source_path':str(source),'output_root':str(root/'runs'),
                'fields':self.extraction['fields'],'extraction_corrections_path':str(root/'review.json')})
            artifacts=manifest['artifacts']
            extraction=read_json(artifacts['extraction'])
            self.assertEqual(len(extraction['records']),2)
            self.assertEqual(len(extraction['review_history']),2)
            self.assertEqual(extraction['review_history'][1]['operation'],'add_record')
            self.assertIn('非独立实验',extraction['records'][0]['label'])
            self.assertEqual(read_json(Path(artifacts['agent']).parent/'extraction.json'),extraction)
            self.assertIn('- **rate**：2 mol/s（supported）',Path(artifacts['markdown']).read_text())
            self.assertIn('来自独立来源复核的值',Path(artifacts['html']).read_text())
            self.assertIn('来自独立来源复核的值',Path(artifacts['csv']).read_text())
            facts=[node for node in read_json(artifacts['graph'])['nodes'] if node['type']=='fact']
            self.assertEqual(facts[0]['value'],2)
            self.assertTrue(Path(artifacts['extraction_before_review']).is_file())

    def test_record_addition_rejects_duplicate_id_bad_quote_and_stale_hash(self):
        for fault in ('duplicate','quote','hash'):
            with self.subTest(fault=fault),tempfile.TemporaryDirectory() as directory:
                root=Path(directory)
                addition={'paper':'paper','source_sha256':'verified-sha','operation':'add_record','actor':'Codex QA',
                    'reason':'核对条件','record':{'id':'review-condition','values':{'rate':copy.deepcopy(self.correction['corrected'])}}}
                if fault=='duplicate':addition['record']['id']='chunk-1-record-1'
                elif fault=='quote':addition['record']['values']['rate']['evidence'][0]['quote']='Rate was 999.'
                else:addition['source_sha256']='wrong-sha'
                write_json(root/'review.json',[addition])
                with self.assertRaises(PipelineError):
                    apply_extraction_review(self.extraction,self.source,{'extraction_corrections_path':str(root/'review.json')},root)
                self.assertFalse((root/'extraction-review.json').exists())


if __name__=='__main__':
    unittest.main()

from __future__ import annotations

import io
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from papershelf_pipeline.book import chapter_plan
from papershelf_pipeline.calculations import evaluate, expression_tree, validate_calculation
from papershelf_pipeline.contracts import PipelineError, read_json, validate_request
from papershelf_pipeline.pipeline import run
from papershelf_pipeline.rendering import math_html
from papershelf_pipeline.provider import Provider
from test_pipeline import chunk_response


class LearningExtensionsTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.source=self.root/'paper.md'
        self.source.write_text('Sample A was measured at 25 C. The rate constant k = 2 s^-1 and r = kC.\n\nAll 1500 measurements were retained.',encoding='utf-8')
        self.request={'source_path':str(self.source),'output_root':str(self.root/'runs'),'mode':'offline','fields':[]}

    def tearDown(self):
        self.temp.cleanup()

    def test_mathml_removes_active_content(self):
        warnings=[]
        hyperlink=math_html(r'\href{javascript:alert(1)}{x}',warnings)
        self.assertNotIn('href=',hyperlink)
        self.assertNotIn('javascript:',hyperlink)
        injected=math_html(r'\text{<svg/onload=alert(1)>}',warnings)
        self.assertNotIn('<svg',injected)
        self.assertNotIn('<script',injected)
        normal=math_html(r'k=\frac{1}{t}',warnings)
        self.assertIn('<mfrac>',normal)

    def test_calculation_source_values_and_safe_expression(self):
        blocks={'b1':{'id':'b1','page':1,'text':'The rate constant is 2 s^-1. The concentration is 3 mol/L.'}}
        citation={'block_id':'b1','page':1,'quote':blocks['b1']['text']}
        calculation={'expression':'k * C','variables':[{'name':'k','value':2,'evidence':[citation]},{'name':'C','value':3,'evidence':[citation]}],'source_ids':['b1']}
        result=validate_calculation(calculation,blocks)
        self.assertEqual(result['computed_value'],6)
        calculation['expression']='2 * 3'
        with self.assertRaisesRegex(PipelineError,'未用于算式'):
            validate_calculation(calculation,blocks)
        calculation['expression']='k * 3'
        with self.assertRaisesRegex(PipelineError,'未用于算式'):
            validate_calculation(calculation,blocks)
        calculation['expression']='k * C'
        self.assertEqual(evaluate(validate_calculation(calculation,blocks)['expression_tree'],{'k':4,'C':3}),12)
        for expression in ['__import__("os").system("touch /tmp/bad")','x.__class__','[x for x in (1,2)]','sqrt(x, y)']:
            with self.assertRaises(PipelineError):
                expression_tree(expression,{'x','y'})
        with self.assertRaises(PipelineError):
            evaluate(expression_tree('1/x',{'x'}),{'x':0})
        calculation['variables'][0]['value']=50
        with self.assertRaises(PipelineError):
            validate_calculation(calculation,blocks)

    def test_book_all_pages_chapters_index_and_missing_range_rejected(self):
        import pymupdf
        pdf=self.root/'book.pdf'
        document=pymupdf.open()
        for index in range(4):
            page=document.new_page()
            page.insert_text((50,60),f'Chapter content page {index+1}. Every paragraph is retained.')
        document.set_toc([[1,'Part One',1],[1,'Part Two',3]])
        document.save(pdf); document.close()
        result=run({**self.request,'source_path':str(pdf),'book':{'auto':True}})
        book=read_json(result['artifacts']['book_manifest'])
        self.assertEqual(book['coverage'],'all_pages_exactly_once')
        self.assertEqual(sum(chapter['source_blocks'] for chapter in book['chapters']),result['metrics']['source_blocks'])
        self.assertEqual(len(book['chapters']),2)
        index=Path(result['artifacts']['html']).read_text()
        for chapter in book['chapters']:
            self.assertIn(chapter['file'],index)
            self.assertTrue((Path(result['run_dir'])/chapter['file']).exists())
            chapter_md = Path(chapter['artifacts']['markdown']).read_text()
            self.assertIn('(../../fulltext.md)', chapter_md)
            for page in range(1, 5):
                if chapter['start_page'] <= page <= chapter['end_page']:
                    self.assertIn(f'Chapter content page {page}.', chapter_md)
                else:
                    self.assertNotIn(f'Chapter content page {page}.', chapter_md)
        source=read_json(result['artifacts']['source'])
        with self.assertRaises(PipelineError):
            chapter_plan(source,{'chapters':[{'title':'Missing last pages','start_page':1,'end_page':2}]})

    def test_partial_upstream_failure_preserves_completed_local_artifacts(self):
        with patch('papershelf_pipeline.integrations.graphiti_ingest',side_effect=RuntimeError('test graph service unavailable')):
            result=run({**self.request,'graphiti':{'enabled':True}})
        self.assertEqual(result['status'],'partial')
        self.assertIn('graphiti',result['integration_errors'])
        self.assertTrue(Path(result['artifacts']['html']).exists())
        self.assertEqual(read_json(self.root/'runs/index.json')['runs'][0]['status'],'partial')

    def test_recursive_inline_credentials_rejected_before_write(self):
        with self.assertRaises(PipelineError):
            validate_request({**self.request,'graphiti':{'nested':{'password':'fixture-secret'}}})
        self.assertFalse((self.root/'runs').exists())

    def test_streaming_provider_preserves_unicode_and_omits_unsupported_temperature(self):
        received=[]
        class Handler(BaseHTTPRequestHandler):
            def do_POST(handler):
                body=json.loads(handler.rfile.read(int(handler.headers['Content-Length'])))
                received.append(body)
                handler.send_response(200);handler.send_header('Content-Type','text/event-stream');handler.end_headers()
                for piece in ['{"ok":','true,"说明":"','全部内容保留','"}']:
                    event={'choices':[{'delta':{'content':piece},'finish_reason':None}]}
                    handler.wfile.write(('data: '+json.dumps(event,ensure_ascii=False)+'\n\n').encode())
                    handler.wfile.flush()
                handler.wfile.write(b'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n')
            def log_message(self,*args):pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            provider=Provider({'base_url':f'http://127.0.0.1:{server.server_port}/v1','model':'auto','stream':True})
            response=provider.json('Return JSON','test')
            self.assertEqual(response['说明'],'全部内容保留')
            self.assertNotIn('temperature',received[0])
            self.assertTrue(received[0]['stream'])
        finally:
            server.shutdown();server.server_close()

    def test_sigterm_during_real_provider_request_finalizes_manifest_and_keeps_chunks(self):
        waiting=threading.Event(); release=threading.Event()
        calls=[]
        class Handler(BaseHTTPRequestHandler):
            def do_POST(handler):
                payload=json.loads(handler.rfile.read(int(handler.headers['Content-Length'])))
                request=json.loads(payload['messages'][-1]['content'])
                calls.append(request)
                if len(calls)>1:
                    waiting.set();release.wait(10)
                content=chunk_response(request)
                response=json.dumps({'choices':[{'message':{'content':json.dumps(content)},'finish_reason':'stop'}]}).encode()
                try:
                    handler.send_response(200);handler.send_header('Content-Length',str(len(response)));handler.end_headers();handler.wfile.write(response)
                except BrokenPipeError:
                    pass
            def log_message(self,*args): pass
        server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        self.source.write_text('\n\n'.join(f'Paragraph {i}: '+('all measurements retained. '*70) for i in range(3)),encoding='utf-8')
        request={**self.request,'mode':'llm','chunk_characters':2000,'provider':{'base_url':f'http://127.0.0.1:{server.server_port}/v1','model':'fixture'}}
        path=self.root/'request.json';path.write_text(json.dumps(request))
        environment=dict(os.environ,PYTHONPATH=str(Path(__file__).resolve().parents[1]))
        process=subprocess.Popen([sys.executable,'-m','papershelf_pipeline','run','--request',str(path)],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            self.assertTrue(waiting.wait(8),'provider did not reach second chunk')
            process.send_signal(signal.SIGTERM)
            stdout,stderr=process.communicate(timeout=5)
            self.assertNotEqual(process.returncode,0)
            manifests=list((self.root/'runs').glob('*/manifest.json'))
            self.assertEqual(len(manifests),1)
            manifest=read_json(manifests[0])
            self.assertEqual(manifest['status'],'cancelled')
            self.assertTrue((manifests[0].parent/'chunks/chunk-0001.json').exists())
            self.assertTrue(Path(manifest['artifacts']['source']).exists())
            self.assertEqual(read_json(self.root/'runs/index.json')['runs'][0]['status'],'cancelled')
        finally:
            release.set()
            if process.poll() is None:
                process.kill();process.wait()
            server.shutdown();server.server_close()


if __name__=='__main__':unittest.main()

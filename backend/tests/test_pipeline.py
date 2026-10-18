from __future__ import annotations

import copy
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

from papershelf_pipeline.agent import answer, load_bundle, search, serve_stdio, tool_call
from papershelf_pipeline.contracts import PipelineError, read_json
from papershelf_pipeline.generation import validate_chunk
from papershelf_pipeline.pipeline import run
from papershelf_pipeline.provider import Provider


def chunk_response(request):
    if 'figure_drafts' in request:
        return {'figures_tables':[{'input_id':entry['input_id'],**entry['value']} for entry in request['figure_drafts']]}
    if 'overview' in request.get('schema',{}) and 'reading_route' in request.get('schema',{}):
        return {'overview':'核对完整原文后按条件解释研究问题。','reading_route':['先核对条件与方法，再核对证据边界。'], 'reviewed_gaps':[{'input_gap_id':gap['id'],'text':gap['text'],'source_ids':[request['source_evidence'][0]['id']],'status':'retained','reason':'夹具保留待原文核验的科学疑点。'} for gap in request.get('gap_drafts',[])]}
    if 'items' in request:
        output = {key:[] for key in ('thematic_sections','methods','findings','critique','transfer','quiz','glossary')}
        output['coverage'] = []
        for item in request['items']:
            output[item['section']].append(copy.deepcopy(item['value']))
            output['coverage'].append({'input_id':item['input_id'], 'action':'retained', 'reason':'保留夹具中的完整内容和来源。'})
        return output
    if 'reading_groups' in request and 'source_blocks' not in request:
        request = {**request, 'source_blocks':request['reading_groups']}
    blocks = request['source_blocks']
    first = blocks[0]
    citation = [first['id']]
    output = {
        'summary':'研究通过测量速率解释温度效应，需检查适用条件。',
        'paragraphs':[{'source_id':block['id'],'source_anchor':block.get('source_anchor',''),'explanation':'完整讲解：'+block['text'],'translation_units':[{'unit_id':unit['id'],'translation':'逐句译述：'+unit['text']} for unit in block.get('translation_units',[])],'key_sentence':block['text'],'reasoning':'【教材】核对单位与测量条件。'} for block in blocks],
        'methods':[{'title':'实验条件','body':'在 25 °C 下测定速率。','source_ids':citation,'kind':'source'}],
        'findings':[{'title':'速率常数','body':'报告 k = 2 s^-1。','source_ids':citation,'kind':'source'}],
        'critique':[{'title':'条件限制','body':'需检查是否改变温度。','source_ids':citation,'kind':'uncertain'}],
        'transfer':[{'title':'迁移验证','body':'【迁移推论】改变条件后需要重新验证。','source_ids':citation,'kind':'inference'}],
        'equations':[{'label':'1','latex':'r=kC','meaning':'速率随浓度变化','symbols':[{'symbol':'r','meaning':'速率'},{'symbol':'k','meaning':'速率常数'},{'symbol':'C','meaning':'浓度'}],'source_ids':citation}],
        'figures_tables':[],
        'quiz':[{'question':'速率常数单位是什么？','answer':'原文为 s^-1。','source_ids':citation}],
        'glossary':[{'term':'速率常数','english':'rate constant','definition':'速率模型中的参数。','source_ids':citation}],
        'gaps':['没有补充材料。'],
        'records':[],
    }
    if request.get('reading_groups'):
        output['clean_reading'] = [{'id':group['id'],'source_ids':group['source_ids'],'text':group['text'],'translation':'完整译文：'+group['text'], 'translation_units':[{'unit_id':unit['id'],'translation':'完整直译：'+unit['text']} for unit in group.get('translation_units',[])], 'editing_notes':[]} for group in request['reading_groups']]
        output['thematic_sections'] = [{'title':'测量条件如何约束速率分析','paragraphs':[{'text':'测量得到的速率参数必须与对应的温度和样品条件一起解释。比较结果前应先核对来源所给出的观测范围和单位，再判断模型的适用边界，避免把不同条件下的结论直接混合。','source_ids':citation,'kind':'source'}]}]
    if request.get('fields'):
        first = request.get('evidence_blocks', blocks)[0]
        output['records'] = [{'label':'样品 A · 25 °C','values':{field['name']:{'value':25 if field['type']=='number' else 'A','status':'supported','unit':'°C' if field['type']=='number' else '', 'evidence':[{'block_id':first['id'],'page':first['page'],'quote':first['text']}]} for field in request['fields']}}]
    return output


class StubHandler(BaseHTTPRequestHandler):
    calls = []

    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        self.calls.append(payload)
        request = json.loads(payload['messages'][-1]['content'])
        if 'source_blocks' in request or 'reading_groups' in request or 'items' in request or 'figure_drafts' in request or 'overview' in request.get('schema',{}):
            content = chunk_response(request)
        elif 'queries' in request.get('output',{}):
            content = {'queries':['rate constant','temperature']}
        elif 'question' in request:
            identifier = request['evidence'][0]['block_id']
            content = {'answer':f'本文测量条件为 25 °C [{identifier}]。','source_ids':[identifier]}
        else:
            content = {'overview':'围绕速率测量与条件展开学习，所有段落均可回到原文核验。','reading_route':['先核对条件，再比较结论。']}
        result = json.dumps({'choices':[{'message':{'content':json.dumps(content,ensure_ascii=False)},'finish_reason':'stop'}],'usage':{'prompt_tokens':100,'completion_tokens':100}}).encode()
        self.send_response(200)
        self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(result)))
        self.end_headers()
        self.wfile.write(result)

    def log_message(self,*args):
        pass


class PipelineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root/'paper.md'
        self.source.write_text('Sample A was measured at 25 °C. The rate constant k = 2 s^-1 and r = kC.\n\nAll 1500 measurements were retained. No supplementary data were supplied.\n',encoding='utf-8')
        self.request = {'source_path':str(self.source),'output_root':str(self.root/'runs'),'title':'Temperature <script>alert(1)</script>','reference_id':'ref-1','mode':'offline','fields':[{'name':'temperature','type':'number','description':'Measurement temperature','unit':'K','required':True}]}

    def tearDown(self):
        self.temp.cleanup()

    def test_offline_truthful_full_artifacts_and_portable_agent(self):
        result = run(self.request)
        self.assertEqual(result['status'],'completed')
        self.assertEqual(result['quality'],'source_draft')
        self.assertEqual(result['metrics']['provider_calls'],0)
        self.assertEqual(result['metrics']['explained_blocks'],0)
        self.assertEqual(result['metrics']['source_blocks'],2)
        for path in result['artifacts'].values():
            self.assertTrue(Path(path).is_file(),path)
        html = Path(result['artifacts']['html']).read_text()
        self.assertIn('未生成讲解',html)
        self.assertIn('&lt;script&gt;alert(1)&lt;/script&gt;',html)
        self.assertNotIn('<script>alert(1)</script>',html)
        markdown = Path(result['artifacts']['markdown']).read_text()
        self.assertIn('All 1500 measurements were retained.',markdown)
        extraction = read_json(result['artifacts']['extraction'])
        self.assertIsNone(extraction['records'][0]['values']['temperature']['value'])
        response = answer(result['manifest_path'],'rate constant')
        self.assertIn('k = 2 s^-1',response['answer'])
        moved = self.root/'moved-agent'
        shutil.copytree(Path(result['artifacts']['agent']).parent,moved)
        process = subprocess.run([sys.executable,str(moved/'run.py'),'--query','rate constant'],capture_output=True,text=True)
        self.assertEqual(process.returncode,0,process.stderr)
        self.assertIn('k = 2 s^-1',json.loads(process.stdout)['answer'])
        repeat = run(self.request)
        self.assertNotEqual(result['run_dir'],repeat['run_dir'])
        self.assertEqual(len(read_json(self.root/'runs/index.json')['runs']),2)

    def test_real_http_provider_full_coverage_and_unit_preservation(self):
        server = ThreadingHTTPServer(('127.0.0.1',0),StubHandler)
        thread = threading.Thread(target=server.serve_forever,daemon=True)
        thread.start()
        try:
            request = {**self.request,'mode':'llm','provider':{'base_url':f'http://127.0.0.1:{server.server_port}/v1','model':'fixture-model'}}
            result = run(request)
            self.assertEqual(result['metrics']['source_blocks'],result['metrics']['explained_blocks'])
            self.assertGreaterEqual(result['metrics']['provider_calls'],2)
            self.assertEqual(result['quality'],'generated_unreviewed')
            cell = read_json(result['artifacts']['extraction'])['records'][0]['values']['temperature']
            self.assertEqual(cell['value'],25)
            self.assertEqual(cell['unit'],'°C')
            self.assertTrue(any('unit' in warning.lower() for warning in result['warnings']))
            text = Path(result['artifacts']['html']).read_text()
            for section in ['论文研读','逐段对照','实验与模型逻辑','公式与符号','自测与答辩','术语表','知识延伸与迁移']:
                self.assertIn(section,text)
            self.assertIn('class="paragraph-audit"',text)
            self.assertIn('测量条件如何约束速率分析',text)
            self.assertIn('r=kC',Path(result['artifacts']['markdown']).read_text())
            response = answer(result['manifest_path'],'rate constant','llm')
            self.assertTrue(response['citations'])
            self.assertIn(response['citations'][0]['block_id'],response['answer'])
            translated = answer(result['manifest_path'],'论文的实验条件是什么？','llm')
            self.assertTrue(translated['citations'])
        finally:
            server.shutdown()
            server.server_close()

    def test_invalid_provider_is_not_silently_offline(self):
        with self.assertRaises(PipelineError):
            run({**self.request,'mode':'llm','provider':{}})

    def test_json_protocol_always_explicitly_requests_json_for_strict_endpoints(self):
        class StrictJSONHandler(BaseHTTPRequestHandler):
            def do_POST(handler):
                payload=json.loads(handler.rfile.read(int(handler.headers['Content-Length'])))
                if payload.get('response_format')=={'type':'json_object'} and not any('json' in message['content'].lower() for message in payload['messages']):
                    handler.send_response(400); handler.end_headers(); return
                body=json.dumps({'choices':[{'message':{'content':'{"ok":true}'}}]}).encode()
                handler.send_response(200)
                handler.send_header('Content-Length',str(len(body)))
                handler.end_headers(); handler.wfile.write(body)
            def log_message(self,*args):
                pass
        server=ThreadingHTTPServer(('127.0.0.1',0),StrictJSONHandler)
        threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            provider=Provider({'base_url':f'http://127.0.0.1:{server.server_port}/v1','model':'strict-fixture'})
            self.assertEqual(provider.json('你是证据助手。','说明本文的方法。'),{'ok':True})
        finally:
            server.shutdown(); server.server_close()

    def test_no_text_sampling_for_large_source(self):
        paragraphs = [f'Unique measurement {index}: all values preserved and traceable.' for index in range(2000)]
        self.source.write_text('\n\n'.join(paragraphs),encoding='utf-8')
        result = run(self.request)
        self.assertEqual(result['metrics']['source_blocks'],2000)
        output = Path(result['artifacts']['source_markdown']).read_text()
        self.assertIn(paragraphs[0],output)
        self.assertIn(paragraphs[-1],output)
        self.assertEqual(Path(result['artifacts']['raw_source_markdown']).read_text(),self.source.read_text())
        for paragraph in paragraphs:
            self.assertIn(paragraph,output)

    def test_hallucinated_quote_and_missing_paragraph_rejected(self):
        blocks = [{'id':'p1-b1','page':1,'text':'The temperature was 25 °C.'}]
        fields = self.request['fields']
        valid = chunk_response({'source_blocks':blocks,'fields':fields})
        self.assertEqual(validate_chunk(copy.deepcopy(valid),blocks,fields)['records'][0]['values']['temperature']['unit'],'°C')
        wrong = copy.deepcopy(valid)
        wrong['records'][0]['values']['temperature']['evidence'][0]['quote']='The temperature was 50 °C.'
        with self.assertRaises(PipelineError):
            validate_chunk(wrong,blocks,fields)
        conflict = copy.deepcopy(valid)
        conflict['records'][0]['values']['temperature']['status']='conflict'
        self.assertEqual(validate_chunk(conflict,blocks,fields)['records'][0]['values']['temperature']['status'],'conflict')
        wrong = copy.deepcopy(valid)
        wrong['paragraphs']=[]
        with self.assertRaises(PipelineError):
            validate_chunk(wrong,blocks,fields)
        wrong = copy.deepcopy(valid)
        wrong['records'][0]['values']['temperature']['value']=True
        with self.assertRaises(PipelineError):
            validate_chunk(wrong,blocks,fields)

    def test_agent_rejects_invented_inline_citation(self):
        result = run(self.request)
        source = read_json(result['artifacts']['source'])
        identifier = source['blocks'][0]['id']
        agent_path = Path(result['artifacts']['agent'])
        config = read_json(agent_path)
        config['provider']={'base_url':'http://localhost:11434/v1','model':'fixture'}
        agent_path.write_text(json.dumps(config))
        with patch('papershelf_pipeline.agent.Provider.json',return_value={'answer':'A claim [totally-invented-block].','source_ids':[identifier]}):
            with self.assertRaises(PipelineError):
                answer(result['manifest_path'],'rate constant','llm')

    def test_agent_current_provider_override_cannot_send_new_key_to_old_endpoint(self):
        class EndpointA(StubHandler):
            calls=[]
        class EndpointB(StubHandler):
            calls=[]
            authorization=[]
            def do_POST(handler):
                handler.authorization.append(handler.headers.get('Authorization'))
                super().do_POST()
        server_a=ThreadingHTTPServer(('127.0.0.1',0),EndpointA)
        server_b=ThreadingHTTPServer(('127.0.0.1',0),EndpointB)
        for server in (server_a,server_b):
            threading.Thread(target=server.serve_forever,daemon=True).start()
        try:
            result=run(self.request)
            agent_path=Path(result['artifacts']['agent'])
            config=read_json(agent_path)
            old_url=f'http://127.0.0.1:{server_a.server_port}/v1'
            config['provider']={'base_url':old_url,'model':'old-model','api_key_env':'PAPERSHELF_TEST_KEY'}
            agent_path.write_text(json.dumps(config))
            current={'base_url':f'http://127.0.0.1:{server_b.server_port}/v1','model':'current-model','api_key_env':'PAPERSHELF_TEST_KEY'}
            with patch.dict(os.environ,{'PAPERSHELF_TEST_KEY':'fixture-current-secret'}):
                response=answer(result['manifest_path'],'rate constant','llm',provider_config=current)
            self.assertTrue(response['citations'])
            self.assertEqual(EndpointA.calls,[])
            self.assertEqual(EndpointB.authorization,['Bearer fixture-current-secret'])
            self.assertEqual(read_json(agent_path)['provider']['base_url'],old_url)
        finally:
            for server in (server_a,server_b):
                server.shutdown();server.server_close()

    def test_mcp_search_read_and_field_tools_are_callable(self):
        result = run(self.request)
        requests = [
            {'jsonrpc':'2.0','id':1,'method':'initialize','params':{}},
            {'jsonrpc':'2.0','method':'notifications/initialized'},
            {'jsonrpc':'2.0','id':2,'method':'tools/list'},
            {'jsonrpc':'2.0','id':3,'method':'tools/call','params':{'name':'search_paper','arguments':{'query':'rate'}}},
            {'jsonrpc':'2.0','id':4,'method':'tools/call','params':{'name':'read_page','arguments':{'page':1}}},
            {'jsonrpc':'2.0','id':5,'method':'tools/call','params':{'name':'get_extraction','arguments':{}}},
        ]
        output = io.StringIO()
        serve_stdio(result['manifest_path'],io.StringIO('\n'.join(map(json.dumps,requests))+'\n'),output)
        replies = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([reply['id'] for reply in replies],[1,2,3,4,5])
        self.assertEqual(len(replies[1]['result']['tools']),4)
        for reply in replies[2:]:
            self.assertFalse(reply['result']['isError'])
        self.assertIn('All 1500 measurements',replies[3]['result']['content'][0]['text'])

    def test_actual_pdf_all_pages_and_block_layout(self):
        try:
            import fitz
        except ImportError:
            self.skipTest('PyMuPDF is not installed in this interpreter')
        pdf = self.root/'paper.pdf'
        document = fitz.open()
        for index in range(3):
            page = document.new_page()
            page.insert_text((50,50),f'Page {index+1}: first paragraph about a catalyst.')
            page.insert_text((50,130),f'Page {index+1}: separate second paragraph containing rate data.')
        document.save(pdf)
        document.close()
        result = run({**self.request,'source_path':str(pdf)})
        self.assertEqual(result['metrics']['pages'],3)
        self.assertEqual(result['metrics']['page_previews'],3)
        self.assertEqual(result['metrics']['source_blocks'],6)
        html = Path(result['artifacts']['html']).read_text()
        self.assertEqual(html.count('data:image/jpeg;base64,'),3)
        self.assertIn('Page 3: separate second paragraph',html)


if __name__ == '__main__':
    unittest.main()

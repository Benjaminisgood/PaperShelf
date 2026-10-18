"""Run orchestration, collision-free artifacts, integrity manifest, and history."""
from __future__ import annotations

import contextlib
import datetime as dt
import fcntl
import json
import os
import shutil
import signal
import sys
import threading
import uuid
from pathlib import Path

from .contracts import PipelineError, PipelineCancelled, read_json, sha256, validate_request, write_json
from .generation import make_learning
from .provider import Provider
from .rendering import render_guide
from .source import extract_source


def progress(message):
    print(message,file=sys.stderr,flush=True)


def create_agent(source,extraction,request,run_dir):
    directory = run_dir / 'agent'
    directory.mkdir()
    package = directory / 'papershelf_pipeline'
    package.mkdir()
    for name in ('__init__.py','agent.py','contracts.py','provider.py'):
        shutil.copyfile(Path(__file__).parent / name,package / name)
    # Store a portable relative source copy; the bundle runs with Python's standard library.
    portable_source = {key:value for key,value in source.items() if key not in {'figures','markdown','canonical_markdown'}}
    write_json(directory / 'source.json',portable_source)
    write_json(directory / 'extraction.json',extraction)
    manifest = {'schema_version':1,'name':request.get('title') or Path(source['path']).stem,'source_path':'source.json','extraction_path':'extraction.json','source_sha256':source['sha256'],'provider':request.get('provider',{}),'tools':['search_paper','read_page','get_extraction','ask_paper'],'capabilities':{'offline_search':True,'llm_answer':bool(request.get('provider',{}).get('model')),'mcp_stdio':True,'generated_scientific_code':False}}
    write_json(directory / 'agent.json',manifest)
    (directory / 'run.py').write_text("#!/usr/bin/env python3\nfrom pathlib import Path\nfrom papershelf_pipeline.agent import main\nif __name__ == '__main__':\n    main(str(Path(__file__).with_name('agent.json')))\n",encoding='utf-8')
    (directory / 'README.md').write_text('''# PaperShelf paper agent

此目录是可独立运行的文献证据 Agent，只需要 Python 3.10+。

```sh
python3 run.py --query "研究方法" --mode offline
python3 run.py --query "本文的证据支持什么结论？" --mode llm
python3 run.py --stdio
```

LLM 模式使用 agent.json 中的兼容 Chat Completions 服务及环境变量名；密钥不写入文件。MCP 客户端配置见 mcp.json。离线问答返回全文块而非假装模型回答；read_page 可取整页。该 Agent 提供阅读/检索/字段证据工具。Paper2Agent 上游复现、测试和科学代码工具生成是独立任务，须运行上游工作流并审阅其结果。
''',encoding='utf-8')
    write_json(directory / 'mcp.json',{'mcpServers':{'papershelf-paper':{'command':'python3','args':[str(directory / 'run.py'),'--stdio']}}})
    return str(directory / 'agent.json')


def update_index(root,manifest):
    with (root / '.index.lock').open('a') as stream:
        fcntl.flock(stream,fcntl.LOCK_EX)
        index_path = root / 'index.json'
        index = read_json(index_path) if index_path.exists() else {'schema_version':1,'runs':[]}
        index['runs'] = [item for item in index['runs'] if item.get('run_id')!=manifest['run_id']]
        index['runs'].append({key:manifest.get(key) for key in ('run_id','reference_id','title','mode','quality','status','created_at','run_dir','manifest_path','artifacts','metrics','warnings')})
        temporary = root / f'.index-{uuid.uuid4().hex}.json'
        write_json(temporary,index)
        temporary.replace(index_path)


def run(request):
    request = validate_request(dict(request))
    provider = Provider(request.get('provider',{})) if request['mode'] == 'llm' else None
    root = Path(request['output_root'])
    root.mkdir(parents=True,exist_ok=True)
    run_id = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ')+'-'+uuid.uuid4().hex[:10]
    directory = root / run_id
    directory.mkdir()
    manifest_path = directory / 'manifest.json'
    manifest = {'schema_version':1,'run_id':run_id,'reference_id':request.get('reference_id'),'title':request.get('title') or Path(request['source_path']).stem,'created_at':dt.datetime.now(dt.timezone.utc).isoformat(),'status':'running','mode':request['mode'],'quality':'source_draft' if request['mode']=='offline' else 'generated_unreviewed','run_dir':str(directory),'manifest_path':str(manifest_path),'artifacts':{},'warnings':[],'metrics':{},'source_path':request['source_path']}
    # Only environment variable names are accepted for secrets; preserve configuration for reproducibility.
    write_json(directory / 'request.json',request)
    write_json(manifest_path,manifest)
    previous_sigterm = None
    cancellation_requested = False
    if threading.current_thread() is threading.main_thread():
        previous_sigterm = signal.getsignal(signal.SIGTERM)
        def cancel(signum,frame):
            nonlocal cancellation_requested
            cancellation_requested = True
            raise PipelineCancelled('用户取消了本次生成；已保留来源和完成的分块。')
        signal.signal(signal.SIGTERM,cancel)
    try:
        progress('提取完整文献与页面版面')
        source = extract_source(request,directory)
        progress(f'已保留 {len(source["pages"])} 页、{len(source.get("raw_blocks",source["blocks"]))} 个原始文本块；按版面重组为 {len(source["blocks"])} 个来源段落')
        book_config = request.get('book',{})
        if book_config and book_config.get('enabled',True):
            from .book import chapter_plan
            chapter_plan(source,book_config)
        warnings = manifest['warnings']
        warnings.extend(source['warnings'])
        source_path = directory / 'source.json'
        write_json(source_path,source)
        (directory / 'source.md').write_text(source['markdown'],encoding='utf-8')
        artifacts = manifest['artifacts']
        artifacts.update({'source':str(source_path),'source_markdown':str(directory / 'source.md')})
        write_json(directory/'figures.json',{'items':source['figure_inventory'],'coverage':source['figure_coverage'],'documents':source['documents']})
        artifacts['figure_inventory'] = str(directory/'figures.json')
        if source.get('canonical_markdown') is not None:
            (directory / 'markitdown.md').write_text(source['canonical_markdown'],encoding='utf-8')
            artifacts['converted_markdown'] = str(directory / 'markitdown.md')
        learning,extraction = make_learning(source,request,directory,provider,progress)
        from .learning_review import apply_extraction_review
        extraction = apply_extraction_review(extraction,source,request,directory)
        if request.get('citation'):
            learning['citation'] = str(request['citation'])
        from .dataset import export_dataset, validate_extraction
        warnings.extend(validate_extraction(extraction,source))
        warnings.extend(extraction.get('warnings',[]))
        write_json(directory / 'learning.json',learning)
        write_json(directory / 'extraction.json',extraction)
        artifacts['learning'] = str(directory / 'learning.json')
        artifacts['extraction'] = str(directory / 'extraction.json')
        if (directory/'learning-review.json').is_file():
            artifacts['learning_review'] = str(directory/'learning-review.json')
        if (directory/'extraction-review.json').is_file():
            artifacts['extraction_review'] = str(directory/'extraction-review.json')
            artifacts['extraction_before_review'] = str(directory/'extraction-before-review.json')
        progress('生成离线 HTML、Markdown、字段数据集与证据图谱')
        artifacts.update(render_guide(source,learning,extraction,directory,warnings))
        from .reading_editions import render_reading_editions
        artifacts.update(render_reading_editions(source,learning,directory))
        if book_config and book_config.get('enabled',True):
            from .book import render_book
            progress('生成全书目录与完整覆盖的章节学习稿')
            artifacts.update(render_book(source,learning,extraction,book_config,directory,warnings))
        artifacts.update(export_dataset(extraction,directory,source))
        artifacts['agent'] = create_agent(source,extraction,request,directory)
        artifacts['mcp'] = str(directory / 'agent' / 'mcp.json')
        from .integrations import create_paper2agent_bundle, graphiti_ingest
        integration_errors = {}
        if request.get('paper2agent',{}).get('enabled'):
            progress('准备可追溯的 Paper2Agent 上游工作流')
            try:
                upstream = create_paper2agent_bundle(Path(request['source_path']),directory / 'paper2agent',request['paper2agent'])
                write_json(directory / 'paper2agent.json',upstream)
                artifacts['upstream_paper2agent'] = str(directory / 'paper2agent.json')
                manifest['paper2agent'] = upstream
                warnings.append('Paper2Agent 上游任务已准备；科学代码复现与工具验证须通过 paper2agent-launch 执行完成后单独检查。')
            except Exception as error:
                if cancellation_requested:
                    raise PipelineCancelled('用户取消了本次生成；本地资料已保留。') from error
                integration_errors['paper2agent'] = str(error)
                warnings.append(f'Paper2Agent 准备失败：{error}；本地学习资料已保留。')
        if request.get('graphiti',{}).get('enabled'):
            progress('向 Graphiti 写入文献，构建时序知识图谱')
            graph_config = dict(request['graphiti'])
            graph_config.setdefault('entity_fields',request['fields'])
            try:
                graph = graphiti_ingest(directory / 'reading-content.md',{'reference_id':request.get('reference_id'),'title':manifest['title'],'source_sha256':source['sha256'],'source_path':source['path']},graph_config)
                write_json(directory / 'graphiti.json',graph)
                artifacts['graphiti'] = str(directory / 'graphiti.json')
                manifest['graphiti'] = graph
            except Exception as error:
                if cancellation_requested:
                    raise PipelineCancelled('用户取消了本次生成；本地资料已保留。') from error
                integration_errors['graphiti'] = str(error)
                warnings.append(f'Graphiti 写入失败：{error}；本地学习资料和证据图谱已保留。')
        metrics = {'pages':len(source['pages']),'source_blocks':len(source['blocks']),'processed_blocks':len(learning['paragraphs']) if request['mode']=='llm' else len(source['blocks']),'explained_blocks':len(learning['paragraphs']),'source_characters':sum(len(page['text']) for page in source['pages']),'page_previews':len(source['figures']),'records':len(extraction['records']),'equations':len(learning['equations']),'quiz_questions':len(learning['quiz']),'provider_calls':provider.calls if provider else 0,'provider_usage':provider.usage if provider else {}}
        if cancellation_requested:
            raise PipelineCancelled('用户取消了本次生成；本地资料已保留。')
        metrics['calculations'] = len(learning.get('calculations',[]))
        metrics['raw_source_blocks'] = len(source.get('raw_blocks',source['blocks']))
        metrics['reading_groups'] = len(source.get('reading_blocks',[]))
        metrics['clean_reading_groups'] = len(learning.get('clean_reading',[]))
        metrics['thematic_sections'] = len(learning.get('thematic_sections',[]))
        metrics['figure_candidates'] = len(source['figure_inventory'])
        manifest.update({'status':'partial' if integration_errors else 'completed','integration_errors':integration_errors,'metrics':metrics,'source_sha256':source['sha256'],'documents':source['documents'],'artifact_sha256':{name:sha256(path) for name,path in artifacts.items() if Path(path).is_file()},'finished_at':dt.datetime.now(dt.timezone.utc).isoformat()})
        write_json(manifest_path,manifest)
        update_index(root,manifest)
        progress(f'完成：{directory}')
        return manifest
    except Exception as error:
        manifest.update({'status':'cancelled' if cancellation_requested or isinstance(error,PipelineCancelled) else 'failed','error':str(error),'finished_at':dt.datetime.now(dt.timezone.utc).isoformat()})
        write_json(manifest_path,manifest)
        update_index(root,manifest)
        raise PipelineError(f'{error}（已保存运行记录：{manifest_path}）') from error
    finally:
        if previous_sigterm is not None:
            signal.signal(signal.SIGTERM,previous_sigterm)

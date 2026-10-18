"""Complete-coverage chapter packages and an offline book index."""
from __future__ import annotations

import copy
import hashlib
import html
from pathlib import Path

from .contracts import PipelineError, write_json


def chapter_plan(source:dict,config:dict)->list[dict]:
    documents = {document['id']:document for document in source['documents']}
    chapters = copy.deepcopy(config.get('chapters',[]))
    if not chapters and config.get('auto'):
        for identifier,document in documents.items():
            outline = [entry for entry in document.get('outline',[]) if entry['level']==1]
            if identifier=='main' and not outline:
                raise PipelineError('本书没有可用的一级 PDF 书签；请在 book.chapters 明确指定章节页码。')
            starts = {entry['page']:entry['title'] for entry in outline}
            if 1 not in starts:
                starts[1] = '前置资料' if outline else document['name']
            pages = sorted(starts)
            for index,page in enumerate(pages):
                chapters.append({'document_id':identifier,'title':starts[page],'start_page':page,'end_page':pages[index+1]-1 if index+1<len(pages) else document['page_count']})
    if not isinstance(chapters,list) or not chapters:
        raise PipelineError('book.chapters 不能为空；或启用 book.auto 从 PDF 书签建章。')
    covered = set()
    for index,chapter in enumerate(chapters,1):
        if not isinstance(chapter,dict):
            raise PipelineError('章节必须为对象。')
        identifier = chapter.setdefault('document_id','main')
        document = documents.get(identifier)
        first,last = chapter.get('start_page'),chapter.get('end_page')
        if not document or type(first) is not int or type(last) is not int or not 1<=first<=last<=document['page_count']:
            raise PipelineError('章节范围必须是相应文档内的有效整页范围。')
        if not isinstance(chapter.get('title'),str) or not chapter['title'].strip():
            raise PipelineError('章节必须有非空 title。')
        chapter['id'] = f'chapter-{index:03d}'
        chapter['file'] = f'chapters/{chapter["id"]}/learning.html'
        for page in range(first,last+1):
            key = (identifier,page)
            if key in covered:
                raise PipelineError(f'章节页码重复：{identifier} p.{page}')
            covered.add(key)
    expected = {(identifier,page) for identifier,document in documents.items() for page in range(1,document['page_count']+1)}
    if covered!=expected:
        missing = ', '.join(f'{doc} p.{page}' for doc,page in sorted(expected-covered))
        raise PipelineError(f'章节必须覆盖全部文档页，当前缺少：{missing}')
    return chapters


def render_book(source,learning,extraction,config,run_dir,warnings):
    from .rendering import render_guide, CSS
    chapters = chapter_plan(source,config)
    owner = {}
    for chapter in chapters:
        for block in source['blocks']:
            if block.get('document_id','main')==chapter['document_id'] and chapter['start_page']<=block['page']<=chapter['end_page']:
                owner[block['id']] = chapter
    for key,prefix in [('equations','eq'),('figures_tables','figure-reading')]:
        for index,item in enumerate(learning[key],1):
            item.setdefault('target_id',f'{prefix}-{index}')
    targets = []
    for key in ('equations','figures_tables'):
        for item in learning[key]:
            identifiers = item.get('source_ids',[])
            if not identifiers:
                continue
            chapter = owner[identifiers[0]]
            label = item.get('label','')
            kind = 'eq' if key=='equations' else ('tab' if label.lower().startswith(('table','tab.','表')) else ('sch' if label.lower().startswith(('scheme','图式')) else 'fig'))
            targets.append({'id':item['target_id'],'label':label,'kind':kind,'document_id':chapter['document_id'],'chapter':chapter})
    for chapter in chapters:
        directory = run_dir/'chapters'/chapter['id']
        directory.mkdir(parents=True)
        belongs = lambda item:item.get('document_id','main')==chapter['document_id'] and chapter['start_page']<=item['page']<=chapter['end_page']
        local_source = copy.deepcopy(source)
        for collection in ('pages','blocks','raw_blocks','figures','figure_crops','figure_inventory','reading_blocks','reading_main_blocks','reading_fragments','reading_excluded'):
            if collection in local_source:
                local_source[collection] = [item for item in source[collection] if belongs(item)]
        local_source['reference_blocks'] = [{**block,'href':f'../{owner[block["id"]]["id"]}/learning.html#src-{block["id"]}'} for block in source['blocks'] if owner[block['id']]['id']!=chapter['id']]
        local_source['reference_targets'] = [{key:value for key,value in target.items() if key!='chapter'}|{'href':f'../{target["chapter"]["id"]}/learning.html#{target["id"]}'} for target in targets if target['chapter']['id']!=chapter['id']]
        local_source['document_set_sha256'] = hashlib.sha256((source['document_set_sha256']+chapter['id']).encode()).hexdigest()
        local_learning = copy.deepcopy(learning)
        local_learning['title'] = f'{learning["title"]} · {chapter["title"]}'
        local_learning['overview'] = f'本章覆盖 {chapter["document_id"]} 第 {chapter["start_page"]}–{chapter["end_page"]} 页。\n\n'+learning['overview']
        local_learning['paragraphs'] = [item for item in learning['paragraphs'] if owner[item['source_id']]['id']==chapter['id']]
        for key in ('methods','findings','critique','transfer','equations','figures_tables','quiz','glossary','calculations'):
            local_learning[key] = [item for item in local_learning.get(key,[]) if item.get('source_ids') and owner[item['source_ids'][0]]['id']==chapter['id']]
        for key, values in local_learning.get('consolidated', {}).items():
            local_learning['consolidated'][key] = [item for item in values if item.get('source_ids') and owner[item['source_ids'][0]]['id']==chapter['id']]
        local_learning['thematic_sections'] = []
        for section in learning.get('thematic_sections', []):
            paragraphs = [item for item in section['paragraphs'] if item.get('source_ids') and owner[item['source_ids'][0]]['id']==chapter['id']]
            if paragraphs:
                local_learning['thematic_sections'].append({**section, 'paragraphs': paragraphs, 'source_ids': list(dict.fromkeys(identifier for item in paragraphs for identifier in item['source_ids']))})
        local_extraction = copy.deepcopy(extraction)
        local_extraction['records'] = [record for record in extraction['records'] if any(owner[citation['block_id']]['id']==chapter['id'] for cell in record['values'].values() for citation in cell.get('evidence',[]))]
        result = render_guide(local_source,local_learning,local_extraction,directory,warnings)
        file = Path(result['html'])
        content = file.read_text(encoding='utf-8').replace('<article>','<article><p><a href="../../index.html">← 返回全书目录</a></p>',1)
        file.write_text(content,encoding='utf-8')
        markdown_file = Path(result['markdown'])
        markdown = markdown_file.read_text(encoding='utf-8')
        for companion in ('fulltext.md','paragraphs.md','source-index.md'):
            markdown = markdown.replace(f']({companion})', f'](../../{companion})')
        markdown_file.write_text(markdown,encoding='utf-8')
        chapter['artifacts'] = result
        chapter['source_blocks'] = len(local_source['blocks'])
        chapter['explained_blocks'] = len(local_learning['paragraphs'])
    links = ''.join(f'<li class="card"><a href="{html.escape(chapter["file"])}">{html.escape(chapter["title"])}</a><p class="meta">{html.escape(chapter["document_id"])} · p.{chapter["start_page"]}–{chapter["end_page"]} · {chapter["source_blocks"]} 个来源块</p></li>' for chapter in chapters)
    index = run_dir/'index.html'
    index.write_text(f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{html.escape(learning["title"])} · 全书目录</title><style>{CSS}</style></head><body><main style="display:block;max-width:900px"><p class="eyebrow">PaperShelf / Book</p><h1>{html.escape(learning["title"])}</h1><p>章节覆盖全部 {len(source["pages"])} 页，合计 {len(source["blocks"])} 个来源块。每章都包含来源链接与页图。</p><ol>{links}</ol><p><a href="learning.html">打开完整单文件学习稿</a> · <a href="learning.md">完整 Markdown</a></p></main></body></html>',encoding='utf-8')
    manifest = {'chapters':chapters,'pages':len(source['pages']),'source_blocks':len(source['blocks']),'coverage':'all_pages_exactly_once'}
    write_json(run_dir/'book.json',manifest)
    return {'html':str(index),'book_index':str(index),'book_manifest':str(run_dir/'book.json'),'full_html':str(run_dir/'learning.html')}

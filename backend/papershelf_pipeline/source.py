"""Retain every extracted page and block, with exact provenance and page previews."""
from __future__ import annotations

import base64
import hashlib
import json
import re
from pathlib import Path

from .contracts import PipelineError, PipelineCancelled, normalize_quote, read_json, sha256


def _extract_document(request: dict, run_dir: Path) -> dict:
    source = Path(request["source_path"])
    warnings = []
    pages = []
    figures = []
    markdown = None
    engine = "text"
    outline = []
    raw_blocks = []
    block_layout = 'paragraph-text-v1'
    if source.suffix.lower() == ".pdf":
        try:
            import fitz
        except ImportError:
            if not request.get("source_pages_path"):
                raise PipelineError("PDF 需要 PyMuPDF。请运行 script/setup_integrations.sh，或提供 PDFKit source_pages_path。")
            raw_pages = read_json(request["source_pages_path"])
            if isinstance(raw_pages, dict):
                raw_pages = raw_pages.get("pages", [])
            pages = [{"page": int(page.get("page", index + 1)), "text": page["text"]} for index, page in enumerate(raw_pages)]
            engine = "pdfkit"
            warnings.append("PDFKit 提供全文；未生成页面图像，图表需要对照原 PDF 核实。")
        else:
            from .paragraphs import group_page_blocks
            engine = f"pymupdf/{fitz.VersionBind}"
            block_layout = 'pymupdf-semantic-paragraphs-v1'
            image_dir = run_dir / "pages"
            image_dir.mkdir()
            with fitz.open(source) as document:
                if document.needs_pass:
                    raise PipelineError("PDF 已加密，需要先提供可读取的副本。")
                outline = [{'level':level,'title':title,'page':page} for level,title,page in document.get_toc() if page>0]
                for index, page in enumerate(document):
                    number = index + 1
                    text = page.get_text("text", sort=True)
                    page_raw = []
                    for block in page.get_text('blocks',sort=True):
                        if block[6]==0 and block[4].strip():
                            page_raw.append({'id':f'p{number}-b{len(raw_blocks)+len(page_raw)+1}',
                                             'page':number,'text':block[4],'bbox':list(block[:4]),'block_number':block[5]})
                    raw_blocks.extend(page_raw)
                    paragraphs = group_page_blocks(page,page_raw)
                    pages.append({"page": number, "text": text, "width": page.rect.width, "height": page.rect.height, "paragraphs": [part['text'] for part in paragraphs],
                                  '_semantic_paragraphs':paragraphs})
                    # Render every page: this also preserves vector figures and scanned pages.
                    pixmap = page.get_pixmap(matrix=fitz.Matrix(1.4, 1.4), alpha=False)
                    path = image_dir / f"page-{number:04d}.jpg"
                    pixmap.save(str(path), jpg_quality=82)
                    figures.append({"page": number, "path": str(path), "width": pixmap.width, "height": pixmap.height, "kind": "page_preview", "caption": f"第 {number} 页原版面（包括图表；未经自动裁图核验）"})
        empty = [page["page"] for page in pages if not page["text"].strip()]
        if empty:
            warnings.append(f"第 {', '.join(map(str, empty))} 页没有可提取文本；保留页面图像，需 OCR 后才能完成这些页的逐段讲解。")
    elif source.suffix.lower() in {".txt", ".md", ".markdown", ".csv", ".json"}:
        markdown = source.read_text(encoding="utf-8-sig")
        pages = [{"page": 1, "text": markdown}]
    else:
        from .integrations import convert_with_markitdown
        converted = convert_with_markitdown(source)
        markdown = converted["markdown"]
        engine = converted["engine"]
        warnings.extend(converted.get("warnings", []))
        pages = [{"page": 1, "text": markdown}]
        warnings.append("此格式由 MarkItDown 转为 Markdown；引用位置为转换文本块，不代表原文页码。")
    if not pages:
        raise PipelineError("文献没有页面或文本。")
    blocks = []
    for page in pages:
        if '_semantic_paragraphs' in page:
            for part_index,part in enumerate(page.pop('_semantic_paragraphs'),1):
                blocks.append({**part,'id':f'p{page["page"]}-g{len(blocks)+1}',
                               'page':page['page'],'paragraph_on_page':part_index})
            continue
        # Form feed / blank lines define paragraphs; no text is discarded or sampled.
        parts = page.get("paragraphs") or [part.strip() for part in re.split(r"\n\s*\n|\f", page["text"]) if part.strip()]
        for part_index, part in enumerate(parts, 1):
            # A long page-sized paragraph is split at lines for bounded provider requests.
            segments = []
            while len(part) > 7000:
                end = max(part.rfind("\n", 0, 6500), part.rfind(". ", 0, 6500), part.rfind("。", 0, 6500))
                end = end + 1 if end > 1000 else 6500
                segments.append(part[:end])
                part = part[end:]
            segments.append(part)
            for segment in segments:
                blocks.append({"id": f"p{page['page']}-b{len(blocks)+1}", "page": page["page"], "text": segment, "paragraph_on_page": part_index})
    for block in blocks:
        block['source_anchor'] = normalize_quote(block['text'])[:96]
    if not raw_blocks:
        raw_blocks = [{key:block[key] for key in ('id','page','text')} for block in blocks]
    fallback_pages = sorted({block['page'] for block in blocks if block.get('grouping_notes')})
    if fallback_pages:
        warnings.append('部分 PDF 布局无法唯一重组，已原样保留对应文本块；请对照第 '+', '.join(map(str,fallback_pages))+' 页原版面核验阅读顺序。')
    if not blocks:
        if request["mode"] == "llm":
            raise PipelineError("未提取到任何文本；扫描件必须先 OCR，不能生成没有来源的讲解。")
        warnings.append("未提取到可搜索的文字；该资料包仅保留原页面图像。")
    if markdown is None:
        markdown = "\n\n".join(f"<!-- source-page: {page['page']} -->\n\n"+'\n\n'.join(page.get('paragraphs') or [page['text']]) for page in pages)
    canonical = None
    if source.suffix.lower() == ".pdf":
        try:
            from .integrations import convert_with_markitdown
            converted = convert_with_markitdown(source)
            canonical = converted["markdown"]
            warnings.extend(converted.get("warnings", []))
        except PipelineCancelled:
            raise
        except Exception as error:
            warnings.append(f"MarkItDown 转换未完成（{type(error).__name__}）；完整页码文本仍由 {engine} 保留。")
    else:
        canonical = markdown
    inventory = {'items':[],'warnings':[],'coverage':'not_applicable'}
    if source.suffix.lower()=='.pdf' and figures:
        from .figures import extract_figure_inventory
        inventory = extract_figure_inventory(source,run_dir/'figure-crops',request.get('_document_id','main'),request.get('figure_boxes'),page_previews=figures)
        warnings.extend(inventory.get('warnings',[]))
        warnings.append('图表清单与候选裁图为可追溯的自动检测结果，保留坐标与完整页图；需审阅是否漏图、跨页或裁切错误。')
    return {"path": str(source), "sha256": sha256(source), "engine": engine, "block_layout":block_layout,
            "pages": pages, "blocks": blocks, "raw_blocks":raw_blocks, "figures": figures, "figure_inventory":list(inventory['items']), "figure_crops":list(inventory['items']), "figure_coverage":inventory.get('coverage'), "outline":outline, "markdown": markdown, "canonical_markdown": canonical, "warnings": warnings}


def extract_source(request: dict, run_dir: Path) -> dict:
    result = _extract_document(request,run_dir)
    result['documents'] = [{'id':'main','name':Path(result['path']).name,'path':result['path'],'sha256':result['sha256'],'role':'main','page_count':len(result['pages']),'outline':result['outline']}]
    for number,supplement in enumerate(request.get('supplementary_paths',[]),1):
        supplement_path = Path(supplement).expanduser().resolve()
        if not supplement_path.is_file():
            raise PipelineError(f'补充材料不存在：{supplement_path}')
        directory = run_dir / f'supplement-{number}'
        directory.mkdir()
        secondary_request = {**request,'source_path':str(supplement_path),'_document_id':f's{number}'}
        secondary_request.pop('source_pages_path',None)
        secondary = _extract_document(secondary_request,directory)
        for collection in ('blocks','raw_blocks','pages','figures'):
            for item in secondary[collection]:
                item['document'] = supplement_path.name
                item['document_id'] = f's{number}'
                if collection in {'blocks','raw_blocks'}:
                    item['id'] = f's{number}-{item["id"]}'
                    if 'raw_block_ids' in item:
                        item['raw_block_ids'] = [f's{number}-{identifier}' for identifier in item['raw_block_ids']]
                    for line in item.get('lines',[]):
                        if line.get('raw_block_id'):
                            line['raw_block_id'] = f's{number}-{line["raw_block_id"]}'
            result[collection].extend(secondary[collection])
        result['documents'].append({'id':f's{number}','name':supplement_path.name,'path':str(supplement_path),'sha256':secondary['sha256'],'role':'supplement','page_count':len(secondary['pages']),'outline':secondary['outline']})
        result['figure_inventory'].extend(secondary['figure_inventory'])
        result['figure_crops'].extend(secondary['figure_crops'])
        result['warnings'].extend(secondary['warnings'])
        result['markdown'] += f'\n\n# 补充材料：{supplement_path.name}\n\n'+secondary['markdown']
        if secondary['canonical_markdown']:
            result['canonical_markdown'] = (result['canonical_markdown'] or '')+f'\n\n# 补充材料：{supplement_path.name}\n\n'+secondary['canonical_markdown']
    embedded = [page['page'] for page in result['pages'] if not page.get('document_id') and re.search(r'(?im)^\s*(?:Supporting|Supplementary)\s+Information(?:\s+for)?\s*$',page['text'][:1200])]
    result['embedded_supplement_start_page'] = min(embedded) if embedded else None
    if embedded:
        result['warnings'].append(f'按标题检测到 PDF 第 {min(embedded)} 页起含内嵌补充材料；这些页面已随全文处理。')
    if not request.get('supplementary_paths'):
        result['warnings'].append('未另行提供外部补充材料；已处理当前文件全部页面（含其中可能内嵌的 SI），仍需核对是否存在额外附件。')
    result['document_set_sha256'] = hashlib.sha256(json.dumps([{'sha256':document['sha256'],'role':document['role']} for document in result['documents']],sort_keys=True).encode()).hexdigest()
    from .learning_review import layout_observations
    result['layout_observations'] = layout_observations(result,request)
    for block in result['blocks']:
        notes = [item for item in result['layout_observations'] if block['id'] in item['source_ids']]
        if notes:
            block['layout_observations'] = notes
    from .reading import apply_reading_layer
    return apply_reading_layer(result)


def image_data(figure: dict) -> str:
    path = Path(figure.get('path') or figure['image_path'])
    mime = 'image/png' if path.suffix.lower()=='.png' else 'image/jpeg'
    return f"data:{mime};base64," + base64.b64encode(path.read_bytes()).decode("ascii")

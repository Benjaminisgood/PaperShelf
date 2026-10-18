"""Offline, escaped HTML learning guide and companion Markdown."""
from __future__ import annotations

import html
import json
import re
import os
import xml.etree.ElementTree as ET
from pathlib import Path

from .source import image_data
from .calculations import CALCULATOR_JS
from .contracts import PipelineCancelled


CSS = r"""
:root{color-scheme:light;--ink:#243131;--muted:#647170;--paper:#faf9f5;--accent:#17685b;--line:#d8dfd9}*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:1rem}body{margin:0;background:var(--paper);color:var(--ink);font:17px/1.85 Georgia,'Times New Roman','Songti SC',serif}main{max-width:1180px;margin:auto;display:grid;grid-template-columns:210px minmax(0,1fr);gap:42px;padding:32px}nav{position:sticky;top:20px;height:calc(100vh - 40px);overflow:auto;font:14px/1.5 system-ui,sans-serif}nav a{display:block;padding:8px 10px;border-left:2px solid var(--line);color:var(--muted);text-decoration:none}nav a:hover{border-color:var(--accent);color:var(--accent)}article{min-width:0}header{border-bottom:2px solid var(--accent);padding-bottom:24px}h1{font-size:clamp(25px,3.5vw,39px);line-height:1.4;letter-spacing:-.02em}h2{font-size:25px;margin:42px 0 18px}h3{font-size:19px;margin:24px 0 8px}p{white-space:pre-wrap;overflow-wrap:anywhere}.eyebrow,.muted,.meta{font:13px/1.6 system-ui,sans-serif;color:var(--muted)}.eyebrow{letter-spacing:.18em;text-transform:uppercase;color:var(--accent)}.callout{background:#edf5f0;border-left:4px solid var(--accent);padding:16px 20px;border-radius:0 9px 9px 0}.warning{background:#fff5e2;border-color:#ac751d}.card,.paragraph{border:1px solid var(--line);background:#fff;border-radius:10px;padding:18px 22px;margin:14px 0}.paragraph:target,.source:target{box-shadow:0 0 0 3px #8bc9b5}.source{border-left:3px solid #c1d3c8;padding:12px 18px;margin:12px 0}.source pre{white-space:pre-wrap;overflow-wrap:anywhere;font:14px/1.7 'Times New Roman','Songti SC',serif}details{margin:8px 0}summary{cursor:pointer;color:var(--accent);font-size:14px}a{color:var(--accent)}.cite{display:inline-block;font:12px/1.5 system-ui,sans-serif;margin:0 3px;padding:2px 5px;border-radius:4px;background:#edf4ef}.badge{display:inline-block;font:11px/1.4 system-ui;padding:3px 6px;border-radius:4px;background:#e6efeb;color:#17685b}.badge.uncertain{background:#fff0eb;color:#a1442d}.badge.inference{background:#ccfbf1;color:#0f766e}.table-wrap,.equation{overflow:auto;max-width:100%}table{border-collapse:collapse;width:100%;font-size:14px}th,td{padding:10px;border:1px solid var(--line);vertical-align:top;text-align:left;overflow-wrap:anywhere}th{background:#eef3ee}figure{margin:20px 0}figure img{display:block;width:100%;height:auto;border:1px solid var(--line);cursor:zoom-in}figcaption{font:13px/1.6 system-ui;margin:9px 0;color:var(--muted)}button,input,textarea{font:14px/1.6 system-ui}button{border:1px solid #aac4b8;border-radius:6px;background:#f3f8f4;padding:7px 11px;color:var(--accent);cursor:pointer}textarea{width:100%;min-height:90px;border:1px solid var(--line);padding:12px;border-radius:6px}.controls{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.notes-status{font:13px system-ui;color:var(--muted)}mark{background:#ffe99d}dialog{width:min(95vw,1200px);max-height:95vh;border:0;border-radius:10px;padding:18px}dialog img{width:100%;height:auto}dialog::backdrop{background:#17221ecc}math{font-family:'Times New Roman',serif;font-size:1.1em}.question{background:#f4f8f4}input[type=search]{width:100%;padding:9px;border:1px solid var(--line);border-radius:6px}.hidden{display:none!important}footer{margin:50px 0;color:var(--muted);font:12px/1.6 system-ui}@media(max-width:760px){main{display:block;padding:20px}nav{position:static;height:auto;margin-bottom:25px;display:flex;gap:4px;flex-wrap:wrap}nav a{padding:4px 8px;border:1px solid var(--line);border-radius:5px}nav .eyebrow{width:100%}.card,.paragraph{padding:14px}h2{font-size:22px}body{font-size:16px}}@media print{nav,.controls,textarea,dialog{display:none}main{display:block;max-width:none;padding:0}details{display:block}details>*{display:block}.card{break-inside:avoid}a{color:inherit}figure{break-inside:avoid}}
"""



def esc(value) -> str:
    return html.escape(str(value or ""), quote=True)


def refs(ids: list, blocks: dict) -> str:
    return " ".join(f'<a class="cite" href="{esc(blocks[identifier].get("href", "#src-"+identifier))}">{esc(blocks[identifier].get("document", ""))} p.{blocks[identifier]["page"]} · {esc(identifier)}</a>' for identifier in ids if identifier in blocks)


def badge(kind: str) -> str:
    labels = {"source": "文中", "background": "教材", "inference": "迁移推论", "uncertain": "存疑"}
    kind = kind if kind in labels else "uncertain"
    return f'<span class="badge {kind}">{labels[kind]}</span>'


def math_html(latex: str, warnings: list) -> str:
    try:
        from latex2mathml.converter import convert
        markup = convert(latex)
        if '<!' in markup:
            raise ValueError('MathML declarations are not permitted')
        root = ET.fromstring(markup)
        tags = {'math','mrow','mi','mn','mo','mfrac','msup','msub','msubsup','msqrt','mroot','mtext','mspace','mtable','mtr','mtd','munder','mover','munderover','mpadded','mphantom','menclose','mstyle','mlabeledtr','mmultiscripts','mprescripts','none'}
        attributes = {'display','mathvariant','stretchy','fence','accent','accentunder','columnalign','rowalign','columnspacing','rowspacing','linethickness','width','height','depth','lspace','rspace','notation','mathsize','form','separator','symmetric','movablelimits','displaystyle','scriptlevel','columnspan','rowspan'}
        for node in root.iter():
            tag = node.tag.rsplit('}',1)[-1]
            if tag not in tags or not node.tag.startswith('{http://www.w3.org/1998/Math/MathML}'):
                raise ValueError('Unsupported MathML element')
            for name,value in list(node.attrib.items()):
                if name not in attributes or not re.fullmatch(r'[a-zA-Z0-9 .,+%_\-]*',value):
                    del node.attrib[name]
        ET.register_namespace('', 'http://www.w3.org/1998/Math/MathML')
        return ET.tostring(root,encoding='unicode')
    except PipelineCancelled:
        raise
    except Exception:
        message = "部分公式无法转换为离线 MathML，保留原 LaTeX 供核对。"
        if message not in warnings:
            warnings.append(message)
        return f'<pre aria-label="LaTeX 公式">{esc(latex)}</pre>'


def render_guide(source: dict, learning: dict, extraction: dict, run_dir: Path, warnings: list, *, formats=None) -> dict:
    from .guide_interactions import normalized_label
    # Keep draft cards in learning.json while presenting the full-document edit.
    learning = {**learning, **learning.get('consolidated', {})}
    blocks = {block['id']:block for block in source.get('reference_blocks',[])}
    blocks.update({block["id"]: block for block in source["blocks"]})
    def doc_id(item):
        identifiers = item.get('source_ids',[]) or [item.get('source_id')]
        return next((blocks[identifier].get('document_id','main') for identifier in identifiers if identifier in blocks),'main')
    def crop_html(crop):
        note = '手工指定坐标' if crop.get('source')=='manual' else '自动候选裁图，需核验边界'
        table = ''
        if crop.get('cells'):
            table = '<p class="meta">下表逐格来自 PDF 表格检测，空白单元保持空白；请展开原图检查合并单元、符号与跨行含义。</p><div class="table-wrap"><table><tbody>'+''.join('<tr>'+''.join(f'<td>{esc(cell)}</td>' for cell in row)+'</tr>' for row in crop['cells'])+'</tbody></table></div>'
        image = f'<figure><img src="{image_data(crop)}" width="{crop["width"]}" height="{crop["height"]}" loading="lazy" alt="{esc(crop["label"])}"><figcaption>{esc(crop["caption"])}<br>{note} · p.{crop["page"]} · PDF 坐标 {esc(crop["rect"])} · 置信度 {crop.get("confidence",0):.2f}</figcaption></figure>'
        return table+('<details><summary>展开原表裁图</summary>'+image+'</details>' if table else image)
    title = learning["title"]
    generated = learning["mode"] == "llm"
    thematic = learning.get('thematic_sections', [])
    reading_edition = 'reading_blocks' in source
    sections = [("overview", "阅读概览"), ("paragraphs", "逐段讲解" if generated else "来源正文"), ("methods", "实验与模型"), ("findings", "结果与证据"), ("equations", "公式与符号"), ("calculations", "数值复算与探索"), ("figures", "图表与原版面"), ("critique", "批评与核验"), ("transfer", "知识迁移"), ("fields", "自定义字段"), ("quiz", "自测与答辩"), ("glossary", "术语表"), ("notes", "学习笔记"), ("gaps", "不足与缺口"), ("sources", "完整来源索引")]
    if thematic:
        sections.insert(1, ('reading', '论文研读'))
        sections = [(identifier, '逐段对照' if identifier == 'paragraphs' else label) for identifier, label in sections]
    nav = ''.join(f'<a href="#{identifier}">{label}</a>' for identifier, label in sections)
    out = [f'<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="doc-id" content="{source.get("document_set_sha256",source["sha256"])[:20]}"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data:; style-src \'unsafe-inline\'; script-src \'unsafe-inline\'; connect-src \'none\'; object-src \'none\'; base-uri \'none\'"><title>{esc(title)} · PaperShelf</title><style>{CSS}</style></head><body><main><nav aria-label="章节目录"><p class="eyebrow">PaperShelf / Study</p>{nav}</nav><article>', f'<header><p class="eyebrow">{("文献精读 · 待核验学习稿" if generated else "离线来源资料包 · 未生成讲解")}</p><h1>{esc(title)}</h1><p class="meta">来源：{esc(Path(source["path"]).name)} · {len(source["pages"])} 页 · {len(source["blocks"])} 个文本块 · {esc(source["engine"])}</p><div class="callout warning">{"AI 译述与解释必须结合原文核验；证据检查不等于科学验收。" if generated else "当前是完整来源资料包。配置模型后才会生成逐段中文译述、分析、自测和有证据的字段结果。"}</div></header>', f'<section id="overview"><h2>阅读概览</h2><p>{esc(learning["overview"])}</p>']
    md = [f'# {title}', '', '> ' + ('AI 文献精读学习稿，待研究者核验。' if generated else '离线来源资料包，尚未生成语义讲解或字段值。'), '', f'来源：{Path(source["path"]).name}', f'SHA256：{source["sha256"]}', '', '## 阅读概览', '', learning["overview"]]
    if learning.get('citation'):
        out.insert(2,f'<p class="meta">{esc(learning["citation"])}</p>')
        md[4:4] = ['引文：'+learning['citation'],'']
    if learning.get("reading_route"):
        out.append('<ol>'+''.join(f'<li>{esc(item)}</li>' for item in learning["reading_route"])+'</ol>')
        md.extend('\n- '+str(item) for item in learning["reading_route"])
    out.append('</section>')
    if thematic:
        out.append('<section id="reading"><h2>论文研读</h2>')
        md.extend(['', '## 论文研读', '', '[原语言全文](fulltext.md) · [逐段对照](paragraphs.md) · [原始来源](source-index.md)', ''])
        for section in thematic:
            out.append(f'<section class="reading-section" data-highlight><h3>{esc(section["title"])}</h3>')
            md.extend(['### ' + section['title'], ''])
            for paragraph in section['paragraphs']:
                out.append(f'<div class="reading-prose" data-document-id="{esc(doc_id(paragraph))}"><p>{esc(paragraph["text"])}</p><div class="meta">{badge(paragraph.get("kind", "source"))} {refs(paragraph["source_ids"],blocks)}</div></div>')
                md.extend([paragraph['text'], '', '来源：' + ', '.join(paragraph['source_ids']), ''])
            out.append('</section>')
        out.append('</section>')
    out.append('<section id="paragraphs"><h2>'+('逐段对照' if thematic else '逐段中文讲解' if generated else '来源正文')+'</h2><label for="search">检索讲解与原文</label><input id="search" type="search" placeholder="输入术语、数值或关键词"><p id="search-status" aria-live="polite" class="meta"></p>')
    if thematic:
        out.append('<details class="paragraph-audit"><summary>展开逐段译述与来源对照</summary>')
    else:
        md.extend(['', '## 逐段中文讲解' if generated else '## 来源正文', ''])
    for paragraph in learning["paragraphs"]:
        identifier = paragraph["source_id"]
        block = blocks[identifier]
        if block.get('include_in_reading') is False or block.get('reading_main') is False:
            continue
        identifiers = paragraph.get('source_ids') or [identifier]
        out.append(f'<div class="paragraph" id="learn-{identifier}" data-highlight data-document-id="{esc(doc_id(paragraph))}"><div class="meta">第 {block["page"]} 页 · {esc(identifier)} {refs(identifiers,blocks)}</div><p>{esc(paragraph["explanation"])}</p>')
        if paragraph.get("reasoning"):
            out.append(f'<div class="callout"><p>{esc(paragraph["reasoning"])}</p></div>')
        for note in paragraph.get('editorial_notes', []):
            out.append('<aside class="callout"><p>原文校核：' + esc(note['text']) + '</p>' + refs(note['source_ids'], blocks) + '</aside>')
        if paragraph.get("key_sentence"):
            out.append(f'<details><summary>原文关键句 · p.{block["page"]}</summary><p lang="en">{esc(paragraph["key_sentence"])}</p></details>')
        original = '\n\n'.join(blocks[item]['text'] for item in identifiers if item in blocks)
        out.append(f'<details><summary>对照本段完整原文 · p.{block["page"]}</summary><pre>{esc(original)}</pre></details>')
        out.append('</div>')
        if not thematic:
            md.extend([f'### 第 {block["page"]} 页 · {identifier}', '', paragraph["explanation"], '', paragraph.get("reasoning", ""), '', f'> {paragraph.get("key_sentence", "")}', ''])
    if thematic:
        out.append('</details>')
    if not generated:
        for group in source.get('reading_main_blocks', source.get('reading_blocks', [])):
            out.append(f'<div class="paragraph" data-highlight><p>{esc(group["text"])}</p>{refs(group["source_ids"],blocks)}</div>')
            md.extend([group['text'], ''])
        out.append('<p>未经整理的提取文本见<a href="#sources">完整来源索引</a>。</p>')
    out.append('</section>')
    for key, heading in [('methods','实验与模型逻辑'),('findings','结果与证据'),('critique','批评与核验'),('transfer','知识延伸与迁移')]:
        out.append(f'<section id="{key}"><h2>{heading}</h2>')
        md.extend(['',f'## {heading}',''])
        for index, item in enumerate(learning[key],1):
            out.append(f'<div class="card" id="{key}-{index}" data-highlight data-document-id="{esc(doc_id(item))}">{badge(item.get("kind","source"))}<h3>{esc(item.get("title"))}</h3><p>{esc(item.get("body"))}</p>{refs(item["source_ids"],blocks)}</div>')
            md.extend([f'### {item.get("title", "")}', '', f'【{item.get("kind", "source")}】{item.get("body", "")}', f'来源：{", ".join(item["source_ids"])}', ''])
        if not learning[key]:
            out.append('<p class="muted">尚未生成本节内容。</p>')
        out.append('</section>')
    out.append('<section id="equations"><h2>公式与符号</h2>')
    md.extend(['','## 公式与符号',''])
    for index, equation in enumerate(learning['equations'],1):
        out.append(f'<div class="card" id="{esc(equation.get("target_id",f"eq-{index}"))}" data-ref-label="{esc(equation.get("label"))}" data-ref-kind="eq" data-document-id="{esc(doc_id(equation))}"><h3>{esc(equation.get("label"))}</h3><div class="equation">{math_html(equation["latex"],warnings)}</div><p>{esc(equation.get("meaning"))}</p><ul>'+''.join(f'<li>{esc(symbol.get("symbol"))}：{esc(symbol.get("meaning"))}</li>' for symbol in equation['symbols'])+'</ul>'+refs(equation['source_ids'],blocks)+'</div>')
        md.extend([f'### {equation.get("label", "公式")}', '', '$$\n'+equation['latex']+'\n$$', equation.get('meaning',''), *[f'- {symbol.get("symbol", "")}：{symbol.get("meaning", "")}' for symbol in equation['symbols']], '来源：'+', '.join(equation['source_ids'])])
    if not learning['equations']:
        out.append('<p class="muted">没有经过生成并定位到来源的公式；请对照原版面。</p>')
    if learning.get('unresolved_equations'):
        out.append('<details class="callout warning"><summary>待核对的公式原文</summary><p>以下提取含未识别字形，尚未可靠重建。保留提取文本和来源，供对照原页。</p>')
        md.extend(['', '<details><summary>待核对的公式原文</summary>', ''])
        for equation in learning['unresolved_equations']:
            out.append('<h3>' + esc(equation.get('label', '公式')) + '</h3><pre style="white-space:pre-wrap">' + esc(equation.get('latex', '')) + '</pre><p>' + esc(equation.get('reason', '需对照原页重建。')) + '</p>' + refs(equation['source_ids'], blocks))
            md.extend(['### ' + equation.get('label', '公式'), '', '```text', equation.get('latex', ''), '```', '', equation.get('reason', '需对照原页重建。'), '来源：' + ', '.join(equation['source_ids']), ''])
        out.append('</details>')
        md.extend(['</details>', ''])
    out.append('</section><section id="calculations"><h2>关键数字复算与交互探索</h2><p class="meta">使用原文数值代入明确算式，单位换算必须写在算式中。交互仅执行下列固定算式，不运行模型生成的代码；改动输入属于条件探索。</p>')
    md.extend(['','## 关键数字复算与交互探索',''])
    for index,calculation in enumerate(learning.get('calculations',[]),1):
        interactive = calculation.get('interactive',True)
        out.append(f'<div class="card" id="calculation-{index}"'+(' data-calculator' if interactive else '')+f' data-unit="{esc(calculation.get("output_unit",""))}" data-document-id="{esc(doc_id(calculation))}"><h3>{esc(calculation.get("title"))}</h3><pre>{esc(calculation["expression"])}</pre><p>{esc(calculation.get("interpretation"))}</p>')
        for variable in calculation['variables']:
            bounds = ''.join(f' {bound}="{variable[bound]}"' for bound in ('min','max') if bound in variable)
            value_control = f'<input type="number" step="any" data-variable="{esc(variable["name"])}" value="{variable["value"]}"{bounds}>' if interactive else esc(variable['value'])
            out.append(f'<label>{esc(variable["name"])} — {esc(variable.get("meaning"))} ({esc(variable.get("unit"))}) {value_control}</label><br>')
        data = json.dumps(calculation['expression_tree'],ensure_ascii=False).replace('<','\\u003c')
        out.append(f'<p>原文输入复算：<b>{calculation["computed_value"]:.12g} {esc(calculation.get("output_unit",""))}</b></p><p>当前输入：<output aria-live="polite"></output></p><script type="application/json">{data}</script>{refs(calculation["source_ids"],blocks)}</div>')
        md.extend([f'### {calculation.get("title", "复算")}',f'算式：`{calculation["expression"]}`',*[f'- {variable["name"]} = {variable["value"]} {variable.get("unit", "")}' for variable in calculation['variables']],f'复算结果：{calculation["computed_value"]:.12g} {calculation.get("output_unit", "")}',calculation.get('interpretation',''),'来源：'+', '.join(calculation['source_ids'])])
    if not learning.get('calculations'):
        out.append('<p class="muted">尚无通过原文数值与算式校验的复算。原文缺少可代入数值时不会编造示例参数。</p>')
    out.append('</section><section id="figures"><h2>图表与原版面</h2><p class="meta">完整保留每一页原版面，包括向量图、表格与扫描页；以下页图不代表已完成独立分图裁剪与图注核验。</p>')
    md.extend(['','## 图表与原版面',''])
    used_crops = set()
    for index,item in enumerate(learning['figures_tables'],1):
        label = item.get('label','')
        kind = 'tab' if re.match(r'(?:Table|Tab\.?|表)',label,re.I) else ('sch' if re.match(r'(?:Scheme|图式)',label,re.I) else 'fig')
        paired = [crop for crop in source.get('figure_crops',[]) if crop.get('include_in_guide',True) and crop.get('document_id','main')==doc_id(item) and normalized_label(crop['label'],crop['kind'])==normalized_label(label,kind) and normalized_label(label,kind)]
        used_crops.update(crop['id'] for crop in paired)
        out.append(f'<div class="card" id="{esc(item.get("target_id",f"figure-reading-{index}"))}" data-ref-label="{esc(label)}" data-ref-kind="{kind}" data-document-id="{esc(doc_id(item))}"><h3>{esc(label)}</h3><p>{esc(item.get("reading"))}</p>'+''.join(crop_html(crop) for crop in paired)+refs(item['source_ids'],blocks)+'</div>')
        md.extend([f'### {item.get("label", "")}',item.get('reading',''),'来源：'+', '.join(item['source_ids'])])
    for crop in source.get('figure_crops',[]):
        if not crop.get('include_in_guide',True):
            continue
        if crop['id'] not in used_crops:
            out.append(f'<div class="card" id="crop-{esc(crop["id"])}" data-ref-label="{esc(crop["label"])}" data-ref-kind="{esc(crop["kind"])}" data-document-id="{esc(crop.get("document_id","main"))}"><h3>{esc(crop["label"])} · 来源裁图</h3>'+crop_html(crop)+'</div>')
        md.extend([f'![{crop["label"]}]({os.path.relpath(crop["image_path"],run_dir)})',f'原图候选边界：p.{crop["page"]}，{crop["rect"]}；{crop["caption"]}',''])
    for figure in source['figures']:
        out.append(f'<details><summary>{esc(figure.get("document", ""))} 第 {figure["page"]} 页 · 原版面（点击查看）</summary><figure id="page-{figure.get("document_id", "main")}-{figure["page"]}"><img src="{image_data(figure)}" width="{figure["width"]}" height="{figure["height"]}" loading="lazy" alt="{esc(figure["caption"])}"><figcaption>{esc(figure["caption"])}</figcaption></figure></details>')
        if not reading_edition:
            md.extend([f'![{figure["caption"]}]({os.path.relpath(figure["path"],run_dir)})',''])
    out.append('</section><section id="fields"><h2>自定义字段与证据</h2><p class="meta">每条记录保留样品/条件区分。未获得的字段值保持为空，需核对是否为提取遗漏；字段引文可定位，但仍须审阅单位与语义。</p>')
    md.extend(['','## 自定义字段与证据',''])
    for record in extraction['records']:
        review_notice = f'<p class="meta">{esc(record["review_notice"])}</p>' if record.get('review_notice') else ''
        out.append(f'<h3>{esc(record.get("label",record["id"]))}</h3>'+review_notice+'<div class="table-wrap"><table><thead><tr><th>字段</th><th>值 / 状态</th><th>原文证据</th></tr></thead><tbody>')
        md.extend(['### '+record.get('label',record['id']),''])
        if record.get('review_notice'):
            md.extend([record['review_notice'],''])
        for name,cell in record['values'].items():
            value = '未获得字段值' if cell['value'] is None else json.dumps(cell['value'],ensure_ascii=False)
            evidence = ''.join(f'<p>{esc(item["quote"])} {refs([item["block_id"]],blocks)}</p>' for item in cell['evidence'])
            out.append(f'<tr><td>{esc(name)}</td><td>{esc(value)} {esc(cell.get("unit",""))}<br><span class="meta">{esc(cell["status"])}</span></td><td>{evidence}<p class="meta">{esc(cell.get("notes",""))}</p></td></tr>')
            md.append(f'- **{name}**：{value} {cell.get("unit", "")}（{cell["status"]}）')
            md.extend(f'  - p.{item["page"]} [{item["block_id"]}]：{item["quote"]}' for item in cell['evidence'])
        out.append('</tbody></table></div>')
    out.append('</section><section id="quiz"><h2>自测与答辩</h2>')
    md.extend(['','## 自测与答辩',''])
    for index,item in enumerate(learning['quiz'],1):
        out.append(f'<div class="card question"><h3>{index}. {esc(item["question"])}</h3><details><summary>显示答案与证据</summary><p>{esc(item["answer"])}</p>{refs(item["source_ids"],blocks)}</details></div>')
        md.extend([f'### {index}. {item["question"]}',item['answer'],'来源：'+', '.join(item['source_ids']),''])
    out.append('</section><section id="glossary"><h2>术语表</h2><dl>')
    md.extend(['','## 术语表',''])
    for item in learning['glossary']:
        out.append(f'<dt><b>{esc(item.get("term"))}</b> <span class="meta">{esc(item.get("english"))}</span></dt><dd><p>{esc(item.get("definition"))}</p>{refs(item["source_ids"],blocks)}</dd>')
        md.append(f'- **{item.get("term", "")} / {item.get("english", "")}**：{item.get("definition", "")} [{", ".join(item["source_ids"])}]')
    out.append('</dl></section><section id="notes"><h2>学习笔记</h2><p class="meta">笔记与划线保存在当前浏览器。支持跨元素选择，并跳过公式内部；导出 JSON 可迁移和备份。</p><textarea data-note="general" aria-label="学习笔记" placeholder="记录理解、疑问、下一步验证……"></textarea><div class="controls"><button id="highlight">标记选中文字</button><button id="export-notes">导出笔记</button><label>导入笔记 <input id="import-notes" type="file" accept="application/json"></label></div><p id="notes-status" class="notes-status" aria-live="polite"></p></section>')
    out.append('<section id="gaps"><h2>不足与缺口</h2><ul>')
    md.extend(['','## 不足与缺口',''])
    for gap in dict.fromkeys(learning['gaps'] + ([] if reading_edition else warnings)):
        out.append(f'<li>{esc(gap)}</li>')
        md.append('- '+gap)
    out.append('</ul></section>')
    if reading_edition and (warnings or learning.get('process_notes')):
        out.append('<details class="processing-notes"><summary>生成记录与提取提示</summary><ul>' + ''.join(f'<li>{esc(note)}</li>' for note in dict.fromkeys(warnings + learning.get('process_notes', []))) + '</ul></details>')
    out.append('<section id="sources"><h2>完整来源索引</h2><p class="meta">保留全部提取文本。PDF 文本块顺序来自版面解析，双栏、公式与表格仍可能需要对照页图。</p><button id="expand-sources">展开全部原文</button>')
    md.extend(['','## 来源与对照','', '[原语言全文](fulltext.md) · [逐段对照](paragraphs.md) · [完整原始来源索引](source-index.md)'] if reading_edition else ['','## 完整来源索引',''])
    for block in source['blocks']:
        out.append(f'<div class="source" id="src-{block["id"]}" data-highlight><details class="source-detail"><summary>p.{block["page"]} · {block["id"]}</summary><pre>{esc(block["text"])}</pre></details></div>')
        if not reading_edition:
            md.extend([f'<a id="src-{block["id"]}"></a>',f'### p.{block["page"]} · {block["id"]}','',block['text'],''])
    out.append(f'</section><footer>PaperShelf · 源文件 SHA256 {esc(source["sha256"])}<br>离线单文件，无远程脚本、字体或跟踪请求。</footer></article></main><dialog id="image-dialog"><button id="close-image">关闭大图</button><img alt="原版面预览"></dialog><script data-papershelf-calculator>{CALCULATOR_JS}</script></body></html>')
    html_path = run_dir / 'learning.html'
    markdown_path = run_dir / 'learning.md'
    formats = {'html', 'markdown'} if formats is None else set(formats)
    artifacts = {}
    if 'html' in formats:
        from .guide_interactions import enrich_html
        content,interaction_warnings = enrich_html(''.join(out),source,learning)
        warnings.extend(item for item in interaction_warnings if item not in warnings)
        if interaction_warnings:
            extra = '<aside class="callout warning"><h3>引用核验缺口</h3><ul>'+''.join(f'<li>{esc(item)}</li>' for item in interaction_warnings)+'</ul></aside>'
            content = content.replace('<section id="sources">',extra+'<section id="sources">',1)
        html_path.write_text(content,encoding='utf-8')
        artifacts['html'] = str(html_path)
    if 'markdown' in formats:
        markdown_path.write_text('\n'.join(md),encoding='utf-8')
        artifacts['markdown'] = str(markdown_path)
    return artifacts

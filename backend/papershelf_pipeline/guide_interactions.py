"""Fixed offline interactions and source-aware figure/equation cross references.

No model-provided script is evaluated.  The annotation approach is adapted from
the user's local HTML/lit-html-guide (text offsets plus quote/context fallback),
with strict import validation, math exclusion and document identity checks.
"""
from __future__ import annotations

import html
import json
import re
from html.parser import HTMLParser
from urllib.parse import urlsplit


LABEL = re.compile(r"(?<![0-9A-Za-z])(?P<s>S)?(?P<n>\d+(?:\.\d+)*)(?P<part>[a-z])?(?![0-9A-Za-z])", re.I)
MENTION = re.compile(
    r"(?<![A-Za-z])(?P<kw>Supplementary\s+(?:Figures?|Figs?\.?|Tables?|Schemes?)|"
    r"Figures?|Figs?\.?|Tables?|Schemes?|Equations?|Eqns?\.?|Eqs?\.?|公式|图式|图|表|式|方案)"
    r"\s*[（(]?(?P<s>S)?(?P<n>\d+(?:\.\d+)*)(?P<part>[a-z])?[）)]?(?![A-Za-z0-9])"
    r"(?P<more>(?:\s*(?:[,，、/–—-]|和|与|及|至|and|to)\s*[（(]?S?\d+(?:\.\d+)*[a-z]?[）)]?)*)",
    re.I,
)
MORE = re.compile(r"(?P<join>\s*(?:[,，、/–—-]|和|与|及|至|and|to)\s*)(?P<label>[（(]?S?\d+(?:\.\d+)*[a-z]?[）)]?)", re.I)


def normalized_label(label: str, kind: str) -> str:
    """Return fig-2/tab-S1/eq-3-1; ids may additionally be document-prefixed."""
    if kind not in {"fig", "tab", "sch", "eq"}:
        return ""
    match = LABEL.search(str(label))
    if not match:
        return ""
    supplement = bool(match.group("s")) or "supplement" in str(label).lower()
    return f"{kind}-{'S' if supplement else ''}{match.group('n').replace('.', '-')}{(match.group('part') or '').lower()}"


def _kind(keyword: str) -> str:
    keyword = keyword.lower()
    if "table" in keyword or keyword == "表":
        return "tab"
    if "eq" in keyword or keyword in {"式", "公式"}:
        return "eq"
    if "scheme" in keyword or keyword in {"方案", "图式"}:
        return "sch"
    return "fig"


class _TargetReader(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.targets = {}
        self.ids = set()
        self.duplicates = set()

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        identifier = attributes.get("id")
        if identifier:
            if identifier in self.ids:
                self.duplicates.add(identifier)
            self.ids.add(identifier)
        if identifier and attributes.get("data-ref-label") and attributes.get("data-ref-kind"):
            key = normalized_label(attributes["data-ref-label"], attributes["data-ref-kind"])
            document = attributes.get("data-document-id", "main")
            # A duplicated label is ambiguous; do not quietly link to an arbitrary figure.
            if key:
                target_key = (document, key)
                href = "#" + identifier
                self.targets[target_key] = href if target_key not in self.targets else None


class _Linker(HTMLParser):
    VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
    SKIP = {"script", "style", "a", "button", "textarea", "nav", "pre", "code", "math", "svg", "h1", "h2", "h3", "h4", "summary", "title"}

    def __init__(self, targets):
        super().__init__(convert_charrefs=False)
        self.targets = targets
        self.stack = []
        self.output = []
        self.unresolved = set()
        self.links = 0

    def handle_starttag(self, tag, attrs):
        attributes = dict(attrs)
        if tag not in self.VOID:
            prior = self.stack[-1] if self.stack else ("", "main", False)
            self.stack.append((tag, attributes.get("data-document-id", prior[1]), prior[2] or tag in self.SKIP or "data-nolink" in attributes))
        self.output.append(self.get_starttag_text())

    def handle_startendtag(self, tag, attrs):
        self.output.append(self.get_starttag_text())

    def handle_endtag(self, tag):
        for index in range(len(self.stack) - 1, -1, -1):
            if self.stack[index][0] == tag:
                del self.stack[index:]
                break
        self.output.append(f"</{tag}>")

    def handle_data(self, data):
        if not self.stack or self.stack[-1][2]:
            self.output.append(data)
            return
        document = self.stack[-1][1]
        def replacement(match):
            kind = _kind(match.group("kw"))
            supplement = bool(match.group("s")) or "supplement" in match.group("kw").lower()
            end = match.start("more") if match.group("more") else match.end()
            first = data[match.start():end]
            key = normalized_label(("S" if supplement else "") + match.group("n") + (match.group("part") or ""), kind)
            result = self._link(first, document, key)
            for extra in MORE.finditer(match.group("more") or ""):
                label = extra.group("label")
                if supplement and "s" not in label.lower():
                    label = "S" + label.lstrip("(（")
                result += extra.group("join") + self._link(extra.group("label"), document, normalized_label(label, kind))
            return result
        self.output.append(MENTION.sub(replacement, data))

    def _link(self, text, document, key):
        href = self.targets.get((document, key))
        if not href and key and key[-1].isalpha() and not key.endswith("S"):
            href = self.targets.get((document, key[:-1]))
        # S-numbered figures normally belong to supplemental documents. Only a
        # unique target across the set may resolve an otherwise unspecified SI.
        if not href and re.match(r"(?:fig|tab|sch|eq)-S", key):
            alternatives = {value for (doc, target), value in self.targets.items() if target == key and value}
            if len(alternatives) == 1:
                href = alternatives.pop()
        if not href:
            self.unresolved.add(f"{document}:{key}")
            return f'<span class="ref-unavailable" title="未找到唯一的图表或公式目标，需对照原版面">{text}</span>'
        self.links += 1
        return f'<a class="figref" id="guide-ref-{self.links}" href="{html.escape(href, quote=True)}">{text}</a>'

    def handle_entityref(self, name): self.output.append(f"&{name};")
    def handle_charref(self, name): self.output.append(f"&#{name};")
    def handle_comment(self, data): self.output.append(f"<!--{data}-->")
    def handle_decl(self, data): self.output.append(f"<!{data}>")
    def handle_pi(self, data): self.output.append(f"<?{data}>")


CSS = r"""
.ref-unavailable{border-bottom:1px dotted #976c2d;color:#806b4d}.figref{cursor:pointer;text-decoration:underline;text-underline-offset:3px}
.guide-target-flash{outline:3px solid #6eaa94;outline-offset:5px;transition:outline-color .2s}
#guide-back{position:fixed;right:16px;bottom:18px;z-index:70;box-shadow:0 3px 15px #0002}
#guide-preview{position:fixed;display:none;z-index:80;max-width:min(420px,calc(100vw - 20px));max-height:55vh;overflow:auto;padding:12px;background:#fff;border:1px solid #b1c4ba;border-radius:10px;box-shadow:0 6px 24px #0003;font:14px/1.6 system-ui;color:#243131}#guide-preview img{max-width:100%;max-height:32vh;object-fit:contain}#guide-preview p{white-space:normal;margin:4px}
mark.guide-highlight{color:inherit;background:#ffe99d;cursor:pointer}mark.guide-highlight[data-color="1"]{background:#bbebcc}mark.guide-highlight[data-color="2"]{background:#badafb}mark.guide-highlight[data-color="3"]{background:#f6c9e0}
#guide-selection{display:none;position:fixed;z-index:95;padding:6px;background:#fff;border:1px solid #b1c4ba;border-radius:8px;box-shadow:0 4px 18px #0002;max-width:calc(100vw - 12px)}#guide-selection button{margin:2px;padding:4px 7px}#guide-selection [data-color]{min-width:26px}
#guide-annotations{margin-top:18px}#guide-annotations-list{max-height:380px;overflow:auto}.guide-annotation-row{border-bottom:1px solid #d8dfd9;padding:10px 0}.guide-annotation-row p{margin:4px 0}.guide-annotation-actions{display:flex;gap:6px;flex-wrap:wrap}.guide-annotation-lost{color:#986021}.guide-math-scroll{overflow:auto;max-width:100%}
@media print{#guide-back,#guide-preview,#guide-selection,#guide-annotations{display:none!important}}
"""


JS = r"""
(()=>{'use strict';
const root=document.querySelector('article')||document.querySelector('main');if(!root)return;
if(!root.id)root.id='guide-content';
const documentID=document.querySelector('meta[name="doc-id"]').content,key='papershelf:'+documentID;
const status=document.getElementById('notes-status'),backStack=[];let currentRange=null,previewLink=null,pointer='mouse';
const say=message=>{if(status)status.textContent=message};
const isObject=value=>value!==null&&typeof value==='object'&&!Array.isArray(value);
function validate(data,importing=false){
 if(!isObject(data)||(importing&&data.document!==key)||!isObject(data.notes)||!Array.isArray(data.highlights))throw Error('文献或数据格式不匹配');
 if(Object.entries(data.notes).some(([name,value])=>typeof value!=='string'||['__proto__','prototype','constructor'].includes(name)))throw Error('笔记格式错误');
 const ids=new Set();for(const item of data.highlights){
  if(!isObject(item)||typeof item.uid!=='string'||!/^h[a-z0-9-]+$/i.test(item.uid)||ids.has(item.uid)||typeof item.root!=='string'||typeof item.quote!=='string'||!item.quote.trim()||typeof item.prefix!=='string'||typeof item.suffix!=='string'||typeof item.note!=='string'||!Number.isInteger(item.start)||!Number.isInteger(item.end)||item.start<0||item.end<=item.start||!Number.isInteger(item.color)||item.color<0||item.color>3)throw Error('划线格式错误');
  ids.add(item.uid);
 }
 return {version:2,notes:{...data.notes},highlights:data.highlights.map(item=>({...item}))};
}
let saved={version:2,notes:{},highlights:[]},storageCorrupt=false;
try{const raw=localStorage.getItem(key);if(raw)saved=validate(JSON.parse(raw))}catch(error){storageCorrupt=true;say('已有笔记格式无法读取，原数据保留；请先导出备份或导入有效文件。')}
function persist(){if(storageCorrupt){say('原始存储异常，未覆盖；请导出备份后导入有效笔记。');return false}try{localStorage.setItem(key,JSON.stringify(saved));say('笔记与划线已保存；可导出 JSON 备份。');return true}catch(error){say('浏览器不允许保存，请导出笔记备份。');return false}}
function eligible(node){return node.parentElement&&!node.parentElement.closest('math,.katex,script,style,button,textarea,input,select,nav,summary,#guide-annotations,#guide-preview,#guide-selection')}
function textNodes(container){const walker=document.createTreeWalker(container,NodeFilter.SHOW_TEXT),result=[];let node,offset=0;while(node=walker.nextNode()){if(!eligible(node))continue;result.push({node,offset});offset+=node.data.length}return result}
const plain=container=>textNodes(container).map(item=>item.node.data).join('');
function offsets(range,container){let start=-1,end=-1;for(const item of textNodes(container)){if(!range.intersectsNode(item.node))continue;const a=item.node===range.startContainer?range.startOffset:0,b=item.node===range.endContainer?range.endOffset:item.node.length;if(b<=a)continue;if(start<0)start=item.offset+a;end=item.offset+b}return start<0?null:[start,end]}
function wrap(container,start,end,item){for(const entry of textNodes(container)){const length=entry.node.length,a=Math.max(start,entry.offset),b=Math.min(end,entry.offset+length);if(b<=a||!entry.node.data.slice(a-entry.offset,b-entry.offset).trim())continue;let text=entry.node;if(a>entry.offset)text=text.splitText(a-entry.offset);if(b<entry.offset+length)text.splitText(b-a);const mark=document.createElement('mark');mark.className='guide-highlight';mark.dataset.uid=item.uid;mark.dataset.color=item.color;if(item.note)mark.title=item.note;text.parentNode.insertBefore(mark,text);mark.appendChild(text)}}
function apply(item){let container=document.getElementById(item.root);if(!container||!root.contains(container))container=root;let text=plain(container),start=item.start;if(text.slice(start,item.end)!==item.quote){container=root;text=plain(root);const candidates=[];let position=0;while((position=text.indexOf(item.quote,position))>=0){const prefix=text.slice(Math.max(0,position-item.prefix.length),position),suffix=text.slice(position+item.quote.length,position+item.quote.length+item.suffix.length);const score=(item.prefix&&prefix===item.prefix?2:0)+(item.suffix&&suffix===item.suffix?2:0);candidates.push({position,score});position++}if(!candidates.length)return false;candidates.sort((a,b)=>b.score-a.score);if(candidates.length>1&&candidates[0].score===candidates[1].score)return false;start=candidates[0].position}wrap(container,start,start+item.quote.length,item);return true}
function unwrap(uid){root.querySelectorAll('mark.guide-highlight').forEach(mark=>{if(mark.dataset.uid!==uid)return;const parent=mark.parentNode;while(mark.firstChild)parent.insertBefore(mark.firstChild,mark);mark.remove();parent.normalize()})}
function openDetails(element){for(let parent=element;parent;parent=parent.parentElement){if(parent.tagName==='DETAILS')parent.open=true;parent.classList?.remove('hidden')}}
function flash(element){if(!element)return;element.classList.remove('guide-target-flash');void element.offsetWidth;element.classList.add('guide-target-flash');setTimeout(()=>element.classList.remove('guide-target-flash'),1800)}
function capture(range,color=0,note=''){if(!range||range.collapsed||!root.contains(range.commonAncestorContainer))return null;let ancestor=range.commonAncestorContainer.nodeType===1?range.commonAncestorContainer:range.commonAncestorContainer.parentElement;let container=ancestor.closest('[data-highlight][id]');if(!container||!container.contains(range.endContainer))container=root;const positions=offsets(range,container),global=offsets(range,root);if(!positions||!global)return null;const text=plain(container),full=plain(root),quote=text.slice(...positions);if(!quote.trim())return null;const item={uid:'h'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2),root:container.id,start:positions[0],end:positions[1],quote,prefix:full.slice(Math.max(0,global[0]-40),global[0]),suffix:full.slice(global[1],global[1]+40),color,note};saved.highlights.push(item);wrap(container,item.start,item.end,item);persist();refreshAnnotations();return item}
const annotations=document.createElement('details');annotations.id='guide-annotations';const annotationTitle=document.createElement('summary');annotations.appendChild(annotationTitle);const annotationList=document.createElement('div');annotationList.id='guide-annotations-list';annotations.appendChild(annotationList);(document.getElementById('notes')||root).appendChild(annotations);
function refreshAnnotations(){annotationTitle.textContent='我的划线与批注（'+saved.highlights.length+'）';annotationList.replaceChildren();for(const item of saved.highlights){const row=document.createElement('div');row.className='guide-annotation-row';const quote=document.createElement('p');quote.textContent=item.quote;row.appendChild(quote);if(item.note){const note=document.createElement('p');note.textContent=item.note;row.appendChild(note)}const marks=[...root.querySelectorAll('mark.guide-highlight')].filter(mark=>mark.dataset.uid===item.uid);if(!marks.length){const missing=document.createElement('p');missing.className='guide-annotation-lost';missing.textContent='此划线未能唯一定位，原批注保留。';row.appendChild(missing)}const buttons=document.createElement('div');buttons.className='guide-annotation-actions';for(const [label,handler] of [['定位',()=>{if(marks[0]){openDetails(marks[0]);marks[0].scrollIntoView({block:'center'});flash(marks[0])}}],['编辑笔记',()=>{const note=prompt('划线笔记',item.note);if(note!==null){item.note=note;marks.forEach(mark=>mark.title=note);persist();refreshAnnotations()}}],['擦除',()=>{unwrap(item.uid);saved.highlights=saved.highlights.filter(entry=>entry.uid!==item.uid);persist();refreshAnnotations()}]]){const button=document.createElement('button');button.type='button';button.textContent=label;button.onclick=handler;buttons.appendChild(button)}row.appendChild(buttons);annotationList.appendChild(row)}}
let lost=0;for(const item of saved.highlights)if(!apply(item))lost++;refreshAnnotations();if(lost)say(lost+' 条划线无法唯一定位，已保留在批注列表中。');
root.querySelectorAll('textarea[data-note]').forEach(element=>{element.value=saved.notes[element.dataset.note]||'';element.addEventListener('input',()=>{saved.notes[element.dataset.note]=element.value;persist()})});
const selectionBar=document.createElement('div');selectionBar.id='guide-selection';selectionBar.setAttribute('role','toolbar');selectionBar.setAttribute('aria-label','选中文字批注');const colors=['#ffe99d','#bbebcc','#badafb','#f6c9e0'];colors.forEach((color,index)=>{const button=document.createElement('button');button.type='button';button.dataset.color=index;button.style.background=color;button.textContent='●';button.title=['黄色划线','绿色划线','蓝色划线','粉色划线'][index];selectionBar.appendChild(button)});const noteButton=document.createElement('button');noteButton.type='button';noteButton.dataset.note='true';noteButton.textContent='批注';selectionBar.appendChild(noteButton);document.body.appendChild(selectionBar);
selectionBar.onmousedown=event=>event.preventDefault();selectionBar.onclick=event=>{const button=event.target.closest('button');if(!button||!currentRange)return;const note=button.dataset.note?prompt('划线笔记',''):'';if(note===null)return;capture(currentRange,Number(button.dataset.color||0),note);getSelection().removeAllRanges();currentRange=null;selectionBar.style.display='none'};
function selectionChanged(){const selection=getSelection();if(!selection||!selection.rangeCount||selection.isCollapsed){selectionBar.style.display='none';return}const range=selection.getRangeAt(0),element=range.startContainer.parentElement;if(!root.contains(range.commonAncestorContainer)||element?.closest('textarea,input,math,.katex,#guide-annotations'))return;currentRange=range.cloneRange();const rect=range.getBoundingClientRect();selectionBar.style.display='block';selectionBar.style.left=Math.max(6,Math.min(rect.left,innerWidth-selectionBar.offsetWidth-6))+'px';selectionBar.style.top=Math.max(6,Math.min(rect.bottom+6,innerHeight-selectionBar.offsetHeight-6))+'px'}
let selectionTimer;document.addEventListener('selectionchange',()=>{clearTimeout(selectionTimer);selectionTimer=setTimeout(selectionChanged,160)});
const highlightButton=document.getElementById('highlight');if(highlightButton){highlightButton.onmousedown=event=>event.preventDefault();highlightButton.onclick=()=>{const selection=getSelection();const range=selection?.rangeCount&&!selection.isCollapsed?selection.getRangeAt(0):currentRange;if(capture(range)){selection?.removeAllRanges();selectionBar.style.display='none'}}}
root.addEventListener('click',event=>{const mark=event.target.closest('mark.guide-highlight');if(mark&&!event.target.closest('a,button')&&getSelection().isCollapsed){annotations.open=true;annotations.scrollIntoView({block:'center'});refreshAnnotations()}});
const exportButton=document.getElementById('export-notes');if(exportButton)exportButton.onclick=()=>{let content=JSON.stringify({document:key,...saved},null,2);if(storageCorrupt){try{content=localStorage.getItem(key)||content}catch(error){}}const blob=new Blob([content],{type:'application/json'}),link=document.createElement('a');link.href=URL.createObjectURL(blob);link.download=storageCorrupt?'papershelf-notes-recovery.json':'papershelf-notes.json';link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000)};
const importInput=document.getElementById('import-notes');if(importInput)importInput.onchange=async event=>{try{const file=event.target.files[0];if(!file)return;const imported=validate(JSON.parse(await file.text()),true);const ids=new Set(saved.highlights.map(item=>item.uid));for(const item of imported.highlights)if(!ids.has(item.uid)){saved.highlights.push(item);ids.add(item.uid);apply(item)}for(const [name,value] of Object.entries(imported.notes)){if(!saved.notes[name])saved.notes[name]=value;else if(value&&saved.notes[name]!==value)saved.notes[name]+='\n\n【导入笔记】\n'+value}storageCorrupt=false;persist();refreshAnnotations();root.querySelectorAll('textarea[data-note]').forEach(element=>element.value=saved.notes[element.dataset.note]||'');say('已合并导入，现有笔记与划线保留。')}catch(error){say('导入失败：格式无效或文献身份不匹配，原笔记未改变。')}finally{event.target.value=''}};
const backButton=document.createElement('button');backButton.id='guide-back';backButton.type='button';backButton.hidden=true;document.body.appendChild(backButton);const preview=document.createElement('div');preview.id='guide-preview';preview.setAttribute('role','dialog');preview.setAttribute('aria-label','引用预览');document.body.appendChild(preview);
function updateBack(){backButton.hidden=!backStack.length;backButton.textContent='↩ 返回原文'+(backStack.length>1?'（'+backStack.length+'）':'')}
function hidePreview(){preview.style.display='none';previewLink=null}
function destination(link){const href=link.getAttribute('href')||'';if(!href.startsWith('#'))return null;try{return document.getElementById(decodeURIComponent(href.slice(1)))}catch(error){return null}}
function go(link){const target=destination(link);if(!target)return false;backStack.push({link,y:scrollY});openDetails(target);target.scrollIntoView({block:'start'});flash(target);hidePreview();updateBack();return true}
function goBack(){const point=backStack.pop();if(point){if(point.link.isConnected){openDetails(point.link);point.link.scrollIntoView({block:'center'});flash(point.link)}else scrollTo(0,point.y)}hidePreview();updateBack()}
backButton.onclick=goBack;
function showPreview(link,x,y,touch=false){const target=destination(link);if(!target)return;preview.replaceChildren();const image=target.querySelector('img');if(image?.getAttribute('src')?.startsWith('data:')){const copy=document.createElement('img');copy.src=image.src;copy.alt=image.alt;preview.appendChild(copy)}const formula=target.querySelector('math,.katex');if(formula){const copy=formula.cloneNode(true);copy.querySelectorAll('[id]').forEach(element=>element.removeAttribute('id'));copy.removeAttribute('id');preview.appendChild(copy)}const text=document.createElement('p');text.textContent=target.querySelector('figcaption,.eqcap')?.textContent||target.textContent;preview.appendChild(text);if(touch){for(const [label,handler] of [['跳到此处',()=>go(link)],['关闭',hidePreview]]){const button=document.createElement('button');button.textContent=label;button.onclick=handler;preview.appendChild(button)}}previewLink=link;preview.style.display='block';preview.style.left=Math.max(8,Math.min(x+12,innerWidth-preview.offsetWidth-8))+'px';preview.style.top=Math.max(8,Math.min(y+12,innerHeight-preview.offsetHeight-8))+'px'}
document.addEventListener('pointerdown',event=>{pointer=event.pointerType||'mouse'},true);
root.addEventListener('click',event=>{const link=event.target.closest('a.figref,a.cite');if(!link||!destination(link))return;event.preventDefault();if(pointer==='touch'&&previewLink!==link){const rect=link.getBoundingClientRect();showPreview(link,rect.left,rect.bottom,true)}else go(link)});
root.addEventListener('mouseover',event=>{const link=event.target.closest('a.figref,a.cite');if(link&&pointer!=='touch')showPreview(link,event.clientX,event.clientY)});root.addEventListener('mouseout',event=>{if(event.target.closest('a.figref,a.cite')&&pointer!=='touch')hidePreview()});document.addEventListener('keydown',event=>{if(event.key==='Escape'){hidePreview();selectionBar.style.display='none'}});
const search=document.getElementById('search');if(search)search.oninput=event=>{const query=event.target.value.trim().toLowerCase();let count=0;root.querySelectorAll('.reading-prose,.paragraph,.source').forEach(element=>{const found=!query||element.textContent.toLowerCase().includes(query);element.classList.toggle('hidden',!found);if(found){count++;if(query){let parent=element.parentElement;while(parent&&parent!==root){if(parent.tagName==='DETAILS')parent.open=true;parent=parent.parentElement}}}});const label=document.getElementById('search-status');if(label)label.textContent=query?count+' 个段落匹配':''};
const expand=document.getElementById('expand-sources');if(expand)expand.onclick=()=>root.querySelectorAll('details.source-detail').forEach(element=>element.open=true);
const dialog=document.getElementById('image-dialog');if(dialog){root.querySelectorAll('figure img').forEach(image=>image.onclick=()=>{dialog.querySelector('img').src=image.src;dialog.querySelector('img').alt=image.alt;dialog.showModal()});const close=document.getElementById('close-image');if(close)close.onclick=()=>dialog.close();dialog.onclick=event=>{if(event.target===dialog)dialog.close()}}
window.PaperShelfGuide={validateNotes:validate,capture,restore:apply,text:plain,list:()=>structuredClone(saved),back:goBack,stack:backStack,lost};
})();
"""


def enrich_html(html_text: str, source: dict, learning: dict) -> tuple[str, list[str]]:
    """Link existing unique targets and add trusted, self-contained interactions."""
    reader = _TargetReader()
    reader.feed(html_text)
    external_targets = {}
    for target in source.get("reference_targets", []):
        key = normalized_label(target.get("label", ""), target.get("kind", ""))
        href = target.get("href")
        local_href = False
        if isinstance(href, str) and href and href == href.strip() and not re.search(r"[\x00-\x20\\]", href):
            parsed = urlsplit(href)
            local_href = not parsed.scheme and not parsed.netloc and not href.startswith("/")
        if key and (href is None or local_href):
            target_key = (target.get("document_id", "main"), key)
            external_targets.setdefault(target_key, set()).add(href)
    for target_key, hrefs in external_targets.items():
        # An in-chapter target supplies useful local context. Without one, a
        # repeated label in several chapters must remain explicitly ambiguous.
        if target_key not in reader.targets:
            reader.targets[target_key] = next(iter(hrefs)) if len(hrefs) == 1 else None
    linker = _Linker(reader.targets)
    linker.feed(html_text)
    result = ''.join(linker.output)
    result = result.replace('</head>', f'<style data-papershelf-interactions>{CSS}</style></head>', 1)
    result = result.replace('</body>', f'<script data-papershelf-interactions>{JS}</script></body>', 1)
    warnings = []
    if linker.unresolved:
        warnings.append('未解析的图表/公式引用（未伪造链接）：' + ', '.join(sorted(linker.unresolved)))
    if reader.duplicates:
        warnings.append('HTML 存在重复锚点，需要核验：' + ', '.join(sorted(reader.duplicates)))
    return result, warnings

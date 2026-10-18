import { SETTINGS_KEY, CITATION_PREFIX, BIBLIOGRAPHY_TAG, parseState, reconcileState } from './state.mjs';
const el = id => document.getElementById(id);
let customStyleXML;
let session, currentPage = 0, searchGeneration = 0, busy = false, ready = false;
const selected = new Map();
function status(message, failed = false) { el('status').textContent = message; el('status').classList.toggle('error', failed); }
async function request(route, body) {
  const response = await fetch(route, { method: body ? 'POST' : 'GET', headers: { 'X-PaperShelf-Session': session.nonce, ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
  return result;
}
function saveState(state) {
  Office.context.document.settings.set(SETTINGS_KEY, JSON.stringify(state));
  return new Promise((resolve, reject) => Office.context.document.settings.saveAsync(result => result.status === Office.AsyncResultStatus.Succeeded ? resolve() : reject(new Error(result.error?.message || 'Word could not save citation metadata. Save the document and retry.'))));
}
function selectionCount() { el('selection-count').textContent = `${selected.size} 篇已选`; }
async function search(offset = 0) {
  const generation = ++searchGeneration;
  try {
    const result = await request('/api/search?' + new URLSearchParams({ q: el('query').value, offset: String(offset) }));
    if (generation !== searchGeneration) return;
    currentPage = result.offset; el('results').replaceChildren();
    for (const paper of result.items) {
      const label = document.createElement('label'); label.className = 'paper';
      const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.checked = selected.has(paper.id);
      checkbox.addEventListener('change', () => { checkbox.checked ? selected.set(paper.id, paper) : selected.delete(paper.id); selectionCount(); });
      const detail = document.createElement('span');
      const title = document.createElement('strong'); title.textContent = paper.title || '(untitled)';
      const metadata = document.createElement('small'); metadata.textContent = [paper.authors.join('; '), paper.year, paper.journal].filter(Boolean).join(' · ');
      detail.append(title, metadata); label.append(checkbox, detail); el('results').append(label);
    }
    el('page').textContent = result.total ? `${result.offset + 1}–${result.offset + result.items.length} / ${result.total}` : '没有匹配文献';
    el('previous').disabled = result.offset === 0; el('next').disabled = !result.hasMore;
  } catch (error) { if (generation === searchGeneration) status(error.message, true); }
}
async function updateDocument({ insert = false, bibliography = false } = {}) {
  if (!ready || busy) return;
  busy = true;
  for (const button of document.querySelectorAll('[data-document-action]')) button.disabled = true;
  try {
    let state = parseState(Office.context.document.settings.get(SETTINGS_KEY));
    state.style = el('style').value;
    if (customStyleXML) state.customStyleXML = customStyleXML;
    let newCitation;
    if (insert) {
      if (!selected.size) throw new Error('先选择至少一篇文献。');
      const items = [];
      for (const id of selected.keys()) {
        const csl = await request(`/api/papers/${encodeURIComponent(id)}/csl`);
        state.items[id] = csl;
        items.push({ id, ...(el('locator').value.trim() ? { locator: el('locator').value.trim(), label: 'page' } : {}) });
      }
      newCitation = { id: crypto.randomUUID(), items };
      state.citations.push(newCitation);
      // Save the metadata before inserting a control. A failed insertion leaves
      // an unused entry that reconciliation can remove, rather than an orphan field.
      await saveState(state);
    }
    await Word.run(async context => {
      if (newCitation) {
        const range = context.document.getSelection().insertText('[PaperShelf]', Word.InsertLocation.end);
        const control = range.insertContentControl();
        control.tag = CITATION_PREFIX + newCitation.id; control.title = 'PaperShelf citation';
        await context.sync();
      }
      const controls = context.document.contentControls;
      controls.load('items/tag,items/id'); await context.sync();
      state = reconcileState(state, controls.items.map(control => control.tag));
      const formatted = await request('/format', state);
      // Persist the complete CSL snapshots, not local file paths or API tokens.
      await saveState(state);
      for (const control of controls.items) {
        if (control.tag.startsWith(CITATION_PREFIX)) {
          const text = formatted.citations[control.tag.slice(CITATION_PREFIX.length)];
          if (typeof text !== 'string') throw new Error('The citation processor did not return a formatted citation.');
          control.cannotEdit = false; control.insertHtml(formatted.citationHTML[control.tag.slice(CITATION_PREFIX.length)], Word.InsertLocation.replace); control.cannotEdit = true;
        }
      }
      let bibliographies = controls.items.filter(control => control.tag === BIBLIOGRAPHY_TAG);
      if (bibliography && !bibliographies.length) {
        const control = context.document.getSelection().insertText('\n[PaperShelf bibliography]\n', Word.InsertLocation.end).insertContentControl();
        control.tag = BIBLIOGRAPHY_TAG; control.title = 'PaperShelf bibliography'; bibliographies = [control];
      }
      for (const control of bibliographies) {
        control.cannotEdit = false;
        control.insertHtml(formatted.bibliographyHTML.join(''), Word.InsertLocation.replace);
      }
      await context.sync();
      for (const control of bibliographies) {
        control.paragraphs.load('items');
      }
      await context.sync();
      for (const control of bibliographies) {
        for (const paragraph of control.paragraphs.items) {
          paragraph.leftIndent = formatted.bibliographyHangingIndent ? 36 : 0;
          paragraph.firstLineIndent = formatted.bibliographyHangingIndent ? -36 : 0;
        }
        control.cannotEdit = true;
      }
      await context.sync();
      status(`已刷新 ${state.citations.length} 处引文、${formatted.bibliography.length} 篇参考文献。请保存 Word 文档。`);
    });
    if (insert) { selected.clear(); selectionCount(); await search(currentPage); }
  } catch (error) { status(error.message, true); }
  finally { busy = false; for (const button of document.querySelectorAll('[data-document-action]')) button.disabled = !ready; }
}
async function initialize() {
  try {
    session = await (await fetch('/session')).json();
    for (const style of session.styles) { const option = document.createElement('option'); option.value = style; option.textContent = ({ numeric: '顺序编码', 'author-year': '作者–年份', apa: 'APA 第 7 版', ieee: 'IEEE' })[style] || style; el('style').append(option); }
    if (typeof Office === 'undefined') throw new Error('请通过 Microsoft Word 中的 PaperShelf 加载项打开此面板。');
    const info = await Office.onReady();
    if (info.host !== Office.HostType.Word || !Office.context.requirements.isSetSupported('WordApi', '1.3')) throw new Error('此面板需要支持 WordApi 1.3 的 Microsoft Word。');
    const state = parseState(Office.context.document.settings.get(SETTINGS_KEY));
    if (state.customStyleXML) { customStyleXML = state.customStyleXML; addCustomStyle(); }
    if (session.styles.includes(state.style) || (state.style === 'custom' && customStyleXML)) el('style').value = state.style;
    ready = true;
    for (const button of document.querySelectorAll('[data-document-action]')) button.disabled = false;
    await request('/api/status'); status('PaperShelf 已连接。引文状态随 Word 文档保存。'); await search();
  } catch (error) { status(error.message, true); }
}
function addCustomStyle() {
  if (!el('style').querySelector('option[value="custom"]')) { const option = document.createElement('option'); option.value = 'custom'; option.textContent = '文档自定义 CSL'; el('style').append(option); }
}
el('custom-style').addEventListener('change', async () => {
  const file = el('custom-style').files[0]; if (!file) return;
  try {
    if (file.size > 1024 * 1024) throw new Error('CSL 文件超过 1 MiB；未读取或截断。');
    const xml = await file.text(); await request('/validate-style', { xml });
    customStyleXML = xml; addCustomStyle(); el('style').value = 'custom';
    const state = parseState(Office.context.document.settings.get(SETTINGS_KEY));
    state.customStyleXML = xml; state.style = 'custom'; await saveState(state);
    status('自定义 CSL 已保存在文档中。点击刷新文档应用格式。');
  } catch (error) { status(error.message, true); }
  finally { el('custom-style').value = ''; }
});
let timer;
el('query').addEventListener('input', () => { clearTimeout(timer); timer = setTimeout(() => search(), 250); });
el('previous').addEventListener('click', () => search(Math.max(0, currentPage - 20)));
el('next').addEventListener('click', () => search(currentPage + 20));
el('insert').addEventListener('click', () => updateDocument({ insert: true }));
el('bibliography').addEventListener('click', () => updateDocument({ bibliography: true }));
el('refresh').addEventListener('click', () => updateDocument());
el('reconnect').addEventListener('click', () => location.reload());
initialize();

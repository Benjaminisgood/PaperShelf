import CSL from 'citeproc';
import { safeCitationHTML, bibliographyHTML } from './safe-html.mjs';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
export async function loadStyles(customDirectory) {
  const styles = new Map();
  for (const directory of [path.join(root, 'styles'), ...(customDirectory ? [customDirectory] : [])]) {
    for (const name of (await readdir(directory)).sort()) {
      if (!/^[a-zA-Z0-9_-]+\.csl$/.test(name)) continue;
      const id = name.slice(0, -4);
      if (styles.has(id)) throw new Error(`Duplicate CSL style name: ${id}`);
      const xml = await readFile(path.join(directory, name), 'utf8');
      if (/<!DOCTYPE|<!ENTITY/i.test(xml)) throw new Error(`CSL external entities are not accepted: ${id}`);
      styles.set(id, xml);
    }
  }
  return { styles, locale: await readFile(path.join(root, 'locales/en-US.xml'), 'utf8') };
}
export function validateStyle(xml, resources) {
  if (typeof xml !== 'string' || !xml.trim() || /<!DOCTYPE|<!ENTITY/i.test(xml) || !/<style\b[^>]*class=["']in-text["']/i.test(xml) || !/<citation\b/.test(xml)) throw new Error('Choose an independent in-text CSL style without external entities. Note styles are not supported.');
  new CSL.Engine({ retrieveLocale: () => resources.locale, retrieveItem: id => ({ id, type: 'article-journal', title: 'Style validation' }) }, xml, 'en-US');
  return true;
}
export function formatDocument(state, resources) {
  if (!state || state.version !== 1 || !Array.isArray(state.citations) || !state.items || typeof state.items !== 'object' || Array.isArray(state.items)) throw new Error('Invalid citation document state.');
  const style = state.style === 'custom' ? state.customStyleXML : resources.styles.get(state.style);
  if (!style) throw new Error('Choose an installed CSL style.');
  validateStyle(style, resources);
  const seen = new Set();
  const citations = state.citations.map(citation => {
    if (!citation || typeof citation.id !== 'string' || !/^[a-zA-Z0-9-]{1,80}$/.test(citation.id) || seen.has(citation.id) || !Array.isArray(citation.items) || !citation.items.length) throw new Error('Invalid or duplicate citation identifier.');
    seen.add(citation.id);
    return { citationID: citation.id, properties: { noteIndex: 0 }, citationItems: citation.items.map(item => {
      if (!item || typeof item.id !== 'string' || !Object.hasOwn(state.items, item.id) || state.items[item.id]?.id !== item.id) throw new Error('A cited paper is missing its CSL metadata.');
      const result = { id: item.id };
      for (const field of ['locator', 'label', 'prefix', 'suffix']) {
        if (item[field] != null && typeof item[field] !== 'string') throw new Error(`Invalid citation ${field}.`);
        if (item[field]) result[field] = item[field];
      }
      return result;
    }) };
  });
  function render(format) {
    const engine = new CSL.Engine({ retrieveLocale: () => resources.locale, retrieveItem: id => structuredClone(state.items[id]) }, style, 'en-US');
    engine.setOutputFormat(format);
    const result = new Map();
    const previous = [];
    for (const original of citations) {
      const citation = structuredClone(original);
      const [, changes] = engine.processCitationCluster(citation, previous, []);
      for (const [index, text] of changes) result.set(citations[index].citationID, text);
      previous.push([citation.citationID, 0]);
    }
    const bibliography = engine.makeBibliography();
    return { citations: Object.fromEntries(result), bibliography: bibliography ? bibliography[1].map(value => value.replace(/\n$/, '')) : [], hangingIndent: Boolean(bibliography && bibliography[0].hangingindent) };
  }
  const plain = render('text'), rich = render('html');
  return { citations: plain.citations, bibliography: plain.bibliography, style: state.style,
    citationHTML: Object.fromEntries(Object.entries(rich.citations).map(([id, html]) => [id, safeCitationHTML(html)])),
    bibliographyHTML: bibliographyHTML(rich.bibliography, rich.hangingIndent), bibliographyHangingIndent: rich.hangingIndent };
}

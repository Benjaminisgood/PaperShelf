import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';
export interface Paper { id: string; type?: string; title: string; authors: string[]; year: string; journal: string; doi: string; url: string; volume?: string; issue?: string; pages?: string; publisher?: string; citationKey?: string; hasPDF: boolean }
export interface SearchPage { items: Paper[]; total: number; offset: number; limit: number; hasMore: boolean }
export function connectionPath(preference?: string): string {
  const value = preference?.trim() || process.env.PAPERSHELF_API_CONNECTION || path.join(homedir(), 'Library/Application Support/PaperShelf/LocalAPI/connection.json');
  return value.startsWith('~/') ? path.join(homedir(), value.slice(2)) : value;
}
export async function readConnection(filename: string) {
  const info = await stat(filename);
  if (!info.isFile() || (info.mode & 0o077) || (process.getuid && info.uid !== process.getuid())) throw new Error('Connection file must be owned by you with permissions 0600.');
  const value = JSON.parse(await readFile(filename, 'utf8')) as { version: number; baseURL: string; token: string };
  const url = new URL(value.baseURL);
  if (value.version !== 1 || url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.pathname !== '/api/v1' || url.search || url.hash || url.username || url.password || typeof value.token !== 'string' || !value.token || /[\r\n]/.test(value.token)) throw new Error('Invalid PaperShelf connection file.');
  return value;
}
export async function searchPapers(query: string, offset = 0, options: { filename?: string; signal?: AbortSignal; fetchImpl?: typeof fetch } = {}): Promise<SearchPage> {
  if (!Number.isInteger(offset) || offset < 0) throw new Error('Invalid page offset.');
  let connection;
  try { connection = await readConnection(options.filename || connectionPath()); } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') throw new Error('Open PaperShelf and enable Local API. For a custom library, set Connection File in extension preferences.');
    throw error;
  }
  const params = new URLSearchParams({ q: query, offset: String(offset), limit: '50' });
  const response = await (options.fetchImpl || fetch)(`${connection.baseURL}/search?${params.toString().replaceAll('+', '%20')}`, { headers: { Authorization: `Bearer ${connection.token}`, Accept: 'application/json' }, redirect: 'error', signal: options.signal ? AbortSignal.any([options.signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`PaperShelf returned HTTP ${response.status}. Check its Local API settings.`);
  const result = await response.json() as SearchPage;
  if (!Array.isArray(result.items) || !Number.isInteger(result.total) || !Number.isInteger(result.offset) || !Number.isInteger(result.limit) || typeof result.hasMore !== 'boolean') throw new Error('Unexpected PaperShelf search response.');
  return result;
}
export function paperDeepLink(paper: Pick<Paper, 'id'>): string {
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(paper.id)) throw new Error('Invalid paper UUID.');
  return `papershelf://paper/${paper.id}`;
}
/** A complete, plain bibliographic citation. This is not an APA/CSL claim. */
export function paperCitation(paper: Paper): string {
  const title = paper.title.trim() || '(untitled)';
  const publication = [paper.journal, [paper.volume, paper.issue ? `(${paper.issue})` : ''].join(''), paper.pages, paper.publisher].filter(Boolean).join(', ');
  return [paper.authors.join('; '), paper.year ? `(${paper.year})` : '', title, publication, paper.doi ? `https://doi.org/${paper.doi}` : paper.url].filter(Boolean).join('. ');
}
export async function checkConnection(options: { filename?: string; fetchImpl?: typeof fetch } = {}) {
  const connection = await readConnection(options.filename || connectionPath());
  const response = await (options.fetchImpl || fetch)(connection.baseURL + '/status', { headers: { Authorization: `Bearer ${connection.token}`, Accept: 'application/json' }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`PaperShelf returned HTTP ${response.status}.`);
  return response.json() as Promise<{ readOnly?: boolean; paperCount?: number; version?: string }>;
}
function bibtexEscape(value: string): string {
  const replacements: Record<string, string> = { '\\': '\\textbackslash{}', '{': '\\{', '}': '\\}', '%': '\\%', '&': '\\&', '#': '\\#', '_': '\\_', '$': '\\$', '^': '\\textasciicircum{}', '~': '\\textasciitilde{}' };
  return value.replace(/[\\{}%&#_$^~]/g, character => replacements[character]);
}
export function paperBibTeX(paper: Paper): string {
  const key = paper.citationKey && /^[a-zA-Z0-9:._/-]+$/.test(paper.citationKey) ? paper.citationKey : 'paper-' + paper.id;
  const kinds: Record<string, string> = { article: 'article', book: 'book', inproceedings: 'inproceedings', phdthesis: 'phdthesis', mastersthesis: 'mastersthesis', techreport: 'techreport' };
  const fields = [['title', paper.title], ['author', paper.authors.join(' and ')], ['year', paper.year], ['journal', paper.journal], ['volume', paper.volume], ['number', paper.issue], ['pages', paper.pages], ['publisher', paper.publisher], ['doi', paper.doi], ['url', paper.url]].filter(([, value]) => value);
  return `@${kinds[paper.type || ''] || 'misc'}{${key},\n${fields.map(([name, value]) => `  ${name} = {${bibtexEscape(value!)}}`).join(',\n')}\n}`;
}
export function paperRIS(paper: Paper): string {
  const kinds: Record<string, string> = { article: 'JOUR', book: 'BOOK', inproceedings: 'CPAPER', phdthesis: 'THES', mastersthesis: 'THES', techreport: 'RPRT' };
  const fields = [['TY', kinds[paper.type || ''] || 'GEN'], ['TI', paper.title], ...paper.authors.map(author => ['AU', author]), ['PY', paper.year], ['JO', paper.journal], ['VL', paper.volume], ['IS', paper.issue], ['SP', paper.pages], ['PB', paper.publisher], ['DO', paper.doi], ['UR', paper.url]].filter(([, value]) => value);
  return fields.map(([name, value]) => `${name}  - ${value!.replace(/\r\n|\r|\n/g, '\n      ')}`).join('\n') + '\nER  -\n';
}
export function paperMarkdown(paper: Paper): string {
  const escape = (value: string) => value.replace(/[\\`*_{}[\]<>]/g, '\\$&');
  return `# ${escape(paper.title)}\n\n${escape(paperCitation(paper))}\n\n[Open in PaperShelf](${paperDeepLink(paper)})\n`;
}

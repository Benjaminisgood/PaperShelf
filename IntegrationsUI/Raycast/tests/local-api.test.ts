import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { mkdtemp, writeFile, chmod, rm } from 'node:fs/promises';
import path from 'node:path';
import { tmpdir } from 'node:os';
import { connectionPath, paperCitation, paperDeepLink, readConnection, searchPapers } from '../src/local-api.ts';
import type { Paper } from '../src/local-api.ts';
const paper: Paper = { id: '0130a9b5-9df9-4470-9150-a382337fb0a0', title: '氧化催化研究', authors: ['Smith, Jane', '李四'], year: '2026', journal: 'Catalysis', volume: '12', issue: '3', pages: '1–20', doi: '10.1234/test', url: '', hasPDF: true };
test('copy citation retains metadata and Unicode; deep links accept UUID only', () => {
  const citation = paperCitation(paper); assert.match(citation, /Smith, Jane; 李四/); assert.match(citation, /氧化催化研究/); assert.match(citation, /12\(3\), 1–20/); assert.match(citation, /https:\/\/doi.org\/10.1234\/test/);
  const long = 'full '.repeat(10000); assert.ok(paperCitation({ ...paper, title: long }).includes(long.trim()));
  assert.equal(paperDeepLink(paper), 'papershelf://paper/' + paper.id); assert.throws(() => paperDeepLink({ id: '../malicious' }), /UUID/);
  assert.ok(connectionPath('~/custom/connection.json').endsWith('/custom/connection.json'));
});
test('real loopback search authenticates each request and preserves pagination without a result cap', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'papershelf-raycast-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const server = http.createServer((request, response) => {
    assert.equal(request.headers.authorization, 'Bearer test-only-secret');
    const url = new URL(request.url!, 'http://127.0.0.1'); assert.equal(url.pathname, '/api/v1/search'); assert.match(request.url!, /DOI%20%26%20title/); assert.equal(url.searchParams.get('q'), 'DOI & title');
    const offset = Number(url.searchParams.get('offset')); response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({ items: offset ? [] : [paper], total: 1, offset, limit: 50, hasMore: false }));
  });
  await new Promise<void>(resolve => server.listen(0, '127.0.0.1', resolve)); t.after(() => new Promise<void>(resolve => server.close(() => resolve())));
  const address = server.address(); assert.ok(address && typeof address !== 'string');
  const filename = path.join(directory, 'connection.json');
  await writeFile(filename, JSON.stringify({ version: 1, baseURL: `http://127.0.0.1:${address.port}/api/v1`, token: 'test-only-secret' }), { mode: 0o600 });
  const first = await searchPapers('DOI & title', 0, { filename }); assert.deepEqual(first.items, [paper]);
  const next = await searchPapers('DOI & title', 50, { filename }); assert.equal(next.offset, 50);
  await chmod(filename, 0o644); await assert.rejects(() => readConnection(filename), /0600/);
});
test('invalid destinations, missing service, and invalid pagination fail clearly', async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'papershelf-raycast-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'connection.json');
  await assert.rejects(() => searchPapers('', 0, { filename }), /enable Local API/);
  await writeFile(filename, JSON.stringify({ version: 1, baseURL: 'https://outside.example/api/v1', token: 'test-only-secret' }), { mode: 0o600 });
  await assert.rejects(() => readConnection(filename), /Invalid/); await assert.rejects(() => searchPapers('', -1, { filename }), /offset/);
});
test('BibTeX, RIS and Markdown exports escape syntax without discarding bibliographic text', async () => {
  const { paperBibTeX, paperRIS, paperMarkdown } = await import('../src/local-api.ts');
  const record = { ...paper, type: 'article', citationKey: 'smith2026', title: 'A {B} & C_2 50%' };
  const bibtex = paperBibTeX(record); assert.match(bibtex, /@article\{smith2026,/); assert.ok(bibtex.includes('A \\{B\\} \\& C\\_2 50\\%')); assert.ok(bibtex.includes('Smith, Jane and 李四'));
  const ris = paperRIS({ ...record, title: 'Title\nER  - injection' }); assert.match(ris, /TY  - JOUR/); assert.match(ris, /AU  - 李四/); assert.ok(ris.includes('Title\n      ER  - injection')); assert.equal(ris.split('\n').filter(line => line === 'ER  -').length, 1);
  const markdown = paperMarkdown({ ...record, title: '<script>Title</script> [link]' }); assert.ok(markdown.includes('\\<script\\>')); assert.ok(markdown.includes('\\[link\\]')); assert.ok(markdown.includes(paperDeepLink(paper)));
});
test('explicit connection check authenticates without following redirects', async t => {
  const { checkConnection } = await import('../src/local-api.ts');
  const directory = await mkdtemp(path.join(tmpdir(), 'papershelf-check-')); t.after(() => rm(directory, { recursive: true, force: true }));
  const filename = path.join(directory, 'connection.json'); await writeFile(filename, JSON.stringify({ version: 1, baseURL: 'http://127.0.0.1:29468/api/v1', token: 'fixture' }), { mode: 0o600 });
  const response = await checkConnection({ filename, fetchImpl: (async (url: string, options: RequestInit) => { assert.equal(url, 'http://127.0.0.1:29468/api/v1/status'); assert.equal(options.redirect, 'error'); assert.equal((options.headers as Record<string, string>).Authorization, 'Bearer fixture'); return new Response(JSON.stringify({ readOnly: true })); }) as typeof fetch });
  assert.equal(response.readOnly, true);
});

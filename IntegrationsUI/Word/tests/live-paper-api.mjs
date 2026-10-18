// Explicit integration check against the repository's isolated Swift harness.
// Never points at a user library and never prints its per-run token.
import { spawn, execFileSync } from 'node:child_process';
import { mkdtemp, readFile, access, rm, cp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import assert from 'node:assert/strict';
import https from 'node:https';
import { fileURLToPath } from 'node:url';
import { apiGet } from '../src/local-api.mjs';
import { createHandler } from '../src/server.mjs';
import { loadStyles, formatDocument } from '../src/formatter.mjs';
import { searchPapers, paperCitation, paperDeepLink } from '../../Raycast/src/local-api.ts';
const root = fileURLToPath(new URL('../../../', import.meta.url));
const directory = await mkdtemp(path.join(tmpdir(), 'papershelf-adapter-live-'));
const filename = path.join(directory, 'LocalAPI/connection.json');
const harness = path.join(root, '.build/local-api-qa/server-harness');
const child = spawn(harness, [directory, 'readonly'], { stdio: ['ignore', 'ignore', 'pipe'] });
let processError; child.on('error', error => { processError = error; });
let server, bundleChild;
try {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (processError) throw processError;
    try { await access(filename); break; } catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  const status = await apiGet('/status', { filename }); assert.equal(status.readOnly, true);
  const search = await apiGet('/search?q=API%20Fixture&offset=0&limit=20', { filename });
  assert.equal(search.total, 1); assert.equal(search.items[0].title, 'API Fixture');
  const id = search.items[0].id;
  const csl = await apiGet(`/papers/${id}/csl`, { filename });
  assert.equal(csl.title, 'API Fixture'); assert.equal(csl.author[0].family, 'Doe');
  const resources = await loadStyles();
  const rendered = formatDocument({ version: 1, style: 'apa', citations: [{ id: 'integration', items: [{ id }] }], items: { [id]: csl } }, resources);
  assert.equal(rendered.citations.integration, '(Doe, 2024)'); assert.match(rendered.bibliography[0], /API Fixture/);
  const raycast = await searchPapers('API Fixture', 0, { filename });
  assert.equal(raycast.items[0].id, id); assert.match(paperCitation(raycast.items[0]), /10\.1234\/fixture/); assert.equal(paperDeepLink(raycast.items[0]), `papershelf://paper/${id}`);
  const keyPath = path.join(directory, 'test-key.pem'), certPath = path.join(directory, 'test-cert.pem');
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', keyPath, '-out', certPath, '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost,IP:127.0.0.1'], { stdio: 'ignore' });
  const certificate = await readFile(certPath);
  server = https.createServer({ key: await readFile(keyPath), cert: certificate });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port, origin = `https://localhost:${port}`;
  server.on('request', createHandler({ origin, resources, get: route => apiGet(route, { filename }) }));
  function secureGet(route, headers = {}) {
    return new Promise((resolve, reject) => {
      const request = https.get(origin + route, { ca: certificate, family: 4, headers }, response => { let body = ''; response.setEncoding('utf8'); response.on('data', value => body += value); response.on('end', () => resolve({ status: response.statusCode, body })); }); request.on('error', reject);
    });
  }
  const page = await secureGet('/'); assert.equal(page.status, 200); assert.match(page.body, /PaperShelf/);
  const session = JSON.parse((await secureGet('/session')).body);
  const proxy = await secureGet('/api/search?q=API%20Fixture', { 'X-PaperShelf-Session': session.nonce, Origin: origin });
  assert.equal(proxy.status, 200); assert.equal(JSON.parse(proxy.body).items[0].title, 'API Fixture');
  assert.equal((await secureGet('/api/status')).status, 401);
  await new Promise(resolve => server.close(resolve)); server = undefined;
  const runtime = path.join(directory, 'standalone-word');
  for (const relative of ['dist', 'web', 'styles', 'locales', 'licenses', 'THIRD_PARTY_NOTICES.md']) await cp(path.join(root, 'IntegrationsUI/Word', relative), path.join(runtime, relative), { recursive: true });
  bundleChild = spawn(process.execPath, [path.join(runtime, 'dist/server.mjs')], { stdio: ['ignore', 'ignore', 'pipe'], env: { ...process.env, PAPERSHELF_WORD_TLS_KEY: keyPath, PAPERSHELF_WORD_TLS_CERT: certPath, PAPERSHELF_WORD_PORT: String(port), PAPERSHELF_API_CONNECTION: filename } });
  let bundleError = ''; bundleChild.stderr.setEncoding('utf8'); bundleChild.stderr.on('data', text => { bundleError += text; });
  let bundledSession;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { bundledSession = JSON.parse((await secureGet('/session')).body); break; } catch { await new Promise(resolve => setTimeout(resolve, 100)); }
  }
  assert.ok(bundledSession?.nonce, 'Standalone bundle starts without node_modules: ' + bundleError);
  assert.equal((await secureGet('/')).status, 200);
  const bundledSearch = await secureGet('/api/search?q=API%20Fixture', { 'X-PaperShelf-Session': bundledSession.nonce, Origin: origin });
  assert.equal(JSON.parse(bundledSearch.body).items[0].title, 'API Fixture');
  assert.match((await secureGet('/licenses/citeproc-source.js')).body, /Copyright/);
  console.log(JSON.stringify({ result: 'passed', source: 'isolated real Swift LocalAPIServer', checks: ['Word authenticated search', 'Word CSL JSON fetch', 'APA citeproc output', 'Raycast authenticated search', 'Raycast full citation and deep link', 'real HTTPS task pane and API proxy with scoped test CA', 'unauthenticated proxy rejected', 'standalone bundled HTTPS host without node_modules'], tls: 'temporary test certificate trusted only by this test client; no system trust changes', realHostInteraction: { word: false, raycast: false } }, null, 2));
} finally {
  if (server) await new Promise(resolve => server.close(resolve));
  if (bundleChild) { bundleChild.kill('SIGTERM'); await new Promise(resolve => { if (bundleChild.exitCode !== null || bundleChild.signalCode !== null) resolve(); else bundleChild.once('exit', resolve); }); }
  child.kill('SIGTERM');
  await new Promise(resolve => { if (child.exitCode !== null || child.signalCode !== null) resolve(); else child.once('exit', resolve); });
  await rm(directory, { recursive: true, force: true });
}

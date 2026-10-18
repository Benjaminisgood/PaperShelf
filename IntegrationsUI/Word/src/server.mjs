import https from 'node:https';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';
import { apiGet } from './local-api.mjs';
import { loadStyles, formatDocument, validateStyle } from './formatter.mjs';
const root = fileURLToPath(new URL('../', import.meta.url));
const assets = new Map([
  ['/', ['web/index.html', 'text/html; charset=utf-8']], ['/index.html', ['web/index.html', 'text/html; charset=utf-8']],
  ['/app.mjs', ['web/app.mjs', 'text/javascript; charset=utf-8']], ['/state.mjs', ['web/state.mjs', 'text/javascript; charset=utf-8']],
  ['/style.css', ['web/style.css', 'text/css; charset=utf-8']], ['/icon.svg', ['web/icon.svg', 'image/svg+xml']], ['/icon.png', ['web/icon.png', 'image/png']],
  ['/licenses', ['THIRD_PARTY_NOTICES.md', 'text/plain; charset=utf-8']],
  ['/licenses/citeproc-source.js', ['dist/citeproc-source.js', 'text/plain; charset=utf-8']],
  ['/licenses/CPAL-1.0.txt', ['licenses/CPAL-1.0.txt', 'text/plain; charset=utf-8']],
]);
function sameSecret(actual, expected) { if (typeof actual !== 'string') return false; const a = Buffer.from(actual), b = Buffer.from(expected); return a.length === b.length && timingSafeEqual(a, b); }
export function createHandler({ origin, resources, get = apiGet, nonce = randomBytes(32).toString('hex') }) {
  const expectedHost = new URL(origin).host;
  return async (request, response) => {
    const send = (status, value, type = 'application/json; charset=utf-8') => {
      response.writeHead(status, { 'Content-Type': type, 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Referrer-Policy': 'no-referrer', 'Content-Security-Policy': "default-src 'self'; script-src 'self' https://appsforoffice.microsoft.com; style-src 'self'; connect-src 'self' https://*.office.com https://*.office.net https://*.microsoft.com; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'none'" });
      response.end(type.startsWith('application/json') ? JSON.stringify(value) : value);
    };
    try {
      if (request.headers.host !== expectedHost) return send(403, { error: 'Host rejected.' });
      if (request.headers.origin && request.headers.origin !== origin) return send(403, { error: 'Origin rejected.' });
      if (request.headers['sec-fetch-site'] === 'cross-site' && request.url !== '/' && request.url !== '/index.html') return send(403, { error: 'Cross-site request rejected.' });
      if (!['GET', 'POST'].includes(request.method)) return send(405, { error: 'Method rejected.' });
      const url = new URL(request.url, origin);
      if (request.method === 'GET' && assets.has(url.pathname)) {
        const [filename, type] = assets.get(url.pathname);
        return send(200, await readFile(path.join(root, filename)), type);
      }
      if (request.method === 'GET' && url.pathname === '/session') return send(200, { nonce, styles: [...resources.styles.keys()] });
      if (!sameSecret(request.headers['x-papershelf-session'], nonce)) return send(401, { error: 'Reload the PaperShelf task pane to reconnect.' });
      if (request.method === 'GET' && url.pathname === '/api/status') return send(200, await get('/status'));
      if (request.method === 'GET' && url.pathname === '/api/search') {
        const params = new URLSearchParams({ q: url.searchParams.get('q') ?? '', offset: url.searchParams.get('offset') ?? '0', limit: '20' });
        if (!/^\d+$/.test(params.get('offset'))) return send(422, { error: 'Invalid search offset.' });
        return send(200, await get('/search?' + params.toString().replaceAll('+', '%20')));
      }
      if (request.method === 'GET' && /^\/api\/papers\/[0-9a-f-]{36}\/csl$/i.test(url.pathname)) return send(200, await get(url.pathname.slice(4)));
      if (request.method === 'POST' && ['/format', '/validate-style'].includes(url.pathname)) {
        if (request.headers['content-type'] !== 'application/json') return send(415, { error: 'Expected application/json.' });
        const chunks = []; let bytes = 0;
        for await (const chunk of request) { bytes += chunk.length; if (bytes > 4 * 1024 * 1024) return send(413, { error: 'Citation state exceeds the 4 MiB request limit; no content was truncated.' }); chunks.push(chunk); }
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        return send(200, url.pathname === '/validate-style' ? { valid: validateStyle(value.xml, resources) } : formatDocument(value, resources));
      }
      return send(404, { error: 'Unknown route.' });
    } catch (error) { return send(422, { error: error.message || 'Unable to complete the request.' }); }
  };
}
export async function start() {
  const port = Number(process.env.PAPERSHELF_WORD_PORT || 29469);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('Invalid PAPERSHELF_WORD_PORT.');
  if (!process.env.PAPERSHELF_WORD_TLS_KEY || !process.env.PAPERSHELF_WORD_TLS_CERT) throw new Error('Set PAPERSHELF_WORD_TLS_KEY and PAPERSHELF_WORD_TLS_CERT to your trusted localhost certificate files. See README.md.');
  const origin = `https://localhost:${port}`;
  const resources = await loadStyles(process.env.PAPERSHELF_WORD_STYLE_DIR);
  const server = https.createServer({ key: await readFile(process.env.PAPERSHELF_WORD_TLS_KEY), cert: await readFile(process.env.PAPERSHELF_WORD_TLS_CERT), minVersion: 'TLSv1.2' }, createHandler({ origin, resources }));
  server.requestTimeout = 20000; server.headersTimeout = 10000;
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(port, '127.0.0.1', resolve); });
  console.log(`PaperShelf Word host: ${origin}. Library credentials remain server-side. Keep this process running while using Word.`);
  return server;
}
if (process.argv[1] && realpathSync(fileURLToPath(import.meta.url)) === realpathSync(process.argv[1])) start().catch(error => { console.error(error.message); process.exitCode = 1; });

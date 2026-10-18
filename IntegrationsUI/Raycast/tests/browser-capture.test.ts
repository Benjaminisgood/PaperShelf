import test from 'node:test';
import assert from 'node:assert/strict';
import { browserScript, readBrowserTab, browserCaptureLink } from '../src/browser-capture.ts';
test('browser reader uses fixed AppleScript URL/title getters with no page script injection', async () => {
  for (const browser of ['safari', 'chrome', 'edge'] as const) {
    const script = browserScript(browser); assert.match(script, /URL of/); assert.doesNotMatch(script, /do JavaScript|execute javascript|System Events|keystroke/i);
    const tab = await readBrowserTab(browser, async received => { assert.equal(received, script); return 'https://example.org/paper\nA Unicode 论文\n'; });
    assert.deepEqual(tab, { url: 'https://example.org/paper', title: 'A Unicode 论文' });
  }
});
test('capture preserves a complete strict native payload and routes only to PaperShelf preview', () => {
  const link = browserCaptureLink({ url: 'https://example.org/paper?id=1', title: '科研 "Title" & data' }, new Date('2026-10-18T00:00:00Z'));
  const url = new URL(link); assert.equal(url.protocol, 'papershelf:'); assert.equal(url.hostname, 'capture');
  const payload = JSON.parse(Buffer.from(url.searchParams.get('payload')!, 'base64url').toString());
  assert.deepEqual(Object.keys(payload).sort(), ['version','id','capturedAt','sourceURL','title','authors','year','journal','doi','abstract','selectedText','pdfURLs'].sort());
  assert.equal(payload.title, '科研 "Title" & data'); assert.equal(payload.sourceURL, 'https://example.org/paper?id=1'); assert.deepEqual(payload.pdfURLs, []); assert.deepEqual(payload.authors, []);
});
test('capture rejects private/credentialed destinations and overlong titles without silent truncation', () => {
  for (const url of ['file:///secret', 'https://user:password@example.org/', 'http://127.0.0.1/', 'http://10.0.0.1/', 'http://localhost/', 'https://service.local/', 'https://example.org:9999/']) assert.throws(() => browserCaptureLink({ url, title: 'Page' }), /public/);
  assert.throws(() => browserCaptureLink({ url: 'https://example.org/', title: 'x'.repeat(2049) }), /shortened/);
});

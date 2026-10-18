const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const {webcrypto} = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname, '../shared/protocol.js'), 'utf8');
const context = vm.createContext({URL, TextEncoder, crypto: webcrypto, btoa});
vm.runInContext(source, context);
const protocol = context.PaperShelfProtocol;
const fixture = () => ({sourceURL:'https://journal.example.org/article', title:'化学反应网络', authors:['张三','Doe, Jane'], year:'2024', journal:'J. Test', doi:'10.1234/test', abstract:'完整摘要\n第二段', selectedText:'全部选中文字', pdfURLs:['https://cdn.example.org/paper.pdf']});
test('Unicode protocol preserves all fields and creates a URL-safe envelope', () => {
  const value = fixture(); const result = protocol.build(value);
  assert.match(result.url, /^papershelf:\/\/capture\?payload=[A-Za-z0-9_-]+$/);
  const payload = JSON.parse(Buffer.from(result.url.split('=')[1], 'base64url').toString('utf8'));
  for (const key of Object.keys(value)) assert.deepEqual(payload[key], value[key]);
  assert.equal(payload.version, 1); assert.ok(payload.id); assert.ok(payload.capturedAt);
});
test('private, privileged and ambiguous destinations are rejected', () => {
  for (const url of ['file:///etc/passwd','javascript:alert(1)','chrome://settings','http://localhost/a','http://127.1/','http://2130706433/','http://0x7f000001/','http://0177.0.0.1/','http://169.254.169.254/','http://10.0.0.1/','https://example.org:8443/','https://user:pass@example.org/','https://printer.local/','https://[::1]/']) assert.throws(() => protocol.publicURL(url), url);
});
test('oversized or malformed metadata fails without truncation', () => {
  for (const patch of [{title:'字'.repeat(1000)},{abstract:'x'.repeat(24001)},{selectedText:'x'.repeat(12001)},{title:''},{year:'bad'},{doi:'bad'},{pdfURLs:['http://127.0.0.1/a.pdf']},{title:'bad\0text'}]) assert.throws(() => protocol.build({...fixture(),...patch}));
});
test('packages request only user-gesture permissions and no remote scripts', () => {
  for (const browser of ['chromium','firefox']) {
    const manifest = JSON.parse(fs.readFileSync(path.join(__dirname, `../manifest.${browser}.json`)));
    assert.deepEqual(manifest.permissions, ['activeTab','scripting']);
    assert.equal(manifest.host_permissions, undefined); assert.equal(manifest.content_scripts, undefined);
    assert.equal(manifest.background, undefined); assert.match(manifest.content_security_policy.extension_pages, /script-src 'self'/);
  }
});

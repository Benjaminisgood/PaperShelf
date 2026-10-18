import test from 'node:test';
import assert from 'node:assert/strict';
import { loadStyles, formatDocument } from '../src/formatter.mjs';
import { emptyState, parseState, reconcileState, CITATION_PREFIX } from '../web/state.mjs';
const resources = await loadStyles();
const ids = ['0130a9b5-9df9-4470-9150-a382337fb0a0', '601bcb24-25e8-4126-a0b9-39249a813e2b'];
function fixture(style = 'numeric') {
  return { ...emptyState(style), items: Object.fromEntries(ids.map((id, index) => [id, { id, type: 'article-journal', title: `Research ${index + 1}`, author: [{ family: 'Smith', given: 'Jane' }], issued: { 'date-parts': [[2026]] }, 'container-title': 'Journal of Tests', DOI: `10.1234/paper${index + 1}` }])), citations: ids.map((id, index) => ({ id: `cite-${index}`, items: [{ id }] })) };
}
test('numeric citations follow document order, repeated papers keep their number, bibliography contains complete records', () => {
  const state = fixture(); state.citations.push({ id: 'again', items: [{ id: ids[0], locator: '12–15', label: 'page' }] });
  const output = formatDocument(state, resources);
  assert.equal(output.citations['cite-0'], '[1]'); assert.equal(output.citations['cite-1'], '[2]');
  assert.match(output.citations.again, /1, pp?\. 12–15/); assert.equal(output.bibliography.length, 2);
  assert.match(output.bibliography[0], /Research 1/); assert.match(output.bibliography[0], /10\.1234\/paper1/);
  state.citations.reverse(); const reordered = formatDocument(state, resources);
  assert.match(reordered.citations.again, /^\[1/);
});
test('author-year CSL disambiguates same author and year and preserves Unicode', () => {
  const state = fixture('author-year'); state.items[ids[0]].title += ' 氧化催化';
  const output = formatDocument(state, resources);
  assert.match(output.citations['cite-0'], /Smith, 2026a/); assert.match(output.citations['cite-1'], /Smith, 2026b/);
  assert.match(output.bibliography.join('\n'), /氧化催化/);
});
test('official IEEE style produces numbered citations and formatted journal bibliography', () => {
  const output = formatDocument(fixture('ieee'), resources);
  assert.equal(output.citations['cite-0'], '[1]');
  assert.equal(output.citations['cite-1'], '[2]');
  assert.equal(output.bibliography.length, 2);
  assert.match(output.bibliography[0], /J\. Smith/);
  assert.match(output.bibliography[0], /Research 1/);
  assert.match(output.bibliographyHTML[0], /<i>Journal of Tests<\/i>/);
});
test('missing item, duplicate citation, and unavailable style fail explicitly', () => {
  const state = fixture(); delete state.items[ids[1]]; assert.throws(() => formatDocument(state, resources), /missing/);
  const duplicate = fixture(); duplicate.citations.push(duplicate.citations[0]); assert.throws(() => formatDocument(duplicate, resources), /duplicate/);
  assert.throws(() => formatDocument({ ...fixture(), style: 'nonexistent' }, resources), /style/);
});
test('saved document state roundtrips, reorders and removes deleted controls without losing snapshots', () => {
  const state = parseState(JSON.stringify(fixture()));
  const reordered = reconcileState(state, [CITATION_PREFIX + 'cite-1', CITATION_PREFIX + 'cite-0']);
  assert.deepEqual(reordered.citations.map(c => c.id), ['cite-1', 'cite-0']);
  const removed = reconcileState(state, [CITATION_PREFIX + 'cite-1']); assert.equal(removed.citations.length, 1); assert.equal(Object.keys(removed.items).length, 2);
  assert.throws(() => reconcileState(state, [CITATION_PREFIX + 'cite-0', CITATION_PREFIX + 'cite-0']), /Duplicated/);
  assert.throws(() => reconcileState(state, [CITATION_PREFIX + 'unknown']), /no saved metadata/);
});
test('long metadata is retained without truncation in bibliography', () => {
  const state = fixture(); const long = 'Complete-text-'.repeat(6000); state.items[ids[0]].title = long;
  assert.ok(formatDocument(state, resources).bibliography[0].includes(long));
});
test('upstream APA 7 style is processed by citeproc; uploaded custom CSL survives document-state roundtrip', () => {
  const apa = formatDocument(fixture('apa'), resources);
  assert.match(apa.citations['cite-0'], /Smith, 2026a/);
  assert.match(apa.bibliography[0], /Smith, J\./);
  const state = fixture('custom'); state.customStyleXML = resources.styles.get('numeric').replace('prefix="[" suffix="]"', 'prefix="(" suffix=")"');
  const saved = parseState(JSON.stringify(state)); assert.equal(formatDocument(saved, resources).citations['cite-0'], '(1)');
  assert.throws(() => formatDocument({ ...state, customStyleXML: '<!ENTITY evil SYSTEM "file:///secret">' }, resources), /independent/);
  assert.throws(() => formatDocument({ ...state, customStyleXML: resources.styles.get('numeric').replace('class="in-text"', 'class="note"') }, resources), /Note styles/);
});
test('citeproc HTML keeps APA italics, custom superscripts and bibliography hanging indents', () => {
  const apa = formatDocument(fixture('apa'), resources);
  assert.match(apa.bibliographyHTML[0], /<i>Journal of Tests<\/i>/); assert.equal(apa.bibliographyHangingIndent, true);
  assert.match(apa.bibliographyHTML[0], /margin-left:36pt;text-indent:-36pt/);
  const state = fixture('custom'); state.customStyleXML = resources.styles.get('numeric').replace('<layout prefix="["', '<layout vertical-align="sup" prefix="["');
  assert.match(formatDocument(state, resources).citationHTML['cite-0'], /<sup>\[1\]<\/sup>/);
});
test('untrusted citation HTML cannot emit scripts, URLs, event attributes or arbitrary CSS', async () => {
  const { safeCitationHTML } = await import('../src/safe-html.mjs');
  const unsafe = '<script>alert(1)</script><img src="https://evil"><a href="javascript:evil">Title</a><i onclick="evil">italics</i><span style="background:url(https://evil);font-style:italic;position:fixed">safe</span><sup>2</sup>';
  const safe = safeCitationHTML(unsafe);
  assert.doesNotMatch(safe, /script|img|href|onclick|background|url\(|position|alert/);
  assert.match(safe, /Title<i>italics<\/i>/); assert.match(safe, /font-style:italic/); assert.match(safe, /<sup>2<\/sup>/);
  const state = fixture('apa'); state.items[ids[0]].title = 'A & B < C > D <script>unsafe</script>';
  const output = formatDocument(state, resources); assert.doesNotMatch(output.bibliographyHTML.join(''), /<script|onerror|javascript:/);
  assert.match(output.bibliographyHTML.join(''), /&amp;/);
});

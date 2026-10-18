const test = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../shared/extract.js'), 'utf8');

// Deliberately small DOM fixture: tests publisher conventions without a third-party test runtime.
function extract({meta=[], json=[], links=[], title='Fallback page', selection='', type='text/html', href='https://journal.example.org/article'}={}) {
  const node = attributes => ({getAttribute:key => attributes[key] || null});
  const document = {title, contentType:type, querySelectorAll(selector) {
    if (selector === 'meta[name],meta[property]') return meta.map(([name, content]) => node({name,content}));
    if (selector === 'script[type="application/ld+json"]') return json.map(value => ({textContent:typeof value === 'string' ? value : JSON.stringify(value)}));
    return links.map(href => node({href}));
  }};
  return JSON.parse(JSON.stringify(vm.runInNewContext(source, {document, location:new URL(href), window:{getSelection:()=>selection}, URL})));
}
test('Highwire/Citation metadata, relative PDF and full selection', () => {
  const value = extract({meta:[['citation_title',' Paper title '],['citation_author','Doe, Jane'],['citation_author','张三'],['citation_publication_date','2024/03/15'],['citation_journal_title','Journal'],['citation_doi','https://doi.org/10.1234/a'],['citation_abstract','Full abstract'],['citation_pdf_url','/full.pdf']],selection:'First\nSecond'});
  assert.equal(value.title,'Paper title'); assert.deepEqual(value.authors,['Doe, Jane','张三']);
  assert.equal(value.year,'2024'); assert.equal(value.doi,'10.1234/a'); assert.deepEqual(value.pdfURLs,['https://journal.example.org/full.pdf']); assert.equal(value.selectedText,'First\nSecond');
});
test('JSON-LD graph scholarly article and typed PDF encoding', () => {
  const value = extract({json:[{'@graph':[{'@type':'ScholarlyArticle',headline:'JSON paper',author:[{givenName:'Jane',familyName:'Doe'}],datePublished:'2023-02-01',identifier:{value:'doi:10.1234/json'},abstract:'Evidence',isPartOf:{name:'Journal'},encoding:{encodingFormat:'application/pdf',contentUrl:'https://cdn.example.org/a.pdf'}}]}]});
  assert.equal(value.title,'JSON paper'); assert.deepEqual(value.authors,['Jane Doe']); assert.equal(value.doi,'10.1234/json'); assert.equal(value.journal,'Journal'); assert.deepEqual(value.pdfURLs,['https://cdn.example.org/a.pdf']);
});
test('Dublin Core and malformed JSON fallback safely', () => {
  const value = extract({meta:[['dc.title','DC paper'],['dc.creator','A'],['dc.date','2022'],['dc.identifier','10.1234/dc']],json:['<script>bad</script>']});
  assert.equal(value.title,'DC paper'); assert.deepEqual(value.authors,['A']); assert.equal(value.doi,'10.1234/dc');
});
test('PDF page detects itself; scripts or local files never become PDF candidates', () => {
  const value = extract({type:'application/pdf',href:'https://journal.example.org/paper.pdf#page=2',links:['javascript:alert(1)','file:///secret','/paper.pdf']});
  assert.deepEqual(value.pdfURLs,['https://journal.example.org/paper.pdf']); assert.equal(value.sourceURL,'https://journal.example.org/paper.pdf');
});

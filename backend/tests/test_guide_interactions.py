"""Static linking and JS DOM unit checks; no browser or local web server is used."""
import json
import os
import shutil
import subprocess
import unittest

from papershelf_pipeline.guide_interactions import JS, enrich_html, normalized_label


def guide(body):
    return '<!doctype html><html><head><meta name="doc-id" content="fixture"></head><body><main><article>' + body + '''
    <section id="notes"><textarea data-note="general"></textarea><button id="highlight">划线</button><button id="export-notes">导出</button><input id="import-notes" type="file"><p id="notes-status"></p></section>
    </article></main></body></html>'''


class GuideInteractionsTests(unittest.TestCase):
    def test_normalized_numbered_labels_and_chapters(self):
        for label, kind, expected in [('Fig. 2', 'fig', 'fig-2'), ('Table S4', 'tab', 'tab-S4'),
                                      ('(3.12)', 'eq', 'eq-3-12'), ('Scheme 5a', 'sch', 'sch-5a'),
                                      ('Supplementary Figure 8', 'fig', 'fig-S8'), ('图1', 'fig', 'fig-1')]:
            with self.subTest(label=label):
                self.assertEqual(normalized_label(label, kind), expected)
        self.assertEqual(normalized_label('unlabelled', 'eq'), '')

    def test_only_existing_unique_targets_are_linked(self):
        text = guide('''<p>See Fig. 1, 2 and 3. Compare 式 (4) and 表 S2.</p>
        <div id="figure-one" data-ref-label="Fig. 1" data-ref-kind="fig"></div>
        <div id="figure-two" data-ref-label="Fig. 2" data-ref-kind="fig"></div>
        <div id="equation-four" data-ref-label="(4)" data-ref-kind="eq"></div>
        <div id="si-table" data-ref-label="Table S2" data-ref-kind="tab" data-document-id="s1"></div>''')
        result, warnings = enrich_html(text, {}, {})
        self.assertIn('href="#figure-one"', result)
        self.assertIn('href="#figure-two"', result)
        self.assertIn('href="#equation-four"', result)
        self.assertIn('href="#si-table"', result)
        self.assertIn('main:fig-3', warnings[0])
        self.assertIn('class="ref-unavailable"', result)
        self.assertNotIn('href="#fig-3"', result)

    def test_supplement_and_main_number_collisions_are_separate(self):
        text = guide('''<p>Fig. 1</p><p data-document-id="s1">Fig. 1</p>
        <div id="main-figure" data-ref-label="Fig. 1" data-ref-kind="fig"></div>
        <div id="supplement-figure" data-ref-label="Fig. 1" data-ref-kind="fig" data-document-id="s1"></div>''')
        result, warnings = enrich_html(text, {}, {})
        self.assertEqual(warnings, [])
        self.assertIn('href="#main-figure">Fig. 1</a>', result)
        self.assertIn('href="#supplement-figure">Fig. 1</a>', result)

    def test_math_code_links_headings_and_escaped_html_remain_intact(self):
        text = guide('''<math><mtext>Fig. 1</mtext></math><pre>Fig. 1</pre><h3>Fig. 1</h3>
        <a href="#original">Fig. 1</a><p>&lt;script&gt;Fig. 1&lt;/script&gt;</p>
        <div id="fig-one" data-ref-label="Fig. 1" data-ref-kind="fig"></div>''')
        result, warnings = enrich_html(text, {}, {})
        self.assertEqual(warnings, [])
        self.assertIn('<math><mtext>Fig. 1</mtext></math>', result)
        self.assertIn('<pre>Fig. 1</pre>', result)
        self.assertIn('<h3>Fig. 1</h3>', result)
        self.assertIn('<a href="#original">Fig. 1</a>', result)
        self.assertIn('&lt;script&gt;<a class="figref"', result)
        self.assertEqual(result.count('<script data-papershelf-interactions>'), 1)

    def test_external_chapter_links_require_safe_local_href(self):
        source = {'reference_targets': [
            {'label': 'Eq. 2', 'kind': 'eq', 'href': 'chapter-2.html#eq-2'},
            {'label': 'Fig. 4', 'kind': 'fig', 'href': 'javascript:alert(1)'},
            {'label': 'Fig. 5', 'kind': 'fig', 'href': None},
            {'label': 'Fig. 6', 'kind': 'fig', 'href': ' javascript:alert(1)'},
            {'label': 'Fig. 7', 'kind': 'fig', 'href': '\\x00javascript:alert(1)'},
            {'label': 'Fig. 8', 'kind': 'fig', 'href': 'https://example.invalid/page.html#fig-8'},
        ]}
        result, warnings = enrich_html(guide('<p>Equation 2; Fig. 4; Fig. 5; Fig. 6; Fig. 7; Fig. 8.</p>'), source, {})
        self.assertIn('href="chapter-2.html#eq-2"', result)
        self.assertNotIn('href="javascript:', result)
        self.assertTrue(any('fig-4' in warning and 'fig-5' in warning for warning in warnings))
        self.assertNotIn('href=" javascript:', result)
        self.assertNotIn('href="https://example.invalid', result)

    def test_external_repeated_labels_are_ambiguous_unless_local_target_exists(self):
        source = {'reference_targets': [
            {'label': 'Eq. 1', 'kind': 'eq', 'href': '../chapter-2/learning.html#eq-1'},
            {'label': 'Eq. 1', 'kind': 'eq', 'href': '../chapter-3/learning.html#eq-2'},
        ]}
        result, warnings = enrich_html(guide('<p>eqn (1)</p>'), source, {})
        self.assertTrue(any('main:eq-1' in warning for warning in warnings))
        self.assertNotIn('href="../chapter', result)
        local = '<p>eqn (1); 图式 2.</p><div id="local-eq" data-ref-label="(1)" data-ref-kind="eq"></div><div id="scheme" data-ref-label="Scheme 2" data-ref-kind="sch"></div>'
        result, warnings = enrich_html(guide(local), source, {})
        self.assertEqual(warnings, [])
        self.assertIn('href="#local-eq">eqn (1)</a>', result)
        self.assertIn('href="#scheme">图式 2</a>', result)

    def test_ambiguous_duplicate_labels_are_not_arbitrarily_resolved(self):
        text = guide('''<p>Fig. 1</p><div id="a" data-ref-label="Fig. 1" data-ref-kind="fig"></div>
        <div id="b" data-ref-label="Fig. 1" data-ref-kind="fig"></div>''')
        result, warnings = enrich_html(text, {}, {})
        self.assertIn('ref-unavailable', result)
        self.assertTrue(warnings)
        self.assertNotIn('href="#a"', result)
        self.assertNotIn('href="#b"', result)

    @unittest.skipUnless(shutil.which('node'), 'Node is needed for fixed JavaScript syntax checks')
    def test_fixed_javascript_parses(self):
        completed = subprocess.run(['node', '--check'], input=JS, capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0, completed.stderr)

    @unittest.skipUnless(os.environ.get('NODE_PATH'), 'Set NODE_PATH to a development jsdom installation for DOM unit tests')
    def test_dom_highlights_skip_math_restore_notes_and_backstack(self):
        text = guide('''<p id="paragraph" data-highlight>Alpha <em>beta</em><math><mi>x</mi></math> gamma.</p>
        <p><a class="cite" href="#src-one">source</a></p><div id="src-one" class="hidden">Full evidence.</div>''')
        script = r'''
const assert=require('node:assert/strict');const {JSDOM}=require('jsdom');
const html=INPUT_HTML,script=INPUT_SCRIPT;
function create(saved){const dom=new JSDOM(html,{url:'https://fixture.invalid/',runScripts:'outside-only'});const w=dom.window;w.structuredClone=structuredClone;w.HTMLElement.prototype.scrollIntoView=function(){};w.Range.prototype.getBoundingClientRect=()=>({left:0,bottom:20});if(saved)w.localStorage.setItem('papershelf:fixture',saved);w.eval(script);return dom}
const first=create(),w=first.window,doc=w.document,range=doc.createRange();range.selectNodeContents(doc.getElementById('paragraph'));
const highlight=w.PaperShelfGuide.capture(range,2,'note across inline elements');assert.ok(highlight);assert.equal(doc.querySelectorAll('math mark').length,0);assert.equal(new Set([...doc.querySelectorAll('mark')].map(item=>item.dataset.uid)).size,1);assert.ok(doc.querySelectorAll('mark').length>=3);
const note=doc.querySelector('textarea');note.value='persistent note';note.dispatchEvent(new w.Event('input'));
const saved=w.localStorage.getItem('papershelf:fixture');const second=create(saved),v=second.window;
assert.equal(v.document.querySelector('textarea').value,'persistent note');assert.equal(v.PaperShelfGuide.lost,0);assert.equal(v.document.querySelectorAll('math mark').length,0);assert.equal(v.PaperShelfGuide.list().highlights[0].note,'note across inline elements');
const citation=v.document.querySelector('a.cite');citation.click();assert.equal(v.PaperShelfGuide.stack.length,1);assert.ok(v.document.getElementById('src-one').classList.contains('guide-target-flash'));assert.equal(v.document.getElementById('src-one').classList.contains('hidden'),false);v.PaperShelfGuide.back();assert.equal(v.PaperShelfGuide.stack.length,0);
for(const invalid of [{document:'papershelf:fixture',notes:null,highlights:[]},{document:'wrong',notes:{},highlights:[]},{document:'papershelf:fixture',notes:{},highlights:[{}]}])assert.throws(()=>v.PaperShelfGuide.validateNotes(invalid,true));
const corrupt='{"notes":null,"highlights":[]}';const third=create(corrupt);assert.equal(third.window.localStorage.getItem('papershelf:fixture'),corrupt);assert.ok(third.window.document.getElementById('notes-status').textContent.includes('保留'));
first.window.close();second.window.close();third.window.close();console.log('DOM checks passed');
'''.replace('INPUT_HTML', json.dumps(text)).replace('INPUT_SCRIPT', json.dumps(JS))
        completed = subprocess.run(['node', '-e', script], capture_output=True, text=True, timeout=30)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn('DOM checks passed', completed.stdout)


if __name__ == '__main__':
    unittest.main()

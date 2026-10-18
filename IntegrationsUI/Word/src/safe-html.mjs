import sanitizeHTML from 'sanitize-html';
/** CSL inline typography only: no links, URLs, images, script, event attributes,
 * arbitrary CSS, or resource-loading elements can reach Word's insertHtml. */
export function safeCitationHTML(html) {
  return sanitizeHTML(html, {
    allowedTags: ['span', 'i', 'em', 'b', 'strong', 'sup', 'sub', 'br'],
    allowedAttributes: { span: ['style'] },
    allowedStyles: { span: {
      'font-style': [/^(italic|normal)$/], 'font-weight': [/^(bold|normal)$/],
      'font-variant': [/^small-caps$/], 'text-decoration': [/^(underline|none)$/],
      'vertical-align': [/^(super|sub|baseline)$/],
    } },
    allowedSchemes: [], allowProtocolRelative: false,
    transformTags: { div: 'span', p: 'span' },
    disallowedTagsMode: 'discard',
  });
}
export function bibliographyHTML(entries, hangingIndent) {
  const style = `margin-top:0;margin-bottom:8pt;${hangingIndent ? 'margin-left:36pt;text-indent:-36pt;' : ''}`;
  return entries.map(value => `<p style="${style}">${safeCitationHTML(value).trim()}</p>`);
}

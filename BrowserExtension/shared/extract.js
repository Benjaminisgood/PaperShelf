/* PaperShelf metadata reader. Runs only after the user clicks the toolbar action. */
(() => {
  "use strict";
  const clean = value => String(value ?? "").replace(/\s+/g, " ").trim();
  const meta = new Map();
  for (const element of document.querySelectorAll("meta[name],meta[property]")) {
    const key = (element.getAttribute("name") || element.getAttribute("property") || "").toLowerCase();
    const value = clean(element.getAttribute("content"));
    if (value) meta.set(key, [...(meta.get(key) || []), value]);
  }
  const first = (...keys) => keys.flatMap(key => meta.get(key) || []).find(Boolean) || "";
  const many = (...keys) => keys.map(key => meta.get(key) || []).find(values => values.length) || [];
  const entities = [];
  function inspect(value, depth = 0) {
    if (!value || typeof value !== "object" || depth > 12) return;
    if (Array.isArray(value)) { for (const child of value) inspect(child, depth + 1); return; }
    const types = Array.isArray(value["@type"]) ? value["@type"] : [value["@type"]];
    if (types.some(type => /^(ScholarlyArticle|Article|MedicalScholarlyArticle|TechArticle|Report|Chapter|Book)$/.test(type || ""))) entities.push(value);
    if (value["@graph"]) inspect(value["@graph"], depth + 1);
    if (value.mainEntity) inspect(value.mainEntity, depth + 1);
  }
  for (const script of document.querySelectorAll('script[type="application/ld+json"]')) {
    try { inspect(JSON.parse(script.textContent)); } catch { /* Invalid publisher JSON-LD is optional metadata. */ }
  }
  const article = entities.find(value => /ScholarlyArticle/.test(String(value["@type"]))) || entities[0] || {};
  const authorNames = value => (Array.isArray(value) ? value : value ? [value] : []).map(author =>
    typeof author === "string" ? clean(author) : clean(author.name || [author.givenName, author.familyName].filter(Boolean).join(" "))).filter(Boolean);
  let authors = many("citation_author", "dc.creator", "dcterms.creator", "dc.contributor", "author");
  if (!authors.length) authors = first("citation_authors").split(";").map(clean).filter(Boolean);
  if (!authors.length) authors = authorNames(article.author);
  const identifiers = [first("citation_doi", "dc.identifier.doi", "prism.doi", "dc.identifier", "dcterms.identifier"), article.identifier, article.sameAs];
  let doi = "";
  for (let candidate of identifiers.flat()) {
    if (candidate && typeof candidate === "object") candidate = candidate.value || candidate["@id"];
    if (typeof candidate !== "string") continue;
    const match = candidate.match(/(?:https?:\/\/(?:dx\.)?doi\.org\/|doi:\s*)?(10\.\d{4,9}\/[^\s<>]+)/i);
    if (match) { doi = match[1]; break; }
  }
  const pdfs = [];
  function addPDF(value) {
    if (typeof value !== "string" || !value.trim()) return;
    try {
      const url = new URL(value, location.href);
      if (!["https:", "http:"].includes(url.protocol) || url.username || url.password) return;
      url.hash = "";
      if (!pdfs.includes(url.href)) pdfs.push(url.href);
    } catch { /* Invalid metadata links are not candidates. */ }
  }
  for (const value of many("citation_pdf_url", "wkhealth_pdf_url")) addPDF(value);
  for (const link of document.querySelectorAll('link[type="application/pdf"][href],a[type="application/pdf"][href]')) addPDF(link.getAttribute("href"));
  for (const encoding of [article.encoding, article.associatedMedia].flat().filter(Boolean)) {
    if (encoding && typeof encoding === "object" && /pdf/i.test(String(encoding.encodingFormat || encoding.fileFormat || ""))) addPDF(encoding.contentUrl || encoding.url);
  }
  if (document.contentType === "application/pdf" || /\.pdf$/i.test(location.pathname)) addPDF(location.href);
  const date = first("citation_publication_date", "citation_date", "dc.date", "dcterms.issued", "prism.publicationdate") || article.datePublished || "";
  const source = new URL(location.href); source.hash = "";
  return {
    sourceURL: source.href,
    title: first("citation_title", "dc.title", "dcterms.title") || clean(article.headline || article.name) || first("og:title", "twitter:title") || clean(document.title),
    authors: [...new Set(authors)],
    year: String(date).match(/\b([12]\d{3})\b/)?.[1] || "",
    journal: first("citation_journal_title", "prism.publicationname") || clean(article.isPartOf?.name),
    doi,
    abstract: first("citation_abstract", "dc.description", "dcterms.abstract") || clean(article.abstract || article.description) || first("description", "og:description"),
    selectedText: String(window.getSelection?.() || "").trim(),
    pdfURLs: pdfs
  };
})();

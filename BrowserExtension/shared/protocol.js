/* Plain data only; this file never evaluates page content or contacts a server. */
globalThis.PaperShelfProtocol = (() => {
  "use strict";
  const MAX_BYTES = 48 * 1024;
  const bytes = value => new TextEncoder().encode(value).length;
  function publicURL(raw) {
    if (bytes(raw) > 8192 || /[\s\\\u0000-\u001f\u007f]/u.test(raw)) throw new Error("地址包含无效字符。");
    let url;
    try { url = new URL(raw); } catch { throw new Error("无法读取页面地址。"); }
    if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.port) throw new Error("只支持不含登录信息的公开 HTTP/HTTPS 页面和标准端口。");
    const host = url.hostname.toLowerCase();
    if (!host.includes(".") || /\.$/.test(host) || /(?:^|\.)(localhost|local|internal|home|lan|test|invalid|onion)$/.test(host)) throw new Error("不能采集本机或局域网地址。");
    if (/^[\d.]+$/.test(host)) {
      const [a,b,c] = host.split(".").map(Number);
      if (a === 0 || a === 10 || a === 127 || a >= 224 || a === 100 && b >= 64 && b <= 127 || a === 169 && b === 254 ||
          a === 172 && b >= 16 && b <= 31 || a === 192 && (b === 168 || b === 0 || b === 88 && c === 99) ||
          a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) || a === 203 && b === 0 && c === 113) throw new Error("不能采集本机、局域网或保留地址。");
    }
    // IPv6 literals stay unsupported in the popup; the native receiver has complete IPv6 checks.
    return url.href;
  }
  function text(value, maximum, name, required = false) {
    if (typeof value !== "string" || required && !value.trim() || /[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/u.test(value)) throw new Error(`${name}无效。`);
    if (bytes(value) > maximum) throw new Error(`${name}太长，请编辑后重试；原文不会自动截断。`);
  }
  function build(metadata, {now = new Date(), id = crypto.randomUUID()} = {}) {
    const value = {version: 1, id, capturedAt: now.toISOString(), ...metadata};
    text(value.title, 2048, "标题", true); text(value.journal, 1024, "期刊");
    text(value.abstract, 24000, "摘要"); text(value.selectedText, 12000, "选中文字"); text(value.doi, 2048, "DOI");
    if (value.year && !/^[12]\d{3}$/.test(value.year)) throw new Error("年份应为四位数字。");
    if (value.doi && !/^(?:https?:\/\/(?:dx\.)?doi\.org\/|doi:\s*)?10\.\d{4,9}\/[^\s<>]+$/i.test(value.doi)) throw new Error("DOI 格式无效。");
    if (!Array.isArray(value.authors) || value.authors.length > 100 || !Array.isArray(value.pdfURLs) || value.pdfURLs.length > 8) throw new Error("作者或 PDF 候选数量超过限制，请编辑后重试。");
    for (const author of value.authors) text(author, 512, "作者", true);
    value.sourceURL = publicURL(value.sourceURL);
    value.pdfURLs = value.pdfURLs.map(publicURL);
    const data = new TextEncoder().encode(JSON.stringify(value));
    if (data.length > MAX_BYTES) throw new Error("采集数据超过 48 KiB，请缩短摘要或选中文字后重试。");
    let binary = "";
    for (const byte of data) binary += String.fromCharCode(byte);
    return {payload: value, url: "papershelf://capture?payload=" + btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")};
  }
  return {build, publicURL, MAX_BYTES};
})();

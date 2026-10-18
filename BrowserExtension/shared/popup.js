/* global PaperShelfProtocol */
"use strict";
const api = globalThis.browser || globalThis.chrome;
const fields = ["title", "authors", "year", "journal", "doi", "sourceURL", "abstract", "selectedText", "pdfURLs"];
const status = document.getElementById("status");
const form = document.getElementById("capture");
function showError(error) { status.textContent = error.message || String(error); status.classList.add("error"); }
function lines(value) { return value.split(/\r?\n/).map(line => line.trim()).filter(Boolean); }
async function load() {
  try {
    const [tab] = await api.tabs.query({active: true, currentWindow: true});
    if (!tab?.id || !tab.url) throw new Error("无法读取当前标签页，请打开公开文章或 PDF 后重试。");
    PaperShelfProtocol.publicURL(tab.url);
    let metadata;
    try {
      const results = await api.scripting.executeScript({target: {tabId: tab.id}, files: ["extract.js"]});
      metadata = results[0]?.result;
    } catch (error) {
      if (!/\.pdf(?:[?#]|$)/i.test(tab.url)) throw new Error("浏览器不允许读取此页面。请在公开文章页操作；浏览器商店、内置页和受限页面不能采集。");
    }
    if (!metadata) metadata = {sourceURL: tab.url, title: tab.title || new URL(tab.url).pathname.split("/").pop(), authors: [], year: "", journal: "", doi: "", abstract: "", selectedText: "", pdfURLs: [tab.url]};
    for (const key of fields) document.getElementById(key).value = Array.isArray(metadata[key]) ? metadata[key].join("\n") : metadata[key] || "";
    form.hidden = false;
    status.textContent = "已读取页面元数据，请核对后采集。";
  } catch (error) { showError(error); }
}
form.addEventListener("submit", event => {
  event.preventDefault();
  try {
    const metadata = Object.fromEntries(fields.map(key => [key, document.getElementById(key).value.trim()]));
    metadata.authors = lines(metadata.authors); metadata.pdfURLs = lines(metadata.pdfURLs);
    const capture = PaperShelfProtocol.build(metadata);
    const link = document.getElementById("retry");
    link.href = capture.url;
    document.getElementById("handoff").hidden = false;
    status.classList.remove("error");
    status.textContent = "已请求打开应用；请在 PaperShelf 中确认，尚未导入。";
    link.click();
  } catch (error) { showError(error); }
});
load();

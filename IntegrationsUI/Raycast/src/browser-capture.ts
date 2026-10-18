import { execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { promisify } from 'node:util';
const run = promisify(execFile);
export const browsers = { safari: 'com.apple.Safari', chrome: 'com.google.Chrome', edge: 'com.microsoft.edgemac' } as const;
export type BrowserName = keyof typeof browsers;
export function browserScript(browser: BrowserName): string {
  if (!Object.hasOwn(browsers, browser)) throw new Error('Choose Safari, Chrome, or Edge.');
  const id = browsers[browser];
  const active = browser === 'safari' ? 'current tab of front window' : 'active tab of front window';
  return `if application id "${id}" is not running then error "Open the selected browser first."
tell application id "${id}"
  if (count of windows) is 0 then error "No browser window is open."
  set pageURL to URL of ${active}
  set pageTitle to ${browser === 'safari' ? 'name' : 'title'} of ${active}
  return pageURL & linefeed & pageTitle
end tell`;
}
export async function readBrowserTab(browser: BrowserName, execute: (script: string) => Promise<string> = async script => (await run('/usr/bin/osascript', ['-e', script], { timeout: 15000, maxBuffer: 1024 * 1024 })).stdout): Promise<{ url: string; title: string }> {
  const value = await execute(browserScript(browser));
  const split = value.indexOf('\n'); if (split < 0) throw new Error('The browser did not return a tab URL and title.');
  return { url: value.slice(0, split).trim(), title: value.slice(split + 1).replace(/\n$/, '') };
}
export function browserCaptureLink(tab: { url: string; title: string }, now = new Date()): string {
  const url = new URL(tab.url);
  const host = url.hostname.toLowerCase();
  if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password || url.port || host === 'localhost' || /\.(local|localhost|internal|home|lan|test|invalid)$/.test(host) || !host.includes('.') || /^\d+\.\d+\.\d+\.\d+$/.test(host) || host.includes(':')) throw new Error('Capture requires a public HTTP(S) page. PaperShelf validates the destination again before preview.');
  if (!tab.title.trim() || Buffer.byteLength(tab.title) > 2048 || /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(tab.title)) throw new Error('The page title is empty, invalid, or exceeds the capture limit. No text was shortened.');
  if (Buffer.byteLength(url.href) > 8192) throw new Error('The page URL exceeds the capture limit.');
  const payload = { version: 1, id: randomUUID(), capturedAt: now.toISOString(), sourceURL: url.href, title: tab.title, authors: [], year: '', journal: '', doi: '', abstract: '', selectedText: '', pdfURLs: [] };
  const bytes = Buffer.from(JSON.stringify(payload)); if (bytes.length > 48 * 1024) throw new Error('The capture exceeds PaperShelf limits.');
  return 'papershelf://capture?payload=' + bytes.toString('base64url');
}

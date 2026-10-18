import { readFile, stat } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

export const defaultConnection = () => process.env.PAPERSHELF_API_CONNECTION || path.join(homedir(), 'Library/Application Support/PaperShelf/LocalAPI/connection.json');
export async function readConnection(filename = defaultConnection()) {
  const info = await stat(filename);
  if (!info.isFile() || (info.mode & 0o077) || (process.getuid && info.uid !== process.getuid())) throw new Error('PaperShelf connection file must be owned by you and readable only by you (0600).');
  const value = JSON.parse(await readFile(filename, 'utf8'));
  const url = new URL(value.baseURL);
  if (value.version !== 1 || url.protocol !== 'http:' || url.hostname !== '127.0.0.1' || !url.port || url.pathname !== '/api/v1' || url.search || url.hash || url.username || url.password || typeof value.token !== 'string' || !value.token || /[\r\n]/.test(value.token)) throw new Error('Invalid PaperShelf connection file.');
  return value;
}
export async function apiGet(route, { filename, fetchImpl = fetch } = {}) {
  if (!/^\/(?:status|search(?:\?[^#]*)?|papers\/[0-9a-f-]{36}(?:\/csl)?)$/i.test(route)) throw new Error('Unsupported PaperShelf read route.');
  let connection;
  try { connection = await readConnection(filename); } catch (error) {
    if (error.code === 'ENOENT') throw new Error('Open PaperShelf and enable Local API. Set PAPERSHELF_API_CONNECTION for a custom library.');
    throw error;
  }
  const response = await fetchImpl(connection.baseURL + route, { headers: { Authorization: `Bearer ${connection.token}`, Accept: 'application/json' }, redirect: 'error', signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`PaperShelf API returned HTTP ${response.status}. Reopen its Local API settings if the service restarted.`);
  return response.json();
}

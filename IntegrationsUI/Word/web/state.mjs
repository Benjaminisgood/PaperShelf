export const SETTINGS_KEY = 'PaperShelf.Citations.v1';
export const CITATION_PREFIX = 'papershelf-citation:';
export const BIBLIOGRAPHY_TAG = 'papershelf-bibliography';
export function emptyState(style = 'numeric') { return { version: 1, style, citations: [], items: {} }; }
export function parseState(raw) {
  if (!raw) return emptyState();
  const state = typeof raw === 'string' ? JSON.parse(raw) : structuredClone(raw);
  if (state.version !== 1 || !Array.isArray(state.citations) || !state.items || typeof state.items !== 'object') throw new Error('Unsupported PaperShelf document state. Restore a document backup before continuing.');
  if (new Set(state.citations.map(c => c.id)).size !== state.citations.length) throw new Error('Duplicate stored citation identifiers.');
  return state;
}
export function reconcileState(state, tags) {
  const next = structuredClone(state);
  const citations = new Map(state.citations.map(c => [c.id, c]));
  const ids = tags.filter(tag => tag.startsWith(CITATION_PREFIX)).map(tag => tag.slice(CITATION_PREFIX.length));
  if (new Set(ids).size !== ids.length) throw new Error('Duplicated citation controls detected. Delete the pasted duplicate and insert it again through PaperShelf.');
  next.citations = ids.map(id => {
    if (!citations.has(id)) throw new Error('A citation control has no saved metadata. Reinsert that citation through PaperShelf.');
    return citations.get(id);
  });
  return next;
}

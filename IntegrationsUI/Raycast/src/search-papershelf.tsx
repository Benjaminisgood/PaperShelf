import { Action, ActionPanel, Icon, List, Toast, getPreferenceValues, open, showToast } from '@raycast/api';
import { useCallback, useEffect, useRef, useState } from 'react';
import { connectionPath, paperCitation, paperDeepLink, paperBibTeX, paperRIS, paperMarkdown, checkConnection, searchPapers } from './local-api';
import type { Paper, SearchPage } from './local-api';
export default function SearchPaperShelf() {
  const preferences = getPreferenceValues<{ connectionFile?: string }>();
  const filename = connectionPath(preferences.connectionFile);
  const [query, setQuery] = useState('');
  const [page, setPage] = useState<SearchPage>({ items: [], total: 0, offset: 0, limit: 50, hasMore: false });
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string>();
  const controller = useRef<AbortController | null>(null);
  const loadingMore = useRef(false);
  const load = useCallback(async (offset: number, append: boolean) => {
    if (append && loadingMore.current) return;
    controller.current?.abort(); const active = new AbortController(); controller.current = active;
    loadingMore.current = append; setLoading(true); setError(undefined);
    try {
      const result = await searchPapers(query, offset, { filename, signal: active.signal });
      if (active.signal.aborted) return;
      setPage(previous => ({ ...result, items: append ? [...previous.items, ...result.items] : result.items }));
    } catch (failure) {
      if (active.signal.aborted) return;
      const message = failure instanceof Error ? failure.message : 'Cannot reach PaperShelf.';
      setError(message); await showToast({ style: Toast.Style.Failure, title: 'PaperShelf unavailable', message });
    } finally { if (!active.signal.aborted) { setLoading(false); loadingMore.current = false; } }
  }, [query, filename]);
  useEffect(() => {
    controller.current?.abort(); loadingMore.current = false; setPage({ items: [], total: 0, offset: 0, limit: 50, hasMore: false });
    const timer = setTimeout(() => void load(0, false), 250);
    return () => { clearTimeout(timer); controller.current?.abort(); };
  }, [load]);
  async function openPaper(paper: Paper) {
    try { await open(paperDeepLink(paper)); } catch (failure) { await showToast({ style: Toast.Style.Failure, title: 'Cannot open PaperShelf', message: failure instanceof Error ? failure.message : 'Open the app and retry.' }); }
  }
  return <List isLoading={loading} filtering={false} searchText={query} onSearchTextChange={setQuery} searchBarPlaceholder="Search titles, authors, DOI…" pagination={{ pageSize: 50, hasMore: page.hasMore, onLoadMore: () => void load(page.offset + page.limit, true) }}>
    <List.EmptyView title={error ? 'Connect to PaperShelf' : 'No papers found'} description={error || 'Search your local library. Keep PaperShelf open with Local API enabled.'} icon={Icon.Book} actions={<ActionPanel><Action title="Retry Connection" onAction={() => void load(0, false)} /></ActionPanel>} />
    <List.Section title="PaperShelf Library" subtitle={`${page.total} papers`}>
      {page.items.map(paper => <List.Item key={paper.id} title={paper.title || '(untitled)'} subtitle={paper.authors.join('; ')} icon={paper.hasPDF ? Icon.Document : Icon.Book} accessories={[{ text: paper.year || undefined }]} actions={<ActionPanel>
        <Action title="Open in PaperShelf" icon={Icon.Book} onAction={() => openPaper(paper)} />
        <Action.CopyToClipboard title="Copy Citation" content={paperCitation(paper)} shortcut={{ modifiers: ['cmd'], key: 'c' }} />
        <Action.CopyToClipboard title="Copy BibTeX" content={paperBibTeX(paper)} />
        <Action.CopyToClipboard title="Copy RIS" content={paperRIS(paper)} />
        <Action.CopyToClipboard title="Copy Markdown" content={paperMarkdown(paper)} />
        <Action title="Check Connection" icon={Icon.Network} onAction={async () => { try { await checkConnection({ filename }); await showToast({ style: Toast.Style.Success, title: 'Connected to PaperShelf' }); } catch (failure) { await showToast({ style: Toast.Style.Failure, title: 'Connection failed', message: String(failure) }); } }} />
        <Action.CopyToClipboard title="Copy PaperShelf Link" content={paperDeepLink(paper)} shortcut={{ modifiers: ['cmd', 'shift'], key: 'c' }} />
        {paper.doi ? <Action.CopyToClipboard title="Copy DOI" content={paper.doi} /> : null}
        <Action title="Refresh Results" icon={Icon.ArrowClockwise} onAction={() => void load(0, false)} />
      </ActionPanel>} />)}
    </List.Section>
  </List>;
}

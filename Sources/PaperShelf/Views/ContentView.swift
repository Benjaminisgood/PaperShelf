import SwiftUI
import QuickLook
import PaperCore

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.undoManager) private var undoManager
    @SceneStorage("library.inspector") private var showingInspector = true
    @AppStorage("library.showStatusBar") private var showStatusBar = true
    @FocusState private var searchFocused: Bool
    @State private var confirmingPurge = false
    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView(store: store).navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 320)
            } detail: {
                Group {
                    if store.filtered.isEmpty {
                        ContentUnavailableView {
                            Label(store.search.isEmpty ? "还没有文献" : "没有匹配的文献", systemImage: "books.vertical")
                        } description: { Text("拖入 PDF、BibTeX 或 RIS，也可以通过标识符或浏览器采集。") }
                        actions: { Button("导入文献…") { store.importFiles() } }
                    } else { LibraryTable(store: store) }
                }
                // Table columns may scroll; they must not set the window's
                // minimum width when both sidebars are visible.
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(Text(LocalizedStringKey(store.heading)))
                .navigationSubtitle(Bundle.main.bundleIdentifier == "local.papershelf.qa" ? "测试文库" : "")
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL); guard !files.isEmpty else { return false }
                    store.importURLs(files); return true
                }
            }
            .navigationSplitViewStyle(.balanced)
            .searchable(text: $store.search, placement: .sidebar, prompt: "搜索全部文献")
            .searchFocused($searchFocused)
            .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfFocusSearch"))) { _ in searchFocused = true }
            // The inspector belongs to the full split view, so opening the
            // source list redistributes one layout rather than a nested split.
            .inspector(isPresented: $showingInspector) {
                Group {
                    if let item = store.selected {
                        ReferenceDetail(store: store, reference: item).id(item.id)
                    } else {
                        ContentUnavailableView("选择文献", systemImage: "doc.text.magnifyingglass", description: Text("元数据、标注与研读资料将在这里显示。"))
                    }
                }
                .inspectorColumnWidth(min: 330, ideal: 390, max: 620)
                .dropDestination(for: URL.self) { urls, _ in
                    let files = urls.filter(\.isFileURL); guard !files.isEmpty else { return false }
                    store.importURLs(files); return true
                }
            }
            if showStatusBar {
                Divider()
                HStack {
                    if let progress = store.fileProgress {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).frame(width: 90)
                        Text("\(progress.completed) / \(progress.total)")
                        Button(progress.isCancelling ? "取消中…" : "取消") { store.cancelFileOperation() }.buttonStyle(.borderless).disabled(progress.isCancelling)
                    } else if store.isBusy { ProgressView().controlSize(.mini) }
                    Text(store.status).lineLimit(1)
                    if store.importTask != nil && store.fileProgress == nil { Button("取消导入") { store.importTask?.cancel() }.buttonStyle(.borderless) }
                    Spacer()
                    Text(store.selectedIDs.isEmpty ? "\(store.filtered.count) 篇文献" : "已选择 \(store.selectedIDs.count) / \(store.filtered.count) 篇")
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.vertical, 6)
            }
        }
        .toolbar { libraryToolbar }
        .quickLookPreview($store.previewURL)
        .sheet(isPresented: $store.showingIdentifier) { DOIImportView(store: store) }
        .sheet(isPresented: $store.showingBatchEditor) { BatchEditView(store: store) }
        .sheet(item: $store.editingReference) { item in
            MetadataEditor(reference: item, collections: store.collectionRecords) { updated in
                guard let current = store.references.first(where: { $0.id == item.id }), current.deletedAt == item.deletedAt else { return "文献在编辑期间已被移除或恢复，请重新打开编辑器。" }
                do {
                    let merged = try ReferenceEdits.merge(base: item, edited: updated, current: current)
                    if store.save(merged) { return nil }
                    let message = store.error ?? "保存失败"; store.error = nil; return message
                } catch { return error.localizedDescription }
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
        .confirmationDialog("永久删除选中记录？原始文件不会删除，此操作不能撤销。", isPresented: $confirmingPurge, titleVisibility: .visible) {
            Button("永久删除记录", role: .destructive) { store.permanentlyDeleteSelected() }
        }
        .onAppear { store.undoManager = undoManager }
        .onChange(of: store.filter) { _, _ in clearHiddenSelection() }
        .onChange(of: store.search) { _, query in if !query.isEmpty && store.filter != "trash" { store.filter = "all" }; clearHiddenSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in try? store.reload() }
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("导入文件…", systemImage: "square.and.arrow.down") { store.importFiles() }
                Button("通过 DOI / ISBN / arXiv 添加…", systemImage: "link.badge.plus") { store.showingIdentifier = true }
                Button("手动添加…", systemImage: "doc.badge.plus") { store.addManual() }
                Divider()
                Button("新建文集…", systemImage: "folder.badge.plus") { store.editCollection() }
                Button("从 Zotero 迁移…") { store.importZotero() }
            } label: { Label("添加", systemImage: "plus") }.help("导入或添加文献")
            Menu {
                ForEach(LibraryExportScope.allCases, id: \.self) { scope in
                    Menu(LocalizedStringKey(scope.rawValue)) {
                        ForEach(ExportFormat.allCases, id: \.self) { format in
                            Button("\(format.rawValue)…") { store.export(format, scope: scope) }
                        }
                    }.disabled(scope == .selected && store.selectedIDs.isEmpty)
                }
                Divider()
                Button("备份书库…") { store.backupLibrary() }
                Button("恢复书库…") { store.restoreLibrary() }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }.help("导出与备份")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button { showingInspector.toggle() } label: { Label("检查器", systemImage: "sidebar.right") }.help(showingInspector ? "隐藏检查器" : "显示检查器")
        }
        if store.selectedIDs.count > 1 {
            ToolbarItem(placement: .secondaryAction) { Button("批量编辑", systemImage: "square.and.pencil") { store.showingBatchEditor = true } }
        }
        if store.filter == "trash" && !store.selectedIDs.isEmpty {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("恢复") { store.restoreSelected() }
                Button("永久删除…", role: .destructive) { confirmingPurge = true }
            }
        }
    }

    private func clearHiddenSelection() { store.selectedIDs.formIntersection(Set(store.filtered.map(\.id))) }
}

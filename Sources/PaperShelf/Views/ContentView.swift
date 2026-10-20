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
    @State private var inspectedReferenceID: UUID?
    @SceneStorage("library.sidebar") private var showingSidebar = true
    @SceneStorage("library.inspector.tab") private var inspectorTab = 0
    var body: some View {
        VStack(spacing: 0) {
            LibrarySplitView(showingSidebar: $showingSidebar, showingInspector: $showingInspector) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索全部文献", text: $store.search)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .accessibilityIdentifier("library.search")
                        if !store.search.isEmpty {
                            Button { store.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("清除搜索")
                        }
                    }
                    .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).padding(10)
                    SidebarView(store: store)
                }
            } content: {
                Group {
                    if store.filtered.isEmpty {
                        ContentUnavailableView {
                            Label(store.search.isEmpty && store.filter == "all" ? "还没有文献" : "没有匹配的文献", systemImage: "books.vertical")
                        } description: { Text("拖入 PDF、BibTeX 或 RIS，也可以通过标识符或浏览器采集。") }
                        actions: { Button("导入文献…") { store.importFiles() } }
                    } else { LibraryTable(store: store) }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in return importFiles(urls) }
            } inspector: {
                Group {
                    if let item = inspectedReference {
                        VStack(spacing: 0) {
                            if !store.filtered.contains(where: { $0.id == item.id }) {
                                HStack {
                                    Text("此文献已不在当前筛选中，可继续编辑。")
                                    Spacer(minLength: 4)
                                    Button("显示文献") {
                                        store.filter = "all"; store.search = ""; store.selectedID = item.id
                                    }.buttonStyle(.borderless)
                                }.font(.caption).foregroundStyle(.secondary).padding(12)
                                Divider()
                            }
                            ReferenceDetail(store: store, reference: item, metadataDraft: store.editingReference?.id == item.id ? store.editingReference : nil, tab: $inspectorTab, isVisible: showingInspector)
                                .id(item.id)
                        }
                    } else {
                        ContentUnavailableView("选择文献", systemImage: "doc.text.magnifyingglass", description: Text("元数据、标注与研读资料将在这里显示。"))
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .dropDestination(for: URL.self) { urls, _ in return importFiles(urls) }
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
        .navigationTitle(Text(LocalizedStringKey(store.heading)))
        .navigationSubtitle(Bundle.main.bundleIdentifier == "local.papershelf.qa" ? "测试文库" : "")
        .toolbar { libraryToolbar }
        .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfFocusSearch"))) { _ in
            showingSidebar = true
            DispatchQueue.main.async { searchFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfToggleSidebar"))) { _ in showingSidebar.toggle() }
        .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfToggleInspector"))) { _ in toggleInspector() }
        .quickLookPreview($store.previewURL)
        .sheet(isPresented: $store.showingIdentifier) { DOIImportView(store: store) }
        .sheet(isPresented: $store.showingBatchEditor) { BatchEditView(store: store) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("好") { store.error = nil } } message: { Text(store.error ?? "") }
        .confirmationDialog("永久删除选中记录？原始文件不会删除，此操作不能撤销。", isPresented: $confirmingPurge, titleVisibility: .visible) {
            Button("永久删除记录", role: .destructive) { store.permanentlyDeleteSelected() }
        }
        .onAppear { store.undoManager = undoManager; inspectedReferenceID = store.selectedID }
        .onChange(of: store.selectedID) { _, id in
            if let id { inspectedReferenceID = id }
            else if let prior = inspectedReferenceID, store.filtered.contains(where: { $0.id == prior }) { inspectedReferenceID = nil }
        }
        .onChange(of: store.filter) { _, _ in clearHiddenSelection(); inspectedReferenceID = store.selectedID }
        .onChange(of: store.search) { _, query in if !query.isEmpty && store.filter != "trash" { store.filter = "all" }; clearHiddenSelection(); inspectedReferenceID = store.selectedID }
        .onChange(of: store.editingReference) { previous, draft in
            guard let draft, let current = store.references.first(where: { $0.id == draft.id }) else { return }
            if previous?.id != draft.id || draft == current {
                store.selectedID = draft.id; inspectedReferenceID = draft.id; showingInspector = true; inspectorTab = 0
            }
            if draft == current { store.editingReference = nil; store.metadataRefreshBase = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfCreateCollection"))) { _ in showingSidebar = true }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in try? store.reload() }
    }
    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { showingSidebar.toggle() } label: { Label("边栏", systemImage: "sidebar.left") }
                .help(showingSidebar ? "隐藏边栏" : "显示边栏")
                .accessibilityLabel(showingSidebar ? "隐藏边栏" : "显示边栏")
                .accessibilityIdentifier("library.toggleSidebar")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("导入文件…", systemImage: "square.and.arrow.down") { store.importFiles() }
                Button("通过 DOI / ISBN / arXiv 添加…", systemImage: "link.badge.plus") { store.showingIdentifier = true }
                Button("手动添加…", systemImage: "doc.badge.plus") { store.addManual() }
                Divider()
                Button("新建文集", systemImage: "folder.badge.plus") { NotificationCenter.default.post(name: .init("PaperShelfCreateCollection"), object: nil) }
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
            Button(action: toggleInspector) { Label("检查器", systemImage: "sidebar.right") }
                .help(showingInspector ? "隐藏检查器" : "显示检查器")
                .accessibilityLabel(showingInspector ? "隐藏检查器" : "显示检查器")
                .accessibilityIdentifier("library.toggleInspector")
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

    private func toggleInspector() {
        if showingInspector && !InlineReferenceEditing.commit() { return }
        showingInspector.toggle()
    }
    private func importFiles(_ urls: [URL]) -> Bool {
        let files = urls.filter(\.isFileURL)
        guard !files.isEmpty else { return false }
        store.importURLs(files)
        return true
    }
    private func clearHiddenSelection() { store.selectedIDs.formIntersection(Set(store.filtered.map(\.id))) }
    private var inspectedReference: Reference? {
        if let selected = store.selected { return selected }
        guard let id = inspectedReferenceID else { return nil }
        return store.references.first { $0.id == id && $0.deletedAt == nil }
    }
}

import SwiftUI
import PaperCore

struct ContentView: View {
    @ObservedObject var store: LibraryStore
    @State private var showingDOI = false
    @State private var confirmingDelete = false

    var body: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 250)
        } content: {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.heading).font(.title2.bold())
                        Text("\(store.filtered.count) 篇文献").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("最近导入") { store.sortNewest = true }
                        Button("标题 A–Z") { store.sortNewest = false }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton).frame(width: 25).help("排序")
                }.padding(18)
                Divider()
                if store.filtered.isEmpty {
                    ContentUnavailableView {
                        Label(store.references.isEmpty ? "建立你的文献书架" : "没有匹配的文献", systemImage: "books.vertical")
                    } description: {
                        Text(store.references.isEmpty ? "导入 PDF、BibTeX 或 RIS，或通过 DOI 获取元数据。PDF 始终保留在原位置。" : "试试其他关键词，或切换左侧分类。")
                    } actions: {
                        Button("导入文献…") { store.importFiles() }.buttonStyle(.borderedProminent)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Table(store.filtered, selection: $store.selectedID) {
                        TableColumn("文献") { reference in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 5) {
                                    if reference.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.orange) }
                                    Text(reference.title).fontWeight(reference.isRead ? .regular : .semibold).lineLimit(2)
                                }
                                Text(reference.authors.isEmpty ? "作者待补充" : reference.authors.joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 6)
                        }.width(min: 210, ideal: 330)
                        TableColumn("年份", value: \.year).width(50)
                        TableColumn("期刊", value: \.journal).width(min: 70, ideal: 110)
                        TableColumn("PDF") { item in
                            Image(systemName: item.pdfPath == nil ? "minus" : "doc.text")
                                .foregroundStyle(.secondary)
                        }.width(30)
                    }
                    .contextMenu(forSelectionType: UUID.self) { ids in
                        if let id = ids.first, let item = store.references.first(where: { $0.id == id }) {
                            Button("打开 PDF") { store.openPDF(item) }.disabled(item.pdfPath == nil)
                            Button("复制 BibTeX") { store.copyCitation(item) }
                            Button(item.isRead ? "标记为待读" : "标记为已读") {
                                var changed = item; changed.isRead.toggle(); _ = store.save(changed)
                            }
                            Divider()
                            Button("移除记录…", role: .destructive) { store.selectedID = id; confirmingDelete = true }
                        }
                    } primaryAction: { ids in
                        if let id = ids.first, let item = store.references.first(where: { $0.id == id }) { store.openPDF(item) }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 420, ideal: 600)
        } detail: {
            if let item = store.selected {
                ReferenceDetail(store: store, reference: item).id(item.id)
            } else {
                ContentUnavailableView("选择一篇文献", systemImage: "doc.text.magnifyingglass", description: Text("查看元数据、阅读笔记与 PDF 批注。"))
            }
        }
        .searchable(text: $store.search, prompt: "搜索标题、作者、DOI、标签")
        .onChange(of: store.filter) { _, _ in clearHiddenSelection() }
        .onChange(of: store.search) { _, _ in clearHiddenSelection() }
        .toolbar {
            ToolbarItemGroup {
                Button { store.importFiles() } label: { Label("导入", systemImage: "square.and.arrow.down") }.help("导入 PDF / BibTeX / RIS")
                Button { showingDOI = true } label: { Label("DOI", systemImage: "link.badge.plus") }.help("通过 DOI 导入")
                Button { store.addManual() } label: { Label("添加", systemImage: "plus") }.help("手动添加文献")
                Menu {
                    Button("当前列表 → BibTeX…") { store.export(.bibtex) }
                    Button("当前列表 → Markdown…") { store.export(.markdown) }
                    Divider()
                    Button("选中文献 → BibTeX…") { store.export(.bibtex, selectedOnly: true) }.disabled(store.selected == nil)
                } label: { Label("导出", systemImage: "square.and.arrow.up") }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "internaldrive").foregroundStyle(.secondary)
                    Text(store.status).lineLimit(1).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("本地书库").font(.caption2).foregroundStyle(.secondary)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }.background(.bar)
        }
        .sheet(isPresented: $showingDOI) { DOIImportView(store: store) }
        .alert("操作未完成", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("好") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .confirmationDialog("移除此书库记录？原始 PDF 不会删除。", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("移除记录", role: .destructive) { store.removeSelected() }
        }
    }

    private func clearHiddenSelection() {
        if let selectedID = store.selectedID, !store.filtered.contains(where: { $0.id == selectedID }) {
            store.selectedID = nil
        }
    }
}

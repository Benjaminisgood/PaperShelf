import SwiftUI
import PaperCore

private struct LibraryTableRow: Identifiable {
    let reference: Reference
    var attachment = false
    var file: ReferenceAttachment?
    var id: String { reference.id.uuidString + (file.map { ":" + $0.id.uuidString } ?? (attachment ? ":pdf" : "")) }
    var title: String { attachment ? file?.name ?? URL(fileURLWithPath: reference.pdfPath ?? "").lastPathComponent : reference.title }
    var authors: String { attachment ? "" : reference.authors.first.map { $0 + (reference.authors.count > 1 ? " 等" : "") } ?? "" }
    var year: String { attachment ? "" : reference.year }
    var journal: String { attachment ? "" : reference.journal }
    var rating: Int { attachment ? 0 : reference.rating }
    var addedAt: Date { reference.addedAt }
    var notes: String { attachment ? "" : reference.notes }
    var children: [LibraryTableRow]? {
        guard !attachment else { return nil }
        let values = (reference.pdfPath != nil ? [LibraryTableRow(reference: reference, attachment: true)] : []) + reference.attachments.map { LibraryTableRow(reference: reference, attachment: true, file: $0) }
        return values.isEmpty ? nil : values
    }
}

struct LibraryTable: View {
    @ObservedObject var store: LibraryStore
    @State private var selection: Set<String> = []
    @State private var sortOrder = [KeyPathComparator(\LibraryTableRow.addedAt, order: .reverse)]
    @AppStorage("library.table.sort") private var savedSort = "date:reverse"
    @AppStorage("library.table.columns.v3") private var columnCustomization = TableColumnCustomization<LibraryTableRow>()
    var body: some View {
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
            TableColumn("标题", value: \.title) { row in
                HStack(spacing: 7) {
                    Image(systemName: row.attachment ? "paperclip" : "doc.text").foregroundStyle(.secondary)
                    Text(row.title).lineLimit(1).help(row.title)
                    if row.reference.isFavorite && !row.attachment { Image(systemName: "star.fill").foregroundStyle(.orange).font(.caption2) }
                }.draggable(dragValue(row.reference.id))
            }.width(min: 220, ideal: 400).customizationID("title")
            TableColumn("作者", value: \.authors).width(min: 100, ideal: 150).customizationID("authors")
            TableColumn("年份", value: \.year).width(min: 48, ideal: 60).customizationID("year")
            TableColumn("来源", value: \.journal).width(min: 100, ideal: 180).customizationID("journal")
            TableColumn("评分", value: \.rating) { row in
                if !row.attachment { Text(row.rating == 0 ? "—" : String(repeating: "★", count: row.rating)).foregroundStyle(.secondary) }
            }.width(min: 70, ideal: 80).customizationID("rating").defaultVisibility(.hidden)
            TableColumn("备注", value: \.notes).width(min: 100, ideal: 180).customizationID("notes").defaultVisibility(.hidden)
            TableColumn("添加日期", value: \.addedAt) { row in
                if !row.attachment { Text(row.addedAt, format: .dateTime.year().month().day()).foregroundStyle(.secondary) }
            }.width(min: 90, ideal: 100).customizationID("date").defaultVisibility(.hidden)
        }
        .controlSize(.small)
        .alternatingRowBackgrounds(.disabled)
        .contextMenu(forSelectionType: String.self) { ids in contextItems(ids) } primaryAction: { ids in open(ids.first) }
        .onChange(of: selection) { _, ids in store.selectedIDs = Set(ids.compactMap { id in UUID(uuidString: String(id.prefix(36))) }) }
        .onChange(of: store.selectedIDs) { _, ids in
            let current = Set(selection.compactMap { UUID(uuidString: String($0.prefix(36))) })
            if current != ids { selection = Set(ids.map(\.uuidString)) }
        }
        .onAppear { selection = Set(store.selectedIDs.map(\.uuidString)); loadSort() }
        .onChange(of: sortOrder) { _, value in persistSort(value) }
        .onKeyPress(.space) { preview(selection.sorted().first); return .handled }
        .onKeyPress(.return) { open(selection.sorted().first); return .handled }
        .onDeleteCommand { if store.filter != "trash" { store.removeSelected() } }
    }
    @ViewBuilder private func contextItems(_ ids: Set<String>) -> some View {
            if !ids.isEmpty {
                Button("打开附件") { open(ids.first) }.disabled(item(for: ids.first)?.pdfPath == nil && attachment(for: ids.first) == nil)
                Button("快速查看") { preview(ids.first) }.disabled(item(for: ids.first)?.pdfPath == nil && attachment(for: ids.first) == nil)
                Button("在 Finder 中显示") { open(ids.first, reveal: true) }
                Divider()
                Button("编辑元数据") { store.editingReference = item(for: ids.first) }
                Button("复制 BibTeX") { select(ids); store.copyReferences(.bibtex) }
                Button("复制 RIS") { select(ids); store.copyReferences(.ris) }
                Button("复制 DOI") { select(ids); store.copySelectedDOIs() }
                Menu("加入文集") {
                    ForEach(store.collectionRecords) { collection in
                        Button(store.collectionPath(collection.id)) { update(ids) { if !$0.collectionIDs.contains(collection.id) { $0.collectionIDs.append(collection.id) } } }
                    }
                }
                Menu("添加标签") {
                    ForEach(store.tags, id: \.self) { tag in
                        Button(tag) { update(ids) { $0.tags = Array(Set($0.tags + [tag])).sorted() } }
                    }
                }
                Button("移除全部文集") { update(ids) { $0.collectionIDs = []; $0.collection = "" } }
                ratingMenu(ids)
                Button("标记已读") { update(ids) { $0.isRead = true } }
                Button("标记待读") { update(ids) { $0.isRead = false } }
                Button("收藏") { update(ids) { $0.isFavorite = true } }
                Button("刷新元数据") { select(ids); store.refreshSelectedMetadata() }.disabled(store.isBusy)
                Button("整理关联文件…") { select(ids); store.organizeFiles(store.selectedReferences) }
                Button("关联文件移到废纸篓…") { select(ids); store.trashLinkedFiles(store.selectedReferences) }
                Divider()
                if store.filter == "trash" { Button("恢复") { select(ids); store.restoreSelected() } }
                else { Button("移到最近删除", role: .destructive) { select(ids); store.removeSelected() } }
            }
    }
    private func ratingMenu(_ ids: Set<String>) -> some View {
        Menu("评分") {
            Button("未评分") { update(ids) { $0.rating = 0 } }
            ForEach([1, 2, 3, 4, 5], id: \.self) { score in
                Button(String(score) + " 星") { update(ids) { $0.rating = score } }
            }
        }
    }
    private func dragValue(_ id: UUID) -> String { store.selectedIDs.contains(id) ? store.selectedIDs.map(\.uuidString).sorted().joined(separator: "\n") : id.uuidString }
    private func select(_ ids: Set<String>) { store.selectedIDs = Set(ids.compactMap { UUID(uuidString: String($0.prefix(36))) }) }
    private func update(_ ids: Set<String>, change: (inout Reference)->Void) { select(ids); store.updateSelected(change) }
    private func attachment(for id: String?) -> ReferenceAttachment? {
        guard let id, let value = item(for: id), let suffix = id.split(separator: ":").last, let uuid = UUID(uuidString: String(suffix)), uuid != value.id else { return nil }
        return value.attachments.first { $0.id == uuid }
    }
    private func open(_ id: String?, reveal: Bool = false) {
        if let file = attachment(for: id) { store.openAttachment(file, reveal: reveal) }
        else if let item = item(for: id), item.pdfPath != nil { store.openPDF(item, reveal: reveal) }
    }
    private func preview(_ id: String?) {
        if let file = attachment(for: id) { do { store.previewURL = try PaperAttachments.resolvedURL(for: file) } catch { store.error = error.localizedDescription } }
        else if let item = item(for: id) { store.preview(item) }
    }
    private func persistSort(_ value: [KeyPathComparator<LibraryTableRow>]) {
        guard let first = value.first else { return }
        let name: String
        switch first.keyPath {
        case \LibraryTableRow.title: name = "title"; store.sortOrder = [.init(\.title, order: first.order)]
        case \LibraryTableRow.authors: name = "authors"
        case \LibraryTableRow.year: name = "year"; store.sortOrder = [.init(\.year, order: first.order)]
        case \LibraryTableRow.journal: name = "journal"; store.sortOrder = [.init(\.journal, order: first.order)]
        case \LibraryTableRow.rating: name = "rating"; store.sortOrder = [.init(\.rating, order: first.order)]
        case \LibraryTableRow.notes: name = "notes"; store.sortOrder = [.init(\.notes, order: first.order)]
        default: name = "date"; store.sortOrder = [.init(\.addedAt, order: first.order)]
        }
        savedSort = name + (first.order == .reverse ? ":reverse" : ":forward")
    }
    private func loadSort() {
        let order: SortOrder = savedSort.hasSuffix(":reverse") ? .reverse : .forward
        switch savedSort.components(separatedBy: ":").first {
        case "title": sortOrder = [.init(\.title, order: order)]
        case "authors": sortOrder = [.init(\.authors, order: order)]
        case "year": sortOrder = [.init(\.year, order: order)]
        case "journal": sortOrder = [.init(\.journal, order: order)]
        case "rating": sortOrder = [.init(\.rating, order: order)]
        case "notes": sortOrder = [.init(\.notes, order: order)]
        default: sortOrder = [.init(\.addedAt, order: order)]
        }
    }
    private var rows: [LibraryTableRow] { store.filtered.map { LibraryTableRow(reference: $0) }.sorted(using: sortOrder) }
    private func item(for id: String?) -> Reference? {
        guard let id, let uuid = UUID(uuidString: String(id.prefix(36))) else { return nil }
        return store.references.first { $0.id == uuid }
    }
}

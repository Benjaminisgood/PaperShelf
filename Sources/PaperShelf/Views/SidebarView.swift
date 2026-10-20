import SwiftUI
import PaperCore

struct SidebarView: View {
    @ObservedObject var store: LibraryStore
    @State private var collectionDraft: SidebarCollectionDraft?
    @State private var tagDraft: SidebarTagDraft?

    var body: some View {
        List(selection: Binding<String?>(get: { store.filter }, set: { store.filter = $0 ?? "all" })) {
            Section("文库") {
                row("全部文献", icon: "books.vertical", filter: "all")
                row("未归类", icon: "tray", filter: "unfiled")
                row("缺少标识符", icon: "exclamationmark.magnifyingglass", filter: "missing-id")
                row("缺少 PDF", icon: "paperclip", filter: "missing")
                row("待读", icon: "book.closed", filter: "unread")
                row("收藏", icon: "star", filter: "favorites")
            }
            Section {
                if let draft = collectionDraft {
                    SidebarNameEditor(title: draft.collection == nil ? "新建文集" : "重命名文集", initialValue: draft.collection?.name ?? "", onSave: { name in
                        guard store.saveCollection(name: name, collection: draft.collection, parentID: draft.parentID) != nil else { return takeError() }
                        return nil
                    }, onCancel: { collectionDraft = nil }).id(draft.id)
                }
                ForEach(store.sortedCollections(parent: nil)) { collection in
                    CollectionSidebarRow(store: store, collection: collection, edit: editCollection)
                }
                ForEach(store.collections, id: \.self) { name in row(name, icon: "folder", filter: "c:" + name) }
            } header: {
                HStack {
                    Text("文集"); Spacer()
                    Button { editCollection(nil, nil) } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建文集").accessibilityLabel("新建文集")
                }
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { payloads, _ in
                    guard let source = payloads.first(where: { $0.hasPrefix("collection:") }),
                          let id = UUID(uuidString: String(source.dropFirst("collection:".count))),
                          let collection = store.collectionRecords.first(where: { $0.id == id }) else { return false }
                    return store.moveCollection(collection, to: nil)
                }
                .help("将文集拖到此处可移到顶层")
            }
            Section {
                if let draft = tagDraft {
                    SidebarNameEditor(title: draft.name == nil ? "新建标签" : "重命名标签", initialValue: draft.name ?? "", onSave: { name in
                        guard store.saveTag(name: name, renaming: draft.name) else { return takeError() }
                        return nil
                    }, onCancel: { tagDraft = nil }).id(draft.id)
                }
                ForEach(store.tags, id: \.self) { name in TagSidebarRow(store: store, name: name, rename: { tagDraft = SidebarTagDraft(name: name) }) }
            } header: {
                HStack {
                    Text("标签"); Spacer()
                    Button { tagDraft = SidebarTagDraft(); collectionDraft = nil } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("新建标签").accessibilityLabel("新建标签")
                }
            }
            Section { row("最近删除", icon: "trash", filter: "trash") }
        }
        .listStyle(.sidebar)
        .onReceive(NotificationCenter.default.publisher(for: .init("PaperShelfCreateCollection"))) { _ in editCollection(nil, nil) }
    }

    private func editCollection(_ collection: LibraryCollection?, _ parentID: UUID?) {
        tagDraft = nil; collectionDraft = SidebarCollectionDraft(collection: collection, parentID: parentID)
    }
    private func takeError() -> String {
        let message = store.error ?? "保存失败"; store.error = nil; return message
    }

    private func row(_ title: String, icon: String, filter: String) -> some View {
        HStack(spacing: 8) {
            SidebarIcon(name: icon)
            Text(LocalizedStringKey(title)).lineLimit(1)
            Spacer()
            if store.count(filter) > 0 { Text("\(store.count(filter))").monospacedDigit().font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .tag(filter)
    }
}

// Keep the icon's width and foreground explicit while macOS updates source-list
// rows during live window moves and resizing, instead of using Label's icon slot.
private struct SidebarIcon: View {
    let name: String
    var color: Color = .primary

    var body: some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(color)
            .frame(width: 20, height: 20)
            .fixedSize()
            .accessibilityHidden(true)
    }
}

private struct TagSidebarRow: View {
    @ObservedObject var store: LibraryStore
    let name: String
    let rename: () -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            SidebarIcon(name: "tag.fill", color: store.tagColor(name))
            Text(name).lineLimit(1); Spacer()
            if store.count("t:" + name) > 0 { Text("\(store.count("t:" + name))").monospacedDigit().font(.caption).foregroundStyle(.secondary) }
        }
        .contentShape(Rectangle())
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .tag("t:" + name)
        .draggable("tag:" + name)
        .dropDestination(for: String.self) { payloads, _ in
            if let source = payloads.first(where: { $0.hasPrefix("tag:") }) {
                return store.placeTag(String(source.dropFirst("tag:".count)), before: name)
            }
            return store.addTag(name, to: store.droppedReferenceIDs(payloads))
        } isTargeted: { isTargeted = $0 }
        .help("拖入文献可批量添加标签；拖入其他标签可调整顺序")
        .contextMenu {
            Button("添加到选中文献") { store.addTag(name, to: store.selectedIDs) }.disabled(store.selectedReferences.allSatisfy { $0.deletedAt != nil })
            Button("从选中文献取消标签") { store.removeTag(name, from: store.selectedIDs) }.disabled(!store.selectedReferences.contains { $0.deletedAt == nil && $0.tags.contains(name) })
            Button("重命名") { rename() }
            Menu("颜色") {
                ForEach([("蓝色", "#007AFF"), ("绿色", "#34C759"), ("橙色", "#FF9500"), ("红色", "#FF3B30"), ("紫色", "#AF52DE")], id: \.1) { color in
                    Button(color.0) { store.colorTag(name, hex: color.1) }
                }
                Divider()
                Button("自定义颜色…") { store.customTagColor(name) }
                Button("默认颜色") { store.colorTag(name, hex: "") }
            }
            Divider()
            Button("上移") { store.shiftTag(name, offset: -1) }.disabled(store.tags.first == name)
            Button("下移") { store.shiftTag(name, offset: 1) }.disabled(store.tags.last == name)
            Divider()
            Button("移除标签", role: .destructive) { store.deleteTag(name) }
        }
    }
}

private struct CollectionSidebarRow: View {
    @ObservedObject var store: LibraryStore
    let collection: LibraryCollection
    let edit: (LibraryCollection?, UUID?) -> Void
    @State private var isExpanded = false
    @State private var isTargeted = false
    @State private var rowHeight: CGFloat = 24

    var body: some View {
        Group {
            if children.isEmpty { label }
            else {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(children) { CollectionSidebarRow(store: store, collection: $0, edit: edit) }
                } label: { label }
            }
        }
        .tag("c:\(collection.id)")
        .contextMenu {
            Button("添加选中文献") { store.addToCollection(collection.id, referenceIDs: store.selectedIDs) }.disabled(store.selectedReferences.allSatisfy { $0.deletedAt != nil })
            Button("从选中文献移出文集") { store.removeFromCollection(collection.id, referenceIDs: store.selectedIDs) }.disabled(!store.selectedReferences.contains { $0.deletedAt == nil && $0.collectionIDs.contains(collection.id) })
            Button("新建子文集") { edit(nil, collection.id); isExpanded = true }
            Button("重命名") { edit(collection, collection.parentID) }
            Toggle("包含子文集文献", isOn: Binding(get: { store.preferences.includeSubcollections }, set: { _ in store.toggleSubcollections() }))
            Divider()
            Button("上移") { store.shiftCollection(collection, offset: -1) }.disabled(siblings.first?.id == collection.id)
            Button("下移") { store.shiftCollection(collection, offset: 1) }.disabled(siblings.last?.id == collection.id)
            Menu("移动到") {
                Button("顶层") { store.moveCollection(collection, to: nil) }.disabled(collection.parentID == nil)
                ForEach(store.collectionRecords.filter { !store.collectionIDs(in: collection.id).contains($0.id) }) { parent in
                    Button(store.collectionPath(parent.id)) { store.moveCollection(collection, to: parent.id) }.disabled(collection.parentID == parent.id)
                }
            }
            Divider()
            Button("移除文集", role: .destructive) { store.deleteCollection(collection) }
        }
    }

    private var children: [LibraryCollection] { store.sortedCollections(parent: collection.id) }
    private var siblings: [LibraryCollection] { store.sortedCollections(parent: collection.parentID) }
    private var label: some View {
        HStack(spacing: 8) {
            SidebarIcon(name: "folder")
            Text(collection.name).lineLimit(1)
            Spacer()
            if store.count("c:\(collection.id)") > 0 { Text("\(store.count("c:\(collection.id)"))").monospacedDigit().font(.caption).foregroundStyle(.secondary) }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .background(isTargeted ? Color.accentColor.opacity(0.12) : Color.clear)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeight = $0 }
        .draggable("collection:\(collection.id.uuidString)")
        .dropDestination(for: String.self) { payloads, location in
            if let source = payloads.first(where: { $0.hasPrefix("collection:") }),
               let id = UUID(uuidString: String(source.dropFirst("collection:".count))),
               let moved = store.collectionRecords.first(where: { $0.id == id }) {
                if location.y < rowHeight * 0.25 { return store.placeCollection(moved, beside: collection, after: false) }
                if location.y > rowHeight * 0.75 { return store.placeCollection(moved, beside: collection, after: true) }
                let success = store.moveCollection(moved, to: collection.id)
                if success { isExpanded = true }; return success
            }
            return store.addToCollection(collection.id, referenceIDs: store.droppedReferenceIDs(payloads))
        } isTargeted: { isTargeted = $0 }
        .help("拖入文献可添加归属；文集拖到行中央成为子文集，拖到上沿或下沿可排序")
    }
}

private struct SidebarCollectionDraft: Identifiable {
    let id = UUID()
    var collection: LibraryCollection?
    var parentID: UUID?
}

private struct SidebarTagDraft: Identifiable {
    let id = UUID()
    var name: String?
}

private struct SidebarNameEditor: View {
    let title: String
    let onSave: (String) -> String?
    let onCancel: () -> Void
    @State private var name: String
    @State private var error: String?
    @FocusState private var focused: Bool

    init(title: String, initialValue: String, onSave: @escaping (String) -> String?, onCancel: @escaping () -> Void) {
        self.title = title; self.onSave = onSave; self.onCancel = onCancel
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                .accessibilityLabel(LocalizedStringKey(title)).onSubmit(save).onExitCommand(perform: onCancel)
            HStack {
                Button("取消", action: onCancel)
                Spacer(minLength: 0)
                Button("保存", action: save).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.buttonStyle(.borderless).controlSize(.small)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.vertical, 6).task { focused = true }
    }

    private func save() {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        error = onSave(value)
        if error == nil { onCancel() }
    }
}

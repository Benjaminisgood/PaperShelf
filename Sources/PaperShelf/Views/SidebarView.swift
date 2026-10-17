import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: LibraryStore

    var body: some View {
        List(selection: Binding<String?>(get: { store.filter }, set: { store.filter = $0 ?? "all" })) {
            Section("书库") {
                Label("全部文献", systemImage: "books.vertical").tag("all")
                Label("待读", systemImage: "book.closed").tag("unread")
                Label("收藏", systemImage: "star").tag("favorites")
                Label("未分类", systemImage: "tray").tag("unfiled")
                Label("缺少附件", systemImage: "doc.badge.plus").tag("missing")
            }
            Section("分类") {
                if store.collections.isEmpty { Text("在元数据中添加分类").font(.caption).foregroundStyle(.tertiary) }
                ForEach(store.collections, id: \.self) { name in
                    Label(name, systemImage: "folder").tag("c:" + name)
                }
            }
            Section("标签") {
                if store.tags.isEmpty { Text("在元数据中添加标签").font(.caption).foregroundStyle(.tertiary) }
                ForEach(store.tags, id: \.self) { name in
                    Label(name, systemImage: "tag").tag("t:" + name)
                }
            }
        }.listStyle(.sidebar)
        .navigationTitle("PaperShelf")
    }
}

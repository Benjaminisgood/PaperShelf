import SwiftUI
import PaperCore

struct BatchEditView: View {
    @ObservedObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var field = "tag"
    @State private var value = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("批量编辑 \(store.selectedIDs.count) 篇文献").font(.title2.bold())
            Picker("字段", selection: $field) {
                Text("添加标签").tag("tag"); Text("来源").tag("journal"); Text("年份").tag("year"); Text("出版者").tag("publisher")
            }
            TextField("新值", text: $value)
            Text("仅更改选定字段，其他信息保持原值。").font(.caption).foregroundStyle(.secondary)
            HStack { Spacer(); Button("取消") { dismiss() }; Button("应用") {
                let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
                store.updateSelected { item in
                    switch field { case "tag": if !text.isEmpty && !item.tags.contains(text) { item.tags.append(text) }
                    case "journal": item.journal = text; case "year": item.year = text; default: item.publisher = text }
                }; dismiss()
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 420)
    }
}

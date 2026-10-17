import SwiftUI
import PaperCore

struct MetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Reference
    @State private var authors: String
    @State private var tags: String
    @State private var saveError: String?
    private let initialAuthors: String
    private let initialTags: String
    let onSave: (Reference) -> String?

    init(reference: Reference, onSave: @escaping (Reference) -> String?) {
        _draft = State(initialValue: reference)
        _authors = State(initialValue: reference.authors.joined(separator: "; "))
        _tags = State(initialValue: reference.tags.joined(separator: ", "))
        initialAuthors = reference.authors.joined(separator: "; ")
        initialTags = reference.tags.joined(separator: ", ")
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("编辑文献").font(.title2.bold()).padding(22)
            Form {
                Section("文献信息") {
                    TextField("标题", text: $draft.title, axis: .vertical)
                    TextField("作者（分号分隔）", text: $authors)
                    TextField("年份", text: $draft.year)
                    TextField("期刊 / 来源", text: $draft.journal)
                    TextField("DOI", text: $draft.doi)
                    TextField("网址", text: $draft.url)
                }
                Section("整理") {
                    TextField("分类", text: $draft.collection)
                    TextField("标签（逗号分隔）", text: $tags)
                    Toggle("已读", isOn: $draft.isRead)
                    Toggle("收藏", isOn: $draft.isFavorite)
                }
                Section("摘要") { TextEditor(text: $draft.abstract).frame(minHeight: 75) }
                Section("阅读笔记") { TextEditor(text: $draft.notes).frame(minHeight: 100) }
            }.formStyle(.grouped)
            Divider()
            if let saveError { Text(saveError).font(.caption).foregroundStyle(.red).padding(.horizontal, 18) }
            HStack {
                Text("更改仅在点击保存后写入书库。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    draft.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.collection = draft.collection.trimmingCharacters(in: .whitespacesAndNewlines)
                    if authors != initialAuthors {
                        draft.authors = authors.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    }
                    if tags != initialTags {
                        draft.tags = Array(Set(tags.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
                    }
                    saveError = onSave(draft)
                    if saveError == nil { dismiss() }
                }.keyboardShortcut(.defaultAction)
                    .disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(18)
        }.frame(width: 650, height: 720)
    }
}

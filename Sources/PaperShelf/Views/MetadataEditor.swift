import SwiftUI
import PaperCore

struct MetadataEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Reference
    @State private var authors: String
    @State private var tags: String
    @State private var newFieldName = ""
    @State private var saveError: String?
    private let initialAuthors: String
    private let initialTags: String
    let collections: [LibraryCollection]
    let onSave: (Reference) -> String?

    init(reference: Reference, collections: [LibraryCollection] = [], onSave: @escaping (Reference) -> String?) {
        _draft = State(initialValue: reference)
        _authors = State(initialValue: reference.authors.joined(separator: "; "))
        _tags = State(initialValue: reference.tags.joined(separator: ", "))
        initialAuthors = reference.authors.joined(separator: "; ")
        initialTags = reference.tags.joined(separator: ", ")
        self.collections = collections
        self.onSave = onSave
    }

    private var typeFields: [(key: String, label: String)] {
        switch draft.entryType {
        case "book", "inbook", "incollection": return [("edition","版次"),("series","系列"),("booktitle","书名"),("editor","编者"),("address","出版地")]
        case "inproceedings", "proceedings": return [("booktitle","论文集"),("eventtitle","会议"),("eventdate","会议日期"),("venue","会议地点"),("organization","主办机构")]
        case "phdthesis", "mastersthesis", "thesis": return [("school","学校"),("degree","学位"),("address","地点")]
        case "techreport", "report": return [("institution","机构"),("number","报告编号"),("address","地点")]
        case "dataset": return [("repository","存储库"),("version","版本"),("license","许可")]
        case "software": return [("repository","代码仓库"),("version","版本"),("license","许可"),("language","编程语言")]
        case "patent": return [("number","专利号"),("assignee","受让人"),("country","国家"),("filingdate","申请日期")]
        case "preprint": return [("arxivId","arXiv 标识符"),("archiveprefix","预印本平台"),("primaryclass","学科分类")]
        case "online": return [("urldate","访问日期"),("organization","机构"),("language","语言")]
        default: return []
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("编辑文献").font(.title2.bold()).padding(22)
            Form {
                Section("文献信息") {
                    Picker("类型", selection: $draft.entryType) {
                        ForEach(["article","book","inbook","incollection","inproceedings","proceedings","phdthesis","mastersthesis","techreport","online","dataset","software","patent","manuscript","preprint","misc"], id: \.self) { Text($0).tag($0) }
                    }
                    TextField("引用键", text: $draft.citationKey)
                    TextField("标题", text: $draft.title, axis: .vertical)
                    TextField("作者（分号分隔）", text: $authors)
                    TextField("年份", text: $draft.year)
                    TextField("期刊 / 来源", text: $draft.journal)
                    TextField("DOI", text: $draft.doi)
                    TextField("网址", text: $draft.url)
                    HStack { TextField("卷", text: $draft.volume); TextField("期", text: $draft.issue); TextField("页码", text: $draft.pages) }
                    TextField("出版者", text: $draft.publisher)
                    TextField("ISBN", text: $draft.isbn)
                    TextField("ISSN", text: $draft.issn)
                }
                if !typeFields.isEmpty {
                    Section("类型字段") {
                        ForEach(typeFields, id: \.key) { field in
                            TextField(LocalizedStringKey(field.label), text: Binding(get: { draft.extraFields[field.key] ?? "" }, set: { value in
                                if value.isEmpty { draft.extraFields.removeValue(forKey: field.key) } else { draft.extraFields[field.key] = value }
                            }))
                        }
                    }
                }
                Section("扩展字段") {
                    ForEach(draft.extraFields.keys.filter { !typeFields.map(\.key).contains($0) }.sorted(), id: \.self) { key in
                        HStack {
                            TextField(key, text: Binding(get: { draft.extraFields[key] ?? "" }, set: { draft.extraFields[key] = $0 }))
                            Button { draft.extraFields.removeValue(forKey: key) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("移除字段")
                        }
                    }
                    HStack {
                        TextField("字段名称，例如 arxivId、edition、language", text: $newFieldName)
                        Button("添加") { let key = newFieldName.trimmingCharacters(in: .whitespaces); if !key.isEmpty && draft.extraFields[key] == nil { draft.extraFields[key] = ""; newFieldName = "" } }.disabled(newFieldName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                Section("整理") {
                    if !draft.collection.isEmpty { TextField("旧分类", text: $draft.collection) }
                    ForEach(collections) { collection in
                        Toggle(collection.name, isOn: Binding(get: { draft.collectionIDs.contains(collection.id) }, set: { selected in
                            if selected { if !draft.collectionIDs.contains(collection.id) { draft.collectionIDs.append(collection.id) } }
                            else { draft.collectionIDs.removeAll { $0 == collection.id }; draft.collection = "" }
                        }))
                    }
                    Picker("评分", selection: $draft.rating) { ForEach(0...5, id: \.self) { value in Text(value == 0 ? "未评分" : "\(value) 星").tag(value) } }
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

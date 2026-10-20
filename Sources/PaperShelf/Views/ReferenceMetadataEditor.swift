import SwiftUI
import AppKit
import PaperCore

/// The inspector edits one field at a time so unrelated, newer changes survive a save.
struct ReferenceMetadataEditor: View {
    let reference: Reference
    let onUpdate: ((inout Reference) -> Void) -> Bool
    let onRefresh: () -> Void
    var refreshDisabled = false
    var isPreview = false
    @State private var showMore = false
    @State private var newFieldName = ""
    @State private var fieldError = ""

    private let types: [(String, String)] = [
        ("article", "期刊论文"), ("book", "图书"), ("inbook", "书中章节"),
        ("incollection", "文集章节"), ("inproceedings", "会议论文"), ("proceedings", "会议论文集"),
        ("phdthesis", "博士论文"), ("mastersthesis", "硕士论文"), ("techreport", "技术报告"),
        ("online", "网页"), ("dataset", "数据集"), ("software", "软件"),
        ("patent", "专利"), ("manuscript", "手稿"), ("preprint", "预印本"), ("misc", "其他文献")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                InlineReferenceTextField(title: "标题", value: reference.title, prominent: true, required: true) { text in
                    onUpdate { $0.title = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                InlineReferenceTextField(title: "作者", value: reference.authors.joined(separator: "; "), placeholder: "作者姓名；多个作者用分号分隔") { text in
                    onUpdate { $0.authors = text.replacingOccurrences(of: "；", with: ";").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
                }
                Text(isPreview ? "可直接修改下方字段，核对后应用更新。" : "直接点击字段编辑，按回车或离开字段自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    sectionTitle("引用")
                    Spacer()
                    Button(action: onRefresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).help("从 DOI 刷新元数据，核对后保存").disabled(refreshDisabled || isPreview)
                }
                VStack(spacing: 0) {
                    HStack {
                        fieldLabel("类型")
                        Picker("类型", selection: Binding(get: { reference.entryType }, set: { value in _ = onUpdate { $0.entryType = value } })) {
                            ForEach(types, id: \.0) { type in Text(LocalizedStringKey(type.1)).tag(type.0) }
                            if !types.contains(where: { $0.0 == reference.entryType }) { Text(reference.entryType).tag(reference.entryType) }
                        }.labelsHidden().pickerStyle(.menu)
                    }.padding(.vertical, 7)
                    Divider()
                    field("年份", \.year)
                    Divider()
                    field("来源", \.journal)
                    Divider()
                    field("DOI", \.doi, monospaced: true)
                    Divider()
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        field("URL", \.url, monospaced: true)
                        if let url = URL(string: reference.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("打开网址")
                        }
                    }
                    Divider()
                    field("引用键", \.citationKey, monospaced: true)
                }.padding(.horizontal, 12).padding(.vertical, 4).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("出版信息")
                VStack(spacing: 0) {
                    field("卷", \.volume)
                    Divider()
                    field("期", \.issue)
                    Divider()
                    field("页码", \.pages)
                    DisclosureGroup("更多字段", isExpanded: $showMore) {
                        VStack(spacing: 0) {
                            field("出版者", \.publisher)
                            field("ISBN", \.isbn)
                            field("ISSN", \.issn)
                            ForEach(typeFields, id: \.key) { field in extraField(field.key, title: field.label, removable: false) }
                            ForEach(reference.extraFields.keys.filter { !typeFields.map(\.key).contains($0) }.sorted(), id: \.self) { key in
                                extraField(key, title: key, removable: true)
                            }
                            HStack {
                                TextField("新字段名称", text: $newFieldName).textFieldStyle(.roundedBorder).onSubmit(addField)
                                Button("添加", action: addField).disabled(newFieldName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }.padding(.vertical, 8)
                            if !fieldError.isEmpty { Text(LocalizedStringKey(fieldError)).font(.caption).foregroundStyle(.red) }
                        }.padding(.top, 8)
                    }.padding(.vertical, 8)
                }.padding(.horizontal, 12).padding(.vertical, 4).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var typeFields: [(key: String, label: String)] {
        switch reference.entryType {
        case "book", "inbook", "incollection": return [("edition", "版次"), ("series", "系列"), ("booktitle", "书名"), ("editor", "编者"), ("address", "出版地")]
        case "inproceedings", "proceedings": return [("booktitle", "论文集"), ("eventtitle", "会议"), ("eventdate", "会议日期"), ("venue", "会议地点"), ("organization", "主办机构")]
        case "phdthesis", "mastersthesis", "thesis": return [("school", "学校"), ("degree", "学位"), ("address", "地点")]
        case "techreport", "report": return [("institution", "机构"), ("number", "报告编号"), ("address", "地点")]
        case "dataset": return [("repository", "存储库"), ("version", "版本"), ("license", "许可")]
        case "software": return [("repository", "代码仓库"), ("version", "版本"), ("license", "许可"), ("language", "编程语言")]
        case "patent": return [("number", "专利号"), ("assignee", "受让人"), ("country", "国家"), ("filingdate", "申请日期")]
        case "preprint": return [("arxivId", "arXiv 标识符"), ("archiveprefix", "预印本平台"), ("primaryclass", "学科分类")]
        case "online": return [("urldate", "访问日期"), ("organization", "机构"), ("language", "语言")]
        default: return []
        }
    }

    private func field(_ title: String, _ keyPath: WritableKeyPath<Reference, String>, monospaced: Bool = false) -> some View {
        InlineReferenceTextField(title: title, value: reference[keyPath: keyPath], monospaced: monospaced) { text in
            onUpdate { $0[keyPath: keyPath] = text }
        }.padding(.vertical, 7)
    }

    private func extraField(_ key: String, title: String, removable: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            InlineReferenceTextField(title: title, value: reference.extraFields[key] ?? "") { text in
                onUpdate { item in
                    // A disappearing, formerly focused row must not resurrect a removed field.
                    if !removable || item.extraFields[key] != nil { item.extraFields[key] = text }
                }
            }
            if removable {
                Button { _ = onUpdate { $0.extraFields.removeValue(forKey: key) } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless).help("移除字段")
            }
        }.padding(.vertical, 7)
    }

    private func addField() {
        let key = newFieldName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        guard reference.extraFields[key] == nil, !typeFields.contains(where: { $0.key == key }) else { fieldError = "该字段已存在"; return }
        if onUpdate({ $0.extraFields[key] = "" }) { newFieldName = ""; fieldError = "" }
    }
    private func sectionTitle(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
    private func fieldLabel(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading) }
}

/// Synchronously flush visible field drafts before actions that consume their values.
enum InlineReferenceEditing {
    static let commitNotification = Notification.Name("PaperShelf.commitInlineReferenceFields")
    final class Result { var succeeded = true }
    static func commit() -> Bool {
        let result = Result()
        NotificationCenter.default.post(name: commitNotification, object: result)
        return result.succeeded
    }
}

/// A persistent text control: Enter/blur saves, Escape restores the last stored value.
struct InlineReferenceTextField: View {
    let title: String
    let value: String
    var placeholder = "点击填写"
    var monospaced = false
    var prominent = false
    var multiline = false
    var required = false
    let onCommit: (String) -> Bool
    @State private var draft = ""
    @State private var baseline = ""
    @State private var failure = ""
    @State private var commitObservers: [NSObjectProtocol] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if prominent || multiline {
                Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary)
                control
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
                    control
                }
            }
            if !failure.isEmpty {
                HStack {
                    Text(LocalizedStringKey(failure)).font(.caption).foregroundStyle(.red)
                    Button("重试") { commit() }.font(.caption).buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            draft = value
            baseline = value
            installCommitObservers()
        }
        .onChange(of: value) { _, current in
            if draft == baseline { draft = current; baseline = current; failure = "" }
        }
        .onChange(of: focused) { wasFocused, isFocused in if wasFocused && !isFocused { commit() } }
        .onDisappear {
            removeCommitObservers()
            commit()
        }
        .onExitCommand { draft = value; baseline = value; failure = ""; focused = false }
    }

    private func installCommitObservers() {
        guard commitObservers.isEmpty else { return }
        // SwiftUI's onReceive may defer delivery until after the action has read the draft.
        // Direct observers execute before post returns, with the current @State values.
        // The surrounding .id changes with the reference and preview mode, so this
        // callback retains the correct save destination until it is removed.
        commitObservers = [
            NotificationCenter.default.addObserver(forName: InlineReferenceEditing.commitNotification, object: nil, queue: nil) { notification in
                if !commit() { (notification.object as? InlineReferenceEditing.Result)?.succeeded = false }
            },
            NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: nil) { _ in commit() },
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in commit() }
        ]
    }

    private func removeCommitObservers() {
        for observer in commitObservers { NotificationCenter.default.removeObserver(observer) }
        commitObservers = []
    }

    @ViewBuilder private var control: some View {
        if multiline {
            TextEditor(text: $draft).font(.callout).focused($focused).scrollContentBackground(.hidden)
                .frame(minHeight: 110, maxHeight: 240).padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(LocalizedStringKey(title))
        } else {
            TextField(LocalizedStringKey(placeholder), text: $draft, axis: .vertical)
                .textFieldStyle(.plain).font(prominent ? .system(size: 21, weight: .semibold, design: .serif) : monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1...(prominent ? 6 : 4)).focused($focused)
                .accessibilityLabel(LocalizedStringKey(title))
                .onSubmit { commit(); focused = false }
        }
    }

    @discardableResult private func commit() -> Bool {
        guard draft != baseline else { return true }
        guard !required || !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { failure = "标题不能为空"; return false }
        let candidate = draft
        if onCommit(candidate) { baseline = candidate; failure = ""; return true }
        failure = "未能保存，请重试"
        return false
    }
}

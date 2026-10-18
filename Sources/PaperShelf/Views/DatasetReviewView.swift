import SwiftUI
import AppKit
import PaperCore

/// Edits one evidence-backed cell at a time. The caller saves a new audited copy
/// through dataset-review and returns its path; this view never writes a run.
struct DatasetReviewView: View {
    let run: LearningRun
    let apply: (Data, String, String) async throws -> String
    @Environment(\.dismiss) private var dismiss
    @State private var document: ReviewDocument?
    @State private var sourceBlocks: [String: ReviewBlock] = [:]
    @State private var selectedRecord = ""
    @State private var selectedField = ""
    @State private var valueText = ""
    @State private var status = "not_found"
    @State private var unit = ""
    @State private var notes = ""
    @State private var evidenceJSON = "[]"
    @State private var reason = ""
    @State private var actor = NSFullUserName()
    @State private var error: String?
    @State private var savedPath: String?
    @State private var saving = false
    @State private var currentExtractionPath: String

    init(run: LearningRun, initialExtractionPath: String? = nil,
         apply: @escaping (Data, String, String) async throws -> String) {
        self.run = run
        self.apply = apply
        _currentExtractionPath = State(initialValue: initialExtractionPath ?? run.artifacts["extraction"] ?? "")
    }

    private var record: ReviewRecord? { document?.records.first { $0.id == selectedRecord } }
    private var field: ReviewField? { document?.fields.first { $0.name == selectedField } }
    private var cell: ReviewCell? { record?.values[selectedField] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("字段校对").font(.title2.bold())
                    Text(run.title).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
            }
            if let document {
                if document.records.isEmpty || document.fields.isEmpty {
                    ContentUnavailableView("没有可校对的字段", systemImage: "tablecells", description: Text("请先配置自定义字段并生成提取结果。"))
                } else {
                    HStack {
                        Picker("记录", selection: $selectedRecord) {
                            ForEach(document.records) { record in Text(record.label ?? record.id).tag(record.id) }
                        }
                        Picker("字段", selection: $selectedField) {
                            ForEach(document.fields) { field in Text(field.name).tag(field.name) }
                        }
                    }.disabled(saving || savedPath != nil)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            evidenceSection
                            Divider()
                            editor
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else if error == nil {
                ProgressView("正在读取提取结果与原始证据…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("无法读取校对资料", systemImage: "doc.badge.exclamationmark",
                                       description: Text("请检查提取结果与来源文件；详情见下方错误。"))
                Button("重试读取") { Task { await load() } }
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
            Divider()
            HStack {
                if let savedPath {
                    Label("已另存校对版本", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Button("打开结果") { NSWorkspace.shared.open(URL(fileURLWithPath: savedPath)) }
                    Spacer()
                    Button("继续校对此版本") {
                        currentExtractionPath = savedPath
                        self.savedPath = nil
                        Task { await load() }
                    }.buttonStyle(.borderedProminent)
                } else {
                    Text("保存时核验字段类型、枚举和逐字出处，并记录修改前后值与理由。").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if saving { ProgressView().controlSize(.small) }
                    Button("保存校对版本") { save() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("s", modifiers: .command)
                        .disabled(saving || field == nil || record == nil || reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || actor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(22).frame(width: 850, height: 730)
        .interactiveDismissDisabled(saving)
        .task { await load() }
        .onChange(of: selectedRecord) { _, _ in resetEditor() }
        .onChange(of: selectedField) { _, _ in resetEditor() }
    }

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("当前版本值与证据").font(.headline)
            HStack(alignment: .top) {
                Text("当前值").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                Text(cell?.value.display ?? "未提取").textSelection(.enabled)
                Spacer()
                Text(statusLabel(cell?.status ?? "not_found")).font(.caption).foregroundStyle(.secondary)
            }
            if let evidence = cell?.evidence, !evidence.isEmpty {
                ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("第 \(item.page) 页 · \(item.blockID)").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Label(matches(item) ? "出处匹配" : "出处需核对", systemImage: matches(item) ? "checkmark.circle" : "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(matches(item) ? Color.secondary : Color.orange)
                        }
                        Text(item.quote).textSelection(.enabled)
                        if let block = sourceBlocks[item.blockID] {
                            DisclosureGroup("查看来源段落") { Text(block.text).font(.callout).textSelection(.enabled) }
                        }
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Text("此字段没有原文证据。标为有证据时，需要补充来源段落、页码和逐字原句。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("校对内容").font(.headline)
            if let field {
                Text("类型：\(field.type ?? "string")\(field.description.map { " · " + $0 } ?? "")").font(.caption).foregroundStyle(.secondary)
                if let choices = field.choices { Text("允许值：\(choices.map(\.display).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
            }
            HStack {
                Picker("状态", selection: $status) {
                    Text("有证据").tag("supported")
                    Text("未提取").tag("not_found")
                    Text("证据冲突").tag("conflict")
                }
                TextField("原文单位", text: $unit).textFieldStyle(.roundedBorder)
            }
            Text(field?.type == "string" || field?.type == nil ? "字段值（文本）" : "字段值（JSON 格式：数值、布尔、列表或对象）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $valueText).font(.system(.body, design: .monospaced)).frame(minHeight: 70)
                .border(.quaternary).disabled(status == "not_found")
            TextField("校对说明（必填）", text: $reason, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
            HStack {
                TextField("校对人", text: $actor).textFieldStyle(.roundedBorder)
                TextField("备注（可选）", text: $notes).textFieldStyle(.roundedBorder)
            }
            DisclosureGroup("修改证据引用") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("每项包含 block_id、page、quote；原句必须出现在对应来源段落中。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $evidenceJSON).font(.system(.caption, design: .monospaced)).frame(minHeight: 110).border(.quaternary)
                    if !sourceBlocks.isEmpty {
                        DisclosureGroup("全部来源段落") {
                            ForEach(sourceBlocks.values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }) { block in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(block.id) · 第 \(block.page) 页").font(.caption).foregroundStyle(.secondary)
                                    Text(block.text).font(.callout).textSelection(.enabled)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
                            }
                        }
                    }
                }
            }
        }.disabled(saving || savedPath != nil)
    }

    private func load() async {
        error = nil
        document = nil
        sourceBlocks = [:]
        do {
            let extraction = currentExtractionPath
            guard !extraction.isEmpty else { throw LearningError.message("此运行没有提取结果。") }
            let source = run.artifacts["source"] ?? URL(fileURLWithPath: run.directory).appendingPathComponent("source.json").path
            let loaded = try await Task.detached {
                let decoder = JSONDecoder()
                return (try decoder.decode(ReviewDocument.self, from: Data(contentsOf: URL(fileURLWithPath: extraction))),
                        try decoder.decode(ReviewSource.self, from: Data(contentsOf: URL(fileURLWithPath: source))))
            }.value
            let ids = loaded.1.blocks.map(\.id)
            guard Set(ids).count == ids.count else { throw LearningError.message("来源段落编号重复，请检查 source.json。") }
            guard Set(loaded.0.records.map(\.id)).count == loaded.0.records.count,
                  Set(loaded.0.fields.map(\.name)).count == loaded.0.fields.count else {
                throw LearningError.message("提取结果包含重复记录或字段名，请检查 extraction.json。")
            }
            document = loaded.0; sourceBlocks = Dictionary(uniqueKeysWithValues: loaded.1.blocks.map { ($0.id, $0) })
            if !loaded.0.records.contains(where: { $0.id == selectedRecord }) { selectedRecord = loaded.0.records.first?.id ?? "" }
            if !loaded.0.fields.contains(where: { $0.name == selectedField }) { selectedField = loaded.0.fields.first?.name ?? "" }
            resetEditor()
        } catch { self.error = "读取失败：\(error.localizedDescription)" }
    }

    private func resetEditor() {
        valueText = cell?.value.editorText ?? ""
        status = cell?.status ?? "not_found"
        unit = cell?.unit ?? ""
        notes = cell?.notes ?? ""
        reason = ""; error = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        evidenceJSON = (try? String(data: encoder.encode(cell?.evidence ?? []), encoding: .utf8)) ?? "[]"
    }

    private func save() {
        guard !saving, let field else { return }
        error = nil
        do {
            let value: ReviewJSON
            if status == "not_found" { value = .null }
            else if field.type == "string" || field.type == nil { value = .string(valueText) }
            else { value = try JSONDecoder().decode(ReviewJSON.self, from: Data(valueText.utf8)) }
            let evidence = try JSONDecoder().decode([ReviewEvidence].self, from: Data(evidenceJSON.utf8))
            let cell = ReviewCell(value: value, status: status, evidence: evidence, unit: unit, notes: notes)
            let correction = ReviewCorrection(recordID: selectedRecord, field: selectedField, reason: reason, after: cell)
            let data = try JSONEncoder().encode([correction])
            saving = true
            Task {
                defer { saving = false }
                do { savedPath = try await apply(data, actor, currentExtractionPath) }
                catch { self.error = error.localizedDescription }
            }
        } catch { self.error = "校对内容格式错误：\(error.localizedDescription)" }
    }

    private func matches(_ evidence: ReviewEvidence) -> Bool {
        guard let block = sourceBlocks[evidence.blockID], block.page == evidence.page else { return false }
        let normalize: (String) -> String = { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        return !evidence.quote.isEmpty && normalize(block.text).contains(normalize(evidence.quote))
    }
    private func statusLabel(_ status: String) -> String { ["supported": "有证据", "not_found": "未提取", "conflict": "证据冲突"][status] ?? status }
}

private struct ReviewDocument: Decodable, Sendable { let fields: [ReviewField]; let records: [ReviewRecord] }
private struct ReviewSource: Decodable, Sendable { let blocks: [ReviewBlock] }
private struct ReviewBlock: Decodable, Identifiable, Sendable { let id: String; let page: Int; let text: String }
private struct ReviewField: Decodable, Identifiable, Sendable {
    var id: String { name }
    let name: String
    let type: String?
    let description: String?
    let choices: [ReviewJSON]?
    enum CodingKeys: String, CodingKey { case name, type, description; case choices = "enum" }
}
private struct ReviewRecord: Decodable, Identifiable, Sendable { let id: String; let label: String?; let values: [String: ReviewCell] }
private struct ReviewCell: Codable, Sendable { let value: ReviewJSON; let status: String; let evidence: [ReviewEvidence]; let unit: String?; let notes: String? }
private struct ReviewEvidence: Codable, Sendable {
    let blockID: String; let page: Int; let quote: String
    enum CodingKeys: String, CodingKey { case blockID = "block_id"; case page, quote }
}
private struct ReviewCorrection: Encodable {
    let recordID: String; let field: String; let reason: String; let after: ReviewCell
    enum CodingKeys: String, CodingKey { case recordID = "record_id"; case field, reason, after }
}
private indirect enum ReviewJSON: Codable, Sendable {
    case string(String), number(Decimal), bool(Bool), array([ReviewJSON]), object([String: ReviewJSON]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Decimal.self) { self = .number(value) }
        else if let value = try? c.decode([ReviewJSON].self) { self = .array(value) }
        else { self = .object(try c.decode([String: ReviewJSON].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .object(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }
    var editorText: String {
        if case .string(let value) = self { return value }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "null"
    }
    var display: String { if case .null = self { return "未提取" }; return editorText }
}

import Foundation

public enum LearningOutput: String, CaseIterable, Codable, Identifiable, Sendable {
    case guide, markdown, source, dataset, agent, presentation
    public var id: String { rawValue }
}

public struct ExtractionField: Codable, Identifiable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var type: String
    public var description: String
    public var required: Bool
    public var unit: String
    public var constraints: [String: JSONValue] = [:]
    public var choices: [String]? {
        get {
            guard case .array(let values) = constraints["enum"] else { return nil }
            let strings = values.compactMap { value -> String? in if case .string(let text) = value { return text }; return nil }
            return strings.count == values.count ? strings : nil
        }
        set { constraints["enum"] = newValue.map { .array($0.map(JSONValue.string)) } }
    }
    enum CodingKeys: String, CodingKey { case name, type, description, required, unit; case choices = "enum" }
    public init(name: String, type: String = "string", description: String = "", required: Bool = false, unit: String = "", choices: [String]? = nil) {
        self.name = name; self.type = type; self.description = description; self.required = required; self.unit = unit
        self.choices = choices
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decodeIfPresent(String.self, forKey: .type) ?? "string"
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? false
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
        var raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        for key in ["name", "type", "description", "required", "unit"] { raw.removeValue(forKey: key) }
        constraints = raw
    }
    public func encode(to encoder: Encoder) throws {
        var raw = constraints
        raw["name"] = .string(name); raw["type"] = .string(type); raw["description"] = .string(description)
        raw["required"] = .bool(required); raw["unit"] = .string(unit)
        var c = encoder.singleValueContainer(); try c.encode(raw)
    }
    public static let defaults: [Self] = [
        .init(name: "research_question", description: "研究问题与目标"),
        .init(name: "method", description: "实验方法、模型与适用条件"),
        .init(name: "findings", type: "array", description: "主要结论；保留原始数值和单位"),
        .init(name: "limitations", type: "array", description: "作者报告的局限与尚待验证的问题")
    ]
    public static func validate(_ fields: [Self]) throws {
        var names = Set<String>()
        for field in fields {
            let name = field.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name == field.name, names.insert(name).inserted else {
                throw LearningError.message("字段名不能为空、带首尾空格或重复。")
            }
            guard ["string", "number", "integer", "boolean", "array", "object"].contains(field.type) else {
                throw LearningError.message("字段 \(name) 的类型不受支持。")
            }
        }
    }
}

public enum LearningError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public struct LearningRun: Codable, Identifiable, Sendable {
    public var id: String { runID }
    public var referenceID: String
    public var title: String
    public var createdAt: Date
    public var runID: String
    public var directory: String
    public var manifestPath: String
    public var artifacts: [String: String]
    public var warnings: [String]
    public var mode: String
    public var status: String?
    public var revisionOf: String?
    public var revisionKind: String?
    public var outputs: [String]?
    public var statusLabel: String {
        switch status {
        case "failed": return "失败"
        case "cancelled": return "已取消"
        case "interrupted", "running": return "未完成"
        case "partial": return "部分完成"
        default:
            if revisionKind == "source_reviewed_revision" { return "原页校核版" }
            return mode == "offline" ? "草稿" : (revisionOf == nil ? "AI 精读" : "AI 校订")
        }
    }

    /// Recover the backend receipt independently of the UI history write.
    public static func recover(manifest data: Data, directory: URL) throws -> LearningRun? {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = value["run_id"] as? String,
              let reference = value["reference_id"] as? String, !reference.isEmpty else { return nil }
        let state = value["status"] as? String ?? "interrupted"
        var warnings = value["warnings"] as? [String] ?? []
        if let error = value["error"] as? String { warnings.append(error) }
        if state == "running" { warnings.append("上次运行未留下结束记录，可查看日志或重新生成。") }
        var run = LearningRun(referenceID: reference, title: value["title"] as? String ?? "未命名文献", runID: id,
                              directory: directory.path, manifestPath: directory.appendingPathComponent("manifest.json").path,
                              artifacts: value["artifacts"] as? [String: String] ?? [:], warnings: warnings,
                              mode: value["mode"] as? String ?? "offline", status: state == "running" ? "interrupted" : state)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let text = value["created_at"] as? String, let date = formatter.date(from: text) { run.createdAt = date }
        run.revisionOf = value["revision_of"] as? String
        run.revisionKind = value["revision_kind"] as? String
        run.outputs = value["outputs"] as? [String]
        return run
    }
    public init(referenceID: String, title: String, runID: String, directory: String, manifestPath: String, artifacts: [String: String], warnings: [String], mode: String, status: String = "completed") {
        self.referenceID = referenceID; self.title = title; self.createdAt = Date(); self.runID = runID
        self.directory = directory; self.manifestPath = manifestPath; self.artifacts = artifacts; self.warnings = warnings; self.mode = mode
        self.status = status
    }
}

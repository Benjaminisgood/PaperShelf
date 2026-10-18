import Foundation

public enum ReferenceEditError: LocalizedError {
    case identity, conflict(String)
    public var errorDescription: String? {
        switch self {
        case .identity: return "文献标识已改变，请重新打开编辑器。"
        case .conflict(let field): return "字段 \(field) 在编辑期间已被其他操作修改。请重新打开编辑器核对。"
        }
    }
}

public enum ReferenceEdits {
    /// Apply only editor changes. Unrelated API updates, file placement and reading state survive.
    public static func merge(base: Reference, edited: Reference, current: Reference) throws -> Reference {
        guard base.id == edited.id, base.id == current.id else { throw ReferenceEditError.identity }
        func object(_ value: Reference) throws -> [String: Any] { try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any] }
        func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return NSDictionary(dictionary: ["value": lhs]).isEqual(to: ["value": rhs])
        }
        func merge(_ original: [String: Any], _ draft: [String: Any], _ latest: [String: Any], prefix: String = "") throws -> [String: Any] {
            var result = latest
            for key in Set(original.keys).union(draft.keys) where !equal(original[key], draft[key]) {
                if let a = original[key] as? [String: Any], let b = draft[key] as? [String: Any], let c = latest[key] as? [String: Any] {
                    result[key] = try merge(a, b, c, prefix: prefix + key + ".")
                } else {
                    guard equal(latest[key], original[key]) || equal(latest[key], draft[key]) else { throw ReferenceEditError.conflict(prefix + key) }
                    result[key] = draft[key]
                }
            }
            return result
        }
        let result = try merge(object(base), object(edited), object(current))
        return try JSONDecoder().decode(Reference.self, from: JSONSerialization.data(withJSONObject: result))
    }
}

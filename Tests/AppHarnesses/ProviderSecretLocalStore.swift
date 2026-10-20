import Foundation

@main struct ProviderSecretLocalStoreCheck {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("papershelf-credential-fixtures-\(UUID().uuidString)", isDirectory: true)
        let file = root.appendingPathComponent("nested/provider-credentials.json")
        defer { try? FileManager.default.removeItem(at: root) }
        let absent = try ProviderSecret.loadSaved(account: "api-key", at: file)
        precondition(absent == nil)
        try ProviderSecret.saveSaved("fixture-provider", account: "api-key", at: file)
        try ProviderSecret.saveSaved("fixture-graph", account: "graph-api-key", at: file)
        let provider = try ProviderSecret.loadSaved(account: "api-key", at: file)
        let graph = try ProviderSecret.loadSaved(account: "graph-api-key", at: file)
        precondition(provider == "fixture-provider" && graph == "fixture-graph")
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        precondition(permissions?.intValue == 0o600)

        try ProviderSecret.saveSaved("", account: "api-key", at: file)
        let cleared = try ProviderSecret.loadSaved(account: "api-key", at: file)
        precondition(cleared == "")
        let preservedClear = try ProviderSecret.migrateLegacy("fixture-old-provider", account: "api-key", at: file)
        let preservedReplacement = try ProviderSecret.migrateLegacy("fixture-old-graph", account: "graph-api-key", at: file)
        let imported = try ProviderSecret.migrateLegacy("fixture-password", account: "graph-password", at: file)
        precondition(preservedClear == "" && preservedReplacement == "fixture-graph" && imported == "fixture-password")

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask { try ProviderSecret.saveSaved("fixture-\(index)", account: "concurrent-\(index)", at: file) }
            }
            try await group.waitForAll()
        }
        for index in 0..<40 {
            let value = try ProviderSecret.loadSaved(account: "concurrent-\(index)", at: file)
            precondition(value == "fixture-\(index)")
        }

        let malformed = Data("[\"fixture-invalid-shape\"]".utf8)
        try malformed.write(to: file, options: .atomic)
        do {
            try ProviderSecret.saveSaved("fixture-new", account: "api-key", at: file)
            preconditionFailure("Malformed files must not be overwritten")
        } catch { }
        let unchanged = try Data(contentsOf: file)
        precondition(unchanged == malformed)
        print("Local credential fixture checks passed: persistence, per-account merge, explicit clear, safe legacy migration, concurrent saves, file permissions, and malformed-file preservation.")
    }
}

import Foundation
import Security
import LocalAuthentication

enum ProviderSecret {
    private static let fileQueue = DispatchQueue(label: "local.papershelf.provider-credentials")

    private static var service: String {
        Bundle.main.bundleIdentifier == "local.papershelf.qa" ? "local.papershelf.qa.provider" : "local.papershelf.provider"
    }

    static var localFile: URL {
        let directory: URL
        if let path = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"], !path.isEmpty {
            directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        } else if let path = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_DIR"], !path.isEmpty {
            directory = URL(fileURLWithPath: path, isDirectory: true)
        } else if Bundle.main.bundleIdentifier == "local.papershelf.qa" {
            directory = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("library", isDirectory: true)
        } else {
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PaperShelf", isDirectory: true)
        }
        return directory.appendingPathComponent("provider-credentials.json")
    }

    static func load(account: String = "api-key") throws -> String {
        let file = localFile
        if let saved = try loadSaved(account: account, at: file) { return saved }
        // Legacy reads are deliberately outside fileQueue: a stalled keychain
        // must never hold up a new form save or a local credential read.
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: authentication]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderSecretError("旧凭据暂时无法读取（\(status)）；请在设置中直接填写并保存。")
        }
        let value = String(data: data, encoding: .utf8) ?? ""
        return value.isEmpty ? value : try migrateLegacy(value, account: account, at: file)
    }

    static func save(_ value: String, account: String = "api-key") throws {
        try saveSaved(value, account: account, at: localFile)
    }

    /// An empty saved value is an explicit clear, distinct from an absent key.
    /// Keeping that entry prevents a cleared legacy keychain value resurfacing.
    static func loadSaved(account: String, at file: URL) throws -> String? {
        try fileQueue.sync { try readSaved(at: file)[account] }
    }

    static func saveSaved(_ value: String, account: String, at file: URL) throws {
        try fileQueue.sync {
            var saved = try readSaved(at: file)
            saved[account] = value
            try writeSaved(saved, at: file)
        }
    }

    /// A legacy read may finish after the user saves a replacement or clears
    /// the field. Recheck under the file queue before importing that old value.
    static func migrateLegacy(_ value: String, account: String, at file: URL) throws -> String {
        try fileQueue.sync {
            var saved = try readSaved(at: file)
            if let current = saved[account] { return current }
            guard !value.isEmpty else { return "" }
            saved[account] = value
            try writeSaved(saved, at: file)
            return value
        }
    }

    private static func writeSaved(_ saved: [String: String], at file: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(saved).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            throw ProviderSecretError("无法保存本地凭据，请检查设置目录的写入权限：\(file.deletingLastPathComponent().path)")
        }
    }

    private static func readSaved(at file: URL) throws -> [String: String] {
        let data: Data
        do { data = try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return [:] }
        catch { throw ProviderSecretError("无法读取本地凭据，请检查文件权限：\(file.path)") }
        do { return try JSONDecoder().decode([String: String].self, from: data) }
        catch {
            throw ProviderSecretError("本地凭据文件格式有误，未覆盖原文件。请修正或移走该文件后重新保存：\(file.path)")
        }
    }
}

private struct ProviderSecretError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

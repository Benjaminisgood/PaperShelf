import Foundation
import CryptoKit

public struct LibraryBackupFile: Codable, Equatable, Sendable {
    public var referenceID: UUID
    public var attachmentID: UUID?
    public var originalPath: String
    public var relativePath: String
    public var sha256: String
}

public struct LibraryBackupManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var databaseSchemaVersion: Int
    public var createdAt: Date
    public var referenceCount: Int
    public var collectionCount: Int
    public var databaseSHA256: String
    public var attachments: [LibraryBackupFile]
    public var warnings: [String]
    public var preferencesSHA256: String? = nil
}

public struct LibraryRestoreResult: Equatable, Sendable {
    public var restoredReferences: Int
    public var restoredCollections: Int
    public var safetyBackupURL: URL
    public var attachmentsDirectory: URL?
    public var warnings: [String]
    public var restoredPreferencesData: Data? = nil
}

public enum LibraryBackupError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let detail): return "备份未通过验证：\(detail)" }
    }
}

public enum LibraryBackup {
    /// Writes a new directory atomically. Existing backups are never overwritten.
    public static func create(database: LibraryDatabase, to destination: URL, includeAttachments: Bool = true, preferencesURL: URL? = nil) throws -> LibraryBackupManifest {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw LibraryBackupError.invalid("目标已存在。") }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let snapshotURL = staging.appendingPathComponent("library.sqlite")
        try database.snapshot(to: snapshotURL)
        // Read the snapshot, rather than a second live query that could have changed.
        let content = try readSnapshot(snapshotURL)
        var copied: [LibraryBackupFile] = []
        var warnings: [String] = []
        if includeAttachments {
            try files.createDirectory(at: staging.appendingPathComponent("attachments"), withIntermediateDirectories: false)
            for reference in content.references {
                var paths: [(UUID?, String, URL)] = reference.pdfPath.map { path in
                    [(nil, path, (try? PDFLinks.resolvedURL(for: reference)) ?? URL(fileURLWithPath: path))]
                } ?? []
                paths += reference.attachments.map { (Optional($0.id), $0.path, (try? PaperAttachments.resolvedURL(for: $0)) ?? URL(fileURLWithPath: $0.path)) }
                for (attachmentID, path, original) in paths {
                    let access = original.startAccessingSecurityScopedResource()
                    defer { if access { original.stopAccessingSecurityScopedResource() } }
                    let resource = try? original.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
                    guard resource?.isRegularFile == true, resource?.isReadable == true else {
                        warnings.append("未包含不可读附件：\(path)"); continue
                    }
                    // Paths in the manifest preserve the original filename. Opaque backup names
                    // stay below filesystem limits even when the original name uses all 255 bytes.
                    let suffix = String(original.pathExtension.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
                    let filename = "\(reference.id.uuidString)-\(attachmentID?.uuidString ?? "primary")" + (suffix.isEmpty ? "" : "." + suffix)
                    let relative = "attachments/" + filename
                    let target = staging.appendingPathComponent(relative)
                    // Copy through bytes to avoid preserving symbolic links into the source library.
                    try copyRegularFile(from: original, to: target)
                    copied.append(LibraryBackupFile(referenceID: reference.id, attachmentID: attachmentID,
                                                    originalPath: path, relativePath: relative, sha256: try hash(target)))
                }
            }
        }
        var preferencesHash: String?
        if let preferencesURL, files.fileExists(atPath: preferencesURL.path) {
            let data = try Data(contentsOf: preferencesURL)
            _ = try preferenceObject(data)
            let target = staging.appendingPathComponent("preferences.json")
            try data.write(to: target, options: .atomic); preferencesHash = try hash(target)
        }
        let manifest = LibraryBackupManifest(formatVersion: 1, databaseSchemaVersion: LibraryDatabase.schemaVersion,
                                             createdAt: Date(), referenceCount: content.references.count,
                                             collectionCount: content.collections.count, databaseSHA256: try hash(snapshotURL),
                                             attachments: copied, warnings: warnings, preferencesSHA256: preferencesHash)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try files.moveItem(at: staging, to: destination)
        return manifest
    }

    /// Validates everything first, saves current data, then commits the replacement in one transaction.
    /// Attachments go into a fresh child of attachmentDirectory, or backupDirectory by default.
    public static func restore(from source: URL, into database: LibraryDatabase, backupDirectory: URL, preferencesURL: URL? = nil, attachmentDirectory: URL? = nil) throws -> LibraryRestoreResult {
        let files = FileManager.default
        let source = source.standardizedFileURL
        try rejectSymlink(source)
        let manifestURL = try safeFile("manifest.json", in: source)
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.formatVersion == 1, (1...LibraryDatabase.schemaVersion).contains(manifest.databaseSchemaVersion) else {
            throw LibraryBackupError.invalid("此备份来自不支持的版本。")
        }
        let snapshot = try safeFile("library.sqlite", in: source)
        guard try hash(snapshot) == manifest.databaseSHA256 else { throw LibraryBackupError.invalid("数据库校验值不匹配。") }
        let temporary = files.temporaryDirectory.appendingPathComponent("PaperShelf-restore-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: temporary) }
        let working = temporary.appendingPathComponent("library.sqlite")
        try files.copyItem(at: snapshot, to: working)
        guard try hash(working) == manifest.databaseSHA256 else { throw LibraryBackupError.invalid("读取时备份数据库发生变化。") }
        var content = try readSnapshot(working)
        guard content.references.count == manifest.referenceCount, content.collections.count == manifest.collectionCount else {
            throw LibraryBackupError.invalid("备份记录数量不匹配。")
        }
        var restoredPreferences: Data?
        if let expectedHash = manifest.preferencesSHA256 {
            let file = try safeFile("preferences.json", in: source)
            let data = try Data(contentsOf: file)
            guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedHash else { throw LibraryBackupError.invalid("设置校验值不匹配。") }
            var object = try preferenceObject(data)
            // A backup must not grant local API/network/file access permissions.
            object.removeValue(forKey: "localAPI")
            restoredPreferences = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        }
        let referenceLookup = Dictionary(uniqueKeysWithValues: content.references.enumerated().map { ($0.element.id, $0.offset) })
        var seen = Set<String>()
        for attachment in manifest.attachments {
            guard let index = referenceLookup[attachment.referenceID] else { throw LibraryBackupError.invalid("附件指向不存在的文献。") }
            let record = content.references[index]
            let stored = attachment.attachmentID.flatMap { id in record.attachments.first { $0.id == id }?.path } ?? (attachment.attachmentID == nil ? record.pdfPath : nil)
            guard stored == attachment.originalPath else { throw LibraryBackupError.invalid("附件与文献不匹配。") }
            let identity = attachment.referenceID.uuidString + (attachment.attachmentID?.uuidString ?? "primary")
            guard seen.insert(identity).inserted else { throw LibraryBackupError.invalid("附件条目重复。") }
            let file = try safeFile(attachment.relativePath, in: source)
            guard try hash(file) == attachment.sha256 else { throw LibraryBackupError.invalid("附件校验值不匹配：\(attachment.relativePath)") }
        }
        try files.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let safety = backupDirectory.appendingPathComponent("BeforeRestore-\(token).papershelfbackup", isDirectory: true)
        _ = try create(database: database, to: safety, preferencesURL: preferencesURL)
        let attachmentRoot = (attachmentDirectory ?? backupDirectory).standardizedFileURL
        let attachmentAccess = attachmentRoot.startAccessingSecurityScopedResource()
        defer { if attachmentAccess { attachmentRoot.stopAccessingSecurityScopedResource() } }
        let restoredDirectory = manifest.attachments.isEmpty ? nil : attachmentRoot.appendingPathComponent("RestoredAttachments-\(token)", isDirectory: true)
        if let directory = restoredDirectory {
            try files.createDirectory(at: attachmentRoot, withIntermediateDirectories: true)
            try files.createDirectory(at: directory, withIntermediateDirectories: false)
            for attachment in manifest.attachments {
                let file = try safeFile(attachment.relativePath, in: source)
                let destination = directory.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
                try files.copyItem(at: file, to: destination)
                guard try hash(destination) == attachment.sha256 else { throw LibraryBackupError.invalid("恢复附件复制校验失败。安全副本已保留。") }
                let index = referenceLookup[attachment.referenceID]!
                if let id = attachment.attachmentID, let attachmentIndex = content.references[index].attachments.firstIndex(where: { $0.id == id }) {
                    content.references[index].attachments[attachmentIndex].path = destination.path
                    content.references[index].attachments[attachmentIndex].bookmark = nil
                } else {
                    content.references[index].pdfPath = destination.path
                    content.references[index].pdfBookmark = nil
                }
            }
        }
        do { try database.replaceAll(with: content) }
        catch { throw LibraryBackupError.invalid("恢复事务已回滚。恢复前安全副本位于 \(safety.path)。\n\(error.localizedDescription)") }
        return LibraryRestoreResult(restoredReferences: content.references.count, restoredCollections: content.collections.count,
                                    safetyBackupURL: safety, attachmentsDirectory: restoredDirectory, warnings: manifest.warnings,
                                    restoredPreferencesData: restoredPreferences)
    }

    private static func preferenceObject(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LibraryBackupError.invalid("设置必须为 JSON 对象。") }
        if let templates = object["templates"] {
            let encoded = try JSONSerialization.data(withJSONObject: templates)
            _ = try JSONDecoder().decode(PaperExportTemplates.self, from: encoded)
        }
        return object
    }

    private static func readSnapshot(_ url: URL) throws -> LibraryImport {
        let database = try LibraryDatabase(url: url)
        return try LibraryImport(references: database.load(), collections: database.loadCollections(), tags: database.loadTags())
    }

    private static func safeFile(_ relative: String, in root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !relative.contains("\\"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw LibraryBackupError.invalid("非法备份路径。") }
        var url = root
        for component in components { url.appendPathComponent(String(component)); try rejectSymlink(url) }
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw LibraryBackupError.invalid("备份内容不是普通文件。") }
        return url
    }

    private static func rejectSymlink(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryBackupError.invalid("备份中不允许符号链接。") }
    }

    private static func copyRegularFile(from source: URL, to target: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw LibraryBackupError.invalid("无法复制附件。") }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        while let block = try input.read(upToCount: 1_048_576), !block.isEmpty { try output.write(contentsOf: block) }
        try output.synchronize()
    }

    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

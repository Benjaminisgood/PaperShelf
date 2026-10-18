import Foundation
import CSQLite
import CryptoKit

public enum ZoteroImportError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return "无法导入 Zotero 数据库：\(message)" }
    }
}

/// Reads a temporary copy of the database and WAL; the user's Zotero files are never opened for writing.
public enum ZoteroImporter {
    public static func read(url: URL, storageDirectory: URL? = nil, linkedAttachmentDirectory: URL? = nil, includeAttachments: Bool = true) throws -> LibraryImport {
        try Task.checkCancellation()
        let manager = FileManager.default
        let storageAccess = storageDirectory?.startAccessingSecurityScopedResource() ?? false
        let linkedAccess = linkedAttachmentDirectory?.startAccessingSecurityScopedResource() ?? false
        defer {
            if storageAccess { storageDirectory?.stopAccessingSecurityScopedResource() }
            if linkedAccess { linkedAttachmentDirectory?.stopAccessingSecurityScopedResource() }
        }
        let temporary = manager.temporaryDirectory.appendingPathComponent("PaperShelf-Zotero-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("zotero.sqlite")
        let wal = URL(fileURLWithPath: url.path + "-wal")
        var copied = false
        for _ in 0..<3 {
            try Task.checkCancellation()
            let before = try signatures([url, wal])
            try? manager.removeItem(at: snapshot)
            try? manager.removeItem(atPath: snapshot.path + "-wal")
            try manager.copyItem(at: url, to: snapshot)
            if manager.fileExists(atPath: wal.path) { try manager.copyItem(at: wal, to: URL(fileURLWithPath: snapshot.path + "-wal")) }
            if before == (try signatures([url, wal])) { copied = true; break }
        }
        guard copied else { throw ZoteroImportError.invalid("数据库正在变化。请暂停 Zotero 同步或关闭 Zotero 后重试。") }
        try Task.checkCancellation()
        let database = try Reader(snapshot)
        guard try database.rows("PRAGMA quick_check").first?.values.first == "ok" else { throw ZoteroImportError.invalid("数据库快照不完整。请关闭 Zotero 后重试。") }
        for table in ["items", "itemTypes", "itemData", "fields", "itemDataValues"] where !(try database.hasTable(table)) {
            throw ZoteroImportError.invalid("缺少 Zotero 表 \(table)。请选择 zotero.sqlite。")
        }
        let itemRows = try database.rows("SELECT i.*, t.typeName AS itemType FROM items i JOIN itemTypes t ON i.itemTypeID=t.itemTypeID ORDER BY i.itemID")
        let fields = try database.rows("SELECT d.itemID, f.fieldName, v.value FROM itemData d JOIN fields f ON d.fieldID=f.fieldID JOIN itemDataValues v ON d.valueID=v.valueID")
        var itemFields: [String: [String: String]] = [:]
        for field in fields { if let id = field["itemID"], let key = field["fieldName"] { itemFields[id, default: [:]][key] = field["value"] ?? "" } }
        let deleted = try database.hasTable("deletedItems") ? Set(database.rows("SELECT itemID FROM deletedItems").compactMap { $0["itemID"] }) : []
        var creators: [String: [String]] = [:]
        var creatorDetails: [String: [[String: String]]] = [:]
        if try database.hasTable("itemCreators"), try database.hasTable("creators") {
            let hasRoles = try database.hasTable("creatorTypes")
            let query = hasRoles
                ? "SELECT ic.itemID, c.*, ct.creatorType AS role FROM itemCreators ic JOIN creators c ON ic.creatorID=c.creatorID LEFT JOIN creatorTypes ct ON ic.creatorTypeID=ct.creatorTypeID ORDER BY ic.itemID, ic.orderIndex"
                : "SELECT ic.itemID, c.* FROM itemCreators ic JOIN creators c ON ic.creatorID=c.creatorID ORDER BY ic.itemID, ic.orderIndex"
            for row in try database.rows(query) {
                if let id = row["itemID"] {
                    let name = [row["lastName"] ?? "", row["firstName"] ?? ""].filter { !$0.isEmpty }.joined(separator: ", ")
                    if !name.isEmpty {
                        creatorDetails[id, default: []].append(["name": name, "role": row["role"] ?? "author"])
                        if !hasRoles || row["role"] == "author" { creators[id, default: []].append(name) }
                    }
                }
            }
        }
        var tags: [String: [String]] = [:]
        if try database.hasTable("tags"), try database.hasTable("itemTags") {
            for row in try database.rows("SELECT it.itemID, t.name FROM itemTags it JOIN tags t ON it.tagID=t.tagID ORDER BY t.name") {
                if let id = row["itemID"], let name = row["name"] { tags[id, default: []].append(name) }
            }
        }
        let collectionRows = try database.hasTable("collections") ? database.rows("SELECT * FROM collections ORDER BY collectionID") : []
        var collectionIDs: [String: UUID] = [:]
        for row in collectionRows {
            if let id = row["collectionID"] { collectionIDs[id] = stableID("collection", library: row["libraryID"], key: row["key"] ?? url.path + ":" + id) }
        }
        var warnings: [String] = []
        for row in collectionRows {
            if let parent = row["parentCollectionID"], collectionIDs[parent] == nil { throw ZoteroImportError.invalid("集合的父节点不存在：\(parent)") }
        }
        let collections = collectionRows.compactMap { row -> LibraryCollection? in
            guard let id = row["collectionID"], let uuid = collectionIDs[id], let name = row["collectionName"] else { return nil }
            return LibraryCollection(id: uuid, name: name, parentID: row["parentCollectionID"].flatMap { collectionIDs[$0] })
        }
        var memberships: [String: [UUID]] = [:]
        if try database.hasTable("collectionItems") {
            for row in try database.rows("SELECT collectionID, itemID FROM collectionItems ORDER BY collectionID") {
                if let id = row["itemID"], let key = row["collectionID"], let collectionID = collectionIDs[key] { memberships[id, default: []].append(collectionID) }
            }
        }
        let noteRows = try database.hasTable("itemNotes") ? database.rows("SELECT * FROM itemNotes ORDER BY itemID") : []
        var notes: [String: [String]] = [:]
        for row in noteRows {
            guard let id = row["itemID"], !deleted.contains(id), let parent = row["parentItemID"], let text = row["note"] else { continue }
            notes[parent, default: []].append(plainText(text))
        }
        let typeMap = ["journalArticle": "article", "book": "book", "bookSection": "incollection", "conferencePaper": "inproceedings", "thesis": "phdthesis", "report": "techreport", "webpage": "online", "preprint": "misc"]
        var references: [Reference] = []
        var indices: [String: Int] = [:]
        for row in itemRows {
            try Task.checkCancellation()
            guard let id = row["itemID"], !deleted.contains(id), let kind = row["itemType"], kind != "attachment", kind != "annotation", kind != "note" else { continue }
            let data = itemFields[id] ?? [:]
            let date = data["date"] ?? ""
            let year = date.range(of: "(?:1[0-9]{3}|20[0-9]{2}|21[0-9]{2})", options: .regularExpression).map { String(date[$0]) } ?? ""
            let key = row["key"] ?? url.path + ":" + id
            var extra = data
            extra["zoteroKey"] = row["key"] ?? ""
            extra["zoteroItemType"] = kind
            extra["zoteroLibraryID"] = row["libraryID"] ?? ""
            if let details = creatorDetails[id], let data = try? JSONEncoder().encode(details) { extra["zoteroCreators"] = String(data: data, encoding: .utf8) }
            let added = parseDate(row["dateAdded"] ?? "") ?? Date(timeIntervalSince1970: 0)
            let citekey = (data["extra"] ?? "").components(separatedBy: .newlines).first(where: { $0.lowercased().hasPrefix("citation key:") }).map { String($0.dropFirst("citation key:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
            indices[id] = references.count
            references.append(Reference(id: stableID("item", library: row["libraryID"], key: key), title: data["title"] ?? "",
                                        authors: creators[id] ?? [], year: year, journal: data["publicationTitle"] ?? data["bookTitle"] ?? data["proceedingsTitle"] ?? "",
                                        doi: data["DOI"] ?? "", url: data["url"] ?? "", abstract: data["abstractNote"] ?? "",
                                        notes: (notes[id] ?? []).joined(separator: "\n\n"), tags: tags[id] ?? [], addedAt: added,
                                        citationKey: citekey, entryType: typeMap[kind] ?? "misc", volume: data["volume"] ?? "", issue: data["issue"] ?? "",
                                        pages: data["pages"] ?? "", publisher: data["publisher"] ?? "", isbn: data["ISBN"] ?? "", issn: data["ISSN"] ?? "",
                                        extraFields: extra, collectionIDs: memberships[id] ?? []))
        }
        if includeAttachments, try database.hasTable("itemAttachments") {
            let rowsByID = Dictionary(uniqueKeysWithValues: itemRows.compactMap { row in row["itemID"].map { ($0, row) } })
            for row in try database.rows("SELECT * FROM itemAttachments ORDER BY itemID") {
                try Task.checkCancellation()
                guard let id = row["itemID"], !deleted.contains(id), let parent = row["parentItemID"], let index = indices[parent], let raw = row["path"], !raw.isEmpty else { continue }
                let key = rowsByID[id]?["key"] ?? ""
                let path: URL
                if raw.hasPrefix("storage:") {
                    let filename = String(raw.dropFirst("storage:".count))
                    let root = storageDirectory ?? url.deletingLastPathComponent().appendingPathComponent("storage")
                    guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                          let resolved = relativeAttachment(key + "/" + filename, in: root), !filename.hasPrefix("/") else {
                        warnings.append("跳过非法 Zotero 附件路径：\(raw)"); continue
                    }
                    path = resolved
                } else if raw.hasPrefix("attachments:") {
                    guard let root = linkedAttachmentDirectory else {
                        warnings.append("外部链接附件需要选择 Zotero 链接附件根目录：\(raw)"); continue
                    }
                    guard let resolved = relativeAttachment(String(raw.dropFirst("attachments:".count)), in: root) else {
                        warnings.append("跳过超出授权目录或非法 Zotero 附件路径：\(raw)"); continue
                    }
                    path = resolved
                } else if raw.hasPrefix("/") {
                    path = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
                    if let root = linkedAttachmentDirectory, !isDescendant(path, of: root) {
                        warnings.append("外部附件不在授权目录内：\(raw)"); continue
                    }
                } else { warnings.append("无法解析 Zotero 相对附件路径：\(raw)。请选择链接附件根目录，或在 Zotero 中使用绝对路径。"); continue }
                guard manager.isReadableFile(atPath: path.path), (try? path.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { warnings.append("附件不可读：\(path.path)"); continue }
                if (row["contentType"] == "application/pdf" || path.pathExtension.lowercased() == "pdf"), references[index].pdfPath == nil {
                    references[index].pdfPath = path.path
                } else {
                    references[index].attachments.append(ReferenceAttachment(id: stableID("attachment", library: rowsByID[id]?["libraryID"], key: key.isEmpty ? url.path + ":" + id : key), name: itemFields[id]?["title"] ?? path.lastPathComponent, path: path.path,
                                                                            addedAt: parseDate(rowsByID[id]?["dateAdded"] ?? "") ?? Date(timeIntervalSince1970: 0)))
                }
            }
        }
        let standaloneNotes = noteRows.filter { $0["parentItemID"] == nil && !deleted.contains($0["itemID"] ?? "") }.count
        if standaloneNotes > 0 { warnings.append("\(standaloneNotes) 条独立 Zotero 笔记不是文献条目；未导入。") }
        return LibraryImport(references: references, collections: collections, tags: Set(tags.values.flatMap { $0 }).sorted().map { LibraryTag(name: $0) }, warnings: warnings)
    }

    private static func relativeAttachment(_ relative: String, in root: URL) -> URL? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !relative.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let path = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        return isDescendant(path, of: root) ? path : nil
    }

    private static func isDescendant(_ path: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return path.path.hasPrefix(rootPath == "/" ? "/" : rootPath + "/") && path.path != rootPath
    }

    private static func signatures(_ urls: [URL]) throws -> [String] {
        try urls.map { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return "missing" }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return "\(attributes[.size] ?? ""):\(modified):\(attributes[.systemFileNumber] ?? "")"
        }
    }

    private static func stableID(_ type: String, library: String?, key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("PaperShelf.Zotero.\(type).\(library ?? "0").\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func parseDate(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func plainText(_ value: String) -> String {
        value.replacingOccurrences(of: "</p>", with: "\n", options: .caseInsensitive)
            .replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class Reader {
    let connection: OpaquePointer
    init(_ url: URL) throws {
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }; throw ZoteroImportError.invalid("无法打开只读快照。")
        }
        connection = opened
        guard sqlite3_exec(opened, "PRAGMA query_only=ON; BEGIN", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(opened); throw ZoteroImportError.invalid("无法开始快照读取。")
        }
    }
    deinit { sqlite3_close(connection) }
    func hasTable(_ name: String) throws -> Bool {
        try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='\(name)'").isEmpty == false
    }
    func rows(_ sql: String) throws -> [[String: String]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw error() }
        defer { sqlite3_finalize(statement) }
        var result: [[String: String]] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw error() }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, index) { row[String(cString: sqlite3_column_name(statement, index))] = String(cString: text) }
            }
            result.append(row)
        }
    }
    private func error() -> ZoteroImportError { .invalid(String(cString: sqlite3_errmsg(connection))) }
}

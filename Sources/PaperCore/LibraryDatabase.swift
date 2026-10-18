import Foundation
import CSQLite

public struct ImportResult: Equatable, Sendable {
    public var inserted: Int
    public var skipped: Int
    public var replaced: Int

    public init(inserted: Int = 0, skipped: Int = 0, replaced: Int = 0) {
        self.inserted = inserted
        self.skipped = skipped
        self.replaced = replaced
    }
}

public enum LibraryDatabaseError: LocalizedError {
    case unsupportedSchema(Int)
    case duplicateDOI(String)
    case corruptRecord(String, String)
    case sqlite(String)
    case invalidCollection(String)
    case invalidReference(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "This library uses database version \(version), which this version of PaperShelf cannot open. Its contents have not been changed."
        case .duplicateDOI(let doi):
            return "Another reference already has DOI \(doi). Edit that reference or use a different DOI."
        case .corruptRecord(let id, let detail):
            return "The library contains an unreadable reference (\(id)): \(detail). Restore a known-good backup before editing this library."
        case .sqlite(let message):
            return "The library database could not complete the operation: \(message)"
        case .invalidCollection(let message): return "集合无效：\(message)"
        case .invalidReference(let message): return "文献记录无效：\(message)"
        }
    }
}

/// A local SQLite store. Callers should serialize access to this instance.
public final class LibraryDatabase {
    private let connection: OpaquePointer
    public let url: URL
    public let isReadOnly: Bool
    private var storedSchemaVersion = LibraryDatabase.schemaVersion
    public static let schemaVersion = 2
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    public init(url: URL, readOnly: Bool = false) throws {
        self.url = url.standardizedFileURL
        self.isReadOnly = readOnly
        if !readOnly {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &opened, (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard status == SQLITE_OK, let database = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open the database file."
            if let opened { sqlite3_close(opened) }
            throw LibraryDatabaseError.sqlite(message)
        }

        do {
            // Check before any mutating PRAGMA, including journal_mode.
            let versionStatement = try Self.prepare("PRAGMA user_version", in: database)
            let version: Int
            do {
                guard sqlite3_step(versionStatement) == SQLITE_ROW else {
                    throw Self.error(in: database)
                }
                version = Int(sqlite3_column_int(versionStatement, 0))
            } catch {
                sqlite3_finalize(versionStatement)
                throw error
            }
            sqlite3_finalize(versionStatement)
            guard (0...Self.schemaVersion).contains(version) else {
                throw LibraryDatabaseError.unsupportedSchema(version)
            }

            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
                throw Self.error(in: database)
            }
            if readOnly {
                try Self.execute("PRAGMA query_only=ON", in: database)
                storedSchemaVersion = version
                connection = database
                return
            }
            try Self.execute("PRAGMA journal_mode=WAL", in: database)
            if version == 0 {
                try Self.execute("BEGIN IMMEDIATE", in: database)
                do {
                    try Self.execute("""
                        CREATE TABLE library_records (
                            id TEXT PRIMARY KEY NOT NULL,
                            normalized_doi TEXT NOT NULL,
                            pdf_path TEXT,
                            payload BLOB NOT NULL
                        )
                        """, in: database)
                    try Self.execute("""
                        CREATE UNIQUE INDEX library_unique_doi
                        ON library_records(normalized_doi) WHERE normalized_doi <> ''
                        """, in: database)
                    try Self.execute("CREATE INDEX library_pdf_path ON library_records(pdf_path)", in: database)
                    try Self.execute("PRAGMA user_version=1", in: database)
                    try Self.execute("COMMIT", in: database)
                } catch {
                    try? Self.execute("ROLLBACK", in: database)
                    throw error
                }
            }
            if version < 2 {
                try Self.execute("BEGIN IMMEDIATE", in: database)
                do {
                    try Self.execute("CREATE TABLE library_collections (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)", in: database)
                    try Self.execute("CREATE TABLE library_tags (name TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)", in: database)
                    try Self.execute("PRAGMA user_version=2", in: database)
                    try Self.execute("COMMIT", in: database)
                } catch {
                    try? Self.execute("ROLLBACK", in: database)
                    throw error
                }
            }
            connection = database
        } catch {
            sqlite3_close(database)
            throw error
        }
        // A legacy label becomes an explicit root collection without changing its name.
        // Retryable and atomic: no record is lost if a malformed legacy payload is found.
        let legacy = try load().filter { $0.collectionIDs.isEmpty && !$0.collection.isEmpty }
        if !legacy.isEmpty { try upsertReferences(legacy) }
    }

    deinit {
        sqlite3_close(connection)
    }

    public func load() throws -> [Reference] {
        let statement = try Self.prepare("SELECT id, payload FROM library_records ORDER BY rowid DESC", in: connection)
        defer { sqlite3_finalize(statement) }
        var references: [Reference] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return references }
            guard status == SQLITE_ROW else { throw Self.error(in: connection) }
            let id = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "unknown"
            let count = Int(sqlite3_column_bytes(statement, 1))
            guard sqlite3_column_type(statement, 1) == SQLITE_BLOB,
                  count > 0, let bytes = sqlite3_column_blob(statement, 1) else {
                throw LibraryDatabaseError.corruptRecord(id, "The stored record is not valid JSON data.")
            }
            let reference: Reference
            do {
                reference = try JSONDecoder().decode(Reference.self, from: Data(bytes: bytes, count: count))
            } catch {
                throw LibraryDatabaseError.corruptRecord(id, String(describing: error))
            }
            guard reference.id.uuidString == id else {
                throw LibraryDatabaseError.corruptRecord(id, "The record identifier does not match its database entry.")
            }
            references.append(reference)
        }
    }

    public func upsert(_ reference: Reference) throws {
        try upsertReferences([reference])
    }

    public func upsertReferences(_ references: [Reference]) throws {
        try transaction {
            for item in references { try writeReference(prepareReference(item)) }
        }
    }

    /// Applies a local undo/redo patch without replacing unrelated records or organization metadata.
    public func applyReferenceChanges(upserting references: [Reference], deleting ids: Set<UUID>) throws {
        let updatedIDs = Set(references.map(\.id))
        guard updatedIDs.count == references.count, updatedIDs.isDisjoint(with: ids) else {
            throw LibraryDatabaseError.invalidReference("局部修改包含重复标识，或同一文献同时被保存和删除。")
        }
        try transaction {
            for id in ids { try delete(id: id) }
            for reference in references { try writeReference(prepareReference(reference)) }
        }
    }

    private func writeReference(_ reference: Reference) throws {
        guard (0...5).contains(reference.rating) else {
            throw LibraryDatabaseError.invalidReference("评分必须在0至5之间。")
        }
        let payload = try JSONEncoder().encode(reference)
        let doi = Self.normalizedDOI(reference.doi)
        let statement = try Self.prepare("""
            INSERT INTO library_records (id, normalized_doi, pdf_path, payload)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                normalized_doi=excluded.normalized_doi,
                pdf_path=excluded.pdf_path,
                payload=excluded.payload
            """, in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(reference.id.uuidString, at: 1, to: statement)
        try bind(doi, at: 2, to: statement)
        try bind(Self.standardizedPath(reference.pdfPath), at: 3, to: statement)
        guard payload.count <= Int(Int32.max) else {
            throw LibraryDatabaseError.sqlite("The reference is too large to store.")
        }
        let bindingStatus = payload.withUnsafeBytes {
            sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), Self.transient)
        }
        guard bindingStatus == SQLITE_OK else { throw Self.error(in: connection) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(connection))
            if status & 0xff == SQLITE_CONSTRAINT && message.contains("normalized_doi") {
                throw LibraryDatabaseError.duplicateDOI(doi)
            }
            throw LibraryDatabaseError.sqlite(message)
        }
    }

    /// Imports are atomic. Existing identifiers, DOIs, or linked PDF paths are skipped.
    public func importReferences(_ references: [Reference]) throws -> ImportResult {
        try importLibrary(LibraryImport(references: references))
    }

    public func importLibrary(_ incoming: LibraryImport, duplicatePolicy: ImportDuplicatePolicy = .skip) throws -> ImportResult {
        try transaction {
            var collections = try loadCollections()
            for item in incoming.collections {
                if let index = collections.firstIndex(where: { $0.id == item.id }) {
                    if duplicatePolicy == .replace { collections[index] = item }
                } else { collections.append(item) }
            }
            try validateCollections(collections)
            for item in collections { try writeMetadata(item, key: item.id.uuidString, table: "library_collections", keyColumn: "id") }
            var tagNames = Set(try loadTags().map(\.name))
            for tag in incoming.tags {
                try validateTag(tag)
                if tagNames.contains(tag.name), duplicatePolicy == .skip { continue }
                try writeMetadata(tag, key: tag.name, table: "library_tags", keyColumn: "name")
                tagNames.insert(tag.name)
            }
            var result = ImportResult()
            for reference in incoming.references {
                if let existing = try duplicate(of: reference) {
                    if duplicatePolicy == .skip { result.skipped += 1; continue }
                    var replacement = reference
                    replacement.id = existing.id
                    replacement.addedAt = existing.addedAt
                    // Importing metadata must not erase local reading state or unlink a PDF.
                    replacement.isRead = existing.isRead
                    replacement.isFavorite = existing.isFavorite
                    replacement.rating = existing.rating
                    replacement.deletedAt = existing.deletedAt
                    if replacement.citationKey.isEmpty { replacement.citationKey = existing.citationKey }
                    replacement.extraFields = existing.extraFields.merging(replacement.extraFields) { _, incoming in incoming }
                    if replacement.notes.isEmpty { replacement.notes = existing.notes }
                    if replacement.pdfPath == nil { replacement.pdfPath = existing.pdfPath; replacement.pdfBookmark = existing.pdfBookmark }
                    let incomingAttachmentIDs = Set(replacement.attachments.map(\.id))
                    replacement.attachments += existing.attachments.filter { !incomingAttachmentIDs.contains($0.id) }
                    replacement.tags = Array(Set(existing.tags + replacement.tags)).sorted()
                    replacement.collectionIDs = Array(Set(existing.collectionIDs + replacement.collectionIDs)).sorted { $0.uuidString < $1.uuidString }
                    if replacement.collection.isEmpty { replacement.collection = existing.collection }
                    try writeReference(prepareReference(replacement))
                    result.replaced += 1
                } else {
                    try writeReference(prepareReference(reference))
                    result.inserted += 1
                }
            }
            return result
        }
    }

    public func delete(id: UUID) throws {
        let statement = try Self.prepare("DELETE FROM library_records WHERE id = ?", in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(in: connection) }
    }

    public func loadCollections() throws -> [LibraryCollection] {
        if storedSchemaVersion < 2 { return [] }
        let items: [LibraryCollection] = try readMetadata(table: "library_collections")
        try validateCollections(items)
        return items.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
    }

    public func upsertCollection(_ collection: LibraryCollection) throws {
        try upsertCollections([collection])
    }

    public func upsertCollections(_ updates: [LibraryCollection]) throws {
        try transaction {
            guard Set(updates.map(\.id)).count == updates.count else { throw LibraryDatabaseError.invalidCollection("集合更新包含重复标识。") }
            let updatedIDs = Set(updates.map(\.id))
            let items = try loadCollections().filter { !updatedIDs.contains($0.id) } + updates
            try validateCollections(items)
            for collection in updates { try writeMetadata(collection, key: collection.id.uuidString, table: "library_collections", keyColumn: "id") }
            let names = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
            // Keep the compatibility label synchronized with the first membership.
            for var reference in try load() where reference.collectionIDs.first.map(updatedIDs.contains) == true {
                reference.collection = reference.collectionIDs.first.flatMap { names[$0] } ?? ""
                try writeReference(reference)
            }
        }
    }

    /// Removing a collection only removes memberships. References and files are retained.
    public func deleteCollection(id: UUID, includingDescendants: Bool = false) throws {
        try transaction {
            let collections = try loadCollections()
            var removed: Set<UUID> = [id]
            while true {
                let children = Set(collections.filter { $0.parentID.map(removed.contains) == true }.map(\.id))
                let expanded = removed.union(children)
                if expanded == removed { break }
                guard includingDescendants else { throw LibraryDatabaseError.invalidCollection("此集合包含子集合。请先移动子集合，或选择同时删除子集合。") }
                removed = expanded
            }
            for item in removed { try deleteMetadata(key: item.uuidString, table: "library_collections", keyColumn: "id") }
            let remaining = Dictionary(uniqueKeysWithValues: collections.filter { !removed.contains($0.id) }.map { ($0.id, $0) })
            for var reference in try load() where reference.collectionIDs.contains(where: removed.contains) {
                reference.collectionIDs.removeAll(where: removed.contains)
                reference.collection = reference.collectionIDs.first.flatMap { remaining[$0]?.name } ?? ""
                try writeReference(reference)
            }
        }
    }

    public func loadTags() throws -> [LibraryTag] {
        if storedSchemaVersion < 2 { return Set(try load().flatMap(\.tags)).sorted().map { LibraryTag(name: $0) } }
        let items: [LibraryTag] = try readMetadata(table: "library_tags")
        for item in items { try validateTag(item) }
        return items.sorted { ($0.sortOrder, $0.name) < ($1.sortOrder, $1.name) }
    }

    public func upsertTag(_ tag: LibraryTag) throws {
        try upsertTags([tag])
    }

    public func upsertTags(_ tags: [LibraryTag]) throws {
        try transaction {
            for tag in tags { try validateTag(tag); try writeMetadata(tag, key: tag.name, table: "library_tags", keyColumn: "name") }
        }
    }

    public func renameTag(from oldName: String, to newName: String) throws {
        guard oldName != newName else { return }
        try transaction {
            let tags = try loadTags()
            guard !tags.contains(where: { $0.name == newName }) else { throw LibraryDatabaseError.invalidReference("已有同名标签。请选择其他名称。") }
            var tag = tags.first { $0.name == oldName } ?? LibraryTag(name: oldName)
            tag.name = newName; try validateTag(tag)
            try writeMetadata(tag, key: newName, table: "library_tags", keyColumn: "name")
            for var reference in try load() where reference.tags.contains(oldName) {
                var seen = Set<String>()
                reference.tags = reference.tags.map { $0 == oldName ? newName : $0 }.filter { seen.insert($0).inserted }
                try writeReference(reference)
            }
            try deleteMetadata(key: oldName, table: "library_tags", keyColumn: "name")
        }
    }

    public func deleteTag(name: String) throws {
        try transaction {
            try deleteMetadata(key: name, table: "library_tags", keyColumn: "name")
            for var reference in try load() where reference.tags.contains(name) {
                reference.tags.removeAll { $0 == name }
                try writeReference(reference)
            }
        }
    }

    /// Used by verified restore. All replacement data is committed together or rolled back.
    public func replaceAll(with library: LibraryImport) throws {
        try transaction {
            try validateCollections(library.collections)
            guard Set(library.references.map(\.id)).count == library.references.count else {
                throw LibraryDatabaseError.invalidReference("备份包含重复文献标识。")
            }
            for table in ["library_records", "library_collections", "library_tags"] { try Self.execute("DELETE FROM \(table)", in: connection) }
            for item in library.collections { try writeMetadata(item, key: item.id.uuidString, table: "library_collections", keyColumn: "id") }
            for item in library.tags { try validateTag(item); try writeMetadata(item, key: item.name, table: "library_tags", keyColumn: "name") }
            for item in library.references { try writeReference(prepareReference(item)) }
        }
    }

    /// SQLite's backup API includes committed WAL content in a consistent snapshot.
    public func snapshot(to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LibraryDatabaseError.sqlite("Snapshot destination already exists.") }
        var target: OpaquePointer?
        guard sqlite3_open_v2(destination.path, &target, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let target else { if let target { sqlite3_close(target) }; throw LibraryDatabaseError.sqlite("Cannot create snapshot.") }
        defer { sqlite3_close(target) }
        guard let backup = sqlite3_backup_init(target, "main", connection, "main") else { throw Self.error(in: target) }
        let result = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finished == SQLITE_OK else { throw Self.error(in: target) }
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try Self.execute("BEGIN IMMEDIATE", in: connection)
        do { let result = try body(); try Self.execute("COMMIT", in: connection); return result }
        catch { try? Self.execute("ROLLBACK", in: connection); throw error }
    }

    private func prepareReference(_ item: Reference) throws -> Reference {
        var item = item
        var collections = try loadCollections()
        if item.collectionIDs.isEmpty, !item.collection.isEmpty {
            if let existing = collections.first(where: { $0.parentID == nil && $0.name == item.collection }) {
                item.collectionIDs = [existing.id]
            } else {
                let collection = LibraryCollection(name: item.collection, sortOrder: collections.count)
                try writeMetadata(collection, key: collection.id.uuidString, table: "library_collections", keyColumn: "id")
                collections.append(collection); item.collectionIDs = [collection.id]
            }
        }
        var seen = Set<UUID>()
        item.collectionIDs = item.collectionIDs.filter { seen.insert($0).inserted }
        let known = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        guard item.collectionIDs.allSatisfy({ known[$0] != nil }) else { throw LibraryDatabaseError.invalidReference("文献指向不存在的集合。") }
        item.collection = item.collectionIDs.first.flatMap { known[$0]?.name } ?? ""
        guard Set(item.attachments.map(\.id)).count == item.attachments.count else { throw LibraryDatabaseError.invalidReference("附件标识重复。") }
        let tags = Set(try loadTags().map(\.name))
        for name in Set(item.tags) where !name.isEmpty && !tags.contains(name) {
            try writeMetadata(LibraryTag(name: name), key: name, table: "library_tags", keyColumn: "name")
        }
        return item
    }

    private func validateCollections(_ items: [LibraryCollection]) throws {
        guard Set(items.map(\.id)).count == items.count else { throw LibraryDatabaseError.invalidCollection("集合标识重复。") }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            guard !item.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryDatabaseError.invalidCollection("名称不能为空。") }
            var ancestors: Set<UUID> = [item.id]
            var parent = item.parentID
            while let id = parent {
                guard ancestors.insert(id).inserted else { throw LibraryDatabaseError.invalidCollection("父子集合不能形成循环。") }
                guard let node = lookup[id] else { throw LibraryDatabaseError.invalidCollection("父集合不存在。") }
                parent = node.parentID
            }
        }
    }

    private func validateTag(_ tag: LibraryTag) throws {
        guard !tag.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryDatabaseError.invalidReference("标签名称不能为空。") }
        guard tag.colorHex.isEmpty || tag.colorHex.range(of: "^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$", options: .regularExpression) != nil else {
            throw LibraryDatabaseError.invalidReference("标签颜色应为 #RRGGBB 或 #RRGGBBAA。")
        }
    }

    private func readMetadata<T: Decodable>(table: String) throws -> [T] {
        let statement = try Self.prepare("SELECT payload FROM \(table) ORDER BY rowid", in: connection)
        defer { sqlite3_finalize(statement) }
        var items: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return items }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw Self.error(in: connection) }
            items.append(try JSONDecoder().decode(T.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))))
        }
    }

    private func writeMetadata<T: Encodable>(_ item: T, key: String, table: String, keyColumn: String) throws {
        let data = try JSONEncoder().encode(item)
        let statement = try Self.prepare("INSERT INTO \(table) (\(keyColumn), payload) VALUES (?, ?) ON CONFLICT(\(keyColumn)) DO UPDATE SET payload=excluded.payload", in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        guard data.count <= Int(Int32.max), data.withUnsafeBytes({ sqlite3_bind_blob(statement, 2, $0.baseAddress, Int32($0.count), Self.transient) }) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(in: connection) }
    }

    private func deleteMetadata(key: String, table: String, keyColumn: String) throws {
        let statement = try Self.prepare("DELETE FROM \(table) WHERE \(keyColumn) = ?", in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(key, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(in: connection) }
    }

    private func duplicate(of reference: Reference) throws -> Reference? {
        let statement = try Self.prepare("""
            SELECT payload FROM library_records
            WHERE id = ? OR (normalized_doi <> '' AND normalized_doi = ?)
                OR (pdf_path IS NOT NULL AND pdf_path = ?) LIMIT 1
            """, in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(reference.id.uuidString, at: 1, to: statement)
        try bind(Self.normalizedDOI(reference.doi), at: 2, to: statement)
        try bind(Self.standardizedPath(reference.pdfPath), at: 3, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else { throw LibraryDatabaseError.corruptRecord(reference.id.uuidString, "Empty payload") }
            return try JSONDecoder().decode(Reference.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0))))
        case SQLITE_DONE: return nil
        default: throw Self.error(in: connection)
        }
    }

    private func bind(_ value: String?, at index: Int32, to statement: OpaquePointer) throws {
        let status: Int32
        if let value {
            guard value.utf8.count <= Int(Int32.max) else {
                throw LibraryDatabaseError.sqlite("The text value is too large to store.")
            }
            status = value.withCString {
                sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), Self.transient)
            }
        } else {
            status = sqlite3_bind_null(statement, index)
        }
        guard status == SQLITE_OK else { throw Self.error(in: connection) }
    }

    private static func normalizedDOI(_ value: String) -> String {
        if let normalized = try? DOIClient.normalize(value) {
            return normalized.lowercased()
        }
        var doi = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefix in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi.org/", "doi:"] {
            if doi.hasPrefix(prefix) {
                doi.removeFirst(prefix.count)
                break
            }
        }
        return doi.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func standardizedPath(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL.path
    }

    private static func prepare(_ sql: String, in database: OpaquePointer) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw error(in: database)
        }
        return statement
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw error(in: database)
        }
    }

    private static func error(in database: OpaquePointer) -> LibraryDatabaseError {
        .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

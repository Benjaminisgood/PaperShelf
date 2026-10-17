import Foundation
import CSQLite

public struct ImportResult: Equatable, Sendable {
    public var inserted: Int
    public var skipped: Int

    public init(inserted: Int = 0, skipped: Int = 0) {
        self.inserted = inserted
        self.skipped = skipped
    }
}

public enum LibraryDatabaseError: LocalizedError {
    case unsupportedSchema(Int)
    case duplicateDOI(String)
    case corruptRecord(String, String)
    case sqlite(String)

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
        }
    }
}

/// A local SQLite store. Callers should serialize access to this instance.
public final class LibraryDatabase {
    private let connection: OpaquePointer
    private static let schemaVersion = 1
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    public init(url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        var opened: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
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
            guard version == 0 || version == Self.schemaVersion else {
                throw LibraryDatabaseError.unsupportedSchema(version)
            }

            guard sqlite3_busy_timeout(database, 5_000) == SQLITE_OK else {
                throw Self.error(in: database)
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
            connection = database
        } catch {
            sqlite3_close(database)
            throw error
        }
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
        try Self.execute("BEGIN IMMEDIATE", in: connection)
        do {
            var result = ImportResult()
            for reference in references {
                if try contains(reference) {
                    result.skipped += 1
                } else {
                    try upsert(reference)
                    result.inserted += 1
                }
            }
            try Self.execute("COMMIT", in: connection)
            return result
        } catch {
            try? Self.execute("ROLLBACK", in: connection)
            throw error
        }
    }

    public func delete(id: UUID) throws {
        let statement = try Self.prepare("DELETE FROM library_records WHERE id = ?", in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(id.uuidString, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw Self.error(in: connection) }
    }

    private func contains(_ reference: Reference) throws -> Bool {
        let statement = try Self.prepare("""
            SELECT 1 FROM library_records
            WHERE id = ? OR (normalized_doi <> '' AND normalized_doi = ?)
                OR (pdf_path IS NOT NULL AND pdf_path = ?) LIMIT 1
            """, in: connection)
        defer { sqlite3_finalize(statement) }
        try bind(reference.id.uuidString, at: 1, to: statement)
        try bind(Self.normalizedDOI(reference.doi), at: 2, to: statement)
        try bind(Self.standardizedPath(reference.pdfPath), at: 3, to: statement)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
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

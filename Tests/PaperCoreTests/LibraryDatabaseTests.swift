import Foundation
import XCTest
import CSQLite
@testable import PaperCore

final class LibraryDatabaseTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL { directory.appendingPathComponent("nested/library.sqlite") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperShelf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testPersistenceUpdateAndDeletionAcrossReopen() throws {
        var reference = Reference()
        reference.title = "O'Brien's 中文 reference"
        reference.authors = ["Doe, Jane", "王明"]
        reference.tags = ["kinetics", "待阅读"]
        reference.pdfPath = "/a paper's folder/paper.pdf"
        reference.pdfBookmark = Data([1, 3, 5, 9])
        reference.notes = "Preserve newlines\nand apostrophes."
        do {
            let database = try LibraryDatabase(url: databaseURL)
            try database.upsert(reference)
        }
        do {
            let reopened = try LibraryDatabase(url: databaseURL)
            XCTAssertEqual(try reopened.load(), [reference])
            reference.title = "Updated title"
            try reopened.upsert(reference)
            XCTAssertEqual(try reopened.load(), [reference])
        }
        let reopened = try LibraryDatabase(url: databaseURL)
        XCTAssertEqual(try reopened.load(), [reference])
        try reopened.delete(id: reference.id)
        XCTAssertEqual(try reopened.load(), [])
    }

    func testDOIImportDeduplicatesNormalizedValuesAndKeepsExistingData() throws {
        let database = try LibraryDatabase(url: databaseURL)
        var first = Reference()
        first.title = "Original"
        first.doi = " HTTPS://doi.org/10.1234/ABC "
        var duplicate = Reference()
        duplicate.title = "Should not overwrite"
        duplicate.doi = "10.1234/abc"
        let emptyDOI = Reference()
        let anotherEmptyDOI = Reference()
        XCTAssertEqual(
            try database.importReferences([first, duplicate, emptyDOI, anotherEmptyDOI, first]),
            ImportResult(inserted: 3, skipped: 2)
        )
        let stored = try database.load()
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(stored.first(where: { $0.id == first.id }), first)
    }

    func testConflictingManualUpdateDoesNotChangeExistingRecords() throws {
        let database = try LibraryDatabase(url: databaseURL)
        var first = Reference()
        first.doi = "10.1234/a"
        var second = Reference()
        second.doi = "10.1234/b"
        try database.upsert(first)
        try database.upsert(second)
        var conflict = second
        conflict.doi = "https://doi.org/10.1234/A"
        XCTAssertThrowsError(try database.upsert(conflict)) { error in
            guard case LibraryDatabaseError.duplicateDOI(let doi) = error else {
                return XCTFail("Expected duplicate DOI error, received \(error)")
            }
            XCTAssertEqual(doi, "10.1234/a")
        }
        XCTAssertEqual(Set(try database.load().map(\.doi)), [first.doi, second.doi])
        first.doi = "10.1234/c"
        try database.upsert(first)
        conflict.doi = "10.1234/a"
        try database.upsert(conflict)
        XCTAssertEqual(try database.load().count, 2)
    }

    func testImportDeduplicatesStandardizedPDFPaths() throws {
        let database = try LibraryDatabase(url: databaseURL)
        var first = Reference()
        first.pdfPath = "/tmp/papers/../paper.pdf"
        var duplicate = Reference()
        duplicate.pdfPath = "/tmp/paper.pdf"
        duplicate.doi = "10.1234/different"
        XCTAssertEqual(try database.importReferences([first, duplicate]), ImportResult(inserted: 1, skipped: 1))
        XCTAssertEqual(try database.load(), [first])
    }

    func testImportDeduplicatesPercentEncodedDOIResolverURLs() throws {
        let database = try LibraryDatabase(url: databaseURL)
        var encoded = Reference()
        encoded.doi = "HTTPS://doi.org/10.1234/A%2FB"
        var decoded = Reference()
        decoded.doi = "10.1234/a/b"
        XCTAssertEqual(try database.importReferences([encoded, decoded]), ImportResult(inserted: 1, skipped: 1))
        XCTAssertEqual(try database.load(), [encoded])
    }

    func testImportRollsBackWholeBatchWhenSQLiteRejectsLaterRecord() throws {
        let database = try LibraryDatabase(url: databaseURL)
        try executeSQL("""
            CREATE TRIGGER reject_test_record BEFORE INSERT ON library_records
            WHEN NEW.normalized_doi = '10.1234/reject'
            BEGIN SELECT RAISE(ABORT, 'Deliberate database failure for rollback test'); END
            """)
        var first = Reference()
        first.doi = "10.1234/first"
        var rejected = Reference()
        rejected.doi = "10.1234/reject"
        XCTAssertThrowsError(try database.importReferences([first, rejected]))
        XCTAssertEqual(try database.load(), [])
        try database.upsert(first)
        XCTAssertEqual(try database.load(), [first], "The transaction must be closed after rollback.")
    }

    func testCorruptRecordRaisesAnErrorInsteadOfAppearingAsEmptyLibrary() throws {
        let database = try LibraryDatabase(url: databaseURL)
        try database.upsert(Reference())
        try executeSQL("UPDATE library_records SET payload = X'7B696E76616C6964'")
        XCTAssertThrowsError(try database.load()) { error in
            guard case LibraryDatabaseError.corruptRecord = error else {
                return XCTFail("Expected corruption error, received \(error)")
            }
        }
    }

    func testFutureSchemaIsRejectedWithoutChangingTheFile() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try executeSQL("CREATE TABLE future_records (value TEXT); INSERT INTO future_records VALUES ('keep me'); PRAGMA user_version = 99")
        let before = try Data(contentsOf: databaseURL)
        XCTAssertThrowsError(try LibraryDatabase(url: databaseURL)) { error in
            guard case LibraryDatabaseError.unsupportedSchema(99) = error else {
                return XCTFail("Expected future schema error, received \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path + "-wal"))
    }

    func testInvalidDatabaseFileIsRejectedWithoutReplacingIt() throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("This is not a SQLite database, and must not be replaced.".utf8)
        try original.write(to: databaseURL)
        XCTAssertThrowsError(try LibraryDatabase(url: databaseURL))
        XCTAssertEqual(try Data(contentsOf: databaseURL), original)
    }

    private func executeSQL(_ sql: String) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &connection) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw NSError(domain: "SQLiteTest", code: 1)
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SQLiteTest", code: 2, userInfo: [NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(connection))])
        }
    }
}

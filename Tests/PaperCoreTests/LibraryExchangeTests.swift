import Foundation
import XCTest
import CSQLite
@testable import PaperCore

final class LibraryExchangeTests: XCTestCase {
    var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperShelf-exchange-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
    func database(_ name: String = "library.sqlite") throws -> LibraryDatabase { try LibraryDatabase(url: directory.appendingPathComponent(name)) }

    func testLegacyReferenceDefaultsAndWrongTypesFail() throws {
        let item = try JSONDecoder().decode(Reference.self, from: Data(#"{"title":"Old library"}"#.utf8))
        XCTAssertEqual(item.title, "Old library"); XCTAssertEqual(item.entryType, "article")
        XCTAssertEqual(item.collectionIDs, []); XCTAssertEqual(item.attachments, []); XCTAssertEqual(item.rating, 0)
        XCTAssertEqual(item.addedAt, Date(timeIntervalSince1970: 0))
        XCTAssertThrowsError(try JSONDecoder().decode(Reference.self, from: Data(#"{"rating":"5"}"#.utf8)))
    }

    func testExtendedBibTeXAndRISPreserveKeyTypeAndMetadata() throws {
        let item = Reference(title: "A book", authors: ["Doe, Jane"], year: "2026", notes: "note one\nnote two", tags: ["A,B", "C;D"], collection: "Learning",
                             citationKey: "Doe2026", entryType: "book", volume: "3", issue: "2", pages: "12--29", publisher: "Example", isbn: "123", issn: "456", extraFields: ["custom_field": "{x} \\ data"])
        for (format, output) in [("bib", Bibliography.exportBibTeX([item])), ("ris", Bibliography.exportRIS([item]))] {
            let imported = try XCTUnwrap(Bibliography.parse(output, format: format).first)
            XCTAssertEqual(imported.citationKey, item.citationKey); XCTAssertEqual(imported.entryType, item.entryType)
            XCTAssertEqual(imported.volume, item.volume); XCTAssertEqual(imported.issue, item.issue); XCTAssertEqual(imported.pages, item.pages)
            XCTAssertEqual(imported.publisher, item.publisher); XCTAssertEqual(imported.isbn, item.isbn); XCTAssertEqual(imported.issn, item.issn)
            XCTAssertEqual(imported.extraFields, item.extraFields); XCTAssertEqual(imported.tags, item.tags); XCTAssertEqual(imported.notes, item.notes)
        }
        let subset = Bibliography.exportBibTeX([item], options: .init(fields: ["title", "year"]))
        XCTAssertTrue(subset.contains("title =")); XCTAssertFalse(subset.contains("publisher =")); XCTAssertFalse(subset.contains("custom_field ="))
        let keys = Bibliography.generateCitationKeys([item, item, item], template: "{author}{year}").map(\.citationKey)
        XCTAssertEqual(keys, ["Doe2026", "Doe2026a", "Doe2026b"])
        XCTAssertEqual(Bibliography.generateCitationKeys([item], template: "{author}{year}", reservedKeys: ["doe2026"]).first?.citationKey, "Doe2026a")
        let yearOnly = Bibliography.exportBibTeX([item], options: .init(fields: ["year"]))
        XCTAssertEqual(try Bibliography.parse(yearOnly, format: "bib").first?.year, "2026")
        let original = try XCTUnwrap(Bibliography.parse("@inproceedings{Original:Key,title={Work},booktitle={Conference},custom={preserved}}", format: "bib").first)
        XCTAssertEqual(original.entryType, "inproceedings"); XCTAssertEqual(original.citationKey, "Original:Key")
        XCTAssertEqual(original.extraFields["custom"], "preserved")
    }

    func testCitationKeyTokensHandleCaseDatesWordCountsAndCollisions() throws {
        let item = Reference(title: "An\nÉtude of Catalysis: Kinetics", authors: ["García Márquez, Gabriel"], year: "2026")
        let pattern = "{auth}:{Auth}:{author}:{shortyear}:{title}:{title-2}:{title-8}"
        XCTAssertEqual(Bibliography.generateCitationKeys([item], template: pattern).first?.citationKey,
                       "garciamarquez:GarciaMarquez:GarciaMarquez:26:AnEtudeof:AnEtude:AnEtudeofCatalysis:Kinetics")
        var dated = item; dated.year = "2026-10-18"; dated.authors = ["Jane Smith"]
        XCTAssertEqual(Bibliography.generateCitationKeys([dated], template: "{Auth}{shortyear}{title-1}").first?.citationKey, "Smith26An")
        dated.year = "n.d."; dated.authors = ["王小明"]
        XCTAssertEqual(Bibliography.generateCitationKeys([dated], template: "{auth}{shortyear}{title-0}").first?.citationKey, "王小明")
        XCTAssertEqual(Bibliography.generateCitationKeys([item], template: "{title-999999999999999999999999}").first?.citationKey,
                       "AnEtudeofCatalysis:Kinetics")
        let collisions = Bibliography.generateCitationKeys([item, item], template: "{auth}{shortyear}{title-1}", reservedKeys: ["GARCIAMARQUEZ26AN"])
        XCTAssertEqual(collisions.map(\.citationKey), ["garciamarquez26Ana", "garciamarquez26Anb"])
        var keyed = item; keyed.citationKey = "Keep:Original"
        XCTAssertEqual(Bibliography.generateCitationKeys([keyed], template: pattern, preserveExisting: true).first?.citationKey, "Keep:Original")
        XCTAssertEqual(Bibliography.generateCitationKeys([item], template: "{title-0}").first?.citationKey,
                       "ref" + item.id.uuidString.replacingOccurrences(of: "-", with: ""))
    }

    func testCollectionsUnlimitedDepthCyclesMembershipAndSafeRemoval() throws {
        let db = try database()
        var chain: [LibraryCollection] = []
        for number in 0..<12 {
            let node = LibraryCollection(name: "Level \(number)", parentID: chain.last?.id)
            try db.upsertCollection(node); chain.append(node)
        }
        var root = chain[0]; root.parentID = chain.last?.id
        XCTAssertThrowsError(try db.upsertCollection(root))
        XCTAssertEqual(try db.loadCollections().count, 12)
        let item = Reference(title: "Keep me", collectionIDs: [chain[0].id, chain[11].id])
        try db.upsert(item)
        XCTAssertThrowsError(try db.deleteCollection(id: chain[0].id))
        try db.deleteCollection(id: chain[0].id, includingDescendants: true)
        XCTAssertEqual(try db.loadCollections().count, 0)
        let saved = try XCTUnwrap(db.load().first)
        XCTAssertEqual(saved.title, item.title); XCTAssertEqual(saved.collectionIDs, []); XCTAssertEqual(saved.collection, "")
    }

    func testLegacyCollectionMigrationAndTransactionRollback() throws {
        let db = try database()
        try db.upsert(Reference(title: "Legacy", collection: "Literal/Root"))
        XCTAssertEqual(try db.loadCollections().map(\.name), ["Literal/Root"])
        let before = try db.load()
        XCTAssertThrowsError(try db.upsertReferences([Reference(title: "Valid", collection: "New"), Reference(title: "Invalid", rating: 9)]))
        XCTAssertEqual(try db.load(), before)
        XCTAssertEqual(try db.loadCollections().map(\.name), ["Literal/Root"])
    }

    func testSchemaOneMigratesLegacyPayloadWithoutDiscardingData() throws {
        let url = directory.appendingPathComponent("legacy.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let handle = try XCTUnwrap(connection)
        let id = UUID()
        let payload = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "title": "Schema one", "collection": "Research"])
        let hex = payload.map { String(format: "%02x", $0) }.joined()
        let sql = """
        CREATE TABLE library_records(id TEXT PRIMARY KEY NOT NULL, normalized_doi TEXT NOT NULL, pdf_path TEXT, payload BLOB NOT NULL);
        CREATE UNIQUE INDEX library_unique_doi ON library_records(normalized_doi) WHERE normalized_doi <> '';
        CREATE INDEX library_pdf_path ON library_records(pdf_path);
        INSERT INTO library_records VALUES('\(id.uuidString)', '', NULL, X'\(hex)');
        PRAGMA user_version=1;
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK); sqlite3_close(handle)
        let migrated = try LibraryDatabase(url: url)
        let item = try XCTUnwrap(migrated.load().first)
        XCTAssertEqual(item.id, id); XCTAssertEqual(item.title, "Schema one"); XCTAssertEqual(item.entryType, "article")
        XCTAssertEqual(item.collection, "Research"); XCTAssertEqual(item.collectionIDs.count, 1)
        XCTAssertEqual(try migrated.loadCollections().first?.id, item.collectionIDs.first)
    }

    func testDuplicateReplacePreservesLocalAnnotationsAndAttachments() throws {
        let db = try database()
        let attachment = ReferenceAttachment(name: "data", path: "/tmp/data.csv")
        let existing = Reference(title: "Old", doi: "10.1234/test", notes: "Local notes", tags: ["local"], isRead: true, isFavorite: true, pdfPath: "/tmp/paper.pdf", citationKey: "LocalKey", extraFields: ["custom": "local"], rating: 5, attachments: [attachment])
        try db.upsert(existing)
        let result = try db.importLibrary(.init(references: [Reference(title: "Updated", doi: "https://doi.org/10.1234/TEST", tags: ["imported"], volume: "12")]), duplicatePolicy: .replace)
        XCTAssertEqual(result, ImportResult(replaced: 1))
        let saved = try XCTUnwrap(db.load().first)
        XCTAssertEqual(saved.id, existing.id); XCTAssertEqual(saved.addedAt, existing.addedAt)
        XCTAssertEqual(saved.notes, existing.notes); XCTAssertEqual(saved.rating, 5); XCTAssertTrue(saved.isRead); XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.pdfPath, existing.pdfPath); XCTAssertEqual(saved.attachments, [attachment]); XCTAssertEqual(saved.volume, "12")
        XCTAssertEqual(saved.citationKey, "LocalKey"); XCTAssertEqual(saved.extraFields["custom"], "local")
        XCTAssertEqual(Set(saved.tags), ["local", "imported"])
    }

    func testTagRenamePreservesColorOrderAndReferencesAtomically() throws {
        let db = try database()
        try db.upsertTag(.init(name: "old", colorHex: "#12345678", sortOrder: 7))
        let item = Reference(title: "Tagged", notes: "retain", tags: ["old", "other"])
        try db.upsert(item)
        try db.renameTag(from: "old", to: "new")
        XCTAssertEqual(try db.loadTags().first(where: { $0.name == "new" })?.colorHex, "#12345678")
        XCTAssertEqual(try db.loadTags().first(where: { $0.name == "new" })?.sortOrder, 7)
        XCTAssertEqual(try db.load().first?.tags, ["new", "other"]); XCTAssertEqual(try db.load().first?.notes, "retain")
        XCTAssertThrowsError(try db.renameTag(from: "new", to: "other"))
        XCTAssertEqual(try db.load().first?.tags, ["new", "other"])
        XCTAssertThrowsError(try db.upsertTags([.init(name: "new", sortOrder: 0), .init(name: "bad", colorHex: "wrong")]))
        XCTAssertEqual(try db.loadTags().first(where: { $0.name == "new" })?.sortOrder, 7)
    }

    func testReadOnlyLibraryDoesNotCreateOrModifyRecords() throws {
        let missing = directory.appendingPathComponent("missing/library.sqlite")
        XCTAssertThrowsError(try LibraryDatabase(url: missing, readOnly: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
        let url = directory.appendingPathComponent("readonly.sqlite")
        let item = Reference(title: "Read only")
        do { let writable = try LibraryDatabase(url: url); try writable.upsert(item) }
        let before = try Data(contentsOf: url)
        do {
            let readOnly = try LibraryDatabase(url: url, readOnly: true)
            XCTAssertTrue(readOnly.isReadOnly); XCTAssertEqual(try readOnly.load(), [item])
            XCTAssertThrowsError(try readOnly.upsert(Reference(title: "Cannot write")))
        }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testLocalUndoPatchIsAtomicAndKeepsUnrelatedData() throws {
        let db = try database()
        let collection = LibraryCollection(name: "Keep collection"); try db.upsertCollection(collection)
        let first = Reference(title: "First", doi: "10.1234/first")
        let other = Reference(title: "Other", doi: "10.1234/other")
        try db.upsertReferences([first, other])
        var replacement = Reference(title: "Replacement", doi: first.doi)
        try db.applyReferenceChanges(upserting: [replacement], deleting: [first.id])
        XCTAssertEqual(Set(try db.load().map(\.id)), [replacement.id, other.id])
        XCTAssertEqual(try db.loadCollections(), [collection])
        replacement.doi = other.doi
        XCTAssertThrowsError(try db.applyReferenceChanges(upserting: [replacement], deleting: [UUID()]))
        XCTAssertEqual(try db.load().first(where: { $0.id == replacement.id })?.doi, first.doi)
        XCTAssertThrowsError(try db.applyReferenceChanges(upserting: [other], deleting: [other.id]))
        XCTAssertThrowsError(try db.applyReferenceChanges(upserting: [other, other], deleting: []))
        XCTAssertEqual(try db.load().count, 2)
    }

    func testLongAttachmentFilenameSurvivesBackupAndRestore() throws {
        let db = try database()
        let filename = String(repeating: "long", count: 60) + ".pdf"
        let original = directory.appendingPathComponent(filename)
        try Data("full filename".utf8).write(to: original)
        try db.upsert(Reference(title: "Long filename", pdfPath: original.path))
        let backup = directory.appendingPathComponent("long.papershelfbackup")
        let manifest = try LibraryBackup.create(database: db, to: backup)
        XCTAssertEqual(manifest.attachments.first?.originalPath, original.path)
        _ = try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery"))
        let path = try XCTUnwrap(db.load().first?.pdfPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("full filename".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testBackupResolvesBookmarksWhenStoredAttachmentPathIsStale() throws {
        let db = try database()
        let actual = directory.appendingPathComponent("actual.pdf")
        try Data("bookmark contents".utf8).write(to: actual)
        let bookmark = try actual.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let stale = directory.appendingPathComponent("old-location.pdf").path
        try db.upsert(Reference(title: "Moved outside app", pdfPath: stale, pdfBookmark: bookmark))
        let backup = directory.appendingPathComponent("bookmark.papershelfbackup")
        let manifest = try LibraryBackup.create(database: db, to: backup)
        XCTAssertEqual(manifest.attachments.count, 1); XCTAssertEqual(manifest.warnings, [])
        XCTAssertEqual(manifest.attachments.first?.originalPath, stale)
        _ = try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery"))
        let path = try XCTUnwrap(db.load().first?.pdfPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("bookmark contents".utf8))
    }

    func testBackupRestoreRelocatesAttachmentsAndRetainsSafetyBackup() throws {
        let db = try database()
        let pdf = directory.appendingPathComponent("paper.pdf"), data = directory.appendingPathComponent("data.csv")
        try Data("pdf fixture".utf8).write(to: pdf); try Data("x,y\n1,2".utf8).write(to: data)
        let collection = LibraryCollection(name: "Root")
        try db.upsertCollection(collection)
        let item = Reference(title: "Original", pdfPath: pdf.path, pdfBookmark: Data([1]), citationKey: "Original", collectionIDs: [collection.id],
                             attachments: [.init(name: "data", path: data.path, bookmark: Data([2]))])
        try db.upsert(item); try db.upsertTag(.init(name: "blue", colorHex: "#112233"))
        let backup = directory.appendingPathComponent("library.papershelfbackup")
        let manifest = try LibraryBackup.create(database: db, to: backup)
        XCTAssertEqual(manifest.attachments.count, 2)
        let current = Reference(title: "Current library")
        try db.replaceAll(with: .init(references: [current]))
        let result = try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery"))
        XCTAssertEqual(result.restoredReferences, 1); XCTAssertEqual(result.restoredCollections, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.safetyBackupURL.path))
        let saved = try XCTUnwrap(db.load().first)
        XCTAssertEqual(saved.id, item.id); XCTAssertEqual(saved.title, item.title); XCTAssertNil(saved.pdfBookmark)
        XCTAssertNotEqual(saved.pdfPath, pdf.path); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: XCTUnwrap(saved.pdfPath))), Data("pdf fixture".utf8))
        XCTAssertNil(saved.attachments[0].bookmark)
        XCTAssertEqual(try Data(contentsOf: data), Data("x,y\n1,2".utf8), "Original attachments must remain untouched")
        let safetyTarget = try database("safety.sqlite")
        _ = try LibraryBackup.restore(from: result.safetyBackupURL, into: safetyTarget, backupDirectory: directory.appendingPathComponent("safety-recovery"))
        XCTAssertEqual(try safetyTarget.load(), [current])
    }

    func testRestoreUsesChosenAttachmentRootWithoutOverwritingExistingFiles() throws {
        let db = try database()
        let original = directory.appendingPathComponent("source.pdf")
        try Data("source attachment".utf8).write(to: original)
        try db.upsert(Reference(title: "Restorable", pdfPath: original.path))
        let backup = directory.appendingPathComponent("custom-root.papershelfbackup")
        _ = try LibraryBackup.create(database: db, to: backup)
        let attachmentRoot = directory.appendingPathComponent("chosen-files", isDirectory: true)
        try FileManager.default.createDirectory(at: attachmentRoot, withIntermediateDirectories: false)
        let existing = attachmentRoot.appendingPathComponent("source.pdf")
        try Data("keep existing".utf8).write(to: existing)
        let recovery = directory.appendingPathComponent("safety-backups", isDirectory: true)
        let result = try LibraryBackup.restore(from: backup, into: db, backupDirectory: recovery, attachmentDirectory: attachmentRoot)
        XCTAssertEqual(result.attachmentsDirectory?.deletingLastPathComponent().standardizedFileURL, attachmentRoot.standardizedFileURL)
        XCTAssertEqual(result.safetyBackupURL.deletingLastPathComponent().standardizedFileURL, recovery.standardizedFileURL)
        let restoredPath = try XCTUnwrap(db.load().first?.pdfPath)
        XCTAssertEqual(URL(fileURLWithPath: restoredPath).deletingLastPathComponent(), result.attachmentsDirectory)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: restoredPath)), Data("source attachment".utf8))
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep existing".utf8))
        XCTAssertEqual(try Data(contentsOf: original), Data("source attachment".utf8))
    }

    func testTamperedBackupRejectedWithoutChangingCurrentLibrary() throws {
        let db = try database(); let item = Reference(title: "Keep this")
        try db.upsert(item)
        let backup = directory.appendingPathComponent("bad.papershelfbackup")
        _ = try LibraryBackup.create(database: db, to: backup)
        try Data("tampered".utf8).write(to: backup.appendingPathComponent("library.sqlite"))
        XCTAssertThrowsError(try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery")))
        XCTAssertEqual(try db.load(), [item])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery").path))
    }

    func testBackupRejectsAttachmentPathTraversalBeforeSafetyMutation() throws {
        let db = try database()
        let pdf = directory.appendingPathComponent("paper.pdf"); try Data("pdf".utf8).write(to: pdf)
        let original = Reference(title: "Keep", pdfPath: pdf.path); try db.upsert(original)
        let backup = directory.appendingPathComponent("paths.papershelfbackup")
        var manifest = try LibraryBackup.create(database: db, to: backup)
        manifest.attachments[0].relativePath = "../paper.pdf"
        try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery")))
        XCTAssertEqual(try db.load(), [original])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery").path))
    }

    func testRestoreDatabaseFailureRollsBackCurrentContentAndKeepsSafetyBackup() throws {
        let db = try database()
        let backup = directory.appendingPathComponent("restore.papershelfbackup")
        try db.upsert(Reference(title: "Reject on restore", doi: "10.1234/reject"))
        _ = try LibraryBackup.create(database: db, to: backup)
        let current = Reference(title: "Current valuable library")
        try db.replaceAll(with: .init(references: [current]))
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(db.url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "CREATE TRIGGER reject_restore BEFORE INSERT ON library_records WHEN NEW.normalized_doi='10.1234/reject' BEGIN SELECT RAISE(ABORT, 'test rollback'); END", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let recovery = directory.appendingPathComponent("recovery")
        XCTAssertThrowsError(try LibraryBackup.restore(from: backup, into: db, backupDirectory: recovery))
        XCTAssertEqual(try db.load(), [current])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).contains { $0.pathExtension == "papershelfbackup" })
    }

    func testBackupIncludesTemplatesButDoesNotRestoreAPIPermissions() throws {
        let db = try database(); try db.upsert(Reference(title: "Template library"))
        let preferences = directory.appendingPathComponent("preferences.json")
        let original: [String: Any] = ["templates": ["metadata": "Custom {{title}}", "annotation": "{{text}}"], "localAPI": ["enabled": true, "readOnly": false], "citationKeyTemplate": "{author}{year}"]
        try JSONSerialization.data(withJSONObject: original).write(to: preferences)
        let backup = directory.appendingPathComponent("preferences.papershelfbackup")
        let manifest = try LibraryBackup.create(database: db, to: backup, preferencesURL: preferences)
        XCTAssertNotNil(manifest.preferencesSHA256)
        let current = Data(#"{"templates":{"metadata":"Current {{title}}","annotation":"{{comment}}"},"localAPI":{"enabled":false}}"#.utf8)
        try current.write(to: preferences)
        let result = try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("recovery"), preferencesURL: preferences)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(result.restoredPreferencesData)) as? [String: Any])
        XCTAssertNil(restored["localAPI"])
        XCTAssertEqual((restored["templates"] as? [String: String])?["metadata"], "Custom {{title}}")
        XCTAssertEqual(try Data(contentsOf: result.safetyBackupURL.appendingPathComponent("preferences.json")), current)
        XCTAssertEqual(try Data(contentsOf: preferences), current, "Caller installs the validated returned preferences explicitly")
        try Data("{}".utf8).write(to: backup.appendingPathComponent("preferences.json"))
        XCTAssertThrowsError(try LibraryBackup.restore(from: backup, into: db, backupDirectory: directory.appendingPathComponent("other")))
    }

    func testZoteroReadsCommittedWALWithoutChangingSource() throws {
        let source = directory.appendingPathComponent("zotero.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &connection), SQLITE_OK)
        let handle = try XCTUnwrap(connection); defer { sqlite3_close(handle) }
        let sql = """
        PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;
        CREATE TABLE itemTypes(itemTypeID INTEGER, typeName TEXT);
        CREATE TABLE items(itemID INTEGER, itemTypeID INTEGER, libraryID INTEGER, key TEXT, dateAdded TEXT);
        CREATE TABLE fields(fieldID INTEGER, fieldName TEXT);
        CREATE TABLE itemDataValues(valueID INTEGER, value TEXT);
        CREATE TABLE itemData(itemID INTEGER, fieldID INTEGER, valueID INTEGER);
        CREATE TABLE collections(collectionID INTEGER, collectionName TEXT, parentCollectionID INTEGER, libraryID INTEGER, key TEXT);
        CREATE TABLE collectionItems(collectionID INTEGER, itemID INTEGER);
        CREATE TABLE itemAttachments(itemID INTEGER, parentItemID INTEGER, path TEXT, contentType TEXT);
        CREATE TABLE itemNotes(itemID INTEGER, parentItemID INTEGER, note TEXT);
        CREATE TABLE deletedItems(itemID INTEGER);
        INSERT INTO itemTypes VALUES(1,'journalArticle'),(2,'attachment'),(3,'note');
        INSERT INTO items VALUES(1,1,1,'PAPERKEY','2026-10-18 10:00:00'),(2,2,1,'FILEKEY','2026-10-18 10:00:00'),(3,1,1,'DELETED','2026-10-18 10:00:00'),(4,3,1,'NOTEKEY','2026-10-18 10:00:00');
        INSERT INTO fields VALUES(1,'title'),(2,'DOI'),(3,'volume');
        INSERT INTO itemDataValues VALUES(1,'From WAL'),(2,'10.1234/zotero'),(3,'7');
        INSERT INTO itemData VALUES(1,1,1),(1,2,2),(1,3,3);
        INSERT INTO collections VALUES(1,'Parent',NULL,1,'COLLROOT'),(2,'Child',1,1,'COLLCHLD');
        INSERT INTO collectionItems VALUES(2,1);
        INSERT INTO itemAttachments VALUES(2,1,'storage:paper.pdf','application/pdf');
        INSERT INTO itemNotes VALUES(4,1,'<p>Reading notes</p>');
        INSERT INTO deletedItems VALUES(3);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        let attachment = directory.appendingPathComponent("storage/FILEKEY/paper.pdf")
        try FileManager.default.createDirectory(at: attachment.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("paper".utf8).write(to: attachment)
        let before = try Data(contentsOf: source), beforeWAL = try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal"))
        let result = try ZoteroImporter.read(url: source)
        XCTAssertEqual(result.references.count, 1); XCTAssertEqual(result.collections.count, 2)
        let item = try XCTUnwrap(result.references.first)
        XCTAssertEqual(item.title, "From WAL"); XCTAssertEqual(item.volume, "7"); XCTAssertEqual(item.notes, "Reading notes")
        XCTAssertEqual(item.pdfPath, attachment.path); XCTAssertEqual(item.collectionIDs.count, 1)
        XCTAssertEqual(try Data(contentsOf: source), before); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: source.path + "-wal")), beforeWAL)
        XCTAssertEqual(try ZoteroImporter.read(url: source).references.first?.id, item.id)
    }

    func testZoteroLinkedAttachmentRootRejectsTraversalAndSupportsMetadataOnly() throws {
        let source = directory.appendingPathComponent("linked-zotero.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(source.path, &connection), SQLITE_OK)
        let handle = try XCTUnwrap(connection); defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE itemTypes(itemTypeID INTEGER, typeName TEXT);
        CREATE TABLE items(itemID INTEGER, itemTypeID INTEGER, libraryID INTEGER, key TEXT);
        CREATE TABLE fields(fieldID INTEGER, fieldName TEXT);
        CREATE TABLE itemDataValues(valueID INTEGER, value TEXT);
        CREATE TABLE itemData(itemID INTEGER, fieldID INTEGER, valueID INTEGER);
        CREATE TABLE itemAttachments(itemID INTEGER, parentItemID INTEGER, path TEXT, contentType TEXT);
        INSERT INTO itemTypes VALUES(1,'journalArticle'),(2,'attachment');
        INSERT INTO items VALUES(1,1,1,'PAPERKEY'),(2,2,1,'GOODFILE'),(3,2,1,'PARENT'),(4,2,1,'ABSOLUTE'),(5,2,1,'SYMLINK'),(6,2,1,'MISSING');
        INSERT INTO fields VALUES(1,'title');
        INSERT INTO itemDataValues VALUES(1,'External attachments');
        INSERT INTO itemData VALUES(1,1,1);
        INSERT INTO itemAttachments VALUES
          (2,1,'attachments:papers/good.pdf','application/pdf'),
          (3,1,'attachments:../outside.pdf','application/pdf'),
          (4,1,'attachments:/outside.pdf','application/pdf'),
          (5,1,'attachments:escape.pdf','application/pdf'),
          (6,1,'attachments:missing.pdf','application/pdf');
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        let root = directory.appendingPathComponent("external")
        let good = root.appendingPathComponent("papers/good.pdf")
        try FileManager.default.createDirectory(at: good.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("good external PDF".utf8).write(to: good)
        let outside = directory.appendingPathComponent("outside.pdf")
        try Data("outside file".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.pdf"), withDestinationURL: outside)
        let before = try Data(contentsOf: source)
        let imported = try ZoteroImporter.read(url: source, linkedAttachmentDirectory: root)
        XCTAssertEqual(imported.references.first?.pdfPath, good.path)
        XCTAssertEqual(imported.references.first?.attachments.count, 0)
        XCTAssertEqual(imported.warnings.count, 4)
        XCTAssertTrue(imported.warnings.contains { $0.contains("附件不可读") && $0.contains("missing.pdf") })
        XCTAssertEqual(try Data(contentsOf: source), before)
        let noRoot = try ZoteroImporter.read(url: source)
        XCTAssertNil(noRoot.references.first?.pdfPath); XCTAssertEqual(noRoot.warnings.count, 5)
        let metadata = try ZoteroImporter.read(url: source, includeAttachments: false)
        XCTAssertEqual(metadata.references.first?.title, "External attachments")
        XCTAssertNil(metadata.references.first?.pdfPath); XCTAssertTrue(metadata.references.first?.attachments.isEmpty == true)
        XCTAssertTrue(metadata.warnings.isEmpty)
        XCTAssertEqual(try Data(contentsOf: good), Data("good external PDF".utf8))
        XCTAssertEqual(try Data(contentsOf: outside), Data("outside file".utf8))
    }

    func testCancelledZoteroReadStopsBeforeOpeningSource() async throws {
        let nonexistent = directory.appendingPathComponent("not-opened.sqlite")
        let worker = Task.detached { () throws -> LibraryImport in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ZoteroImporter.read(url: nonexistent)
        }
        do { _ = try await worker.value; XCTFail("Cancelled import must not start") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation before source I/O, received \(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonexistent.path))
    }
}

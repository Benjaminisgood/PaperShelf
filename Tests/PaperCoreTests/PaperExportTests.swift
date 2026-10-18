import XCTest
@testable import PaperCore

final class PaperExportTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    func testNestedTemplatesPreserveLiteralContentAndValidateConditions() throws {
        let text = try PaperTemplateRenderer.render("{{#a}}A {{a}}{{#b}} B {{b}}{{/b}}{{/a}}{{#empty}}HIDDEN{{/empty}}", values: ["a":"{{b}}", "b":"exact", "empty":""])
        XCTAssertEqual(text, "A {{b}} B exact")
        XCTAssertThrowsError(try PaperTemplateRenderer.render("{{#empty}}{{/wrong}}", values: ["empty":""]))
        XCTAssertThrowsError(try PaperTemplateRenderer.render("{{missing}}", values: [:]))
        XCTAssertThrowsError(try PaperTemplateRenderer.render("{{#a}}unclosed", values: ["a":""]))
    }

    func testTextBundleContainsEveryImageAndDoesNotOverwriteExistingArtifact() throws {
        let reference = Reference(title: "../Research/name", authors: ["Doe, Jane"], abstract: String(repeating: "Full text. ", count: 10000))
        let image = Data([137,80,78,71,13,10,26,10])
        let annotations = [PaperAnnotation(id: "a", page: 2, kind: "Square", text: "", comment: "Image comment", imagePNG: image)]
        let first = try PaperDetailedExport.export(reference: reference, annotations: annotations, to: directory)
        let second = try PaperDetailedExport.export(reference: reference, annotations: annotations, to: directory)
        XCTAssertEqual(first.pathExtension, "textbundle"); XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.deletingLastPathComponent().path, directory.path)
        XCTAssertEqual(try Data(contentsOf: first.appendingPathComponent("assets/annotation-1.png")), image)
        let body = try String(contentsOf: first.appendingPathComponent("text.md"), encoding: .utf8)
        XCTAssertTrue(body.contains(reference.abstract)); XCTAssertTrue(body.contains("assets/annotation-1.png"))
        let info = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: first.appendingPathComponent("info.json"))) as? [String: Any])
        XCTAssertEqual(info["version"] as? Int, 2)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".papershelf-export") })
    }

    func testPlainMarkdownAndCustomFields() throws {
        let reference = Reference(title: "Test", extraFields: ["custom":"Preserved value"])
        let output = try PaperDetailedExport.export(reference: reference, annotations: [], to: directory,
                                                    templates: .init(metadata: "{{title}} / {{custom}}", annotation: "{{text}}"))
        XCTAssertEqual(output.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: output, encoding: .utf8), "Test / Preserved value")
        XCTAssertThrowsError(try PaperDetailedExport.export(reference: reference, annotations: [], to: directory,
                                                            templates: .init(metadata: "{{typo}}")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testFileCopyCollisionMoveAndRollback() throws {
        let source = directory.appendingPathComponent("original.csv")
        let root = directory.appendingPathComponent("library")
        let data = Data("a,b\n1,2\n".utf8); try data.write(to: source)
        let reference = Reference(title: "Data", year: "2026", citationKey: "doe2026")
        let first = try PaperFileOrganizer.place(source: source, reference: reference, in: root, kind: .attachment)
        let second = try PaperFileOrganizer.place(source: source, reference: reference, in: root, kind: .attachment)
        XCTAssertEqual(first.action, .copy); XCTAssertNotEqual(first.destinationURL, second.destinationURL)
        XCTAssertTrue(first.destinationURL.path.contains("Attachments"))
        XCTAssertEqual(try Data(contentsOf: source), data)
        try first.rollback(); XCTAssertFalse(FileManager.default.fileExists(atPath: first.destinationURL.path))
        let moved = try PaperFileOrganizer.place(source: source, reference: reference, in: root,
                                                options: .init(action: .move, grouping: .year, layout: .paperFolders, renameTemplate: "{year}-{title}"), kind: .attachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(moved.destinationURL.path.contains("2026"))
        XCTAssertEqual(moved.destinationURL.lastPathComponent, "original.csv", "Non-PDF attachments retain descriptive source filenames")
        try moved.rollback(); XCTAssertEqual(try Data(contentsOf: source), data)
    }

    func testOrganizerRejectsSymlinkEscapeAndRollbackOfChangedFile() throws {
        let source = directory.appendingPathComponent("data.txt"); try Data("original".utf8).write(to: source)
        let root = directory.appendingPathComponent("root"); let outside = directory.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("2026"), withDestinationURL: outside)
        let reference = Reference(title: "Test", year: "2026")
        XCTAssertThrowsError(try PaperFileOrganizer.place(source: source, reference: reference, in: root, options: .init(grouping: .year)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        let placement = try PaperFileOrganizer.place(source: source, reference: reference, in: root)
        try Data("user changed".utf8).write(to: placement.destinationURL)
        XCTAssertThrowsError(try placement.rollback())
        XCTAssertEqual(try String(contentsOf: placement.destinationURL, encoding: .utf8), "user changed")
    }

    func testAttachmentsBookmarkArbitraryFileAndMissingRenameValueKeepsName() throws {
        let source = directory.appendingPathComponent("notes.md"); try Data("# note".utf8).write(to: source)
        let attachment = try PaperAttachments.link(source)
        XCTAssertEqual(attachment.name, "notes.md"); XCTAssertNotNil(attachment.bookmark)
        XCTAssertEqual(try PaperAttachments.resolvedURL(for: attachment).resolvingSymlinksInPath().path, source.resolvingSymlinksInPath().path)
        let placed = try PaperFileOrganizer.place(source: source, reference: Reference(title: "No Year"), in: directory.appendingPathComponent("library"),
                                                  options: .init(renameTemplate: "{year}-{title}"), kind: .attachment)
        XCTAssertEqual(placed.destinationURL.lastPathComponent, "notes.md")
    }
}

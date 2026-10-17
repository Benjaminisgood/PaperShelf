import XCTest
import PDFKit
import CoreGraphics
@testable import PaperCore

final class PDFLinksTests: XCTestCase {
    func testOriginalUnchangedBookmarkAndAnnotationPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Fixture.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let document = try XCTUnwrap(PDFDocument(url: url))
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: "Bookmark fixture", PDFDocumentAttribute.authorAttribute: "Test Author"]
        let annotation = PDFAnnotation(bounds: CGRect(x: 50, y: 50, width: 100, height: 40), forType: .text, withProperties: nil)
        annotation.contents = "A note that must survive extraction"
        document.page(at: 0)!.addAnnotation(annotation)
        XCTAssertTrue(document.write(to: url))
        let original = try Data(contentsOf: url)

        let reference = try PDFLinks.reference(from: url)
        XCTAssertEqual(reference.title, "Bookmark fixture")
        XCTAssertEqual(reference.authors, ["Test Author"])
        XCTAssertEqual(reference.pdfPath, url.path)
        XCTAssertNotNil(reference.pdfBookmark)
        let db = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
        try db.upsert(reference)
        let restored = try XCTUnwrap(db.load().first)
        let notes = try PDFLinks.annotations(for: restored)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.page, 1)
        XCTAssertEqual(notes.first?.comment, "A note that must survive extraction")
        XCTAssertEqual(try Data(contentsOf: url), original)
        try db.delete(id: reference.id)
        XCTAssertEqual(try Data(contentsOf: url), original, "Removing the record must not remove or mutate the original PDF")
    }

    func testMissingAndInvalidAttachmentFailClearly() throws {
        var reference = Reference()
        reference.pdfPath = "/nonexistent/\(UUID()).pdf"
        XCTAssertThrowsError(try PDFLinks.annotations(for: reference))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not a PDF".utf8).write(to: url)
        XCTAssertThrowsError(try PDFLinks.reference(from: url))
    }
}

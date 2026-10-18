import XCTest
@testable import PaperCore
final class ReferenceEditsTests: XCTestCase {
    func testEditorPreservesConcurrentAttachmentAndNotes() throws {
        let base = Reference(title: "Original")
        var edited = base; edited.title = "Revised"
        var current = base; current.pdfPath = "/new/paper.pdf"; current.notes = "Later note"; current.rating = 4
        let result = try ReferenceEdits.merge(base: base, edited: edited, current: current)
        XCTAssertEqual(result.title, "Revised"); XCTAssertEqual(result.pdfPath, current.pdfPath)
        XCTAssertEqual(result.notes, "Later note"); XCTAssertEqual(result.rating, 4)
    }
    func testSameFieldConflictDoesNotOverwrite() throws {
        let base = Reference(title: "Original")
        var edited = base; edited.title = "Editor"
        var current = base; current.title = "Newer"
        XCTAssertThrowsError(try ReferenceEdits.merge(base: base, edited: edited, current: current))
    }
    func testIndependentExtraFieldsMergeAndRemoval() throws {
        var base = Reference(title: "Paper"); base.extraFields = ["a":"old", "remove":"yes"]
        var edited = base; edited.extraFields["a"] = "edited"; edited.extraFields.removeValue(forKey:"remove")
        var current = base; current.extraFields["b"] = "later"
        XCTAssertEqual(try ReferenceEdits.merge(base:base,edited:edited,current:current).extraFields, ["a":"edited","b":"later"])
    }
}

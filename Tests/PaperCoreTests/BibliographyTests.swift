import XCTest
@testable import PaperCore

final class BibliographyTests: XCTestCase {
    func testNestedBibTeXAndMacros() throws {
        let input = #"""
        % A real export can use macros and multiline, nested braces.
        @string{journal = "Surface " # "Science"}
        @comment{Ignored {nested} content}
        @article{sample,
          title = {A {TAP} method:
        full resolution},
          author = {Doe, Jane and {Research and Development} and 王, 小明},
          year = 2026,
          journal = journal,
          doi = {10.1234/example},
          abstract = "A {nested \"quote\"} field",
        }
        """#
        let references = try Bibliography.parse(input, format: ".bib")
        XCTAssertEqual(references.count, 1)
        XCTAssertEqual(references[0].title, "A {TAP} method:\nfull resolution")
        XCTAssertEqual(references[0].authors, ["Doe, Jane", "Research and Development", "王, 小明"])
        XCTAssertEqual(references[0].journal, "Surface Science")
        XCTAssertEqual(references[0].year, "2026")
    }

    func testExportRoundTripPreservesLiteralText() throws {
        let original = Reference(title: #"Literal {braces}, \alpha, $5 & 20%_#"#,
                                 authors: ["Doe, Jane", "Research and Development", #"A \ B {C}"#],
                                 year: "2026", journal: "Journal & Notes", doi: "10.1234/a_b",
                                 url: "https://example.com/?a=1&b=2", abstract: "Line one\nLine two",
                                 notes: #"Keep \textbackslash{} and {data}"#,
                                 tags: ["catalysis; chemistry", "A,B", "测试"], collection: "Review")
        let exported = Bibliography.exportBibTeX([original])
        let parsed = try XCTUnwrap(Bibliography.parse(exported, format: "bibtex").first)
        XCTAssertEqual(parsed.title, original.title)
        XCTAssertEqual(parsed.authors, original.authors)
        XCTAssertEqual(parsed.year, original.year)
        XCTAssertEqual(parsed.journal, original.journal)
        XCTAssertEqual(parsed.doi, original.doi)
        XCTAssertEqual(parsed.url, original.url)
        XCTAssertEqual(parsed.abstract, original.abstract)
        XCTAssertEqual(parsed.notes, original.notes)
        XCTAssertEqual(parsed.tags, original.tags)
        XCTAssertEqual(parsed.collection, original.collection)
    }

    func testMalformedBibTeXIsRejectedWithoutPartialImport() {
        for text in ["", "@article{a,title={truncated}", "@article{a,title=\"unfinished}",
                     "@article{a,title={good}}\n@article{b,title={broken}",
                     "@article{a,title={one} year={2026}}", "@article{a,title=unknown}"] {
            XCTAssertThrowsError(try Bibliography.parse(text, format: "bib"), text)
        }
    }

    func testBibTeXExportKeepsPersonalNamesParseable() {
        let reference = Reference(title: "Author semantics", authors: ["Doe, Jane", "Smith, John", "Research and Development"])
        let text = Bibliography.exportBibTeX([reference])
        XCTAssertTrue(text.contains("author = {Doe, Jane and Smith, John and {Research and Development}}"))
    }

    func testRISMultilineRepeatedFieldsAndMultipleRecords() throws {
        let input = "\u{FEFF}TY  - JOUR\r\nTI  - Kinetics\r\nAU  - Doe, Jane\r\nAU  - 王, 小明\r\nPY  - 2026/10/18\r\nAB  - First line\r\n      Continued line\r\nKW  - TAP\r\nKW  - kinetics\r\nDO  - 10.1234/test\r\nER  - \r\n\r\nTY  - BOOK\r\nT1  - Another item\r\nER  -\r\n"
        let references = try Bibliography.parse(input, format: "ris")
        XCTAssertEqual(references.count, 2)
        XCTAssertEqual(references[0].authors, ["Doe, Jane", "王, 小明"])
        XCTAssertEqual(references[0].abstract, "First line\nContinued line")
        XCTAssertEqual(references[0].tags, ["TAP", "kinetics"])
        XCTAssertEqual(references[0].year, "2026")
        XCTAssertEqual(references[1].title, "Another item")
    }

    func testRISRequiresCompleteRecords() {
        for text in ["TY  - JOUR\nTI  - Incomplete", "TI  - No type\nER  -", "TY  - JOUR\nTY  - BOOK\nER  -", "TY  - JOUR\nunindented garbage\nER  -"] {
            XCTAssertThrowsError(try Bibliography.parse(text, format: "ris"), text)
        }
        XCTAssertThrowsError(try Bibliography.parse("[]", format: "json"))
    }

    func testMarkdownEscapesUntrustedMarkup() {
        let text = Bibliography.exportMarkdown([Reference(title: "[fake](file) <script>", notes: "# heading")])
        XCTAssertTrue(text.contains(#"\[fake\](file) \<script\>"#))
        XCTAssertTrue(text.contains("\\# heading"))
    }
}

import XCTest
import PDFKit
import AppKit
import CoreText
@testable import PaperCore

final class PDFAdvancedTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func draw(_ text: String, in context: CGContext, at point: CGPoint, size: CGFloat = 20) {
        let attributes: [NSAttributedString.Key: Any] = [.font: CTFontCreateWithName("TimesNewRomanPSMT" as CFString, size, nil), .foregroundColor: NSColor.black]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private func makePDF(name: String = "fixture", drawPage: (CGContext) -> Void) throws -> URL {
        let url = directory.appendingPathComponent(name + ".pdf")
        var bounds = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &bounds, nil))
        context.beginPDFPage(nil); drawPage(context); context.endPDFPage(); context.closePDF()
        return url
    }

    func testDisjointQuadrilateralsExcludeInterveningTextAndKeepColor() throws {
        let url = try makePDF { context in
            draw("FIRST selected", in: context, at: CGPoint(x: 50, y: 720))
            draw("NOT SELECTED", in: context, at: CGPoint(x: 50, y: 680))
            draw("SECOND selected", in: context, at: CGPoint(x: 50, y: 640))
        }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        let first = try XCTUnwrap(document.findString("FIRST selected", withOptions: []).first).bounds(for: page)
        let second = try XCTUnwrap(document.findString("SECOND selected", withOptions: []).first).bounds(for: page)
        let bounds = first.union(second)
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.8, alpha: 0.5)
        annotation.quadrilateralPoints = [first, second].flatMap { rect in
            [CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)]
                .map { NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        }
        annotation.contents = "Exact regions"
        page.addAnnotation(annotation); XCTAssertTrue(document.write(to: url))
        let before = try Data(contentsOf: url)
        let reference = try PDFLinks.reference(from: url)
        let extracted = try XCTUnwrap(PDFLinks.annotations(for: reference).first)
        XCTAssertTrue(extracted.text.contains("FIRST selected"), extracted.text)
        XCTAssertTrue(extracted.text.contains("SECOND selected"), extracted.text + " quads=" + String(describing: extracted.quadrilaterals))
        XCTAssertFalse(extracted.text.contains("NOT SELECTED"))
        XCTAssertEqual(extracted.quadrilaterals.count, 2)
        XCTAssertEqual(extracted.colorHex, "#3399CC")
        let stored = try XCTUnwrap(PDFDocument(url: url)?.page(at: 0)?.annotations.first)
        XCTAssertEqual(extracted.opacity, Double(stored.color.alphaComponent), accuracy: 0.02, "Retain the persisted PDF color; PDFKit may flatten alpha when saving")
        XCTAssertEqual(extracted.textSource, "pdf-quads")
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testShapeImagesAndPageTextAreExportableWithoutMutatingPDF() throws {
        let url = try makePDF { context in
            context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 80, y: 100, width: 100, height: 80))
            draw("Caption content", in: context, at: CGPoint(x: 50, y: 720))
        }
        let document = try XCTUnwrap(PDFDocument(url: url))
        let page = try XCTUnwrap(document.page(at: 0))
        for kind in [PDFAnnotationSubtype.square, .circle] {
            page.addAnnotation(PDFAnnotation(bounds: CGRect(x: 70, y: 90, width: 120, height: 100), forType: kind, withProperties: nil))
        }
        XCTAssertTrue(document.write(to: url))
        let reference = try PDFLinks.reference(from: url)
        let annotations = try PDFLinks.annotations(for: reference)
        XCTAssertEqual(Set(annotations.map(\.kind)), ["Square", "Circle"])
        for annotation in annotations {
            let image = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(annotation.imagePNG)))
            XCTAssertEqual(image.pixelsWide, 240); XCTAssertEqual(image.pixelsHigh, 200)
        }
        let text = try PDFLinks.extractedText(for: reference, ocrIfNeeded: false)
        XCTAssertEqual(text.count, 1); XCTAssertEqual(text[0].source, "pdf-text")
        XCTAssertTrue(text[0].text.contains("Caption content"))
    }

    func testScannedPageUsesSystemOCRAndLabelsItsProvenance() throws {
        let bitmap = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1)); bitmap.fill(CGRect(x: 0, y: 0, width: 1200, height: 400))
        draw("SCANNED RESEARCH 2026", in: bitmap, at: CGPoint(x: 60, y: 180), size: 70)
        let image = try XCTUnwrap(bitmap.makeImage())
        let url = try makePDF(name: "scan") { context in context.draw(image, in: CGRect(x: 0, y: 400, width: 600, height: 200)) }
        let reference = try PDFLinks.reference(from: url)
        XCTAssertTrue(try PDFLinks.extractedText(for: reference, ocrIfNeeded: false)[0].text.isEmpty)
        let text = try PDFLinks.extractedText(for: reference)
        XCTAssertEqual(text[0].source, "ocr")
        XCTAssertTrue(text[0].text.contains("SCANNED RESEARCH"), text[0].text)
    }

    func testIdentifierExtractionUsesFullTextAndDeclinesAmbiguity() throws {
        let text = String(repeating: "Original content without identifiers.\n", count: 10000)
            + "DOI: 10.1234/example. ISBN: 978-0-306-40615-7 arXiv: 1706.03762v2"
        let result = PDFMetadataIdentifiers.extract(metadata: "", text: text)
        XCTAssertEqual(result.doi, "10.1234/example")
        XCTAssertEqual(result.isbn, "9780306406157")
        XCTAssertEqual(result.arxivID, "1706.03762v2")
        XCTAssertNil(PDFMetadataIdentifiers.extract(metadata: "", text: "10.1234/one 10.5678/two").doi)
        XCTAssertEqual(PDFMetadataIdentifiers.extract(metadata: "doi: 10.9999/metadata", text: text).doi, "10.9999/metadata")
        XCTAssertNil(PDFMetadataIdentifiers.extract(metadata: "", text: "ISBN: 9780306406158").isbn)
    }
}

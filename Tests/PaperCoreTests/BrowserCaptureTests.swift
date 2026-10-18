import XCTest
@testable import PaperCore

final class BrowserCaptureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    func testCaptureDestinationUsesSelectedRootAndRejectsEscapingSymlink() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        let first = base.appendingPathComponent("Library"), second = base.appendingPathComponent("Changed")
        try fm.createDirectory(at: first, withIntermediateDirectories: false)
        try fm.createDirectory(at: second, withIntermediateDirectories: false)
        let a = try BrowserCaptureStorage.destination(in: first)
        let b = try BrowserCaptureStorage.destination(in: first)
        let c = try BrowserCaptureStorage.destination(in: second)
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.path.hasPrefix(first.resolvingSymlinksInPath().path + "/BrowserCaptures/"))
        XCTAssertTrue(c.path.hasPrefix(second.resolvingSymlinksInPath().path + "/BrowserCaptures/"))
        XCTAssertFalse(fm.fileExists(atPath: a.path))
        let escaped = base.appendingPathComponent("Escaped")
        try fm.createDirectory(at: escaped, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: escaped.appendingPathComponent("BrowserCaptures"), withDestinationURL: first)
        XCTAssertThrowsError(try BrowserCaptureStorage.destination(in: escaped))
        XCTAssertThrowsError(try BrowserCaptureStorage.destination(in: URL(string: "https://example.org/")!))
        XCTAssertThrowsError(try BrowserCaptureStorage.destination(in: base.appendingPathComponent("Missing")))
    }
    private func fixture(title: String = "化学反应网络") -> BrowserCapturePayload {
        BrowserCapturePayload(capturedAt: ISO8601DateFormatter().string(from: now), sourceURL: "https://journals.example.org/paper?id=1",
                              title: title, authors: ["张三", "Doe, Jane"], year: "2024", journal: "Journal",
                              doi: "10.1234/example", abstract: "Full abstract\n第二段", selectedText: "原文证据",
                              pdfURLs: ["https://cdn.example.org/paper.pdf"])
    }

    func testRoundTripPreservesUnicodeEvidenceAndProvenance() throws {
        let payload = fixture()
        let restored = try BrowserCapturePayload.decode(payload.encodedURL(now: now), now: now)
        XCTAssertEqual(payload, restored)
        let reference = restored.reference()
        XCTAssertEqual(reference.abstract, payload.abstract)
        XCTAssertEqual(reference.authors, payload.authors)
        XCTAssertEqual(reference.url, payload.sourceURL)
        XCTAssertTrue(reference.notes.contains(payload.selectedText))
        XCTAssertTrue(reference.notes.contains(payload.id.uuidString))
        XCTAssertNil(reference.pdfPath)
        XCTAssertNil(reference.pdfBookmark)
    }

    func testRejectsEnvelopeAmbiguityAndAdditionalFields() throws {
        let valid = try fixture().encodedURL(now: now)
        for url in [valid.absoluteString + "&command=run", valid.absoluteString + "#ignored",
                    valid.absoluteString.replacingOccurrences(of: "capture?", with: "capture/run?"),
                    valid.absoluteString.replacingOccurrences(of: "papershelf:", with: "https:"),
                    "papershelf://user@capture?payload=e30", "papershelf://capture:80?payload=e30",
                    "papershelf://capture?payload=%%%", "papershelf://capture?payload=e30"] {
            XCTAssertThrowsError(try BrowserCapturePayload.decode(URL(string: url)!, now: now), url)
        }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture())) as? [String: Any])
        object["command"] = "open-file"
        let encoded = try JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try BrowserCapturePayload.decode(URL(string: "papershelf://capture?payload=\(encoded)")!, now: now))
    }

    func testRejectsExpiredFutureOversizedAndControlCharacters() throws {
        let valid = try fixture().encodedURL(now: now)
        XCTAssertThrowsError(try BrowserCapturePayload.decode(valid, now: now.addingTimeInterval(86401)))
        XCTAssertThrowsError(try BrowserCapturePayload.decode(valid, now: now.addingTimeInterval(-301)))
        XCTAssertThrowsError(try fixture(title: String(repeating: "字", count: 1000)).encodedURL(now: now))
        XCTAssertThrowsError(try fixture(title: "Title\u{0000}bad").encodedURL(now: now))
        XCTAssertThrowsError(try fixture(title: "   ").encodedURL(now: now))
    }

    func testRejectsDangerousDestinationsAndAmbiguousIPRepresentations() throws {
        let bad = ["file:///etc/passwd", "javascript:alert(1)", "http://localhost/p.pdf", "http://127.0.0.1/",
                   "http://127.1/", "http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/", "http://10.0.0.1/",
                   "https://192.168.1.2/", "http://169.254.169.254/", "http://172.16.0.1/", "http://100.64.0.1/",
                   "https://printer.local/", "https://host.internal/", "https://host.test/", "https://host.invalid/",
                   "https://example.org:8443/a.pdf", "https://user:secret@example.org/", "https://example.org./",
                   "https://[::1]/", "https://[::ffff:127.0.0.1]/", "https://[fc00::1]/", "https://[2002:7f00:1::]/",
                   "https://example.org\\@127.0.0.1/", "https://example.org/hello world"]
        for value in bad { XCTAssertThrowsError(try BrowserCaptureNetworkPolicy.publicURL(value), value) }
        for value in ["https://example.org/a.pdf?token=a%2Bb", "https://8.8.8.8/", "https://[2606:4700:4700::1111]/"] {
            XCTAssertNoThrow(try BrowserCaptureNetworkPolicy.publicURL(value), value)
        }
    }

    func testIPClassificationBlocksReservedAndTransitionNetworks() {
        for ip in ["0.0.0.0", "127.255.1.1", "10.1.1.1", "172.31.255.255", "192.0.2.1", "198.51.100.2", "203.0.113.1", "198.18.1.2", "224.1.2.3", "255.255.255.255", "::", "::1", "::ffff:8.8.8.8", "2001:db8::1", "2001::1", "2002::1", "fe80::1", "fc00::1", "ff00::1", "3fff::1"] {
            XCTAssertFalse(BrowserCaptureNetworkPolicy.isPublicIPAddress(ip), ip)
        }
        for ip in ["8.8.8.8", "1.1.1.1", "172.32.0.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(BrowserCaptureNetworkPolicy.isPublicIPAddress(ip), ip)
        }
    }

    func testInvalidVersionDOIYearAndURLFailBeforeSideEffects() throws {
        let baseline = fixture()
        for payload in [
            BrowserCapturePayload(version: 2, capturedAt: baseline.capturedAt, sourceURL: baseline.sourceURL, title: "Title"),
            BrowserCapturePayload(capturedAt: baseline.capturedAt, sourceURL: baseline.sourceURL, title: "Title", year: "tomorrow"),
            BrowserCapturePayload(capturedAt: baseline.capturedAt, sourceURL: baseline.sourceURL, title: "Title", doi: "not a DOI"),
            BrowserCapturePayload(capturedAt: baseline.capturedAt, sourceURL: baseline.sourceURL, title: "Title", pdfURLs: ["http://127.0.0.1/secret"])
        ] { XCTAssertThrowsError(try payload.encodedURL(now: now)) }
    }
}

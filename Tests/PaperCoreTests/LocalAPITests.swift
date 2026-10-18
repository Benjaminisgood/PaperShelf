import XCTest
@testable import PaperCore

final class LocalAPITests: XCTestCase {
    private func head(_ extra:String = "", method:String = "GET", target:String = "/api/v1/status") throws -> LocalHTTPRequest.Head {
        let result = try LocalHTTPRequest.parseHead(Data("\(method) \(target) HTTP/1.1\r\nHost: 127.0.0.1:29468\r\n\(extra)\r\n".utf8))
        return try XCTUnwrap(result)
    }
    func testAuthenticationHostAndOriginAreIndependentGates() throws {
        XCTAssertThrowsError(try LocalHTTPRequest.authorize(head(),token:"secret",port:29468,allowedOrigins:[]))
        XCTAssertNil(try LocalHTTPRequest.authorize(head("Authorization: Bearer secret\r\n"),token:"secret",port:29468,allowedOrigins:[]))
        XCTAssertThrowsError(try LocalHTTPRequest.authorize(head("Authorization: Bearer secret\r\nOrigin: https://evil.example\r\n"),token:"secret",port:29468,allowedOrigins:[]))
        XCTAssertThrowsError(try LocalHTTPRequest.authorize(head("Authorization: Bearer secret\r\n"),token:"secret",port:12345,allowedOrigins:[]))
        let preflight = try head("Origin: https://localhost:3456\r\nAccess-Control-Request-Method: POST\r\n",method:"OPTIONS")
        XCTAssertEqual(try LocalHTTPRequest.authorize(preflight,token:"secret",port:29468,allowedOrigins:["https://localhost:3456"]),"https://localhost:3456")
    }
    func testHTTPParserRejectsSmugglingAndOversizedBodies() throws {
        for extra in ["Content-Length: 1\r\nContent-Length: 1\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: -1\r\n", "Content-Length: 104857601\r\n", "Expect: 100-continue\r\n", " bad: value\r\n"] {
            XCTAssertThrowsError(try head(extra,method:"POST"),extra)
        }
        XCTAssertThrowsError(try head(target:"http://evil.example/api/v1/status"))
        XCTAssertNil(try LocalHTTPRequest.parseHead(Data("GET /api/v1/status HTTP/1.1\r\n".utf8)))
    }
    func testDefaultPolicyIsOffAndReadOnly() {
        let value = LocalAPIConfiguration()
        XCTAssertFalse(value.enabled); XCTAssertTrue(value.readOnly)
        XCTAssertTrue(value.trustedFolders.isEmpty); XCTAssertTrue(value.allowedOrigins.isEmpty)
    }
    func testOptionalPrivacyFieldsAndCSLAuthorStructure() throws {
        let reference = Reference(title:"Title",authors:["Doe, Jane","Organization"],year:"2024",abstract:"Private abstract",notes:"Private notes",pdfPath:"/private/paper.pdf",citationKey:"Doe2024",entryType:"article")
        let basic = LocalAPIRecords.object(reference)
        XCTAssertNil(basic["abstract"]); XCTAssertNil(basic["notes"]); XCTAssertNil(basic["pdfPath"]); XCTAssertNil(basic["pdfBookmark"])
        let rich = LocalAPIRecords.object(reference,include:["abstract","library","pdfPath"])
        XCTAssertEqual(rich["abstract"] as? String,reference.abstract); XCTAssertEqual(rich["notes"] as? String,reference.notes)
        let authors = try XCTUnwrap(LocalAPIRecords.csl(reference)["author"] as? [[String:String]])
        XCTAssertEqual(authors[0],["family":"Doe","given":"Jane"]); XCTAssertEqual(authors[1],["literal":"Organization"])
    }
    func testCreateRejectsFilesystemInjectionAndWrongFieldTypes() throws {
        XCTAssertThrowsError(try LocalAPIRecords.newReference(["title":"T","pdfPath":"/secret"]))
        XCTAssertThrowsError(try LocalAPIRecords.newReference(["title":"T","authors":"not an array"]))
        XCTAssertThrowsError(try LocalAPIRecords.newReference(["title":"T","collectionIDs":["bad"]]))
        XCTAssertEqual(try LocalAPIRecords.newReference(["title":"T","authors":["A"]]).authors,["A"])
    }
    func testTrustedFolderChecksSymlinksAndPathBoundaries() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trusted = root.appendingPathComponent("trusted"), outside = root.appendingPathComponent("trusted-other")
        try FileManager.default.createDirectory(at:trusted,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let good = trusted.appendingPathComponent("a.pdf"), bad = outside.appendingPathComponent("b.pdf")
        try Data("%PDF-".utf8).write(to:good); try Data("%PDF-".utf8).write(to:bad)
        let link = trusted.appendingPathComponent("link.pdf")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:bad)
        XCTAssertEqual(try LocalAPIRecords.trustedFile(good.path,folders:[trusted.path]),good)
        XCTAssertThrowsError(try LocalAPIRecords.trustedFile(bad.path,folders:[trusted.path]))
        XCTAssertThrowsError(try LocalAPIRecords.trustedFile(link.path,folders:[trusted.path]))
        XCTAssertThrowsError(try LocalAPIRecords.trustedFile(good.path,folders:["/"]))
    }
}

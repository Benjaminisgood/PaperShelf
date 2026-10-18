import XCTest
@testable import PaperCore

private final class LookupProtocol: URLProtocol {
    static var response: ((URLRequest) throws -> (Int, String))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, payload) = try Self.response(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(payload.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class MetadataLookupTests: XCTestCase {
    private func client() -> MetadataLookup {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [LookupProtocol.self]
        return MetadataLookup(session: URLSession(configuration: config))
    }
    func testISBNChecksumAndBookFields() async throws {
        XCTAssertTrue(MetadataLookup.validISBN("9780262035613")); XCTAssertTrue(MetadataLookup.validISBN("080442957X"))
        XCTAssertFalse(MetadataLookup.validISBN("9780262035614")); XCTAssertFalse(MetadataLookup.validISBN("08044295XX"))
        LookupProtocol.response = { request in
            XCTAssertEqual(request.url?.host, "openlibrary.org")
            return (200, #"{"ISBN:9780262035613":{"title":"Deep Learning","authors":[{"name":"Ian Goodfellow"}],"publish_date":"November 2016","publishers":[{"name":"MIT Press"}],"number_of_pages":800}}"#)
        }
        let value = try await client().fetch("ISBN 978-0-262-03561-3")
        XCTAssertEqual(value.entryType, "book"); XCTAssertEqual(value.year, "2016"); XCTAssertEqual(value.isbn, "9780262035613")
        XCTAssertEqual(value.publisher, "MIT Press"); XCTAssertEqual(value.extraFields["pagetotal"], "800")
    }
    func testArxivErrorWordInValidTitleIsNotFailure() async throws {
        LookupProtocol.response = { request in
            XCTAssertEqual(request.url?.host, "export.arxiv.org")
            return (200, """
            <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom"><title>Query result</title><entry><id>http://arxiv.org/abs/2002.09062v1</id><title>Error correction in models</title><published>2020-02-21T00:00:00Z</published><summary>A &amp; B</summary><author><name>Alice Smith</name></author><arxiv:doi>10.1234/example</arxiv:doi></entry></feed>
            """)
        }
        let value = try await client().fetch("https://arxiv.org/pdf/2002.09062.pdf")
        XCTAssertEqual(value.title, "Error correction in models"); XCTAssertEqual(value.authors, ["Alice Smith"])
        XCTAssertEqual(value.extraFields["arxivId"], "2002.09062"); XCTAssertEqual(value.doi, "10.1234/example")
        XCTAssertEqual(value.abstract, "A & B")
    }
    func testCrossrefNotFoundFallsBackToDataCite() async throws {
        LookupProtocol.response = { request in
            if request.url?.host == "api.crossref.org" { return (404, "{}") }
            XCTAssertEqual(request.url?.host, "api.datacite.org")
            return (200, #"{"data":{"attributes":{"titles":[{"title":"Open dataset"}],"creators":[{"name":"Research Team"}],"publicationYear":2025,"publisher":"Archive","types":{"resourceTypeGeneral":"Dataset"},"descriptions":[{"descriptionType":"Abstract","description":"Public experiment"}]}}}"#)
        }
        let value = try await client().fetch("10.5281/zenodo.12345")
        XCTAssertEqual(value.title, "Open dataset"); XCTAssertEqual(value.entryType, "dataset"); XCTAssertEqual(value.year, "2025")
    }
    func testInvalidInputNeverSendsRequest() async {
        LookupProtocol.response = { _ in XCTFail("Invalid identifier must not trigger a request"); return (400, "") }
        do { _ = try await client().fetch("not an identifier"); XCTFail("Expected validation failure") } catch { }
    }
}

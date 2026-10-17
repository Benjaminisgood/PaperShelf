import XCTest
@testable import PaperCore

private final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DOIClientTests: XCTestCase {
    private var session: URLSession!
    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: configuration)
    }
    override func tearDown() {
        session.invalidateAndCancel()
        session = nil
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testNormalizesDOIAndResolverURLs() throws {
        XCTAssertEqual(try DOIClient.normalize(" doi:10.1234/AbC "), "10.1234/AbC")
        XCTAssertEqual(try DOIClient.normalize("HTTPS://DOI.ORG/10.1234/a%2Fb"), "10.1234/a/b")
        XCTAssertEqual(try DOIClient.normalize("https://dx.doi.org/10.1234/example"), "10.1234/example")
        for input in ["", "10.12/test", "11.1234/test", "10.1234/", "10.1234/two words", "https://example.com/10.1234/test", "10.1234/<tag>"] {
            XCTAssertThrowsError(try DOIClient.normalize(input), input)
        }
    }

    func testFetchMapsCrossrefFieldsAndEncodesURL() async throws {
        StubURLProtocol.handler = { request in
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertTrue(request.url!.absoluteString.contains("a%3Fb%23c"))
            let data = #"""
            {"message":{"title":["A &amp; B"],"DOI":"10.1234/a?b#c",
            "author":[{"given":"Jane","family":"Doe"},{"name":"Research Group"},{"given":"Single"},{}],
            "published":{"date-parts":[[2026,10,18]]},"container-title":["Science"],
            "abstract":"<jats:p>First &lt; 2.</jats:p><jats:p>Second &amp; third.</jats:p>",
            "URL":"https://doi.org/10.1234/a?b#c"}}
            """#.data(using: .utf8)!
            return (200, data)
        }
        let reference = try await DOIClient(session: session).fetch("10.1234/a?b#c")
        XCTAssertEqual(reference.title, "A & B")
        XCTAssertEqual(reference.authors, ["Doe, Jane", "Research Group", "Single"])
        XCTAssertEqual(reference.year, "2026")
        XCTAssertEqual(reference.journal, "Science")
        XCTAssertEqual(reference.abstract, "First < 2.\nSecond & third.")
    }

    func testHTTPFailuresAndMalformedPayload() async throws {
        for (status, json, expected) in [(404, "{}", DOIClientError.notFound),
                                         (429, "{}", DOIClientError.httpStatus(429)),
                                         (503, "{}", DOIClientError.httpStatus(503)),
                                         (200, "not json", DOIClientError.invalidResponse),
                                         (200, "{}", DOIClientError.invalidResponse),
                                         (200, #"{"message":{"title":[]}}"#, DOIClientError.missingTitle)] {
            StubURLProtocol.handler = { _ in (status, Data(json.utf8)) }
            do {
                _ = try await DOIClient(session: session).fetch("10.1234/test")
                XCTFail("Expected error for \(status) / \(json)")
            } catch { XCTAssertEqual(error as? DOIClientError, expected) }
        }
    }

    func testNetworkTimeoutIsPropagated() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        do {
            _ = try await DOIClient(session: session).fetch("10.1234/test")
            XCTFail("Expected timeout")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
    }
}

import Foundation

public struct LocalAPIConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var port: UInt16
    public var readOnly: Bool
    public var trustedFolders: [String]
    public var allowedOrigins: [String]
    public init(enabled: Bool = false, port: UInt16 = 29468, readOnly: Bool = true,
                trustedFolders: [String] = [], allowedOrigins: [String] = []) {
        self.enabled = enabled; self.port = port; self.readOnly = readOnly
        self.trustedFolders = trustedFolders; self.allowedOrigins = allowedOrigins
    }
}

public struct LocalAPIConnectionInfo: Codable, Sendable {
    public let version: Int
    public let baseURL: String
    public let token: String
    public let processID: Int32
    public init(baseURL: String, token: String, processID: Int32) {
        version = 1; self.baseURL = baseURL; self.token = token; self.processID = processID
    }
}

public struct LocalAPISnapshot: Sendable {
    public let references: [Reference]
    public let collections: [LibraryCollection]
    public let tags: [LibraryTag]
    public init(references: [Reference], collections: [LibraryCollection], tags: [LibraryTag]) {
        self.references = references.filter { $0.deletedAt == nil }; self.collections = collections; self.tags = tags
    }
}

public struct LocalAPIError: LocalizedError {
    public let status: Int
    public let message: String
    public init(_ status: Int, _ message: String) { self.status = status; self.message = message }
    public var errorDescription: String? { message }
}

public struct LocalHTTPRequest: Sendable {
    public struct Head: Sendable {
        public let method: String
        public let target: String
        public let headers: [String: String]
        public let contentLength: Int
        public let headerLength: Int
    }
    public let head: Head
    public let body: Data
    public init(head: Head, body: Data) { self.head = head; self.body = body }
    public static let maximumHeaderBytes = 32 * 1024
    public static let maximumBodyBytes = 100 * 1024 * 1024

    public static func parseHead(_ data: Data) throws -> Head? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maximumHeaderBytes { throw LocalAPIError(431, "Request headers too large") }
            return nil
        }
        guard range.upperBound <= maximumHeaderBytes,
              let text = String(data: data[..<range.lowerBound], encoding: .utf8) else { throw LocalAPIError(400, "Invalid headers") }
        let lines = text.components(separatedBy: "\r\n")
        guard let start = lines.first, lines.count <= 65 else { throw LocalAPIError(400, "Invalid request") }
        let words = start.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, ["GET", "POST", "PUT", "OPTIONS"].contains(String(words[0])),
              words[2] == "HTTP/1.1", words[1].hasPrefix("/api/v1/"), words[1].utf8.count <= 8192,
              !words[1].contains("#"), !words[1].contains("\\") else { throw LocalAPIError(400, "Unsupported request line") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw LocalAPIError(400, "Invalid header") }
            let name = String(line[..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw LocalAPIError(400, "Duplicate or invalid header") }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw LocalAPIError(400, "Chunked and Expect requests are unsupported") }
        let length: Int
        if let raw = headers["content-length"] {
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw), value <= maximumBodyBytes else { throw LocalAPIError(413, "Body too large or invalid length") }
            length = value
        } else { length = 0 }
        guard !["GET", "OPTIONS"].contains(String(words[0])) || length == 0 else { throw LocalAPIError(400, "Unexpected body") }
        return Head(method: String(words[0]), target: String(words[1]), headers: headers, contentLength: length, headerLength: range.upperBound)
    }

    public static func authorize(_ head: Head, token: String, port: UInt16, allowedOrigins: [String]) throws -> String? {
        guard ["127.0.0.1:\(port)", "localhost:\(port)"].contains(head.headers["host"] ?? "") else { throw LocalAPIError(403, "Invalid local Host") }
        let origin = head.headers["origin"]
        if let origin, origin == "null" || !allowedOrigins.contains(origin) { throw LocalAPIError(403, "Origin is not approved") }
        if head.method == "OPTIONS" {
            guard origin != nil, let method = head.headers["access-control-request-method"], ["GET", "POST", "PUT"].contains(method) else { throw LocalAPIError(403, "Invalid preflight") }
            return origin
        }
        let supplied = Array((head.headers["authorization"] ?? "").utf8)
        let expected = Array("Bearer \(token)".utf8)
        var difference = supplied.count ^ expected.count
        for index in 0..<max(supplied.count, expected.count) {
            difference |= Int((index < supplied.count ? supplied[index] : 0) ^ (index < expected.count ? expected[index] : 0))
        }
        guard difference == 0 else { throw LocalAPIError(401, "Bearer token required") }
        return origin
    }
}

public struct LocalHTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public init(status: Int = 200, json: Any) throws {
        self.status = status
        self.body = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .fragmentsAllowed])
    }
    public static func failure(_ error: Error) -> Self {
        let error = error as? LocalAPIError ?? LocalAPIError(500, "Local API request failed")
        return try! Self(status: error.status, json: ["error": ["message": error.message, "status": error.status]])
    }
    public func wire(origin: String? = nil) -> Data {
        let reason = [200:"OK",201:"Created",204:"No Content",400:"Bad Request",401:"Unauthorized",403:"Forbidden",404:"Not Found",409:"Conflict",413:"Payload Too Large",422:"Unprocessable Entity",429:"Too Many Requests",431:"Request Header Fields Too Large",500:"Internal Server Error",503:"Service Unavailable"][status] ?? "Error"
        var headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n"
        if let origin {
            headers += "Access-Control-Allow-Origin: \(origin)\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, PUT, OPTIONS\r\nAccess-Control-Allow-Headers: Authorization, Content-Type\r\n"
        }
        return Data((headers + "\r\n").utf8) + body
    }
}

public enum LocalAPIRecords {
    public static func object(_ item: Reference, include: Set<String> = []) -> [String: Any] {
        var result: [String: Any] = ["id": item.id.uuidString, "title": item.title, "authors": item.authors, "year": item.year,
            "journal": item.journal, "doi": item.doi, "url": item.url, "citationKey": item.citationKey, "type": item.entryType,
            "volume": item.volume, "issue": item.issue, "pages": item.pages, "publisher": item.publisher, "isbn": item.isbn,
            "issn": item.issn, "extraFields": item.extraFields, "hasPDF": item.pdfPath != nil, "deepLink": "papershelf://paper/\(item.id.uuidString)"]
        if include.contains("abstract") { result["abstract"] = item.abstract }
        if include.contains("pdfPath") { result["pdfPath"] = item.pdfPath ?? NSNull() }
        if include.contains("library") || include.contains("collections") { result["collectionIDs"] = item.collectionIDs.map(\.uuidString); result["collection"] = item.collection }
        if include.contains("library") || include.contains("tags") { result["tags"] = item.tags }
        if include.contains("library") { result["notes"] = item.notes; result["rating"] = item.rating; result["isRead"] = item.isRead; result["isFavorite"] = item.isFavorite }
        return result
    }

    public static func csl(_ item: Reference) -> [String: Any] {
        let types = ["article":"article-journal", "inproceedings":"paper-conference", "incollection":"chapter", "inbook":"chapter", "online":"webpage", "thesis":"thesis", "book":"book", "report":"report", "dataset":"dataset", "software":"software", "patent":"patent"]
        var value: [String: Any] = ["id":item.id.uuidString, "type":types[item.entryType] ?? "article", "title":item.title,
            "author": item.authors.map { name -> [String:String] in
                let parts = name.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 ? ["family":parts[0], "given":parts[1]] : ["literal":name]
            }]
        for (key, text) in [("container-title",item.journal),("DOI",item.doi),("URL",item.url),("volume",item.volume),("issue",item.issue),("page",item.pages),("publisher",item.publisher),("ISBN",item.isbn),("ISSN",item.issn)] where !text.isEmpty { value[key] = text }
        if let year = Int(item.year) { value["issued"] = ["date-parts":[[year]]] }
        return value
    }

    public static func newReference(_ object: [String: Any]) throws -> Reference {
        let allowed: Set<String> = ["title","authors","year","journal","doi","url","abstract","notes","tags","collectionIDs","citationKey","type","volume","issue","pages","publisher","isbn","issn","extraFields","duplicatePolicy"]
        guard Set(object.keys).isSubset(of: allowed) else { throw LocalAPIError(422, "Unknown field; file paths and bookmarks are not accepted here") }
        func string(_ key: String, max: Int = 24000) throws -> String {
            guard let raw = object[key] else { return "" }
            guard let value = raw as? String, value.utf8.count <= max, !value.unicodeScalars.contains(where: { $0.value < 32 && ![9,10,13].contains($0.value) }) else { throw LocalAPIError(422, "Invalid \(key)") }
            return value
        }
        let title = try string("title", max: 2048)
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalAPIError(422, "Title required") }
        let authors = object["authors"] as? [String] ?? []
        let tags = object["tags"] as? [String] ?? []
        let ids = object["collectionIDs"] as? [String] ?? []
        guard object["authors"] == nil || object["authors"] is [String], object["tags"] == nil || object["tags"] is [String],
              object["collectionIDs"] == nil || object["collectionIDs"] is [String], authors.count <= 500, tags.count <= 200,
              ids.count <= 200, ids.allSatisfy({ UUID(uuidString: $0) != nil }),
              (authors + tags).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 }) else { throw LocalAPIError(422, "Invalid authors, tags or collection IDs") }
        let extra = object["extraFields"] as? [String:String] ?? [:]
        guard object["extraFields"] == nil || object["extraFields"] is [String:String], extra.count <= 100 else { throw LocalAPIError(422, "Invalid extra fields") }
        return try Reference(title:title, authors:authors, year:string("year",max:32), journal:string("journal",max:2048), doi:string("doi",max:2048), url:string("url",max:8192), abstract:string("abstract"), notes:string("notes"), tags:tags,
                             citationKey:string("citationKey",max:256), entryType:object["type"] == nil ? "article" : string("type",max:64), volume:string("volume",max:128), issue:string("issue",max:128), pages:string("pages",max:128), publisher:string("publisher",max:2048), isbn:string("isbn",max:128), issn:string("issn",max:128), extraFields:extra, collectionIDs:ids.compactMap(UUID.init(uuidString:)))
    }

    public static func trustedFile(_ raw: String, folders: [String]) throws -> URL {
        let url = URL(fileURLWithPath: raw).standardizedFileURL.resolvingSymlinksInPath()
        guard raw.hasPrefix("/"), url.pathExtension.lowercased() == "pdf",
              folders.contains(where: { folder in
                  let root = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
                  return root != "/" && url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
              }), (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { throw LocalAPIError(403, "File is outside trusted folders or not a regular PDF") }
        return url
    }
}

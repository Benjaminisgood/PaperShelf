import Foundation
import Network
import Security
import PDFKit
import PaperCore

@MainActor
final class LocalAPIServer {
    let connectionURL: URL
    private let storageDirectory: URL
    private let snapshot: () -> LocalAPISnapshot
    private let save: (Reference) -> Bool
    private let onStatus: (String) -> Void
    private var listener: NWListener?
    private var connections: [UUID: LocalHTTPConnection] = [:]
    private var configuration = LocalAPIConfiguration()
    private var token = ""

    init(storageDirectory: URL, snapshot: @escaping () -> LocalAPISnapshot,
         save: @escaping (Reference) -> Bool, onStatus: @escaping (String) -> Void = { _ in }) {
        self.storageDirectory = storageDirectory.appendingPathComponent("LocalAPI", isDirectory: true)
        self.connectionURL = self.storageDirectory.appendingPathComponent("connection.json")
        self.snapshot = snapshot; self.save = save; self.onStatus = onStatus
    }

    func start(configuration: LocalAPIConfiguration) throws {
        stop()
        guard configuration.enabled else { return }
        guard configuration.port == 0 || configuration.port >= 1024 else { throw LocalAPIError(422, "Choose a port above 1023") }
        for origin in configuration.allowedOrigins {
            guard let parts = URLComponents(string: origin), ["http", "https"].contains(parts.scheme),
                  parts.host != nil, parts.user == nil, parts.password == nil, parts.path.isEmpty,
                  parts.query == nil, parts.fragment == nil else { throw LocalAPIError(422, "Allowed origins must be exact http(s) origins") }
        }
        self.configuration = configuration
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw LocalAPIError(500, "Cannot create authentication token") }
        token = Data(random).base64EncodedString()
        let port = NWEndpoint.Port(rawValue: configuration.port)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
        parameters.allowLocalEndpointReuse = false
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else { return }
                    do {
                        let fm = FileManager.default
                        try fm.createDirectory(at: self.storageDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.storageDirectory.path)
                        let info = LocalAPIConnectionInfo(baseURL: "http://127.0.0.1:\(port.rawValue)/api/v1", token: self.token, processID: ProcessInfo.processInfo.processIdentifier)
                        try JSONEncoder().encode(info).write(to: self.connectionURL, options: .atomic)
                        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: self.connectionURL.path)
                        self.onStatus("本地 API 已启动 · 127.0.0.1:\(port.rawValue) · \(configuration.readOnly ? "只读" : "允许写入")")
                    } catch { self.stop(); self.onStatus("本地 API 未启动：\(error.localizedDescription)") }
                case .failed(let error): self.stop(); self.onStatus("本地 API 未启动：\(error.localizedDescription)")
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener?.cancel(); listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        try? FileManager.default.removeItem(at: connectionURL)
        token = ""
    }

    private func accept(_ connection: NWConnection) {
        guard let port = listener?.port, connections.count < 4 else { connection.cancel(); return }
        let id = UUID()
        let peer = LocalHTTPConnection(connection: connection, token: token, port: port.rawValue,
            allowedOrigins: configuration.allowedOrigins, handler: { [weak self] request in
                guard let self else { return .failure(LocalAPIError(503, "API stopped")) }
                return await self.respond(request)
            }, finished: { [weak self] in Task { @MainActor in self?.connections[id] = nil } })
        connections[id] = peer
        peer.start()
    }

    private func respond(_ request: LocalHTTPRequest) async -> LocalHTTPResponse {
        do { return try await route(request) }
        catch let error as LocalAPIError { return .failure(error) }
        catch { return .failure(LocalAPIError(422, error.localizedDescription)) }
    }

    private func route(_ request: LocalHTTPRequest) async throws -> LocalHTTPResponse {
        guard listener != nil else { throw LocalAPIError(503, "API stopped") }
        if request.head.method == "OPTIONS" { return try LocalHTTPResponse(json: ["ok":true]) }
        guard let parts = URLComponents(string: "http://127.0.0.1" + request.head.target) else { throw LocalAPIError(400, "Invalid target") }
        var query: [String:String] = [:]
        for item in parts.queryItems ?? [] {
            guard query[item.name] == nil else { throw LocalAPIError(400, "Duplicate query parameter") }
            query[item.name] = item.value ?? ""
        }
        let path = parts.path.split(separator: "/").map(String.init)
        let items = snapshot()
        let include = Set((query["include"] ?? "").split(separator: ",").map(String.init))
        guard include.isSubset(of: ["abstract","pdfPath","library","collections","tags"]) else { throw LocalAPIError(422, "Unsupported include field") }
        if request.head.method == "GET" {
            switch path {
            case ["api","v1","status"]:
                return try LocalHTTPResponse(json: ["name":"PaperShelf", "apiVersion":1, "readOnly":configuration.readOnly,
                    "count":items.references.count, "capabilities":["search","metadata","csl-json","collections","tags","include-fields","pdf-upload","trusted-pdf-path","bearer-auth"],
                    "limits":["maximumPDFBytes":LocalHTTPRequest.maximumBodyBytes], "writesEnabled":!configuration.readOnly])
            case ["api","v1","search"]:
                let text = query["q"] ?? ""
                let matches = items.references.filter { value in
                    text.isEmpty || ([value.title,value.journal,value.year,value.doi,value.isbn,value.citationKey] + value.authors).joined(separator:" ").localizedCaseInsensitiveContains(text)
                }
                guard let offset = Int(query["offset"] ?? "0"), let limit = Int(query["limit"] ?? "50"), offset >= 0, (1...500).contains(limit) else { throw LocalAPIError(422, "Invalid pagination") }
                let page = matches.dropFirst(min(offset, matches.count)).prefix(limit).map { LocalAPIRecords.object($0, include:include) }
                return try LocalHTTPResponse(json: ["items":page, "total":matches.count, "offset":offset, "limit":limit, "hasMore":offset + page.count < matches.count])
            case ["api","v1","collections"]:
                return try LocalHTTPResponse(json: ["items":items.collections.map { ["id":$0.id.uuidString,"name":$0.name,"parentID":$0.parentID?.uuidString ?? NSNull(),"sortOrder":$0.sortOrder] as [String:Any] }])
            case ["api","v1","tags"]:
                return try LocalHTTPResponse(json: ["items":items.tags.map { ["name":$0.name,"colorHex":$0.colorHex,"sortOrder":$0.sortOrder] as [String:Any] }])
            case ["api","v1","metadata"]:
                guard let identifier = query["identifier"], identifier.utf8.count <= 2048 else { throw LocalAPIError(422, "identifier required") }
                let value = try await MetadataLookup().fetch(identifier)
                return try LocalHTTPResponse(json: LocalAPIRecords.object(value, include:include.union(["abstract"])))
            default:
                if path.count >= 4, Array(path.prefix(3)) == ["api","v1","papers"] {
                    let value: Reference?
                    if path[3] == "by-reference", let reference = query["reference"] {
                        value = items.references.first { $0.id.uuidString.caseInsensitiveCompare(reference) == .orderedSame || (!$0.doi.isEmpty && $0.doi.caseInsensitiveCompare(reference) == .orderedSame) || (!$0.citationKey.isEmpty && $0.citationKey == reference) }
                    } else { value = items.references.first { $0.id == UUID(uuidString:path[3]) } }
                    guard let value else { throw LocalAPIError(404, "Paper not found") }
                    if path.count == 5, path[4] == "csl" { return try LocalHTTPResponse(json: LocalAPIRecords.csl(value)) }
                    guard path.count == 4 else { throw LocalAPIError(404, "Unknown route") }
                    return try LocalHTTPResponse(json: LocalAPIRecords.object(value, include:include))
                }
                throw LocalAPIError(404, "Unknown route")
            }
        }
        guard !configuration.readOnly else { throw LocalAPIError(403, "Local API is read-only") }
        if request.head.method == "POST", path == ["api","v1","papers"] || path == ["api","v1","papers","by-identifier"] {
            let object = try jsonBody(request)
            let reference: Reference
            if path.last == "by-identifier" {
                guard let identifier = object["identifier"] as? String, identifier.utf8.count <= 2048,
                      Set(object.keys).isSubset(of:["identifier","duplicatePolicy"]) else { throw LocalAPIError(422, "identifier required") }
                reference = try await MetadataLookup().fetch(identifier)
            } else { reference = try LocalAPIRecords.newReference(object) }
            // A lookup can suspend; re-check the live access policy before the eventual mutation.
            guard listener != nil, !configuration.readOnly, !Task.isCancelled else { throw LocalAPIError(403, "API writes disabled") }
            let policy = object["duplicatePolicy"] as? String ?? "skip"
            guard ["skip","replace"].contains(policy) else { throw LocalAPIError(422, "Invalid duplicatePolicy") }
            var value = reference
            if let previous = snapshot().references.first(where: { candidate in
                !value.doi.isEmpty && candidate.doi.caseInsensitiveCompare(value.doi) == .orderedSame ||
                !value.isbn.isEmpty && candidate.isbn == value.isbn ||
                candidate.title.caseInsensitiveCompare(value.title) == .orderedSame && candidate.year == value.year
            }) {
                if policy == "skip" { return try LocalHTTPResponse(json:["status":"skipped", "paper":LocalAPIRecords.object(previous, include:include)]) }
                value.id = previous.id; value.addedAt = previous.addedAt
                value.pdfPath = previous.pdfPath; value.pdfBookmark = previous.pdfBookmark; value.attachments = previous.attachments
                value.collectionIDs = Array(Set(previous.collectionIDs + value.collectionIDs)); value.tags = Array(Set(previous.tags + value.tags)).sorted()
                value.notes = object["notes"] == nil ? previous.notes : value.notes
                value.rating = previous.rating; value.isRead = previous.isRead; value.isFavorite = previous.isFavorite
                if value.citationKey.isEmpty { value.citationKey = previous.citationKey }
                value.extraFields = previous.extraFields.merging(value.extraFields) { _, incoming in incoming }
            }
            let validIDs = Set(snapshot().collections.map(\.id))
            guard Set(value.collectionIDs).isSubset(of:validIDs) else { throw LocalAPIError(422, "Unknown collection ID") }
            guard save(value) else { throw LocalAPIError(500, "Library save failed") }
            return try LocalHTTPResponse(status:201, json:["status":"saved", "paper":LocalAPIRecords.object(value, include:include)])
        }
        if request.head.method == "PUT", path.count == 5, Array(path.prefix(3)) == ["api","v1","papers"], path[4] == "pdf" {
            guard let id = UUID(uuidString:path[3]), var value = items.references.first(where: { $0.id == id }) else { throw LocalAPIError(404, "Paper not found") }
            guard value.pdfPath == nil || query["force"] == "true" else { throw LocalAPIError(409, "Existing PDF requires force=true") }
            let data: Data
            if request.head.headers["content-type"]?.split(separator:";").first == "application/json" {
                let object = try jsonBody(request)
                guard Set(object.keys) == ["path"], let raw = object["path"] as? String else { throw LocalAPIError(422, "PDF path required") }
                let file = try LocalAPIRecords.trustedFile(raw, folders:configuration.trustedFolders)
                let size = try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                guard size <= LocalHTTPRequest.maximumBodyBytes else { throw LocalAPIError(413, "PDF too large") }
                data = try Data(contentsOf:file)
            } else {
                guard request.head.headers["content-type"]?.split(separator:";").first == "application/pdf" else { throw LocalAPIError(422, "Use application/pdf or a trusted JSON path") }
                data = request.body
            }
            guard data.count <= LocalHTTPRequest.maximumBodyBytes, data.starts(with:Data("%PDF-".utf8)),
                  let pdf = PDFDocument(data:data), !pdf.isLocked, pdf.pageCount > 0 else { throw LocalAPIError(422, "Invalid or locked PDF") }
            let directory = storageDirectory.appendingPathComponent("Uploads/\(UUID().uuidString)", isDirectory:true)
            let destination = directory.appendingPathComponent("paper.pdf")
            try FileManager.default.createDirectory(at:directory, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            do {
                try data.write(to:destination, options:.withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath:destination.path)
                try PDFLinks.attach(destination, to:&value)
                guard save(value) else { throw LocalAPIError(500, "Library save failed") }
            } catch { try? FileManager.default.removeItem(at:directory); throw error }
            return try LocalHTTPResponse(json:["status":"attached", "paper":LocalAPIRecords.object(value, include:include)])
        }
        throw LocalAPIError(404, "Unknown route")
    }

    private func jsonBody(_ request: LocalHTTPRequest) throws -> [String:Any] {
        guard request.head.headers["content-type"]?.split(separator:";").first == "application/json", request.body.count <= 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with:request.body) as? [String:Any] else { throw LocalAPIError(422, "Expected a JSON object under 1 MiB") }
        return object
    }
}

private final class LocalHTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let token: String
    private let port: UInt16
    private let allowedOrigins: [String]
    private let handler: @Sendable (LocalHTTPRequest) async -> LocalHTTPResponse
    private let finished: @Sendable () -> Void
    private let queue = DispatchQueue(label:"local.papershelf.api.connection")
    private var buffer = Data()
    private var head: LocalHTTPRequest.Head?
    private var origin: String?
    private var ended = false
    private var task: Task<Void,Never>?

    init(connection:NWConnection, token:String, port:UInt16, allowedOrigins:[String],
         handler:@escaping @Sendable (LocalHTTPRequest) async -> LocalHTTPResponse, finished:@escaping @Sendable () -> Void) {
        self.connection = connection; self.token = token; self.port = port; self.allowedOrigins = allowedOrigins
        self.handler = handler; self.finished = finished
    }
    func start() {
        connection.start(queue:queue)
        queue.async { self.receive() }
        queue.asyncAfter(deadline:.now()+120) { self.finish() }
    }
    func cancel() { queue.async { self.finish() } }
    private func finish() {
        guard !ended else { return }; ended = true
        task?.cancel(); connection.cancel(); finished()
    }
    private func receive() {
        guard !ended else { return }
        connection.receive(minimumIncompleteLength:1, maximumLength:65536) { [self] data, _, complete, error in
            guard !ended else { return }
            do {
                if let data { buffer.append(data) }
                if head == nil, let parsed = try LocalHTTPRequest.parseHead(buffer) {
                    origin = try LocalHTTPRequest.authorize(parsed, token:token, port:port, allowedOrigins:allowedOrigins)
                    head = parsed
                }
                if let head {
                    let total = head.headerLength + head.contentLength
                    guard buffer.count <= total else { throw LocalAPIError(400, "Pipelining and trailing bytes are unsupported") }
                    if buffer.count == total {
                        let request = LocalHTTPRequest(head:head, body:Data(buffer[head.headerLength...]))
                        buffer.removeAll(keepingCapacity:false)
                        task = Task { [self] in
                            let response = await self.handler(request)
                            self.queue.async { self.send(response) }
                        }
                        return
                    }
                }
                if complete || error != nil { finish() } else { receive() }
            } catch { send(.failure(error)) }
        }
    }
    private func send(_ response:LocalHTTPResponse) {
        guard !ended else { return }
        connection.send(content:response.wire(origin:origin), completion:.contentProcessed { [self] _ in finish() })
    }
}

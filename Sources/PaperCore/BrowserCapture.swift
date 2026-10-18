import Foundation
import Darwin

/// The caller keeps access to the user-selected root for the whole download and import.
public enum BrowserCaptureStorage {
    public static func destination(in root: URL) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw BrowserCaptureError.invalidPayload("文件库必须是本地目录") }
        let resolved = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try resolved.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw BrowserCaptureError.invalidPayload("文件库目录不可用，请在设置中重新选择")
        }
        let captures = resolved.appendingPathComponent("BrowserCaptures", isDirectory: true)
        let expectedPath = captures.standardizedFileURL.path
        guard captures.resolvingSymlinksInPath().path == expectedPath else { throw BrowserCaptureError.invalidPayload("采集目录不能是符号链接") }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: captures.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw BrowserCaptureError.invalidPayload("采集目录被同名文件占用") }
        } else {
            try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard captures.resolvingSymlinksInPath().path == expectedPath else { throw BrowserCaptureError.invalidPayload("采集目录发生变化") }
        return captures.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("paper.pdf")
    }
}
public enum BrowserCaptureError: LocalizedError, Equatable {
    case invalidEnvelope, invalidPayload(String), unsafeURL, oversized, expired, network(String), invalidPDF

    public var errorDescription: String? {
        switch self {
        case .invalidEnvelope: return "无效的 PaperShelf 采集链接。"
        case .invalidPayload(let field): return "采集数据无效：\(field)。"
        case .unsafeURL: return "浏览器采集只接受公开 HTTP/HTTPS 地址，不能包含登录信息、本地网络或非标准端口。"
        case .oversized: return "采集内容超过大小限制；请缩短摘要或选中文字后重试。"
        case .expired: return "采集请求已超过 24 小时，请从浏览器重新采集。"
        case .network(let message): return "PDF 下载失败：\(message)"
        case .invalidPDF: return "服务器没有返回可读取的 PDF。元数据可单独导入。"
        }
    }
}

/// Untrusted browser metadata. Decoding never imports, downloads, or executes anything.
public struct BrowserCapturePayload: Codable, Equatable, Identifiable, Sendable {
    public static let maximumBytes = 48 * 1024
    public static let maximumPDFBytes = 100 * 1024 * 1024
    public let version: Int
    public let id: UUID
    public let capturedAt: String
    public let sourceURL: String
    public let title: String
    public let authors: [String]
    public let year: String
    public let journal: String
    public let doi: String
    public let abstract: String
    public let selectedText: String
    public let pdfURLs: [String]

    public init(version: Int = 1, id: UUID = UUID(), capturedAt: String = ISO8601DateFormatter().string(from: Date()),
                sourceURL: String, title: String, authors: [String] = [], year: String = "", journal: String = "",
                doi: String = "", abstract: String = "", selectedText: String = "", pdfURLs: [String] = []) {
        self.version = version; self.id = id; self.capturedAt = capturedAt; self.sourceURL = sourceURL
        self.title = title; self.authors = authors; self.year = year; self.journal = journal; self.doi = doi
        self.abstract = abstract; self.selectedText = selectedText; self.pdfURLs = pdfURLs
    }

    public static func decode(_ url: URL, now: Date = Date()) throws -> Self {
        guard url.absoluteString.utf8.count <= maximumBytes * 2,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "papershelf", parts.host == "capture",
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "payload",
              let raw = items[0].value, !raw.isEmpty,
              raw.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw BrowserCaptureError.invalidEnvelope
        }
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { throw BrowserCaptureError.invalidEnvelope }
        guard data.count <= maximumBytes else { throw BrowserCaptureError.oversized }
        let expected: Set<String> = ["version", "id", "capturedAt", "sourceURL", "title", "authors", "year", "journal", "doi", "abstract", "selectedText", "pdfURLs"]
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == expected else { throw BrowserCaptureError.invalidPayload("字段集合") }
        let payload: Self
        do { payload = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw BrowserCaptureError.invalidPayload("JSON 类型") }
        try payload.validate(now: now)
        return payload
    }

    public func encodedURL(now: Date = Date()) throws -> URL {
        try validate(now: now)
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw BrowserCaptureError.oversized }
        let base64 = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return URL(string: "papershelf://capture?payload=\(base64)")!
    }

    public func validate(now: Date = Date()) throws {
        guard version == 1 else { throw BrowserCaptureError.invalidPayload("版本") }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let captured = formatter.date(from: capturedAt) ?? ISO8601DateFormatter().date(from: capturedAt)
        guard let captured else { throw BrowserCaptureError.invalidPayload("时间") }
        guard captured.timeIntervalSince(now) <= 300, now.timeIntervalSince(captured) <= 86400 else { throw BrowserCaptureError.expired }
        try Self.validateText(title, name: "标题", maximum: 2048, required: true)
        try Self.validateText(journal, name: "期刊", maximum: 1024)
        try Self.validateText(abstract, name: "摘要", maximum: 24000)
        try Self.validateText(selectedText, name: "选中文字", maximum: 12000)
        try Self.validateText(doi, name: "DOI", maximum: 2048)
        guard year.isEmpty || year.range(of: #"^[12][0-9]{3}$"#, options: .regularExpression) != nil else { throw BrowserCaptureError.invalidPayload("年份") }
        guard authors.count <= 100, pdfURLs.count <= 8 else { throw BrowserCaptureError.oversized }
        for author in authors { try Self.validateText(author, name: "作者", maximum: 512, required: true) }
        if !doi.isEmpty { _ = try DOIClient.normalize(doi) }
        _ = try BrowserCaptureNetworkPolicy.publicURL(sourceURL)
        for raw in pdfURLs { _ = try BrowserCaptureNetworkPolicy.publicURL(raw) }
    }

    public func reference() -> Reference {
        let selection = selectedText.isEmpty ? "" : "\n\n浏览器选中文字（未核验）：\n\(selectedText)"
        return Reference(title: title, authors: authors, year: year, journal: journal,
                         doi: (try? DOIClient.normalize(doi)) ?? "", url: sourceURL, abstract: abstract,
                         notes: "浏览器采集，元数据待核对。\n来源：\(sourceURL)\n采集时间：\(capturedAt)\n采集 ID：\(id.uuidString)\(selection)")
    }

    private static func validateText(_ value: String, name: String, maximum: Int, required: Bool = false) throws {
        guard value.utf8.count <= maximum else { throw BrowserCaptureError.oversized }
        guard !required || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw BrowserCaptureError.invalidPayload(name)
        }
    }
}

public enum BrowserCaptureNetworkPolicy {
    /// Syntactic public destination check. Downloaders must also resolve DNS before each request/redirect.
    public static func publicURL(_ raw: String) throws -> URL {
        guard raw.utf8.count <= 8192, !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: raw), let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme), components.user == nil, components.password == nil,
              components.port == nil || components.port == (scheme == "https" ? 443 : 80),
              let host = components.host?.lowercased(), !host.isEmpty, !host.hasSuffix("."),
              !["localhost", "local", "internal", "home", "lan", "test", "invalid"].contains(host),
              ![".localhost", ".local", ".internal", ".home", ".lan", ".test", ".invalid", ".onion"].contains(where: host.hasSuffix),
              let url = components.url else { throw BrowserCaptureError.unsafeURL }
        let address = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if address.contains(":") || address.allSatisfy({ $0.isNumber || $0 == "." }) {
            guard isPublicIPAddress(address) else { throw BrowserCaptureError.unsafeURL }
        } else {
            guard host.contains("."), host.utf8.count <= 253,
                  host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                      !label.isEmpty && label.utf8.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-") &&
                      label.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) || $0 == 45 }
                  }) else { throw BrowserCaptureError.unsafeURL }
        }
        return url
    }

    /// Reject non-global IPv4/IPv6 ranges, IPv4-mapped IPv6 and transition addresses.
    public static func isPublicIPAddress(_ raw: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, raw, &v4) == 1 {
            let octets = raw.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.allSatisfy({ part in
                guard let value = UInt8(part) else { return false }
                return String(value) == part
            }) else { return false }
            let value = UInt32(bigEndian: v4.s_addr)
            let a = value >> 24, b = (value >> 16) & 255, c = (value >> 8) & 255
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 || a == 172 && (16...31).contains(b) || a == 192 && b == 168 { return false }
            if a == 192 && b == 0 || a == 192 && b == 88 && c == 99 { return false }
            if a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) || a == 203 && b == 0 && c == 113 { return false }
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, raw, &v6) == 1 else { return false }
        return withUnsafeBytes(of: v6) { bytes in
            // Only global unicast 2000::/3. Also exclude Teredo, benchmarking, documentation and 6to4.
            guard bytes[0] & 0xe0 == 0x20 else { return false }
            if bytes[0] == 0x20 && bytes[1] == 0x01 {
                if bytes[2] < 2 || bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
            }
            if bytes[0] == 0x20 && bytes[1] == 0x02 || bytes[0] == 0x3f && bytes[1] == 0xff { return false }
            return true
        }
    }

    public static func validateDNS(for url: URL) throws { _ = try publicAddresses(for: url) }

    /// Returned addresses are used by the downloader to pin DNS for the actual connection.
    public static func publicAddresses(for url: URL) throws -> [String] {
        _ = try publicURL(url.absoluteString)
        guard let rawHost = url.host else { throw BrowserCaptureError.unsafeURL }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { throw BrowserCaptureError.network("无法解析服务器地址") }
        defer { freeaddrinfo(first) }
        var current: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [String] = []
        while let entry = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
            let address = String(cString: buffer)
            guard status == 0, isPublicIPAddress(address) else { throw BrowserCaptureError.unsafeURL }
            if !addresses.contains(address) { addresses.append(address) }
            current = entry.pointee.ai_next
        }
        guard !addresses.isEmpty else { throw BrowserCaptureError.unsafeURL }
        return addresses
    }
}

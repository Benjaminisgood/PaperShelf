import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DOIClientError: LocalizedError, Equatable {
    case invalidDOI
    case notFound
    case httpStatus(Int)
    case invalidResponse
    case missingTitle

    public var errorDescription: String? {
        switch self {
        case .invalidDOI: return "请输入有效的 DOI 或 doi.org 链接，例如 10.1038/nphys1170。"
        case .notFound: return "Crossref 没有找到该 DOI。可手动新建条目，其他注册机构的 DOI 可能未收录。"
        case .httpStatus(let status): return "Crossref 请求失败（HTTP \(status)），请稍后重试。"
        case .invalidResponse: return "Crossref 返回的数据格式无效。"
        case .missingTitle: return "Crossref 返回的条目缺少标题，请手动新建条目。"
        }
    }
}

public struct DOIClient {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public static func normalize(_ value: String) throws -> String {
        var doi = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "http://dx.doi.org/", "doi:"]
        for prefix in prefixes where doi.lowercased().hasPrefix(prefix) {
            doi = String(doi.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if prefix.hasPrefix("http") {
                guard let decoded = doi.removingPercentEncoding else { throw DOIClientError.invalidDOI }
                doi = decoded
            }
            break
        }
        guard doi.count <= 2048,
              doi.range(of: #"^10\.[0-9]{4,9}/[^\s<>]+$"#, options: .regularExpression) != nil,
              !doi.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DOIClientError.invalidDOI
        }
        return doi
    }

    /// Queries Crossref only. A valid DOI registered elsewhere may not have a Crossref record.
    public func fetch(_ input: String) async throws -> Reference {
        let doi = try Self.normalize(input)
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%")
        guard let encoded = doi.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.crossref.org/works/" + encoded) else {
            throw DOIClientError.invalidDOI
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PaperShelf/0.1 (native macOS reference manager)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw DOIClientError.invalidResponse }
        if response.statusCode == 404 { throw DOIClientError.notFound }
        guard (200..<300).contains(response.statusCode) else { throw DOIClientError.httpStatus(response.statusCode) }
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) }
        catch { throw DOIClientError.invalidResponse }
        guard let object = root as? [String: Any], let message = object["message"] as? [String: Any] else {
            throw DOIClientError.invalidResponse
        }
        let title = (message["title"] as? [String])?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { throw DOIClientError.missingTitle }
        let authors: [String] = (message["author"] as? [[String: Any]] ?? []).compactMap { author in
            if let name = author["name"] as? String, !name.isEmpty { return name }
            let name = [author["family"] as? String, author["given"] as? String]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            return name.isEmpty ? nil : name
        }
        var year = ""
        for field in ["published", "published-print", "published-online", "issued"] {
            if let date = message[field] as? [String: Any],
               let parts = date["date-parts"] as? [[Int]], let value = parts.first?.first, value > 0 {
                year = String(value); break
            }
        }
        let returnedDOI = (message["DOI"] as? String).flatMap { try? Self.normalize($0) } ?? doi
        return Reference(title: plainText(title), authors: authors, year: year,
                         journal: (message["container-title"] as? [String])?.first.map(plainText) ?? "",
                         doi: returnedDOI, url: message["URL"] as? String ?? "https://doi.org/\(returnedDOI)",
                         abstract: plainText(message["abstract"] as? String ?? ""))
    }

    private func plainText(_ value: String) -> String {
        // Crossref abstracts often contain JATS tags. Keep their text; do not interpret or load HTML.
        let separated = value.replacingOccurrences(of: #"</(?:jats:)?(?:p|title)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
        let stripped = separated.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
        return stripped.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

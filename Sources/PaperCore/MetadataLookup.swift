import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum MetadataLookupError: LocalizedError {
    case invalidIdentifier, noRecord, response(Int)
    public var errorDescription: String? { switch self {
    case .invalidIdentifier: return "请输入 DOI、ISBN 或 arXiv 标识符。"
    case .noRecord: return "元数据服务未找到记录，已有信息仍可手动编辑。"
    case .response(let code): return "元数据服务返回 HTTP \(code)。"
    } }
}

public struct MetadataLookup {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func fetch(_ input: String) async throws -> Reference {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let doi = try? DOIClient.normalize(value) {
            do { return try await DOIClient(session: session).fetch(doi) }
            catch DOIClientError.notFound { return try await dataCite(doi) }
        }
        let isbn = value.replacingOccurrences(of: "ISBN", with: "", options: .caseInsensitive).filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
        if (isbn.count == 10 || isbn.count == 13), Self.validISBN(isbn) { return try await openLibrary(isbn) }
        let arxiv = value.replacingOccurrences(of: "https://arxiv.org/abs/", with: "").replacingOccurrences(of: "https://arxiv.org/pdf/", with: "").replacingOccurrences(of: "arXiv:", with: "", options: .caseInsensitive).replacingOccurrences(of: ".pdf", with: "")
        guard arxiv.range(of: #"^(?:\d{4}\.\d{4,5}|[a-zA-Z.-]+/\d{7})(?:v\d+)?$"#, options: .regularExpression) != nil else { throw MetadataLookupError.invalidIdentifier }
        return try await arxivRecord(arxiv)
    }
    public static func validISBN(_ value: String) -> Bool {
        let chars = Array(value.uppercased())
        if chars.count == 10 {
            let values = chars.enumerated().compactMap { index, char -> Int? in if char == "X" && index == 9 { return 10 }; return char.wholeNumberValue }
            return values.count == 10 && zip(values, stride(from: 10, through: 1, by: -1)).map(*).reduce(0,+) % 11 == 0
        }
        let values = chars.compactMap(\.wholeNumberValue)
        return values.count == 13 && values.enumerated().map { $0.element * ($0.offset.isMultiple(of: 2) ? 1 : 3) }.reduce(0,+) % 10 == 0
    }
    private func data(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 25; request.setValue("PaperShelf/0.3 (reference manager)", forHTTPHeaderField: "User-Agent")
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw MetadataLookupError.noRecord }
        guard (200..<300).contains(response.statusCode) else { throw MetadataLookupError.response(response.statusCode) }
        return data
    }
    private func openLibrary(_ isbn: String) async throws -> Reference {
        let payload = try await data(URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(isbn)&jscmd=data&format=json")!)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String:Any], let book = object["ISBN:\(isbn)"] as? [String:Any], let title = book["title"] as? String else { throw MetadataLookupError.noRecord }
        let date = book["publish_date"] as? String ?? ""
        let year = date.range(of: #"\b\d{4}\b"#, options: .regularExpression).map { String(date[$0]) } ?? ""
        var value = Reference(title: title, authors: (book["authors"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }, year: year, url: book["url"] as? String ?? "")
        value.entryType = "book"; value.isbn = isbn
        value.publisher = (book["publishers"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }.joined(separator: "; ")
        if let count = book["number_of_pages"] as? Int { value.extraFields["pagetotal"] = String(count) }
        return value
    }
    private func dataCite(_ doi: String) async throws -> Reference {
        var allowed = CharacterSet.urlPathAllowed; allowed.remove(charactersIn: "?#%")
        guard let escaped = doi.addingPercentEncoding(withAllowedCharacters: allowed) else { throw MetadataLookupError.invalidIdentifier }
        let payload = try await data(URL(string: "https://api.datacite.org/dois/" + escaped)!)
        guard let object = try JSONSerialization.jsonObject(with: payload) as? [String:Any], let root = object["data"] as? [String:Any], let a = root["attributes"] as? [String:Any], let title = (a["titles"] as? [[String:Any]])?.first?["title"] as? String else { throw MetadataLookupError.noRecord }
        var value = Reference(title: title, authors: (a["creators"] as? [[String:Any]] ?? []).compactMap { $0["name"] as? String }, year: (a["publicationYear"] as? Int).map(String.init) ?? "", doi: doi, url: a["url"] as? String ?? "https://doi.org/\(doi)")
        value.publisher = a["publisher"] as? String ?? ""
        let kind = (a["types"] as? [String:Any])?["resourceTypeGeneral"] as? String ?? ""
        value.entryType = ["Dataset":"dataset","Software":"software","Book":"book","Text":"article"][kind] ?? "misc"
        value.abstract = (a["descriptions"] as? [[String:Any]] ?? []).first { ($0["descriptionType"] as? String) == "Abstract" }?["description"] as? String ?? ""
        return value
    }
    private func arxivRecord(_ identifier: String) async throws -> Reference {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!; components.queryItems = [URLQueryItem(name: "id_list", value: identifier)]
        let parser = XMLParser(data: try await data(components.url!)); let delegate = ArxivMetadataParser(); parser.delegate = delegate; parser.shouldResolveExternalEntities = false
        guard parser.parse(), !delegate.title.isEmpty, !delegate.isError else { throw MetadataLookupError.noRecord }
        var value = Reference(title: delegate.title, authors: delegate.authors, year: String(delegate.published.prefix(4)), doi: delegate.doi, url: "https://arxiv.org/abs/\(identifier)", abstract: delegate.summary)
        value.entryType = "preprint"; value.extraFields["arxivId"] = identifier; value.extraFields["eprint"] = identifier; value.extraFields["archiveprefix"] = "arXiv"
        return value
    }
}

private final class ArxivMetadataParser: NSObject, XMLParserDelegate {
    var title = "", summary = "", published = "", doi = ""
    var authors: [String] = []
    var isError = false
    private var inside = false, inAuthor = false
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
        if name == "entry" { inside = true }; if name == "author" { inAuthor = true }; text = ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inside else { return }; let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        switch name { case "id": if value.contains("arxiv.org/api/errors") { isError = true }; case "title": title = value; case "summary": summary = value; case "published": published = value; case "arxiv:doi": doi = value; case "name" where inAuthor: authors.append(value); case "author": inAuthor = false; case "entry": inside = false; default: break }
        text = ""
    }
}

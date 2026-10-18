import Foundation
import PaperCore

struct LibraryPreferences: Codable, Equatable {
    var localAPI = LocalAPIConfiguration()
    var templates = PaperExportTemplates()
    var updateCitationKeyOnEdit = false
    var citationKeyTemplate = "{author}{year}{title}"
    var fileRoot = ""
    var fileRootBookmark: Data?
    var fileOptions = PaperFileOptions(action: .link)
    var automaticallyOrganize = false
    var includeSubcollections = true
    var annotationOCR = false
    var readerBundleID = ""
    var bibtexFields: [String] = []
    init() {}
    private enum CodingKeys: String, CodingKey { case localAPI, templates, updateCitationKeyOnEdit, citationKeyTemplate, fileRoot, fileRootBookmark, fileOptions, automaticallyOrganize, includeSubcollections, annotationOCR, readerBundleID, bibtexFields }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        localAPI = try c.decodeIfPresent(LocalAPIConfiguration.self, forKey: .localAPI) ?? .init()
        templates = try c.decodeIfPresent(PaperExportTemplates.self, forKey: .templates) ?? .init()
        updateCitationKeyOnEdit = try c.decodeIfPresent(Bool.self, forKey: .updateCitationKeyOnEdit) ?? false
        citationKeyTemplate = try c.decodeIfPresent(String.self, forKey: .citationKeyTemplate) ?? "{author}{year}{title}"
        fileRoot = try c.decodeIfPresent(String.self, forKey: .fileRoot) ?? ""
        fileRootBookmark = try c.decodeIfPresent(Data.self, forKey: .fileRootBookmark)
        fileOptions = try c.decodeIfPresent(PaperFileOptions.self, forKey: .fileOptions) ?? .init(action: .link)
        automaticallyOrganize = try c.decodeIfPresent(Bool.self, forKey: .automaticallyOrganize) ?? false
        includeSubcollections = try c.decodeIfPresent(Bool.self, forKey: .includeSubcollections) ?? true
        annotationOCR = try c.decodeIfPresent(Bool.self, forKey: .annotationOCR) ?? false
        readerBundleID = try c.decodeIfPresent(String.self, forKey: .readerBundleID) ?? ""
        bibtexFields = try c.decodeIfPresent([String].self, forKey: .bibtexFields) ?? []
    }
    static func load(from url: URL) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), (try? JSONDecoder().decode(Self.self, from: data)) == nil {
            let backup = url.deletingPathExtension().appendingPathExtension("invalid-" + UUID().uuidString + ".json")
            try data.write(to: backup, options: .withoutOverwriting)
        }
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
    func resolvedFileRoot() throws -> URL {
        if let bookmark = fileRootBookmark { var stale = false; return try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) }
        return URL(fileURLWithPath: fileRoot)
    }
}

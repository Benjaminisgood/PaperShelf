import AppIntents
import AppKit
import Foundation
import PaperCore
import UniformTypeIdentifiers

struct PaperShelfReferenceEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "文献"
    static var defaultQuery = PaperShelfReferenceQuery()
    var id: UUID
    @Property(title: "标题") var title: String
    @Property(title: "引用键") var citationKey: String
    @Property(title: "文献 UUID") var identifier: String
    var subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(_ reference: Reference) {
        id = reference.id
        subtitle = [reference.citationKey, reference.authors.first ?? "", reference.year].filter { !$0.isEmpty }.joined(separator: " · ")
        title = reference.title.isEmpty ? "未命名文献" : reference.title
        citationKey = reference.citationKey
        identifier = reference.id.uuidString
    }
}

struct PaperShelfReferenceQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [PaperShelfReferenceEntity] {
        let records = try PaperShelfIntentLibrary.load().references
        let lookup = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return identifiers.compactMap { lookup[$0].map(PaperShelfReferenceEntity.init) }
    }

    func entities(matching string: String) async throws -> [PaperShelfReferenceEntity] {
        try PaperShelfIntentLibrary.search(string).map(PaperShelfReferenceEntity.init)
    }

    func suggestedEntities() async throws -> [PaperShelfReferenceEntity] {
        try PaperShelfIntentLibrary.load().references.map(PaperShelfReferenceEntity.init)
    }
}

struct SearchPaperShelfIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索 PaperShelf 文献"
    static var description = IntentDescription("按标题、作者、年份、DOI、标签、备注或引用键搜索本机文献库，返回全部匹配文献。")
    @Parameter(title: "检索词", default: "") var query: String

    func perform() async throws -> some IntentResult & ReturnsValue<[PaperShelfReferenceEntity]> {
        .result(value: try PaperShelfIntentLibrary.search(query).map(PaperShelfReferenceEntity.init))
    }
}

struct OpenPaperShelfReferenceIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 PaperShelf 文献"
    static var description = IntentDescription("通过文献 UUID 或完整引用键，在 PaperShelf 中选中文献。")
    static var openAppWhenRun = true
    @Parameter(title: "UUID 或引用键") var identifier: String

    func perform() async throws -> some IntentResult & OpensIntent {
        let input = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let records = try PaperShelfIntentLibrary.load().references
        let matches = records.filter { $0.id.uuidString.caseInsensitiveCompare(input) == .orderedSame || (!$0.citationKey.isEmpty && $0.citationKey.caseInsensitiveCompare(input) == .orderedSame) }
        guard !matches.isEmpty else { throw PaperShelfIntentError.notFound(input) }
        guard matches.count == 1 else { throw PaperShelfIntentError.ambiguous(input) }
        let scheme = Bundle.main.bundleIdentifier == "local.papershelf.qa" ? "papershelf-qa" : "papershelf"
        let url = URL(string: "\(scheme)://paper/\(matches[0].id.uuidString)")!
        return .result(opensIntent: OpenURLIntent(url))
    }
}

struct ExportPaperShelfMarkdownIntent: AppIntent {
    static var title: LocalizedStringResource = "导出 PaperShelf Markdown"
    static var description = IntentDescription("将一篇或多篇文献按设置中的元数据与批注模板导出为 Markdown 文件。区域批注图片直接嵌入文件。")
    @Parameter(title: "文献") var references: [PaperShelfReferenceEntity]
    @Parameter(title: "包含 PDF 批注", default: true) var includeAnnotations: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let text = try PaperShelfIntentLibrary.markdown(references, includeAnnotations: includeAnnotations)
        let filename = references.count == 1 ? PaperDetailedExport.safeFilename(references[0].citationKey.isEmpty ? references[0].title : references[0].citationKey) + ".md" : "PaperShelf-References.md"
        return .result(value: IntentFile(data: Data(text.utf8), filename: filename, type: UTType(filenameExtension: "md") ?? .plainText))
    }
}

struct ReadPaperShelfNotesIntent: AppIntent {
    static var title: LocalizedStringResource = "提取 PaperShelf 笔记"
    static var description = IntentDescription("选择一篇或多篇文献，按保存的模板返回完整笔记文本，可包含 PDF 批注并复制到剪贴板。")
    @Parameter(title: "文献") var references: [PaperShelfReferenceEntity]
    @Parameter(title: "包含 PDF 批注", default: true) var includeAnnotations: Bool
    @Parameter(title: "复制到剪贴板", default: false) var copyToClipboard: Bool

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = try PaperShelfIntentLibrary.markdown(references, includeAnnotations: includeAnnotations)
        if copyToClipboard {
            await MainActor.run {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        return .result(value: text)
    }
}

struct PaperShelfShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ReadPaperShelfNotesIntent(), phrases: ["用 \(.applicationName) 提取笔记"], shortTitle: "提取笔记", systemImageName: "doc.on.clipboard")
        AppShortcut(intent: SearchPaperShelfIntent(), phrases: ["在 \(.applicationName) 中搜索文献"], shortTitle: "搜索文献", systemImageName: "magnifyingglass")
        AppShortcut(intent: OpenPaperShelfReferenceIntent(), phrases: ["在 \(.applicationName) 中打开文献"], shortTitle: "打开文献", systemImageName: "book")
        AppShortcut(intent: ExportPaperShelfMarkdownIntent(), phrases: ["用 \(.applicationName) 导出学习资料"], shortTitle: "导出 Markdown", systemImageName: "doc.text")
    }
}

private enum PaperShelfIntentError: LocalizedError {
    case notFound(String), ambiguous(String), emptySelection
    var errorDescription: String? {
        switch self {
        case .notFound(let value): return "找不到文献 \(value)。请先打开 PaperShelf 检查文献库。"
        case .ambiguous(let value): return "多篇文献使用引用键 \(value)，请改用文献 UUID。"
        case .emptySelection: return "请至少选择一篇文献，或将“搜索 PaperShelf 文献”的结果传入此操作。"
        }
    }
}

private enum PaperShelfIntentLibrary {
    struct Preferences: Decodable {
        var templates: PaperExportTemplates?
        var annotationOCR: Bool?
    }

    static var databaseURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["PAPERSHELF_LIBRARY_PATH"], !path.isEmpty { return URL(fileURLWithPath: path) }
        if let directory = environment["PAPERSHELF_LIBRARY_DIR"], !directory.isEmpty { return URL(fileURLWithPath: directory).appendingPathComponent("library.sqlite") }
        if Bundle.main.bundleIdentifier == "local.papershelf.qa" { return Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("library/library.sqlite") }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperShelf/library.sqlite")
    }

    static func load() throws -> LibraryImport {
        let database = try LibraryDatabase(url: databaseURL, readOnly: true)
        return try LibraryImport(references: database.load().filter { $0.deletedAt == nil }.sorted {
            if $0.title == $1.title { return $0.id.uuidString < $1.id.uuidString }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }, collections: database.loadCollections())
    }

    static func search(_ query: String) throws -> [Reference] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return try load().references.filter { reference in
            let text = ([reference.id.uuidString, reference.title, reference.year, reference.journal, reference.doi, reference.isbn,
                         reference.citationKey, reference.notes, reference.abstract] + reference.authors + reference.tags + Array(reference.extraFields.values)).joined(separator: " ")
            return terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    static func markdown(_ references: [PaperShelfReferenceEntity], includeAnnotations: Bool) throws -> String {
        guard !references.isEmpty else { throw PaperShelfIntentError.emptySelection }
        let library = try PaperShelfIntentLibrary.load()
        let lookup = Dictionary(uniqueKeysWithValues: library.references.map { ($0.id, $0) })
        let preferences = try PaperShelfIntentLibrary.preferences()
        var rendered: [String] = []
        var seen = Set<UUID>()
        for entity in references where seen.insert(entity.id).inserted {
            guard let reference = lookup[entity.id] else { throw PaperShelfIntentError.notFound(entity.id.uuidString) }
            let annotations = includeAnnotations && reference.pdfPath != nil
                ? try PDFLinks.annotations(for: reference, options: .init(ocrIfNeeded: preferences.annotationOCR ?? false)) : []
            let imageLinks = Dictionary(uniqueKeysWithValues: annotations.compactMap { item in
                item.imagePNG.map { (item.id, "data:image/png;base64," + $0.base64EncodedString()) }
            })
            let paths = PaperShelfIntentLibrary.collectionPaths(for: reference, in: library.collections)
            rendered.append(try PaperTemplateRenderer.render(reference: reference, annotations: annotations,
                                                             templates: preferences.templates ?? .init(), collectionPaths: paths, imageLinks: imageLinks))
        }
        return rendered.joined(separator: "\n\n---\n\n") + "\n"
    }

    static func preferences() throws -> Preferences {
        let url = databaseURL.deletingLastPathComponent().appendingPathComponent("preferences.json")
        if !FileManager.default.fileExists(atPath: url.path) { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: url))
    }

    static func collectionPaths(for reference: Reference, in collections: [LibraryCollection]) -> [String] {
        let lookup = Dictionary(uniqueKeysWithValues: collections.map { ($0.id, $0) })
        return reference.collectionIDs.compactMap { id in
            var names: [String] = []; var cursor: UUID? = id; var visited = Set<UUID>()
            while let current = cursor, visited.insert(current).inserted, let collection = lookup[current] {
                names.insert(collection.name, at: 0); cursor = collection.parentID
            }
            return names.isEmpty ? nil : names.joined(separator: "/")
        }
    }
}

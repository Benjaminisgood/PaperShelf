import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperCore

enum ExportFormat { case bibtex, markdown }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var references: [Reference] = []
    @Published var selectedID: UUID?
    @Published var filter = "all"
    @Published var search = ""
    @Published var status = "PDF 保留在原位置，书库保存在本机。"
    @Published var error: String?
    @Published var isBusy = false
    @Published var sortNewest = true
    private var database: LibraryDatabase?

    let libraryURL: URL
    init() {
        if let path = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"] {
            libraryURL = URL(fileURLWithPath: path)
        } else {
            libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("PaperShelf/library.sqlite")
        }
        do {
            database = try LibraryDatabase(url: libraryURL)
            references = try database!.load()
        } catch {
            database = nil
            self.error = "书库无法打开，未覆盖已有数据。\n\(error.localizedDescription)"
        }
    }

    var collections: [String] { Array(Set(references.map(\.collection).filter { !$0.isEmpty })).sorted() }
    var tags: [String] { Array(Set(references.flatMap(\.tags))).sorted() }
    var selected: Reference? { references.first { $0.id == selectedID } }
    var heading: String {
        switch filter {
        case "all": return "全部文献"
        case "unread": return "待读"
        case "favorites": return "收藏"
        case "unfiled": return "未分类"
        case "missing": return "缺少附件"
        default: return String(filter.dropFirst(2))
        }
    }
    var filtered: [Reference] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return references.filter { reference in
            let inFilter: Bool
            switch filter {
            case "unread": inFilter = !reference.isRead
            case "favorites": inFilter = reference.isFavorite
            case "unfiled": inFilter = reference.collection.isEmpty
            case "missing": inFilter = reference.pdfPath == nil
            default:
                if filter.hasPrefix("c:") { inFilter = reference.collection == String(filter.dropFirst(2)) }
                else if filter.hasPrefix("t:") { inFilter = reference.tags.contains(String(filter.dropFirst(2))) }
                else { inFilter = true }
            }
            let text = ([reference.title, reference.journal, reference.year, reference.doi, reference.notes] + reference.authors + reference.tags).joined(separator: " ")
            return inFilter && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }.sorted {
            sortNewest ? $0.addedAt > $1.addedAt : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private func requireDatabase() throws -> LibraryDatabase {
        guard let database else { throw CocoaError(.fileReadUnknown) }
        return database
    }

    func save(_ reference: Reference) -> Bool {
        do {
            try requireDatabase().upsert(reference)
            references = try requireDatabase().load()
            status = "已保存 · \(reference.title)"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func addManual() {
        var reference = Reference()
        reference.title = "未命名文献"
        if filter.hasPrefix("c:") { reference.collection = String(filter.dropFirst(2)) }
        if save(reference) { filter = "all"; search = ""; selectedID = reference.id }
    }

    func removeSelected() {
        guard let reference = selected else { return }
        do {
            try requireDatabase().delete(id: reference.id)
            references = try requireDatabase().load()
            selectedID = nil
            status = "已移除书库记录；原始 PDF 保留。"
        } catch { self.error = error.localizedDescription }
    }

    func importFiles() {
        let panel = NSOpenPanel()
        panel.title = "导入 PDF、BibTeX 或 RIS"
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "bib") ?? .plainText, UTType(filenameExtension: "ris") ?? .plainText]
        guard panel.runModal() == .OK else { return }
        importURLs(panel.urls)
    }

    func importURLs(_ urls: [URL]) {
        do {
            var incoming: [Reference] = []
            for url in urls {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                if url.pathExtension.lowercased() == "pdf" {
                    incoming.append(try PDFLinks.reference(from: url))
                } else {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    incoming.append(contentsOf: try Bibliography.parse(content, format: url.pathExtension.lowercased()))
                }
            }
            let result = try requireDatabase().importReferences(incoming)
            references = try requireDatabase().load()
            filter = "all"; search = ""
            if let first = incoming.first(where: { item in references.contains { $0.id == item.id } }) { selectedID = first.id }
            status = "导入 \(result.inserted) 条，跳过 \(result.skipped) 条重复记录。"
        } catch { self.error = "未完成导入：\(error.localizedDescription)" }
    }

    func importDOI(_ value: String) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            let reference = try await DOIClient().fetch(value)
            let result = try requireDatabase().importReferences([reference])
            references = try requireDatabase().load()
            filter = "all"; search = ""
            selectedID = references.first { $0.doi.caseInsensitiveCompare(reference.doi) == .orderedSame }?.id
            status = result.inserted == 1 ? "已从 Crossref 导入元数据，请核对。" : "此 DOI 已在书库中，保留原有记录。"
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func attachPDF(to reference: Reference) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var updated = reference
            try PDFLinks.attach(url, to: &updated)
            _ = save(updated)
        } catch { self.error = error.localizedDescription }
    }

    func openPDF(_ reference: Reference, reveal: Bool = false) {
        do {
            try PDFLinks.withURL(for: reference) { url in
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else if !NSWorkspace.shared.open(url) { throw PDFLinkError.unreadable }
            }
        } catch { self.error = error.localizedDescription }
    }

    func export(_ format: ExportFormat, selectedOnly: Bool = false) {
        let items = selectedOnly ? selected.map { [$0] } ?? [] : filtered
        guard !items.isEmpty else { status = "当前列表没有可导出的文献。"; return }
        let text = format == .bibtex ? Bibliography.exportBibTeX(items) : Bibliography.exportMarkdown(items)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = format == .bibtex ? "PaperShelf.bib" : "PaperShelf.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "已导出 \(items.count) 条文献。" }
        catch { self.error = error.localizedDescription }
    }

    func copyCitation(_ reference: Reference) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Bibliography.exportBibTeX([reference]), forType: .string)
        status = "已复制 BibTeX。"
    }
}

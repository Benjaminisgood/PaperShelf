import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperCore

enum ExportFormat: String, CaseIterable { case bibtex = "BibTeX", ris = "RIS", markdown = "Markdown", textBundle = "TextBundle" }

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var references: [Reference] = []
    @Published private(set) var collectionRecords: [LibraryCollection] = []
    @Published private(set) var tagRecords: [LibraryTag] = []
    @Published var selectedIDs: Set<UUID> = []
    @Published var filter = "all"
    @Published var search = ""
    @Published var status = "就绪"
    @Published var error: String?
    @Published var isBusy = false
    @Published var preferences = LibraryPreferences()
    @Published var sortOrder = [KeyPathComparator(\Reference.addedAt, order: .reverse)]
    @Published var previewURL: URL?
    @Published var editingReference: Reference?
    @Published var metadataRefreshBase: Reference?
    @Published var showingIdentifier = false
    @Published var showingBatchEditor = false
    @Published var fileProgress: LibraryFileProgress?
    var importTask: Task<Void, Never>?
    var organizeTask: Task<Void, Never>?
    var localAPI: LocalAPIServer?
    var captureReceiver: BrowserCaptureReceiver?
    weak var undoManager: UndoManager?
    var database: LibraryDatabase?
    let libraryURL: URL
    let learning: LearningStore

    init() {
        if let path = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_PATH"] { libraryURL = URL(fileURLWithPath: path) }
        else if let path = ProcessInfo.processInfo.environment["PAPERSHELF_LIBRARY_DIR"] { libraryURL = URL(fileURLWithPath: path).appendingPathComponent("library.sqlite") }
        else if Bundle.main.bundleIdentifier == "local.papershelf.qa" { libraryURL = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("library/library.sqlite") }
        else { libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PaperShelf/library.sqlite") }
        learning = LearningStore(libraryURL: libraryURL)
        var preferenceError: String?
        do { preferences = try LibraryPreferences.load(from: libraryURL.deletingLastPathComponent().appendingPathComponent("preferences.json")) }
        catch { preferenceError = "设置文件无法读取，已保留原文件并临时使用默认设置。\n" + error.localizedDescription }
        do { database = try LibraryDatabase(url: libraryURL); try reload() }
        catch { database = nil; self.error = "书库无法打开，未覆盖已有数据。\n\(error.localizedDescription)" }
        if self.error == nil { self.error = preferenceError }
    }

    var selectedID: UUID? {
        get { selectedIDs.sorted { $0.uuidString < $1.uuidString }.first }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    var selected: Reference? { references.first { $0.id == selectedID } }
    var selectedReferences: [Reference] { references.filter { selectedIDs.contains($0.id) } }
    var activeReferences: [Reference] { references.filter { $0.deletedAt == nil } }
    var collections: [String] { Array(Set(activeReferences.filter { $0.collectionIDs.isEmpty }.map(\.collection).filter { !$0.isEmpty })).sorted() }
    var tags: [String] { let known = tagRecords.map(\.name); return known + Set(activeReferences.flatMap(\.tags)).subtracting(known).sorted() }
    var heading: String {
        switch filter {
        case "all": return "全部文献"
        case "unread": return "待读"
        case "favorites": return "收藏"
        case "unfiled": return "未归类"
        case "missing": return "缺少 PDF"
        case "missing-id": return "缺少标识符"
        case "trash": return "最近删除"
        default:
            if filter.hasPrefix("c:"), let id = UUID(uuidString: String(filter.dropFirst(2))) { return collectionRecords.first { $0.id == id }?.name ?? "文集" }
            return String(filter.dropFirst(2))
        }
    }
    func collectionIDs(in id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id]
        var frontier = [id]
        while let parent = frontier.popLast() {
            for child in collectionRecords where child.parentID == parent && !result.contains(child.id) { result.insert(child.id); frontier.append(child.id) }
        }
        return result
    }
    func matches(_ reference: Reference, filter: String) -> Bool {
        if filter == "trash" { return reference.deletedAt != nil }
        guard reference.deletedAt == nil else { return false }
        switch filter {
        case "unread": return !reference.isRead
        case "favorites": return reference.isFavorite
        case "unfiled": return reference.collection.isEmpty && reference.collectionIDs.isEmpty
        case "missing": return reference.pdfPath == nil
        case "missing-id": return reference.doi.isEmpty && reference.isbn.isEmpty && (reference.extraFields["arxivId"] ?? reference.extraFields["arxiv"] ?? "").isEmpty
        default:
            if filter.hasPrefix("c:") {
                let value = String(filter.dropFirst(2))
                if let id = UUID(uuidString: value) { return !Set(reference.collectionIDs).isDisjoint(with: preferences.includeSubcollections ? collectionIDs(in: id) : [id]) }
                return reference.collection == value
            }
            if filter.hasPrefix("t:") { return reference.tags.contains(String(filter.dropFirst(2))) }
            return true
        }
    }
    func count(_ filter: String) -> Int { references.filter { matches($0, filter: filter) }.count }
    var filtered: [Reference] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return references.filter { item in
            let text = ([item.title, item.journal, item.year, item.doi, item.notes, item.abstract, item.citationKey, item.isbn] + item.authors + item.tags + Array(item.extraFields.values)).joined(separator: " ")
            return matches(item, filter: filter) && (query.isEmpty || text.localizedCaseInsensitiveContains(query))
        }.sorted(using: sortOrder)
    }
    func requireDatabase() throws -> LibraryDatabase {
        guard let database else { throw CocoaError(.fileReadUnknown) }; return database
    }
    func reload() throws {
        let loadedReferences = try requireDatabase().load()
        let loadedCollections = try requireDatabase().loadCollections()
        let loadedTags = try requireDatabase().loadTags()
        references = loadedReferences; collectionRecords = loadedCollections; tagRecords = loadedTags
        selectedIDs.formIntersection(Set(filtered.map(\.id)))
    }
    @discardableResult func save(_ reference: Reference) -> Bool { saveBatch([reference]) }
    @discardableResult func saveBatch(_ values: [Reference], action: String = "编辑文献") -> Bool {
        let ids = Set(values.map(\.id)); let before = references.filter { ids.contains($0.id) }
        var values = values
        if preferences.updateCitationKeyOnEdit {
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            let indices = values.indices.filter { index in
                guard let original = old[values[index].id] else { return false }
                let edited = values[index]
                return edited.citationKey == original.citationKey &&
                    (edited.title != original.title || edited.authors != original.authors || edited.year != original.year || edited.entryType != original.entryType)
            }
            let generatedIDs = Set(indices.map { values[$0].id })
            let reserved = Set(references.filter { !ids.contains($0.id) }.map(\.citationKey) + values.filter { !generatedIDs.contains($0.id) }.map(\.citationKey))
            let generated = Bibliography.generateCitationKeys(indices.map { values[$0] }, template: preferences.citationKeyTemplate, reservedKeys: reserved)
            for (offset, index) in indices.enumerated() { values[index].citationKey = generated[offset].citationKey }
        }
        do {
            try requireDatabase().upsertReferences(values)
            refreshAfterCommit()
            registerHistory(before:before,after:references.filter { ids.contains($0.id) },action:action)
            status = "已保存 \(values.count) 篇文献"; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func updateSelected(_ change: (inout Reference) -> Void) {
        let items = selectedReferences.map { item in var updated = item; change(&updated); return updated }
        if !items.isEmpty { _ = saveBatch(items) }
    }
    func addManual() {
        var reference = Reference(title: "未命名文献")
        if filter.hasPrefix("c:"), let id = UUID(uuidString: String(filter.dropFirst(2))) { reference.collectionIDs = [id] }
        if filter.hasPrefix("t:") { reference.tags = [String(filter.dropFirst(2))] }
        if save(reference) {
            if !matches(reference,filter:filter) { filter = "all" }
            search = ""; selectedID = reference.id; editingReference = reference
        }
    }
    func removeSelected() { updateSelected { $0.deletedAt = Date() }; selectedIDs = []; status = "已移到最近删除，原始 PDF 保留" }
    func restoreSelected() { updateSelected { $0.deletedAt = nil }; selectedIDs = []; status = "已恢复文献" }
    func permanentlyDeleteSelected() {
        do { for item in selectedReferences where item.deletedAt != nil { try requireDatabase().delete(id: item.id) }; try reload(); selectedIDs = []; status = "已删除记录，原始 PDF 保留" }
        catch { self.error = error.localizedDescription }
    }
    func existingDuplicate(of item:Reference) -> Reference? {
        func doi(_ value:String) -> String { ((try? DOIClient.normalize(value)) ?? value.trimmingCharacters(in:.whitespacesAndNewlines)).lowercased() }
        let identifier = doi(item.doi)
        let path = item.pdfPath.map { URL(fileURLWithPath:$0).standardizedFileURL.path }
        return references.first { value in
            value.id == item.id || (!identifier.isEmpty && doi(value.doi) == identifier) ||
            (path != nil && value.pdfPath.map { URL(fileURLWithPath:$0).standardizedFileURL.path } == path)
        }
    }
    @discardableResult func importReferences(_ incoming: [Reference], collections: [LibraryCollection] = [], duplicatePolicy: ImportDuplicatePolicy = .skip) -> Bool {
        do {
            let before = references
            let classified = incoming.map { original in
                var item = original
                if filter.hasPrefix("c:"), let id = UUID(uuidString: String(filter.dropFirst(2))), !item.collectionIDs.contains(id) { item.collectionIDs.append(id) }
                if filter.hasPrefix("t:") { item.tags = Array(Set(item.tags + [String(filter.dropFirst(2))])).sorted() }
                return item
            }
            let oldIDs = Set(references.map(\.id))
            var keyed = classified
            var keyIndices:[Int] = []
            for index in classified.indices {
                if let existing = existingDuplicate(of:classified[index]), !existing.citationKey.isEmpty { keyed[index].citationKey = existing.citationKey }
                else { keyIndices.append(index) }
            }
            let generated = Bibliography.generateCitationKeys(keyIndices.map { classified[$0] }, template: preferences.citationKeyTemplate, preserveExisting: true, reservedKeys: Set(references.map(\.citationKey)))
            for (offset,index) in keyIndices.enumerated() { keyed[index] = generated[offset] }
            let result = try requireDatabase().importLibrary(LibraryImport(references: keyed, collections: collections), duplicatePolicy: duplicatePolicy)
            refreshAfterCommit()
            if duplicatePolicy == .skip {
                var membershipChanges:[UUID:Reference] = [:]
                for item in classified {
                    guard let matched = existingDuplicate(of:item), matched.deletedAt == nil else { continue }
                    var existing = membershipChanges[matched.id] ?? matched
                    existing.collectionIDs = Array(Set(existing.collectionIDs + item.collectionIDs)).sorted { $0.uuidString < $1.uuidString }
                    existing.tags = Array(Set(existing.tags + item.tags)).sorted()
                    if existing != matched { membershipChanges[existing.id] = existing }
                }
                if !membershipChanges.isEmpty {
                    do { try requireDatabase().upsertReferences(Array(membershipChanges.values)); refreshAfterCommit() }
                    catch { self.error = "文献已导入，但重复条目的分类未更新：\(error.localizedDescription)" }
                }
            }
            registerHistory(before:before,after:references,action:"导入文献")
            search = ""
            let added = references.filter { !oldIDs.contains($0.id) }
            if let first = added.first { selectedID = first.id }
            else if let item = incoming.first, let existing = existingDuplicate(of:item), existing.deletedAt == nil { selectedID = existing.id }
            if let selected, selected.deletedAt == nil, !matches(selected,filter:filter) { filter = "all" }
            status = "导入 \(result.inserted) 条，跳过 \(result.skipped) 条，替换 \(result.replaced) 条"
            let addedIDs = Set(added.map(\.id))
            let enqueueLearning = { [weak self] in
                guard let self, self.learning.settings.automaticallyGenerate else { return }
                self.learning.enqueue(self.references.filter { addedIDs.contains($0.id) && $0.deletedAt == nil })
            }
            if !preferences.automaticallyOrganize || added.isEmpty || !organizeFiles(added, completion: enqueueLearning) { enqueueLearning() }
            return true
        } catch { self.error = "未完成导入：\(error.localizedDescription)"; return false }
    }
    func importFiles() {
        let panel = NSOpenPanel(); panel.title = "导入文献或文件夹"; panel.allowsMultipleSelection = true; panel.canChooseDirectories = true
        panel.allowedContentTypes = [.pdf, UTType(filenameExtension: "bib") ?? .plainText, UTType(filenameExtension: "ris") ?? .plainText]
        guard panel.runModal() == .OK else { return }; importURLs(panel.urls)
    }
    func importURLs(_ urls: [URL]) {
        guard importTask == nil, organizeTask == nil else { status = "正在处理文件，请等待或取消当前任务"; return }
        isBusy = true
        importTask = Task {
            defer { isBusy = false; importTask = nil }
            let worker = Task.detached { () throws -> ([Reference], [String]) in
                var files: [URL] = []; var seen: Set<String> = []; var warnings: [String] = []
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
                for url in urls {
                    try Task.checkCancellation()
                    let info = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if info.isDirectory == true {
                        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                        while let file = enumerator.nextObject() as? URL {
                            try Task.checkCancellation()
                            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            if values.isRegularFile == true && values.isSymbolicLink != true && ["pdf", "bib", "ris"].contains(file.pathExtension.lowercased()) { files.append(file) }
                        }
                    } else { files.append(url) }
                }
                files = files.filter { seen.insert($0.standardizedFileURL.path).inserted }.sorted { $0.path < $1.path }
                var values: [Reference] = []
                let total = files.count
                for (index, url) in files.enumerated() {
                    try Task.checkCancellation()
                    await MainActor.run { self.status = "读取 \(index + 1) / \(total)：\(url.lastPathComponent)" }
                    do {
                        if url.pathExtension.lowercased() == "pdf" { values.append(try PDFLinks.reference(from: url)) }
                        else { values.append(contentsOf: try Bibliography.parse(String(contentsOf: url, encoding: .utf8), format: url.pathExtension.lowercased())) }
                    } catch { warnings.append("\(url.lastPathComponent)：\(error.localizedDescription)") }
                }
                return (values, warnings)
            }
            do {
                let (incoming, warnings) = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                var policy = ImportDuplicatePolicy.skip
                let hasDuplicates = incoming.contains { existingDuplicate(of:$0) != nil }
                if hasDuplicates {
                    let alert = NSAlert(); alert.messageText = "本批次包含已有文献"; alert.informativeText = "选择本批次所有重复记录的处理方式。替换会保留本地笔记、阅读状态和附件。"; alert.addButton(withTitle: "跳过重复"); alert.addButton(withTitle: "替换重复"); alert.addButton(withTitle: "取消")
                    let response = alert.runModal(); if response == .alertThirdButtonReturn { status = "已取消导入"; return }; if response == .alertSecondButtonReturn { policy = .replace }
                }
                _ = importReferences(incoming, duplicatePolicy: policy)
                if !warnings.isEmpty { error = "部分文件未导入：\n" + warnings.joined(separator: "\n") }
            } catch is CancellationError { status = "已取消导入，未写入本批次" }
            catch { self.error = error.localizedDescription }
        }
    }
    func importDOI(_ value: String) async -> Bool {
        isBusy = true; defer { isBusy = false }
        do { return importReferences([try await MetadataLookup().fetch(value)]) }
        catch { self.error = error.localizedDescription; return false }
    }
    func refreshMetadata(_ reference: Reference) async {
        let identifier = !reference.doi.isEmpty ? reference.doi : !reference.isbn.isEmpty ? reference.isbn : reference.extraFields["arxivId"] ?? reference.extraFields["arxiv"] ?? ""
        guard !identifier.isEmpty else { error = "请先补充 DOI、ISBN 或 arXiv 标识符。"; return }
        isBusy = true; defer { isBusy = false }
        do {
            let fetched = try await MetadataLookup().fetch(identifier)
            var updated = reference
            updated.title = fetched.title; updated.authors = fetched.authors; updated.year = fetched.year; updated.journal = fetched.journal
            updated.doi = fetched.doi; updated.url = fetched.url
            if !fetched.abstract.isEmpty { updated.abstract = fetched.abstract }
            for key in [\Reference.volume, \.issue, \.pages, \.publisher, \.isbn, \.issn] { if !fetched[keyPath: key].isEmpty { updated[keyPath: key] = fetched[keyPath: key] } }
            metadataRefreshBase = reference
            editingReference = updated; status = "已取得元数据，请核对后保存"
        } catch { self.error = error.localizedDescription }
    }
    func attachPDF(to reference: Reference) {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }; attachPDF(url, to: reference)
    }
    func attachPDF(_ url: URL, to reference: Reference) {
        do {
            guard var updated = references.first(where: { $0.id == reference.id }), updated.deletedAt == nil else { return }
            try PDFLinks.attach(url, to: &updated)
            if save(updated), learning.settings.automaticallyGenerate { learning.enqueue([updated]) }
        } catch { self.error = error.localizedDescription }
    }
    func openPDF(_ reference: Reference, reveal: Bool = false) {
        do { try PDFLinks.withURL(for: reference) { url in
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            else if !preferences.readerBundleID.isEmpty, let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferences.readerBundleID) { NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) }
            else if !NSWorkspace.shared.open(url) { throw PDFLinkError.unreadable }
        } } catch { self.error = error.localizedDescription }
    }
    func preview(_ reference: Reference? = nil) {
        guard let item = reference ?? selected else { return }
        do { previewURL = try PDFLinks.withURL(for: item) { $0 } }
        catch { self.error = error.localizedDescription }
    }
    func copyCitation(_ reference: Reference) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Bibliography.exportBibTeX([reference]), forType: .string)
        status = "已复制 BibTeX"
    }
    func copySelectedDOIs() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(selectedReferences.map(\.doi).filter { !$0.isEmpty }.joined(separator: "\n"), forType: .string)
    }
}

import AppKit
import PaperCore

extension LibraryStore {
    func savePreferences() {
        do { try preferences.save(to: libraryURL.deletingLastPathComponent().appendingPathComponent("preferences.json")) }
        catch { self.error = error.localizedDescription }
    }
    func chooseFileLibrary() {
        let panel = NSOpenPanel(); panel.title = "选择文件库"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { preferences.fileRootBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil); preferences.fileRoot = url.path; savePreferences() }
        catch { self.error = error.localizedDescription }
    }
    func addAttachments(to reference: Reference) {
        let panel = NSOpenPanel(); panel.title = "添加附件"; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            guard var value = references.first(where: { $0.id == reference.id }), value.deletedAt == nil else { return }
            for url in panel.urls { value.attachments.append(try PaperAttachments.link(url)) }
            _ = save(value)
        }
        catch { self.error = error.localizedDescription }
    }
    func openAttachment(_ attachment: ReferenceAttachment, reveal: Bool = false) {
        do { let url = try PaperAttachments.resolvedURL(for: attachment); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) } else { NSWorkspace.shared.open(url) }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func organizeFiles(_ items: [Reference], action: PaperFileAction? = nil, completion: @escaping () -> Void = {}) -> Bool {
        guard organizeTask == nil, fileProgress == nil else { error = "已有文件任务正在进行，请等待或取消。"; return false }
        guard !preferences.fileRoot.isEmpty else { error = "请先在设置中选择文件库。"; return false }
        guard !learning.busy else { error = "请先等待学习资料任务完成，再整理其来源文件。"; return false }
        var options = preferences.fileOptions; if let action { options.action = action }
        if options.action == .move {
            let alert = NSAlert(); alert.messageText = "移动文件到文件库？"; alert.informativeText = "将移动选中文献的 PDF 和附件，并更新书库路径。其他软件的旧路径可能失效。"; alert.addButton(withTitle: "移动"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        do {
            let root = try preferences.resolvedFileRoot()
            let ids = Array(Set(items.map(\.id))).sorted { $0.uuidString < $1.uuidString }
            guard !ids.isEmpty else { return false }
            fileProgress = LibraryFileProgress(completed: 0, total: ids.count, title: "准备整理文件")
            organizeTask = Task {
                defer { fileProgress = nil; organizeTask = nil; completion() }
                await performFileOrganization(ids, root: root, options: options)
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func cancelFileOperation() {
        guard organizeTask != nil || importTask != nil else { return }
        fileProgress?.isCancelling = true
        status = "正在取消；等待当前文件操作结束后安全回滚…"
        organizeTask?.cancel(); importTask?.cancel()
    }

    func cancelFileOperationsForTermination() async {
        let organization = organizeTask, importing = importTask
        cancelFileOperation()
        await organization?.value
        await importing?.value
    }

    func performFileOrganization(_ ids: [UUID], root: URL, options: PaperFileOptions) async {
        var completed = 0
        do {
            for id in ids {
                try Task.checkCancellation()
                guard let original = references.first(where: { $0.id == id }), original.deletedAt == nil else { continue }
                if options.action == .move { try ensureFilesAreNotShared([original], allowing: [original.id]) }
                fileProgress = LibraryFileProgress(completed: completed, total: ids.count, title: original.title)
                status = "整理文件 \(completed + 1) / \(ids.count)：\(original.title)"
                let prepared = try await prepareReferenceFiles(original, root: root, options: options, collectionPaths: original.collectionIDs.map(collectionPath))
                do {
                    try Task.checkCancellation()
                    guard var current = references.first(where: { $0.id == original.id }), current.deletedAt == nil,
                          current.pdfPath == original.pdfPath, current.pdfBookmark == original.pdfBookmark,
                          current.attachments == original.attachments else {
                        throw LocalAPIError(409, "文献或附件在整理期间已改变；本篇文件操作已取消，请重试。")
                    }
                    if options.action == .move { try ensureFilesAreNotShared([original], allowing: [original.id]) }
                    // Preserve metadata edited while the files were being processed.
                    current.pdfPath = prepared.reference.pdfPath; current.pdfBookmark = prepared.reference.pdfBookmark
                    current.attachments = prepared.reference.attachments
                    try requireDatabase().upsert(current)
                } catch { throw LibraryFilePreparation.rollback(prepared.placements, because: error) }
                // A refresh failure must never undo a successfully committed file move.
                refreshAfterCommit()
                completed += 1
                fileProgress = LibraryFileProgress(completed: completed, total: ids.count, title: original.title)
                await Task.yield()
            }
            status = "已整理 \(completed) 篇文献的文件"
        } catch is CancellationError { status = "已取消文件整理；保留已完成的 \(completed) 篇，当前未提交文件已回滚" }
        catch { self.error = error.localizedDescription; status = "文件整理已停止；已完成 \(completed) 篇" }
    }

    func prepareReferenceFiles(_ reference: Reference, root: URL, options: PaperFileOptions, collectionPaths: [String]) async throws -> PreparedReferenceFiles {
        try Task.checkCancellation()
        let worker = Task.detached { try LibraryFilePreparation.prepare(reference, root: root, options: options, collectionPaths: collectionPaths) }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Destructive operations cannot remove a file still linked by another row,
    /// including a record in Recently Deleted. Resolve bookmarks as well as paths.
    func ensureFilesAreNotShared(_ items: [Reference], allowing ids: Set<UUID>) throws {
        func paths(_ item: Reference) throws -> Set<String> {
            var urls = try item.attachments.map { try PaperAttachments.resolvedURL(for: $0) }
            if item.pdfPath != nil { urls.append(try PDFLinks.resolvedURL(for: item)) }
            let recorded = item.attachments.map { URL(fileURLWithPath: $0.path) } + (item.pdfPath.map { [URL(fileURLWithPath: $0)] } ?? [])
            return Set((urls + recorded).map { $0.standardizedFileURL.resolvingSymlinksInPath().path })
        }
        let selected = try items.reduce(into: Set<String>()) { $0.formUnion(try paths($1)) }
        for other in references where !ids.contains(other.id) {
            if !selected.isDisjoint(with: try paths(other)) {
                throw LocalAPIError(409, "文件仍被另一篇文献引用：\(other.title)。请先解除共享关联，或使用复制。")
            }
        }
    }
    func regenerateCitationKeys() {
        let values = selectedReferences.isEmpty ? activeReferences : selectedReferences
        let ids = Set(values.map(\.id))
        let reserved = Set(references.filter { !ids.contains($0.id) }.map(\.citationKey))
        let changed = Bibliography.generateCitationKeys(values, template: preferences.citationKeyTemplate, reservedKeys: reserved)
        _ = saveBatch(changed, action: "更新引用键")
    }
}

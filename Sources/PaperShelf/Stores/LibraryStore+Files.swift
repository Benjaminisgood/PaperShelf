import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PaperCore

enum LibraryExportScope: String, CaseIterable {
    case selected = "选中文献"
    case current = "当前列表"
    case all = "全部文献"
}

extension LibraryStore {
    func export(_ format: ExportFormat, selectedOnly: Bool = false, scope: LibraryExportScope? = nil) {
        let items: [Reference]
        switch scope ?? (selectedOnly ? .selected : .current) {
        case .selected: items = selectedReferences
        case .current: items = filtered
        case .all: items = activeReferences
        }
        guard !items.isEmpty else { status = "没有可导出的文献"; return }
        if format == .textBundle { exportDetailed(items, textBundle: true); return }
        let text: String
        switch format { case .bibtex: text = Bibliography.exportBibTeX(items, options: .init(fields: preferences.bibtexFields.isEmpty ? nil : Set(preferences.bibtexFields), citationKeyTemplate: preferences.citationKeyTemplate)); case .ris: text = Bibliography.exportRIS(items); default: text = Bibliography.exportMarkdown(items) }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "PaperShelf." + (format == .bibtex ? "bib" : format == .ris ? "ris" : "md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); status = "已导出 \(items.count) 篇文献" }
        catch { self.error = error.localizedDescription }
    }
    func importZotero() {
        guard !isBusy, importTask == nil, organizeTask == nil else { error = "请先完成或取消正在进行的文件任务。"; return }
        let panel = NSOpenPanel(); panel.title = "选择 Zotero 的 zotero.sqlite"; panel.message = "只读迁移文献与文集；不会修改 Zotero。"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let optionsPanel = NSAlert(); optionsPanel.messageText = "选择 Zotero 导入方式"
        optionsPanel.informativeText = "元数据模式导入文献、文集、标签和笔记，不关联附件。复制模式将 PDF 和附件复制到文件库，始终保留 Zotero 原文件。重复文献会跳过。"
        optionsPanel.addButton(withTitle: "仅导入元数据"); optionsPanel.addButton(withTitle: "复制附件到文件库"); optionsPanel.addButton(withTitle: "取消")
        let external = NSButton(checkboxWithTitle: "指定外部链接附件目录（attachments:）", target: nil, action: nil)
        external.frame = NSRect(x: 0, y: 0, width: 370, height: 26); optionsPanel.accessoryView = external
        let choice = optionsPanel.runModal()
        guard choice != .alertThirdButtonReturn else { return }
        let copyAttachments = choice == .alertSecondButtonReturn
        var linkedRoot: URL?
        if copyAttachments, external.state == .on {
            let directory = NSOpenPanel(); directory.title = "选择 Zotero 外部链接附件目录"; directory.canChooseDirectories = true; directory.canChooseFiles = false
            guard directory.runModal() == .OK, let selected = directory.url else { return }
            linkedRoot = selected
        }
        var copyRoot: URL?
        if copyAttachments {
            if preferences.fileRoot.isEmpty { chooseFileLibrary() }
            guard !preferences.fileRoot.isEmpty else { return }
            do { copyRoot = try preferences.resolvedFileRoot() }
            catch { self.error = error.localizedDescription; return }
        }
        let destination = copyRoot, linkedDirectory = linkedRoot
        // Zotero migration always copies, regardless of ordinary organization preferences.
        var fileOptions = preferences.fileOptions; fileOptions.action = .copy
        isBusy = true
        importTask = Task {
            let accessed = [url, linkedDirectory].compactMap { $0 }.filter { $0.startAccessingSecurityScopedResource() }
            defer {
                accessed.forEach { $0.stopAccessingSecurityScopedResource() }
                isBusy = false; importTask = nil; fileProgress = nil
            }
            status = "正在读取 Zotero 快照…"
            let worker = Task.detached {
                try ZoteroImporter.read(url: url, storageDirectory: url.deletingLastPathComponent().appendingPathComponent("storage"),
                                        linkedAttachmentDirectory: linkedDirectory, includeAttachments: copyAttachments)
            }
            do {
                let library = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                await importZoteroLibrary(library, copyingTo: destination, options: fileOptions)
            } catch is CancellationError { status = "已取消 Zotero 导入，未写入文献" }
            catch { self.error = error.localizedDescription }
        }
    }

    /// Commits one paper only after its copied files are ready. Duplicate checks
    /// run both before and after the worker suspension to avoid orphaned copies.
    func importZoteroLibrary(_ library: LibraryImport, copyingTo root: URL?, options: PaperFileOptions) async {
        var committed: [Reference] = [], skipped = 0, processed = 0
        var copyOptions = options; copyOptions.action = .copy
        defer {
            registerHistory(before: [], after: committed, action: "从 Zotero 导入")
            if learning.settings.automaticallyGenerate {
                let ids = Set(committed.map(\.id))
                learning.enqueue(references.filter { ids.contains($0.id) && $0.deletedAt == nil })
            }
        }
        do {
            try Task.checkCancellation()
            _ = try requireDatabase().importLibrary(LibraryImport(references: [], collections: library.collections, tags: library.tags))
            refreshAfterCommit(); filter = "all"
            for incoming in library.references {
                try Task.checkCancellation()
                fileProgress = LibraryFileProgress(completed: processed, total: library.references.count, title: incoming.title)
                status = "导入 Zotero \(processed + 1) / \(library.references.count)：\(incoming.title)"
                if existingDuplicate(of: incoming) != nil {
                    skipped += 1; processed += 1
                    fileProgress?.completed = processed
                    await Task.yield(); continue
                }
                var value = Bibliography.generateCitationKeys([incoming], template: preferences.citationKeyTemplate, preserveExisting: true, reservedKeys: Set(references.map(\.citationKey)))[0]
                var prepared: PreparedReferenceFiles?
                if let root {
                    prepared = try await prepareReferenceFiles(value, root: root, options: copyOptions, collectionPaths: value.collectionIDs.map(collectionPath))
                    value = prepared!.reference
                } else { value.pdfPath = nil; value.pdfBookmark = nil; value.attachments = [] }
                var inserted = false
                do {
                    try Task.checkCancellation()
                    if existingDuplicate(of: incoming) == nil {
                        value = Bibliography.generateCitationKeys([value], template: preferences.citationKeyTemplate, preserveExisting: true, reservedKeys: Set(references.map(\.citationKey)))[0]
                        let result = try requireDatabase().importLibrary(LibraryImport(references: [value]))
                        inserted = result.inserted == 1
                    }
                } catch { throw LibraryFilePreparation.rollback(prepared?.placements ?? [], because: error) }
                if inserted {
                    committed.append(value)
                    refreshAfterCommit()
                } else {
                    // A duplicate arrived through the local API during the file copy.
                    let rollbackResult = LibraryFilePreparation.rollback(prepared?.placements ?? [], because: ZoteroSkippedDuplicate())
                    if !(rollbackResult is ZoteroSkippedDuplicate) { throw rollbackResult }
                    skipped += 1
                }
                processed += 1
                fileProgress?.completed = processed
                await Task.yield()
            }
            status = "已从 Zotero 导入 \(committed.count) 篇，跳过 \(skipped) 篇；\(library.warnings.count) 条提示"
            if !library.warnings.isEmpty { self.error = library.warnings.joined(separator: "\n") }
        } catch is CancellationError {
            status = "已取消 Zotero 导入；保留已完成的 \(committed.count) 篇，当前未提交文件已回滚"
        } catch {
            self.error = error.localizedDescription
            status = "Zotero 导入已停止；保留已完成的 \(committed.count) 篇"
        }
    }
    func backupLibrary() {
        guard organizeTask == nil, fileProgress == nil else { error = "请先完成或取消正在进行的文件任务，再备份书库。"; return }
        let panel = NSSavePanel(); panel.title = "备份书库"; panel.nameFieldStringValue = "PaperShelf-\(Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))).papershelfbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let manifest = try LibraryBackup.create(database: requireDatabase(), to: url, includeAttachments: true, preferencesURL: libraryURL.deletingLastPathComponent().appendingPathComponent("preferences.json")); status = "书库与附件已备份"; if !manifest.warnings.isEmpty { self.error = manifest.warnings.joined(separator: "\n") } }
        catch { self.error = error.localizedDescription }
    }
    func restoreLibrary() {
        guard !isBusy, importTask == nil, organizeTask == nil, !learning.busy else { error = "请先完成或取消正在进行的任务，再恢复书库。"; return }
        let panel = NSOpenPanel(); panel.title = "选择 PaperShelf 备份"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destinationPanel = NSOpenPanel(); destinationPanel.title = "选择恢复附件的存放目录"
        destinationPanel.message = "将在此目录中新建唯一的 RestoredAttachments 文件夹；已有文件不会覆盖。"
        destinationPanel.canChooseDirectories = true; destinationPanel.canChooseFiles = false; destinationPanel.canCreateDirectories = true
        if !preferences.fileRoot.isEmpty { destinationPanel.directoryURL = try? preferences.resolvedFileRoot() }
        guard destinationPanel.runModal() == .OK, let attachmentDirectory = destinationPanel.url else { return }
        let alert = NSAlert(); alert.messageText = "从备份恢复书库？"; alert.informativeText = "将替换当前书库记录。恢复前会自动保存当前书库的安全备份，原始文件不会删除。"; alert.addButton(withTitle: "恢复"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        localAPI?.stop(); captureReceiver?.cancel()
        defer { do { try localAPI?.start(configuration:preferences.localAPI) } catch { self.error = error.localizedDescription } }
        do {
            let result = try LibraryBackup.restore(from: url, into: requireDatabase(), backupDirectory: libraryURL.deletingLastPathComponent().appendingPathComponent("Backups"), preferencesURL: libraryURL.deletingLastPathComponent().appendingPathComponent("preferences.json"), attachmentDirectory: attachmentDirectory)
            undoManager?.removeAllActions(); editingReference = nil
            if let data = result.restoredPreferencesData {
                do {
                    var restored = try JSONDecoder().decode(LibraryPreferences.self, from: data)
                    restored.localAPI = preferences.localAPI
                    preferences = restored; savePreferences()
                } catch { self.error = "书库已恢复，但备份设置无法读取；保留当前设置。\n\(error.localizedDescription)" }
            }
            refreshAfterCommit(); selectedIDs = []; filter = "all"; status = "已恢复 \(result.restoredReferences) 篇文献；恢复前快照已保存"
            if !result.warnings.isEmpty { self.error = result.warnings.joined(separator: "\n") }
        } catch { self.error = error.localizedDescription }
    }
    func exportDetailed(_ items: [Reference], textBundle: Bool) {
        let panel = NSOpenPanel(); panel.title = "导出详细笔记"; panel.message = "包含区域图片时生成 TextBundle，其余生成 Markdown。"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        isBusy = true
        let templates = preferences.templates; let ocr = preferences.annotationOCR
        let paths = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.collectionIDs.map(collectionPath)) })
        Task { defer { isBusy = false }
            do {
                let count = try await Task.detached { () throws -> Int in
                    for item in items {
                        let annotations = item.pdfPath == nil ? [] : try PDFLinks.annotations(for: item, options: .init(ocrIfNeeded: ocr))
                        _ = try PaperDetailedExport.export(reference: item, annotations: annotations, to: directory, templates: templates, collectionPaths: paths[item.id] ?? [])
                    }
                    return items.count
                }.value
                status = "已导出 \(count) 篇详细笔记"
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct ZoteroSkippedDuplicate: Error {}

import AppKit
import Foundation
import PaperCore

/// UI boundary: every external URL is untrusted and requires a visible import decision.
@MainActor
final class BrowserCaptureReceiver {
    private let storageDirectory: URL
    private let downloadRoot: (() throws -> URL)?
    private let snapshot: () -> LocalAPISnapshot
    private let onImport: (Reference, ImportDuplicatePolicy) -> Bool
    private let onSelect: (UUID) -> Void
    private let onStatus: (String) -> Void
    private let onError: (String) -> Void
    private var queue: [BrowserCapturePayload] = []
    private var seen: [UUID] = []
    private var processing = false
    private var task: Task<Void, Never>?

    init(storageDirectory: URL, downloadRoot: (() throws -> URL)? = nil, snapshot: @escaping () -> LocalAPISnapshot = { LocalAPISnapshot(references:[],collections:[],tags:[]) },
         onImport: @escaping (Reference, ImportDuplicatePolicy) -> Bool, onSelect: @escaping (UUID) -> Void = { _ in },
         onStatus: @escaping (String) -> Void = { _ in }, onError: @escaping (String) -> Void = { _ in }) {
        self.storageDirectory = storageDirectory
        self.downloadRoot = downloadRoot
        self.snapshot = snapshot; self.onImport = onImport; self.onSelect = onSelect; self.onStatus = onStatus; self.onError = onError
    }

    func handle(_ urls: [URL]) {
        for url in urls {
            do {
                let payload = try BrowserCapturePayload.decode(url)
                guard !seen.contains(payload.id), !queue.contains(where: { $0.id == payload.id }) else { continue }
                guard queue.count < 20 else { throw BrowserCaptureError.invalidPayload("待确认采集过多") }
                queue.append(payload)
            } catch { onError(error.localizedDescription) }
        }
        guard !processing, !queue.isEmpty else { return }
        processing = true
        task = Task { await processQueue() }
    }

    func cancel() { task?.cancel(); queue.removeAll() }
    func cancelForTermination() async {
        let pending = task
        cancel()
        await pending?.value
    }

    private func processQueue() async {
        defer { processing = false; task = nil }
        while !queue.isEmpty, !Task.isCancelled {
            let payload = queue.removeFirst()
            seen.append(payload.id)
            if seen.count > 512 { seen.removeFirst(seen.count - 512) }
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "采集到 PaperShelf？"
            alert.informativeText = "来源：\(URL(string: payload.sourceURL)?.host ?? "")\n网页元数据未经核验。请滚动核对全部信息；PDF 需单独选择。"
            alert.addButton(withTitle: "仅导入元数据")
            alert.addButton(withTitle: "取消")
            let library = snapshot()
            let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: payload.pdfURLs.isEmpty ? 320 : 360))
            let scroll = NSScrollView(frame: NSRect(x: 0, y: payload.pdfURLs.isEmpty ? 80 : 120, width: 520, height: 240))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let preview = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 240))
            preview.isEditable = false; preview.isSelectable = true
            preview.isHorizontallyResizable = false; preview.isVerticallyResizable = true
            preview.textContainer?.widthTracksTextView = true
            preview.autoresizingMask = [.width]
            preview.font = .systemFont(ofSize: 12)
            preview.string = "标题：\(payload.title)\n作者：\(payload.authors.joined(separator: "; "))\n期刊：\(payload.journal)\n年份：\(payload.year)\nDOI：\(payload.doi)\n来源：\(payload.sourceURL)\n\n摘要：\n\(payload.abstract)\n\n选中文字：\n\(payload.selectedText)"
            scroll.documentView = preview
            accessory.addSubview(scroll)
            let collection = NSPopUpButton(frame:NSRect(x:0,y:40,width:520,height:28))
            collection.addItem(withTitle:"文集：不额外归类")
            for value in library.collections {
                var names = [value.name], parent = value.parentID, visited: Set<UUID> = [value.id]
                while let id = parent, visited.insert(id).inserted, let next = library.collections.first(where: { $0.id == id }) {
                    names.insert(next.name,at:0); parent = next.parentID
                }
                collection.addItem(withTitle:names.joined(separator:" / "))
            }
            accessory.addSubview(collection)
            let tags = NSTextField(frame:NSRect(x:0,y:4,width:520,height:26))
            tags.placeholderString = "标签，以分号分隔；可新建标签"
            tags.toolTip = "已有标签：" + library.tags.map(\.name).joined(separator:"; ")
            accessory.addSubview(tags)
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 80, width: 520, height: 28))
            if !payload.pdfURLs.isEmpty {
                picker.addItems(withTitles: payload.pdfURLs)
                picker.toolTip = "仅下载公开 PDF；不继承浏览器登录、Cookie 或机构权限。"
                accessory.addSubview(picker)
                alert.addButton(withTitle: "同时下载所选 PDF")
            }
            alert.accessoryView = accessory
            let answer = alert.runModal()
            guard answer == .alertFirstButtonReturn || answer == .alertThirdButtonReturn else { continue }
            var reference = payload.reference()
            if collection.indexOfSelectedItem > 0, library.collections.indices.contains(collection.indexOfSelectedItem-1) {
                reference.collectionIDs = [library.collections[collection.indexOfSelectedItem-1].id]
            }
            reference.tags = Array(Set(tags.stringValue.split(separator:";").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
            let capturedMetadata = reference
            var previousSnapshot:Reference?
            var policy = ImportDuplicatePolicy.skip
            if let previous = snapshot().references.first(where: { value in
                !reference.doi.isEmpty && value.doi.caseInsensitiveCompare(reference.doi) == .orderedSame ||
                value.title.caseInsensitiveCompare(reference.title) == .orderedSame && value.year == reference.year
            }) {
                let duplicate = NSAlert()
                duplicate.messageText = "书库中已有此文献"
                duplicate.informativeText = "\(previous.title)\n替换仅更新本次有值的网页元数据，并保留原有笔记、状态和附件。"
                duplicate.addButton(withTitle:"跳过")
                duplicate.addButton(withTitle:"替换元数据")
                duplicate.addButton(withTitle:"打开已有文献")
                let decision = duplicate.runModal()
                if decision == .alertThirdButtonReturn { onSelect(previous.id); onStatus("已打开已有文献"); continue }
                guard decision == .alertSecondButtonReturn else { onStatus("已跳过重复文献"); continue }
                reference = merging(capturedMetadata,into:previous)
                previousSnapshot = previous; policy = .replace
            }
            let metadataReference = reference
            var downloaded: URL?
            var scopedRoot: URL?
            defer { scopedRoot?.stopAccessingSecurityScopedResource() }
            if answer == .alertThirdButtonReturn, payload.pdfURLs.indices.contains(picker.indexOfSelectedItem) {
                do {
                    let url = try BrowserCaptureNetworkPolicy.publicURL(payload.pdfURLs[picker.indexOfSelectedItem])
                    let root = try downloadRoot?() ?? storageDirectory
                    if root.startAccessingSecurityScopedResource() { scopedRoot = root }
                    let destination = try BrowserCaptureStorage.destination(in: root)
                    onStatus("正在下载公开 PDF · \(payload.title)")
                    try await BrowserCaptureDownloader.download(url, to: destination)
                    downloaded = destination
                    try PDFLinks.attach(destination, to: &reference)
                    reference.notes += "\nPDF 来源：\(url.absoluteString)"
                } catch {
                    if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                    if Task.isCancelled { return }
                    let recovery = NSAlert()
                    recovery.messageText = "PDF 未下载"
                    recovery.informativeText = "\(error.localizedDescription)\n\n可仅导入元数据；需要登录的 PDF 请在浏览器下载后手动关联。"
                    recovery.addButton(withTitle: "仅导入元数据")
                    recovery.addButton(withTitle: "取消")
                    guard recovery.runModal() == .alertFirstButtonReturn else { continue }
                    downloaded = nil
                    reference = metadataReference
                }
            }
            if Task.isCancelled {
                if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
                return
            }
            let current = snapshot().references
            if let previousSnapshot, !current.contains(where: { $0.id == previousSnapshot.id }) {
                if let downloaded { try? FileManager.default.removeItem(at:downloaded.deletingLastPathComponent()) }
                onError("下载期间原文献已被删除，未重新建立或覆盖记录。"); continue
            }
            let latest = previousSnapshot.flatMap { old in current.first { $0.id == old.id } } ?? current.first { value in
                !capturedMetadata.doi.isEmpty && value.doi.caseInsensitiveCompare(capturedMetadata.doi) == .orderedSame ||
                value.title.caseInsensitiveCompare(capturedMetadata.title) == .orderedSame && value.year == capturedMetadata.year
            }
            if let latest, previousSnapshot == nil || latest != previousSnapshot {
                let changed = NSAlert()
                changed.messageText = "下载期间书库记录发生变化"
                changed.informativeText = "\(latest.title)\n可跳过本次采集，或把本次元数据合并到当前记录；当前笔记、状态和其他附件会保留。"
                changed.addButton(withTitle:"跳过")
                changed.addButton(withTitle:"合并到当前记录")
                changed.addButton(withTitle:"打开已有文献")
                let decision = changed.runModal()
                guard decision == .alertSecondButtonReturn else {
                    if let downloaded { try? FileManager.default.removeItem(at:downloaded.deletingLastPathComponent()) }
                    if decision == .alertThirdButtonReturn { onSelect(latest.id) }
                    continue
                }
                var merged = merging(capturedMetadata,into:latest)
                if downloaded != nil { merged.pdfPath = reference.pdfPath; merged.pdfBookmark = reference.pdfBookmark }
                reference = merged; policy = .replace
            }
            if onImport(reference,policy) { onStatus("已采集 · \(reference.title)（元数据待核对）") }
            else if let downloaded { try? FileManager.default.removeItem(at: downloaded.deletingLastPathComponent()) }
        }
    }

    private func merging(_ captured:Reference,into previous:Reference) -> Reference {
        var value = previous
        value.title = captured.title
        if !captured.authors.isEmpty { value.authors = captured.authors }
        if !captured.year.isEmpty { value.year = captured.year }
        if !captured.journal.isEmpty { value.journal = captured.journal }
        if !captured.doi.isEmpty { value.doi = captured.doi }
        value.url = captured.url
        if !captured.abstract.isEmpty { value.abstract = captured.abstract }
        value.notes += (value.notes.isEmpty ? "" : "\n\n") + captured.notes
        value.tags = Array(Set(value.tags + captured.tags)).sorted()
        value.collectionIDs = Array(Set(value.collectionIDs + captured.collectionIDs))
        return value
    }
}

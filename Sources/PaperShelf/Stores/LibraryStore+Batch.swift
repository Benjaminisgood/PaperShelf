import AppKit
import PaperCore

extension LibraryStore {
    func importClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "剪贴板没有文本"; return }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("@") || trimmed.hasPrefix("TY  -") {
                _ = importReferences(try Bibliography.parse(trimmed, format: trimmed.hasPrefix("@") ? "bib" : "ris"))
            } else { Task { _ = await importDOI(trimmed) } }
        } catch { self.error = error.localizedDescription }
    }
    func copyReferences(_ format: ExportFormat) {
        let values = selectedReferences.isEmpty ? filtered : selectedReferences
        let text: String
        switch format {
        case .bibtex: text = Bibliography.exportBibTeX(values, options: .init(fields: preferences.bibtexFields.isEmpty ? nil : Set(preferences.bibtexFields), citationKeyTemplate: preferences.citationKeyTemplate))
        case .ris: text = Bibliography.exportRIS(values)
        default: text = Bibliography.exportMarkdown(values)
        }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        status = "已复制 \(values.count) 篇文献的 \(format.rawValue)"
    }
    func refreshSelectedMetadata() {
        let values = selectedReferences
        guard !values.isEmpty, !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            var fetchedByID: [UUID:Reference] = [:]; var failures: [String] = []
            for (index, original) in values.enumerated() {
                let identifier = !original.doi.isEmpty ? original.doi : !original.isbn.isEmpty ? original.isbn : original.extraFields["arxivId"] ?? original.extraFields["arxiv"] ?? ""
                guard !identifier.isEmpty else { failures.append("\(original.title)：没有标识符"); continue }
                status = "更新元数据 \(index + 1) / \(values.count)"
                do {
                    fetchedByID[original.id] = try await MetadataLookup().fetch(identifier)
                } catch { failures.append("\(original.title)：\(error.localizedDescription)") }
            }
            // Fetches suspend. Merge only after all requests finish so a later edit,
            // API attachment, rating change or deletion is not replaced by a stale row.
            var refreshed:[Reference] = []
            for original in values {
                guard let value = fetchedByID[original.id], var updated = references.first(where: { $0.id == original.id }), updated.deletedAt == nil else { continue }
                if updated.authors == original.authors, !value.authors.isEmpty { updated.authors = value.authors }
                for key in [\Reference.title, \.year, \.journal, \.doi, \.url, \.abstract, \.volume, \.issue, \.pages, \.publisher, \.isbn, \.issn] {
                    if updated[keyPath:key] == original[keyPath:key], !value[keyPath:key].isEmpty { updated[keyPath:key] = value[keyPath:key] }
                }
                for (key,newValue) in value.extraFields where updated.extraFields[key] == original.extraFields[key] { updated.extraFields[key] = newValue }
                refreshed.append(updated)
            }
            if !refreshed.isEmpty, !saveBatch(refreshed, action:"批量更新元数据") { return }
            status = "已更新 \(refreshed.count) 篇，\(failures.count) 篇未更新；可用撤销恢复"
            if !failures.isEmpty { error = failures.joined(separator: "\n") }
        }
    }
    func trashLinkedFiles(_ values: [Reference]) {
        guard !values.isEmpty else { return }
        guard organizeTask == nil, fileProgress == nil else { error = "请先完成或取消正在进行的文件任务。"; return }
        let alert = NSAlert(); alert.messageText = "将关联文件移到系统废纸篓？"
        alert.informativeText = "会移除这些文献的主 PDF 和附件文件，并清除其关联。文件可从 Finder 废纸篓恢复；文献记录保留。"
        alert.addButton(withTitle: "移到废纸篓"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var moved: [(URL, URL)] = []; var changed: [Reference] = []
        do {
            let ids = Set(values.map(\.id))
            try ensureFilesAreNotShared(references.filter { ids.contains($0.id) }, allowing: ids)
            for original in values {
                guard var item = references.first(where: { $0.id == original.id }) else { continue }
                var urls: [URL] = []
                if item.pdfPath != nil { urls.append(try PDFLinks.resolvedURL(for: item)) }
                urls += try item.attachments.map { try PaperAttachments.resolvedURL(for: $0) }
                for url in urls where !moved.contains(where: { $0.0.standardizedFileURL == url.standardizedFileURL }) {
                    var destination: NSURL?; try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
                    if let destination { moved.append((url, destination as URL)) }
                }
                item.pdfPath = nil; item.pdfBookmark = nil; item.attachments = []; changed.append(item)
            }
            try requireDatabase().upsertReferences(changed)
        } catch {
            var failures: [String] = []
            for (original, trashed) in moved.reversed() {
                do { try FileManager.default.moveItem(at: trashed, to: original) } catch { failures.append(error.localizedDescription) }
            }
            self.error = error.localizedDescription + (failures.isEmpty ? "" : "\n文件回滚未全部完成：" + failures.joined(separator: "\n"))
            return
        }
        refreshAfterCommit(); status = "关联文件已移到系统废纸篓"
    }
}

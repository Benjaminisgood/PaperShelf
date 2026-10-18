import Foundation
import PaperCore

struct LibraryFileProgress: Equatable {
    var completed: Int
    var total: Int
    var title: String
    var isCancelling = false
}

struct PreparedReferenceFiles: Sendable {
    var reference: Reference
    var placements: [PaperFilePlacement]
}

/// File work runs away from the main actor. A result is provisional until its
/// corresponding database write succeeds; cancellation rolls it back as well.
enum LibraryFilePreparation {
    static func prepare(_ original: Reference, root: URL, options: PaperFileOptions,
                        collectionPaths: [String]) throws -> PreparedReferenceFiles {
        let rootAccess = root.startAccessingSecurityScopedResource()
        defer { if rootAccess { root.stopAccessingSecurityScopedResource() } }
        var value = original
        var placements: [PaperFilePlacement] = []
        do {
            try Task.checkCancellation()
            if value.pdfPath != nil {
                let source = try PDFLinks.resolvedURL(for: value)
                let placement = try PaperFileOrganizer.place(source: source, reference: value, in: root,
                                                            options: options, kind: .primaryPDF, collectionPaths: collectionPaths)
                placements.append(placement)
                try Task.checkCancellation()
                try PDFLinks.attach(placement.destinationURL, to: &value)
            }
            for index in value.attachments.indices {
                try Task.checkCancellation()
                let source = try PaperAttachments.resolvedURL(for: value.attachments[index])
                let placement = try PaperFileOrganizer.place(source: source, reference: value, in: root,
                                                            options: options, kind: .attachment, collectionPaths: collectionPaths)
                placements.append(placement)
                try Task.checkCancellation()
                let linked = try PaperAttachments.link(placement.destinationURL)
                value.attachments[index].path = linked.path
                value.attachments[index].bookmark = linked.bookmark
            }
            try Task.checkCancellation()
            return PreparedReferenceFiles(reference: value, placements: placements)
        } catch { throw rollback(placements, because: error) }
    }

    static func rollback(_ placements: [PaperFilePlacement], because cause: Error) -> Error {
        var failures: [String] = []
        for placement in placements.reversed() {
            do { try placement.rollback() } catch { failures.append(error.localizedDescription) }
        }
        guard !failures.isEmpty else { return cause }
        return LocalAPIError(500, cause.localizedDescription + "\n文件回滚未全部完成，已保留无法安全回滚的文件：\n" + failures.joined(separator: "\n"))
    }
}

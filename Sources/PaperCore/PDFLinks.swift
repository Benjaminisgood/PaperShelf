import Foundation
import PDFKit

public enum PDFLinkError: LocalizedError {
    case unreadable, missing
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取此 PDF，文件可能已加密或损坏。"
        case .missing: return "找不到原始 PDF，请使用“关联 PDF”重新选择文件。"
        }
    }
}

public struct PaperAnnotation: Identifiable, Equatable, Sendable {
    public var id: String
    public var page: Int
    public var kind: String
    public var text: String
    public var comment: String
}

/// Stores a bookmark to the user's original file. Never copies or modifies the PDF.
public enum PDFLinks {
    public static func reference(from url: URL) throws -> Reference {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
        let attributes = document.documentAttributes ?? [:]
        var reference = Reference()
        let title = (attributes[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        reference.title = title.isEmpty ? url.deletingPathExtension().lastPathComponent : title
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty {
            reference.authors = [author]
        }
        try attach(url, to: &reference)
        return reference
    }

    public static func attach(_ url: URL, to reference: inout Reference) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
        reference.pdfBookmark = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        reference.pdfPath = url.standardizedFileURL.path
    }

    public static func resolvedURL(for reference: Reference) throws -> URL {
        if let data = reference.pdfBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                return url
            }
        }
        guard let path = reference.pdfPath else { throw PDFLinkError.missing }
        return URL(fileURLWithPath: path)
    }

    public static func withURL<T>(for reference: Reference, _ action: (URL) throws -> T) throws -> T {
        let url = try resolvedURL(for: reference)
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { throw PDFLinkError.missing }
        return try action(url)
    }

    public static func annotations(for reference: Reference) throws -> [PaperAnnotation] {
        try withURL(for: reference) { url in
            guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
            var result: [PaperAnnotation] = []
            let kinds: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text", "FreeText"]
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for (offset, annotation) in page.annotations.enumerated() {
                    let kind = annotation.type ?? ""
                    guard kinds.contains(kind) else { continue }
                    let selected = ["Highlight", "Underline", "StrikeOut"].contains(kind)
                        ? page.selection(for: annotation.bounds)?.string ?? "" : ""
                    result.append(PaperAnnotation(id: "\(index)-\(offset)", page: index + 1, kind: kind,
                                                  text: selected, comment: annotation.contents ?? ""))
                }
            }
            return result
        }
    }

    public static func markdown(_ annotations: [PaperAnnotation]) -> String {
        annotations.map { item in
            "### 第 \(item.page) 页 · \(item.kind)\n\n\(item.text)\n\n\(item.comment)"
        }.joined(separator: "\n\n")
    }
}

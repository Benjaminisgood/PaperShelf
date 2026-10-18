import Foundation
import CryptoKit

public enum PaperFileAction: String, Codable, Sendable { case link, copy, move }
public enum PaperFileGrouping: String, Codable, Sendable { case none, year, collection, authorInitial }
public enum PaperFileLayout: String, Codable, Sendable { case pdfCentric, paperFolders }
public enum PaperFileKind: String, Sendable { case primaryPDF, attachment }

public struct PaperFileOptions: Codable, Equatable, Sendable {
    public var action: PaperFileAction
    public var grouping: PaperFileGrouping
    public var layout: PaperFileLayout
    public var renameTemplate: String
    public init(action: PaperFileAction = .copy, grouping: PaperFileGrouping = .none,
                layout: PaperFileLayout = .pdfCentric, renameTemplate: String = "") {
        self.action = action; self.grouping = grouping; self.layout = layout; self.renameTemplate = renameTemplate
    }
}

public enum PaperFileError: LocalizedError {
    case invalidSource, unsafeDestination, changedFile, rollbackConflict
    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "附件必须是可读取的本地普通文件。"
        case .unsafeDestination: return "文件目标越过了选定文件库，或包含符号链接。"
        case .changedFile: return "文件已发生变化；为保留现有内容，未自动回滚。"
        case .rollbackConflict: return "原位置已有文件，无法安全回滚移动。整理后的文件仍保留。"
        }
    }
}

public struct PaperFilePlacement: Sendable {
    public var sourceURL: URL
    public var destinationURL: URL
    public var action: PaperFileAction
    public var didCreate: Bool
    fileprivate var digest: String
    fileprivate var libraryRoot: URL

    /// Call if storing the new attachment location fails. Refuses to remove or
    /// replace a file changed since this operation.
    public func rollback() throws {
        guard didCreate else { return }
        let sourceAccess = sourceURL.startAccessingSecurityScopedResource()
        let rootAccess = libraryRoot.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { sourceURL.stopAccessingSecurityScopedResource() }
            if rootAccess { libraryRoot.stopAccessingSecurityScopedResource() }
        }
        guard try PaperFileOrganizer.sha256(destinationURL) == digest else { throw PaperFileError.changedFile }
        if action == .move {
            guard !FileManager.default.fileExists(atPath: sourceURL.path) else { throw PaperFileError.rollbackConflict }
            try FileManager.default.moveItem(at: destinationURL, to: sourceURL)
        } else { try FileManager.default.removeItem(at: destinationURL) }
    }
}

public enum PaperFileOrganizer {
    /// Places one file. Copy is the default; moving requires an explicit .move.
    /// The caller persists the returned path and rolls back on a database error.
    public static func place(source: URL, reference: Reference, in root: URL,
                             options: PaperFileOptions = .init(), kind: PaperFileKind = .primaryPDF,
                             collectionPaths: [String] = []) throws -> PaperFilePlacement {
        let sourceAccess = source.startAccessingSecurityScopedResource()
        let rootAccess = root.startAccessingSecurityScopedResource()
        defer {
            if sourceAccess { source.stopAccessingSecurityScopedResource() }
            if rootAccess { root.stopAccessingSecurityScopedResource() }
        }
        let manager = FileManager.default
        let sourceInfo = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard source.isFileURL, root.isFileURL,
              sourceInfo.isRegularFile == true, sourceInfo.isSymbolicLink != true,
              manager.isReadableFile(atPath: source.path) else { throw PaperFileError.invalidSource }
        let originalDigest = try sha256(source)
        if options.action == .link {
            return PaperFilePlacement(sourceURL: source, destinationURL: source, action: .link,
                                      didCreate: false, digest: originalDigest, libraryRoot: root)
        }
        let canonicalRoot = root.standardizedFileURL
        let group: [String]
        switch options.grouping {
        case .none: group = []
        case .year: group = [reference.year.isEmpty ? "Unsorted" : reference.year]
        case .collection:
            let path = collectionPaths.first ?? reference.collection
            group = path.isEmpty ? ["Unsorted"] : path.components(separatedBy: "/")
        case .authorInitial:
            let author = reference.authors.first ?? ""
            let surname = author.contains(",") ? author.components(separatedBy: ",")[0] : author.split(separator: " ").last.map(String.init) ?? ""
            group = [surname.first.map { String($0).uppercased() } ?? "Unsorted"]
        }
        var directory = canonicalRoot
        if options.layout == .pdfCentric && kind == .attachment { directory.appendPathComponent("Attachments", isDirectory: true) }
        for component in group { directory.appendPathComponent(PaperDetailedExport.safeFilename(component), isDirectory: true) }
        if options.layout == .paperFolders {
            let label = PaperDetailedExport.safeFilename(reference.citationKey.isEmpty ? reference.title : reference.citationKey)
            directory.appendPathComponent(label + "-" + reference.id.uuidString.lowercased(), isDirectory: true)
        }
        try validateDirectory(directory, inside: canonicalRoot)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try validateDirectory(directory, inside: canonicalRoot)
        let base = try filename(source: source, reference: reference, template: kind == .primaryPDF ? options.renameTemplate : "")
        let fileExtension = source.pathExtension
        var number = 1
        while true {
            let label = base + (number == 1 ? "" : "-\(number)")
            let destination = fileExtension.isEmpty ? directory.appendingPathComponent(label) : directory.appendingPathComponent(label).appendingPathExtension(fileExtension)
            if destination.standardizedFileURL == source.standardizedFileURL {
                return PaperFilePlacement(sourceURL: source, destinationURL: source, action: options.action,
                                          didCreate: false, digest: originalDigest, libraryRoot: root)
            }
            do {
                if options.action == .move { try manager.moveItem(at: source, to: destination) }
                else { try manager.copyItem(at: source, to: destination) }
                let placement = PaperFilePlacement(sourceURL: source, destinationURL: destination, action: options.action,
                                                   didCreate: true, digest: originalDigest, libraryRoot: root)
                guard try sha256(destination) == originalDigest else {
                    // Keep the destination on a changed-source race; never delete
                    // the only possibly complete copy to make the operation pass.
                    throw PaperFileError.changedFile
                }
                return placement
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSFileWriteFileExistsError {
                    number += 1
                } else { throw error }
            }
        }
    }

    /// Only metadata substitutions are accepted. Missing values preserve the
    /// source's name; only its on-disk label is sanitized.
    static func filename(source: URL, reference: Reference, template: String) throws -> String {
        guard !template.isEmpty else { return PaperDetailedExport.safeFilename(source.deletingPathExtension().lastPathComponent) }
        var values = PaperTemplateRenderer.values(for: reference)
        let author = reference.authors.first ?? ""
        values["author"] = author.contains(",") ? author.components(separatedBy: ",")[0] : author.split(separator: " ").last.map(String.init) ?? ""
        values["auth"] = values["author"]?.lowercased(); values["Auth"] = values["author"]
        let expression = try NSRegularExpression(pattern: #"(?<!\{)\{([A-Za-z][A-Za-z0-9]*)\}(?!\})"#)
        let normalized = expression.stringByReplacingMatches(in: template, range: NSRange(template.startIndex..., in: template), withTemplate: "{{$1}}")
        let variables = try NSRegularExpression(pattern: #"\{\{([A-Za-z][A-Za-z0-9]*)\}\}"#)
        for match in variables.matches(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)) {
            let name = (normalized as NSString).substring(with: match.range(at: 1))
            guard let value = values[name] else { throw PaperTemplateError.unknownVariable(name) }
            if value.isEmpty { return PaperDetailedExport.safeFilename(source.deletingPathExtension().lastPathComponent) }
        }
        return PaperDetailedExport.safeFilename(try PaperTemplateRenderer.render(normalized, values: values))
    }

    static func validateDirectory(_ directory: URL, inside root: URL) throws {
        let components = directory.standardizedFileURL.pathComponents
        let rootComponents = root.standardizedFileURL.pathComponents
        guard components.starts(with: rootComponents) else { throw PaperFileError.unsafeDestination }
        var cursor = root.standardizedFileURL
        for component in [""] + Array(components.dropFirst(rootComponents.count)) {
            if !component.isEmpty { cursor.appendPathComponent(component) }
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw PaperFileError.unsafeDestination }
        }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum PaperAttachments {
    public static func link(_ url: URL) throws -> ReferenceAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw PaperFileError.invalidSource }
        return ReferenceAttachment(name: url.lastPathComponent, path: url.standardizedFileURL.path,
                                   bookmark: try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
    }

    public static func resolvedURL(for attachment: ReferenceAttachment) throws -> URL {
        if let data = attachment.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) { return url }
        }
        let url = URL(fileURLWithPath: attachment.path)
        guard FileManager.default.fileExists(atPath: url.path) else { throw PaperFileError.invalidSource }
        return url
    }
}

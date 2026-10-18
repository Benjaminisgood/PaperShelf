import Foundation

public enum PaperTemplateError: LocalizedError {
    case malformed(String), unknownVariable(String)
    public var errorDescription: String? {
        switch self {
        case .malformed(let value): return "模板条件块不匹配：\(value)"
        case .unknownVariable(let value): return "模板变量不存在：\(value)"
        }
    }
}

public struct PaperExportTemplates: Codable, Equatable, Sendable {
    public var metadata: String
    public var annotation: String
    public init(metadata: String = Self.defaultMetadata, annotation: String = Self.defaultAnnotation) {
        self.metadata = metadata; self.annotation = annotation
    }
    public static let defaultMetadata = """
    # {{title}}

    {{#authors}}作者：{{authors}}
    {{/authors}}{{#journal}}来源：{{journal}}{{#year}} ({{year}}){{/year}}
    {{/journal}}{{#doi}}DOI：[{{doi}}](https://doi.org/{{doi}})
    {{/doi}}{{#bibtexKey}}引用键：{{bibtexKey}}
    {{/bibtexKey}}[在 PaperShelf 中打开]({{papershelfURL}})
    {{#pdfURL}}[打开 PDF]({{pdfURL}})
    {{/pdfURL}}
    {{#abstract}}## 摘要

    {{abstract}}
    {{/abstract}}{{#notes}}
    ## 备注

    {{notes}}
    {{/notes}}{{#annotations}}
    ## PDF 批注

    {{annotations}}
    {{/annotations}}
    """
    public static let defaultAnnotation = """
    ### 第 {{page}} 页 · {{type}}

    {{#text}}{{text}}
    {{/text}}{{#comment}}
    {{comment}}
    {{/comment}}{{#image}}
    {{image}}
    {{/image}}
    """
}

public enum PaperTemplateRenderer {
    private indirect enum Node { case text(String), variable(String), conditional(String, [Node]) }

    /// Nested conditions are parsed even when their field is empty, so malformed
    /// templates cannot silently omit content from an export.
    public static func render(_ template: String, values: [String: String]) throws -> String {
        let expression = try NSRegularExpression(pattern: #"\{\{([#/]?)([^{}]+)\}\}"#)
        let source = template as NSString
        let matches = expression.matches(in: template, range: NSRange(location: 0, length: source.length))
        var cursor = 0, position = 0
        func parse(until closing: String?) throws -> [Node] {
            var nodes: [Node] = []
            while position < matches.count {
                let match = matches[position]
                if match.range.location > cursor { nodes.append(.text(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))) }
                let marker = source.substring(with: match.range(at: 1))
                let key = source.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
                cursor = match.range.location + match.range.length; position += 1
                if marker == "/" {
                    guard closing == key else { throw PaperTemplateError.malformed(key) }
                    return nodes
                }
                guard values[key] != nil else { throw PaperTemplateError.unknownVariable(key) }
                if marker == "#" { nodes.append(.conditional(key, try parse(until: key))) }
                else { nodes.append(.variable(key)) }
            }
            if let closing { throw PaperTemplateError.malformed(closing) }
            if cursor < source.length { nodes.append(.text(source.substring(from: cursor))) }
            return nodes
        }
        func evaluate(_ nodes: [Node]) -> String {
            nodes.map { node in
                switch node {
                case .text(let text): return text
                case .variable(let key): return values[key] ?? ""
                case .conditional(let key, let children): return (values[key] ?? "").isEmpty ? "" : evaluate(children)
                }
            }.joined()
        }
        return evaluate(try parse(until: nil))
    }

    public static func values(for reference: Reference, collectionPaths: [String] = []) -> [String: String] {
        var values = reference.extraFields
        let link = "papershelf://paper/\(reference.id.uuidString)"
        let standard = ["title":reference.title, "authors":reference.authors.joined(separator: "; "),
                        "year":reference.year, "journal":reference.journal, "doi":reference.doi,
                        "url":reference.url, "abstract":reference.abstract, "volume":reference.volume,
                        "issue":reference.issue, "pages":reference.pages, "publisher":reference.publisher,
                        "isbn":reference.isbn, "issn":reference.issn, "bibtexKey":reference.citationKey,
                        "citationKey":reference.citationKey, "rating":reference.rating == 0 ? "" : String(reference.rating),
                        "paperType":reference.entryType, "notes":reference.notes,
                        "collections":collectionPaths.isEmpty ? reference.collection : collectionPaths.map { $0.components(separatedBy: "/").last ?? $0 }.joined(separator: "; "),
                        "collectionPaths":collectionPaths.isEmpty ? reference.collection : collectionPaths.joined(separator: "; "),
                        "tags":reference.tags.joined(separator: "; "), "annotations":"",
                        "papershelfURL":link, "latticeURL":link, "latticeurl":link,
                        "pdfURL":reference.pdfPath.map { URL(fileURLWithPath: $0).absoluteString } ?? "",
                        "pdfurl":reference.pdfPath.map { URL(fileURLWithPath: $0).absoluteString } ?? ""]
        values.merge(standard) { _, current in current }
        return values
    }

    public static func render(reference: Reference, annotations: [PaperAnnotation], templates: PaperExportTemplates = .init(),
                              collectionPaths: [String] = [], imageLinks: [String: String] = [:]) throws -> String {
        let rendered = try annotations.map { item in
            try render(templates.annotation, values: ["type":item.kind, "page":String(item.page),
                "pageLabel":item.pageLabel, "text":item.text, "comment":item.comment,
                "color":item.colorHex, "opacity":String(item.opacity), "textSource":item.textSource,
                "image":imageLinks[item.id].map { "![第 \(item.page) 页批注](\($0))" } ?? (item.imagePNG == nil ? "" : "[第 \(item.page) 页区域图片]")])
        }.joined(separator: "\n\n")
        var values = values(for: reference, collectionPaths: collectionPaths)
        values["annotations"] = rendered
        return try render(templates.metadata, values: values)
    }
}

public enum PaperDetailedExport {
    /// Writes one independent artifact without replacing an existing file. All
    /// image assets and metadata are staged before publishing the TextBundle.
    public static func export(reference: Reference, annotations: [PaperAnnotation], to directory: URL,
                              templates: PaperExportTemplates = .init(), collectionPaths: [String] = []) throws -> URL {
        let access = directory.startAccessingSecurityScopedResource()
        defer { if access { directory.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let hasImages = annotations.contains { $0.imagePNG != nil }
        let name = safeFilename(reference.citationKey.isEmpty ? reference.title : reference.citationKey)
        let extensionName = hasImages ? "textbundle" : "md"
        let temporary = directory.appendingPathComponent(".papershelf-export-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: temporary) }
        var imageLinks: [String: String] = [:]
        if hasImages {
            let assets = temporary.appendingPathComponent("assets", isDirectory: true)
            try manager.createDirectory(at: assets, withIntermediateDirectories: true)
            for (index, annotation) in annotations.enumerated() {
                guard let data = annotation.imagePNG else { continue }
                let filename = "annotation-\(index + 1).png"
                try data.write(to: assets.appendingPathComponent(filename), options: .withoutOverwriting)
                imageLinks[annotation.id] = "assets/\(filename)"
            }
        }
        let text = try PaperTemplateRenderer.render(reference: reference, annotations: annotations,
                                                   templates: templates, collectionPaths: collectionPaths, imageLinks: imageLinks)
        if hasImages {
            try Data(text.utf8).write(to: temporary.appendingPathComponent("text.md"), options: .withoutOverwriting)
            let info: [String: Any] = ["version":2, "type":"net.daringfireball.markdown", "transient":false,
                                       "creatorIdentifier":"local.papershelf.library"]
            try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]).write(to: temporary.appendingPathComponent("info.json"), options: .withoutOverwriting)
        } else { try Data(text.utf8).write(to: temporary, options: .withoutOverwriting) }
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let target = directory.appendingPathComponent(name + suffix).appendingPathExtension(extensionName)
            do { try manager.moveItem(at: temporary, to: target); return target }
            catch {
                guard manager.fileExists(atPath: target.path) else { throw error }
                number += 1
            }
        }
    }

    public static func safeFilename(_ value: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        let cleaned = value.components(separatedBy: forbidden).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        // File names have filesystem limits; this affects only the label, never
        // the bibliographic data or exported text.
        var name = ""
        for character in cleaned {
            if (name + String(character)).utf8.count > 180 { break }
            name.append(character)
        }
        return name.isEmpty || name == "." || name == ".." ? "Untitled" : name
    }
}

import Foundation
import PDFKit
import AppKit
import Vision

public enum PDFLinkError: LocalizedError {
    case unreadable, missing, rendering
    public var errorDescription: String? {
        switch self {
        case .unreadable: return "无法读取此 PDF，文件可能已加密或损坏。"
        case .missing: return "找不到原始 PDF，请使用“关联 PDF”重新选择文件。"
        case .rendering: return "无法渲染 PDF 页面或批注区域。"
        }
    }
}

public struct PaperAnnotation: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var page: Int
    public var kind: String
    public var text: String
    public var comment: String
    public var pageLabel: String
    public var bounds: CGRect
    /// PDF page-space points, with each quad in PDFKit's Z order.
    public var quadrilaterals: [[CGPoint]]
    public var colorHex: String
    public var opacity: Double
    public var imagePNG: Data?
    /// pdf-quads, pdf-bounds, ocr, or none. OCR is never presented as embedded text.
    public var textSource: String

    public init(id: String, page: Int, kind: String, text: String, comment: String,
                pageLabel: String = "", bounds: CGRect = .zero, quadrilaterals: [[CGPoint]] = [],
                colorHex: String = "", opacity: Double = 1, imagePNG: Data? = nil, textSource: String = "none") {
        self.id = id; self.page = page; self.kind = kind; self.text = text; self.comment = comment
        self.pageLabel = pageLabel; self.bounds = bounds; self.quadrilaterals = quadrilaterals
        self.colorHex = colorHex; self.opacity = opacity; self.imagePNG = imagePNG; self.textSource = textSource
    }
}

public struct PDFAnnotationOptions: Sendable {
    public var includeRegionImages: Bool
    public var ocrIfNeeded: Bool
    public var imageScale: Double
    public init(includeRegionImages: Bool = true, ocrIfNeeded: Bool = false, imageScale: Double = 2) {
        self.includeRegionImages = includeRegionImages; self.ocrIfNeeded = ocrIfNeeded; self.imageScale = imageScale
    }
}

public struct PDFPageText: Equatable, Sendable {
    public var page: Int
    public var pageLabel: String
    public var text: String
    public var source: String
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
        let metadataText = attributes.map { "\(String(describing: $0.key)): \($0.value)" }.joined(separator: "\n")
        let fullText = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        let identifiers = PDFMetadataIdentifiers.extract(metadata: metadataText, text: fullText)
        reference.doi = identifiers.doi ?? ""
        reference.isbn = identifiers.isbn ?? ""
        if let arxiv = identifiers.arxivID { reference.extraFields["arxivId"] = arxiv }
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

    public static func annotations(for reference: Reference, options: PDFAnnotationOptions = .init()) throws -> [PaperAnnotation] {
        try withURL(for: reference) { url in
            guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
            var result: [PaperAnnotation] = []
            let kinds: Set<String> = ["Highlight", "Underline", "StrikeOut", "Text", "FreeText", "Square", "Circle"]
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { continue }
                for (offset, annotation) in page.annotations.enumerated() {
                    let kind = annotation.type ?? ""
                    guard kinds.contains(kind) else { continue }
                    let isMarkup = ["Highlight", "Underline", "StrikeOut"].contains(kind)
                    let isShape = ["Square", "Circle"].contains(kind)
                    let points = (annotation.quadrilateralPoints ?? []).map {
                        CGPoint(x: $0.pointValue.x + annotation.bounds.minX, y: $0.pointValue.y + annotation.bounds.minY)
                    }
                    let quads = stride(from: 0, to: points.count - points.count % 4, by: 4).map { Array(points[$0..<$0+4]) }
                    var selected = ""
                    var source = "none"
                    if isMarkup || isShape {
                        selected = isMarkup && !quads.isEmpty ? selectedText(on: page, quads: quads) : page.selection(for: annotation.bounds)?.string ?? ""
                        if !selected.isEmpty { source = quads.isEmpty ? "pdf-bounds" : "pdf-quads" }
                    }
                    var image: CGImage?
                    if isShape && options.includeRegionImages {
                        image = try render(page: page, region: annotation.bounds, scale: options.imageScale)
                    }
                    if options.ocrIfNeeded && (isMarkup || isShape) && selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isMarkup && !quads.isEmpty {
                            selected = try quads.map { quad in
                                let xs = quad.map(\.x), ys = quad.map(\.y)
                                let region = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                                return try recognizeText(in: render(page: page, region: region, scale: options.imageScale, quad: quad))
                            }.filter { !$0.isEmpty }.joined(separator: "\n")
                        } else {
                            let ocrImage = try image ?? render(page: page, region: annotation.bounds, scale: options.imageScale)
                            selected = try recognizeText(in: ocrImage)
                        }
                        if !selected.isEmpty { source = "ocr" }
                    }
                    // A FreeText annotation without /C can have an empty color
                    // that cannot convert to sRGB. NSColor.black is gray, and
                    // reading its RGB components raises an Objective-C exception.
                    // Use an explicit RGB fallback and keep the original opacity.
                    let originalColor = annotation.color
                    let color = originalColor.usingColorSpace(.sRGB)
                        ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: originalColor.alphaComponent)
                    let hex = String(format: "#%02X%02X%02X", Int((color.redComponent * 255).rounded()), Int((color.greenComponent * 255).rounded()), Int((color.blueComponent * 255).rounded()))
                    let png = isShape && options.includeRegionImages ? image.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) } : nil
                    result.append(PaperAnnotation(id: "\(index)-\(offset)", page: index + 1, kind: kind,
                                                  text: selected, comment: annotation.contents ?? "",
                                                  pageLabel: page.label ?? String(index + 1), bounds: annotation.bounds,
                                                  quadrilaterals: quads, colorHex: hex, opacity: Double(color.alphaComponent),
                                                  imagePNG: png, textSource: source))
                }
            }
            return result
        }
    }

    /// Uses every character's geometry within the actual quads. The union's
    /// bounding rectangle can include unrelated columns or intermediate lines.
    static func selectedText(on page: PDFPage, quads: [[CGPoint]]) -> String {
        let pageText = (page.string ?? "") as NSString
        var used = Set<Int>()
        var lines: [String] = []
        for quad in quads where quad.count == 4 {
            let path = CGMutablePath()
            path.move(to: quad[0]); path.addLine(to: quad[1]); path.addLine(to: quad[3]); path.addLine(to: quad[2]); path.closeSubpath()
            var indices: [Int] = []
            for index in 0..<pageText.length where !used.contains(index) {
                // PDFKit's characterBounds indexes omit inferred line breaks on
                // some PDFs, while NSRange indexes include them. Use the same
                // text-range coordinate system for both selection and geometry.
                guard !pageText.substring(with: NSRange(location: index, length: 1)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let selection = page.selection(for: NSRange(location: index, length: 1)) else { continue }
                let rect = selection.bounds(for: page)
                if !rect.isEmpty && path.contains(CGPoint(x: rect.midX, y: rect.midY)) { indices.append(index) }
            }
            guard let first = indices.first, let last = indices.last else { continue }
            // Preserve spaces between selected glyphs, but never include text
            // outside a quadrilateral simply because it lies between indices.
            let selected = Set(indices)
            var ranges: [NSRange] = []
            for index in first...last {
                let character = pageText.substring(with: NSRange(location: index, length: 1))
                guard selected.contains(index) || character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                if let previous = ranges.last, previous.location + previous.length == index {
                    ranges[ranges.count - 1].length += 1
                } else { ranges.append(NSRange(location: index, length: 1)) }
            }
            let value = ranges.compactMap { page.selection(for: $0)?.string }.joined(separator: " ")
            used.formUnion(indices)
            if !value.isEmpty { lines.append(value) }
        }
        return lines.joined(separator: "\n")
    }

    public static func extractedText(for reference: Reference, ocrIfNeeded: Bool = true) throws -> [PDFPageText] {
        try withURL(for: reference) { url in
            guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
            return try (0..<document.pageCount).map { index in
                guard let page = document.page(at: index) else { throw PDFLinkError.unreadable }
                var text = page.string ?? ""
                var source = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "none" : "pdf-text"
                if source == "none" && ocrIfNeeded {
                    text = try recognizeText(in: render(page: page, region: page.bounds(for: .cropBox), scale: 3))
                    if !text.isEmpty { source = "ocr" }
                }
                return PDFPageText(page: index + 1, pageLabel: page.label ?? String(index + 1), text: text, source: source)
            }
        }
    }

    static func render(page: PDFPage, region: CGRect, scale: Double, quad: [CGPoint]? = nil) throws -> CGImage {
        let area = region.standardized.intersection(page.bounds(for: .cropBox))
        guard !area.isEmpty, !area.isNull, scale.isFinite, scale > 0,
              let pageRef = page.pageRef else { throw PDFLinkError.rendering }
        let width = area.width * scale, height = area.height * scale
        guard width.isFinite, height.isFinite, width < Double(Int.max), height < Double(Int.max),
              let context = CGContext(data: nil, width: Int(ceil(width)), height: Int(ceil(height)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw PDFLinkError.rendering }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: ceil(width), height: ceil(height)))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -area.minX, y: -area.minY)
        if let quad, quad.count == 4 {
            context.move(to: quad[0]); context.addLine(to: quad[1]); context.addLine(to: quad[3]); context.addLine(to: quad[2])
            context.closePath(); context.clip()
        }
        context.drawPDFPage(pageRef)
        guard let image = context.makeImage() else { throw PDFLinkError.rendering }
        return image
    }

    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    public static func markdown(_ annotations: [PaperAnnotation]) -> String {
        annotations.map { item in
            "### 第 \(item.page) 页 · \(item.kind)\n\n\(item.text)\n\n\(item.comment)"
        }.joined(separator: "\n\n")
    }
}

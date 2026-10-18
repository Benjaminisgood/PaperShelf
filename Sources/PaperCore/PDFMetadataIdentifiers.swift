import Foundation

public struct PDFIdentifiers: Equatable, Sendable {
    public var doi: String?
    public var isbn: String?
    public var arxivID: String?
}

public enum PDFMetadataIdentifiers {
    /// Uses complete metadata and page text, never a page or character cap. A
    /// unique metadata candidate wins; ambiguous full-text matches stay unset
    /// so a bibliography's identifiers are not guessed as this paper's identity.
    public static func extract(metadata: String, text: String) -> PDFIdentifiers {
        func matches(_ pattern: String, in value: String) -> [String] {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let source = value as NSString
            return expression.matches(in: value, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range(at: 1)) }
        }
        func only(_ values: [String]) -> String? {
            let unique = Set(values)
            return unique.count == 1 ? unique.first : nil
        }
        func doiCandidates(_ source: String) -> [String] {
            matches(#"\b(10\.\d{4,9}/[^\s<>\"\[\]]+)"#, in: source).compactMap { value in
                var cleaned = value.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                while cleaned.last == ")" && cleaned.filter({ $0 == ")" }).count > cleaned.filter({ $0 == "(" }).count { cleaned.removeLast() }
                return try? DOIClient.normalize(cleaned)
            }
        }
        func isbnCandidates(_ source: String) -> [String] {
            matches(#"\bISBN(?:-1[03])?\s*[:：]?\s*([0-9][0-9Xx\- ]{8,24}[0-9Xx])"#, in: source)
                .compactMap { value in
                    let normalized = value.filter { $0.isNumber || $0 == "X" || $0 == "x" }.uppercased()
                    return validISBN(normalized) ? normalized : nil
                }
        }
        func arxivCandidates(_ source: String) -> [String] {
            matches(#"(?:arXiv\s*:\s*|arxiv\.org/(?:abs|pdf)/)(\d{4}\.\d{4,5}(?:v\d+)?|[a-z][a-z.\-]+/\d{7}(?:v\d+)?)"#, in: source)
                .map { $0.lowercased() }
        }
        return PDFIdentifiers(doi: only(doiCandidates(metadata)) ?? only(doiCandidates(text)),
                              isbn: only(isbnCandidates(metadata)) ?? only(isbnCandidates(text)),
                              arxivID: only(arxivCandidates(metadata)) ?? only(arxivCandidates(text)))
    }

    public static func validISBN(_ value: String) -> Bool {
        let chars = Array(value)
        if chars.count == 13, chars.allSatisfy({ $0.isASCII && $0.isNumber }) {
            let digits = chars.compactMap { $0.wholeNumberValue }
            return digits.enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 1 : 3) } % 10 == 0
        }
        if chars.count == 10 {
            var sum = 0
            for (index, character) in chars.enumerated() {
                if character == "X" && index == 9 { sum += 10 }
                else if character.isASCII, let value = character.wholeNumberValue { sum += (10 - index) * value }
                else { return false }
            }
            return sum % 11 == 0
        }
        return false
    }
}

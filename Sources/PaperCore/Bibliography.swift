import Foundation

public enum BibliographyError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case malformed(String)
    case unsupportedMacro(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let format): return "不支持的文献格式：\(format)。请选择 BibTeX 或 RIS。"
        case .malformed(let detail): return "文献文件格式有误：\(detail)"
        case .unsupportedMacro(let name): return "BibTeX 使用了未定义的字符串宏：\(name)。请先展开该宏。"
        }
    }
}

public struct BibTeXExportOptions: Equatable, Sendable {
    /// BibTeX field names; nil includes every available field.
    public var fields: Set<String>?
    public var citationKeyTemplate: String
    public var preserveCitationKeys: Bool
    public init(fields: Set<String>? = nil, citationKeyTemplate: String = "{author}{year}{title}", preserveCitationKeys: Bool = true) {
        self.fields = fields; self.citationKeyTemplate = citationKeyTemplate; self.preserveCitationKeys = preserveCitationKeys
    }
}

public enum Bibliography {
    /// Imports common bibliographic fields. This is not a TeX renderer or a complete BibLaTeX implementation.
    public static func parse(_ text: String, format: String) throws -> [Reference] {
        let format = format.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        switch format {
        case "bib", "bibtex":
            var parser = BibParser(text)
            return try parser.parse()
        case "ris": return try parseRIS(text)
        default: throw BibliographyError.unsupportedFormat(format)
        }
    }

    public static func exportBibTeX(_ references: [Reference], options: BibTeXExportOptions = .init()) -> String {
        let keyed = generateCitationKeys(references, template: options.citationKeyTemplate, preserveExisting: options.preserveCitationKeys)
        return keyed.map { reference in
            let key = reference.citationKey
            var fields: [(String, String)] = [("title", reference.title)]
            if !reference.authors.isEmpty {
                fields.append(("author", reference.authors.map { author in
                    let escaped = escape(author)
                    // Personal names must remain parseable by BibTeX citation styles.
                    // Group names containing a separator so they remain one author.
                    return author.range(of: #"(?i)(^|\s)and(\s|$)"#, options: .regularExpression) == nil
                        ? escaped : "{" + escaped + "}"
                }.joined(separator: " and ")))
            }
            for (name, value) in [("year", reference.year), ("journal", reference.journal),
                                  ("doi", reference.doi), ("url", reference.url),
                                  ("abstract", reference.abstract), ("note", reference.notes),
                                  ("volume", reference.volume), ("number", reference.issue), ("pages", reference.pages),
                                  ("publisher", reference.publisher), ("isbn", reference.isbn), ("issn", reference.issn),
                                  ("keywords", reference.tags.joined(separator: "; ")),
                                  ("papershelf_collection", reference.collection)] where !value.isEmpty {
                fields.append((name, value))
            }
            // Preserve tag boundaries even when a tag itself contains a comma or semicolon.
            if !reference.tags.isEmpty, let data = try? JSONEncoder().encode(reference.tags),
               let json = String(data: data, encoding: .utf8) {
                fields.append(("papershelf_tags", json))
            }
            let known = Set(fields.map(\.0))
            for (name, value) in reference.extraFields.sorted(by: { $0.key < $1.key })
                where !known.contains(name.lowercased()) && name.range(of: "^[a-zA-Z][a-zA-Z0-9_:-]*$", options: .regularExpression) != nil {
                fields.append((name, value))
            }
            if let selected = options.fields { fields = fields.filter { selected.contains($0.0) } }
            let kind = reference.entryType.range(of: "^[a-zA-Z][a-zA-Z0-9_-]*$", options: .regularExpression) != nil ? reference.entryType : "misc"
            return "@\(kind){\(key),\n" + fields.map { name, value in
                "  \(name) = {\(name == "author" ? value : escape(value))}"
            }.joined(separator: ",\n") + "\n}"
        }.joined(separator: "\n\n") + (references.isEmpty ? "" : "\n")
    }

    /// {author}/{Auth} preserve the first surname's case; {auth} lowercases it.
    /// {shortyear} uses the final two digits of the year; {title} uses three words,
    /// and {title-N} uses the first N words. Duplicate keys receive a, b, … suffixes.
    public static func generateCitationKeys(_ references: [Reference], template: String = "{author}{year}{title}", preserveExisting: Bool = false, reservedKeys: Set<String> = []) -> [Reference] {
        var used = Set(reservedKeys.map { $0.lowercased() })
        return references.map { item in
            var reference = item
            let author = (item.authors.first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let surname = author.isEmpty ? "Anon" : (author.contains(",")
                ? String(author.split(separator: ",", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                : String(author.split(whereSeparator: { $0.isWhitespace }).last ?? Substring(author)))
            let titleWords = item.title.split(whereSeparator: { $0.isWhitespace })
            // Reference.year may also contain an ISO date imported from BibLaTeX.
            let yearDigits = item.year.split(whereSeparator: { !$0.isNumber }).first.map(String.init) ?? ""
            var generated = template
                .replacingOccurrences(of: "{author}", with: surname)
                .replacingOccurrences(of: "{auth}", with: surname.lowercased())
                .replacingOccurrences(of: "{Auth}", with: surname)
                .replacingOccurrences(of: "{year}", with: item.year)
                .replacingOccurrences(of: "{shortyear}", with: String(yearDigits.suffix(2)))
                .replacingOccurrences(of: "{title}", with: titleWords.prefix(3).joined())
                .replacingOccurrences(of: "{id}", with: item.id.uuidString.replacingOccurrences(of: "-", with: ""))
            let titlePattern = try! NSRegularExpression(pattern: #"\{title-([0-9]+)\}"#)
            for match in titlePattern.matches(in: generated, range: NSRange(generated.startIndex..., in: generated)).reversed() {
                guard let range = Range(match.range, in: generated), let numberRange = Range(match.range(at: 1), in: generated) else { continue }
                // A count larger than Int.max still means all available words.
                let count = Int(generated[numberRange]) ?? titleWords.count
                generated.replaceSubrange(range, with: titleWords.prefix(count).joined())
            }
            var base = preserveExisting && !item.citationKey.isEmpty ? item.citationKey : generated
            base = base.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .filter { $0.isLetter || $0.isNumber || "_:-.+/".contains($0) }
            if base.isEmpty { base = "ref" + item.id.uuidString.replacingOccurrences(of: "-", with: "") }
            var key = base; var suffix = 0
            while used.contains(key.lowercased()) {
                var number = suffix; var letters = ""
                repeat { letters = String(UnicodeScalar(97 + number % 26)!) + letters; number = number / 26 - 1 } while number >= 0
                key = base + letters; suffix += 1
            }
            used.insert(key.lowercased()); reference.citationKey = key
            return reference
        }
    }

    public static func exportRIS(_ references: [Reference]) -> String {
        references.map { reference in
            let types = ["article": "JOUR", "book": "BOOK", "inbook": "CHAP", "incollection": "CHAP", "inproceedings": "CPAPER", "proceedings": "CONF", "phdthesis": "THES", "mastersthesis": "THES", "techreport": "RPRT", "misc": "GEN"]
            var fields: [(String, String)] = [("TY", types[reference.entryType.lowercased()] ?? "GEN"), ("TI", reference.title)]
            fields += reference.authors.map { ("AU", $0) }
            fields += [("PY", reference.year), ("JO", reference.journal), ("DO", reference.doi), ("UR", reference.url),
                       ("AB", reference.abstract), ("N1", reference.notes), ("VL", reference.volume), ("IS", reference.issue),
                       ("SP", reference.pages), ("PB", reference.publisher), ("SN", reference.isbn.isEmpty ? reference.issn : reference.isbn), ("ID", reference.citationKey)]
            fields += reference.tags.map { ("KW", $0) }
            // Standard RIS has no arbitrary-field namespace. A custom tag preserves exact extended metadata.
            let supplemental = ["entryType": reference.entryType, "isbn": reference.isbn, "issn": reference.issn,
                                "collection": reference.collection, "extraFields": jsonString(reference.extraFields)]
            fields.append(("C1", "PaperShelf:" + jsonString(supplemental)))
            let lines = fields.filter { !$0.1.isEmpty }.map { tag, value in
                tag + "  - " + value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\n", with: "\n      ")
            }
            return (lines + ["ER  -"]).joined(separator: "\n")
        }.joined(separator: "\n\n") + (references.isEmpty ? "" : "\n")
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    public static func exportMarkdown(_ references: [Reference]) -> String {
        references.map { reference in
            var lines = ["## " + markdown(reference.title.isEmpty ? "Untitled" : reference.title)]
            let citation = [reference.authors.joined(separator: "; "), reference.year, reference.journal]
                .filter { !$0.isEmpty }.map(markdown).joined(separator: " · ")
            if !citation.isEmpty { lines.append(citation) }
            if !reference.doi.isEmpty { lines.append("DOI: " + markdown(reference.doi)) }
            if !reference.url.isEmpty { lines.append("URL: " + markdown(reference.url)) }
            if !reference.tags.isEmpty { lines.append("Tags: " + reference.tags.map(markdown).joined(separator: ", ")) }
            if !reference.abstract.isEmpty { lines.append(markdown(reference.abstract)) }
            if !reference.notes.isEmpty { lines.append("### Notes\n\n" + markdown(reference.notes)) }
            return lines.joined(separator: "\n\n")
        }.joined(separator: "\n\n---\n\n") + (references.isEmpty ? "" : "\n")
    }

    private static func escape(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if character == "\\" { result += "\\textbackslash{}" }
            else if "{}%&#_$".contains(character) { result += "\\" + String(character) }
            else { result.append(character) }
        }
    }

    private static func markdown(_ value: String) -> String {
        value.reduce(into: "") { result, character in
            if "\\`*_{}[]<>#!|".contains(character) { result += "\\" }
            result.append(character)
        }
    }

    fileprivate static func decode(_ raw: String) -> String {
        let chars = Array(raw)
        var result = ""
        var index = 0
        let backslash = Array("\\textbackslash{}")
        while index < chars.count {
            if chars[index...].starts(with: backslash) {
                result += "\\"
                index += backslash.count
            } else if chars[index] == "\\", index + 1 < chars.count,
                      "{}%&#_$".contains(chars[index + 1]) {
                result.append(chars[index + 1])
                index += 2
            } else {
                result.append(chars[index])
                index += 1
            }
        }
        return result
    }

    fileprivate static func reference(_ fields: [String: String], key: String, kind: String) -> Reference {
        func value(_ names: String...) -> String {
            for name in names { if let raw = fields[name], !raw.isEmpty { return decode(raw) } }
            return ""
        }
        let rawAuthors = fields["author"] ?? fields["editor"] ?? ""
        var tags = value("keywords").components(separatedBy: CharacterSet(charactersIn: ";,"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let data = value("papershelf_tags").data(using: .utf8),
           let savedTags = try? JSONDecoder().decode([String].self, from: data) { tags = savedTags }
        let known: Set<String> = ["title", "author", "year", "journal", "doi", "url", "abstract", "note", "keywords", "papershelf_tags", "papershelf_collection", "volume", "number", "pages", "publisher", "isbn", "issn"]
        return Reference(title: value("title"), authors: splitAuthors(rawAuthors), year: value("year", "date"),
                         journal: value("journal", "journaltitle", "booktitle"), doi: value("doi"), url: value("url"),
                         abstract: value("abstract"), notes: value("note", "annote"), tags: tags,
                         collection: value("papershelf_collection"), citationKey: key, entryType: kind,
                         volume: value("volume"), issue: value("number", "issue"), pages: value("pages"),
                         publisher: value("publisher"), isbn: value("isbn"), issn: value("issn"),
                         extraFields: fields.filter { !known.contains($0.key) }.mapValues(decode))
    }

    private static func splitAuthors(_ value: String) -> [String] {
        let chars = Array(value)
        var pieces: [String] = []
        var current = ""
        var depth = 0
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character == "\\", index + 1 < chars.count {
                current.append(character); current.append(chars[index + 1]); index += 2; continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1 }
            if depth == 0, index + 3 <= chars.count, String(chars[index..<index + 3]).lowercased() == "and",
               (index == 0 || chars[index - 1].isWhitespace),
               (index + 3 == chars.count || chars[index + 3].isWhitespace) {
                pieces.append(current); current = ""; index += 3; continue
            }
            current.append(character); index += 1
        }
        pieces.append(current)
        return pieces.compactMap { piece in
            var text = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            if isWrappedGroup(text) { text.removeFirst(); text.removeLast() }
            return text.isEmpty ? nil : decode(text)
        }
    }

    private static func isWrappedGroup(_ text: String) -> Bool {
        let chars = Array(text)
        guard chars.first == "{", chars.last == "}" else { return false }
        var depth = 0
        var index = 0
        while index < chars.count {
            if chars[index] == "\\", index + 1 < chars.count { index += 2; continue }
            if chars[index] == "{" { depth += 1 }
            if chars[index] == "}" { depth -= 1 }
            if depth == 0 && index != chars.count - 1 { return false }
            index += 1
        }
        return depth == 0
    }

    private static func parseRIS(_ text: String) throws -> [Reference] {
        var records: [Reference] = []
        var fields: [String: [String]]?
        var previousTag: String?
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for (offset, rawLine) in normalized.components(separatedBy: "\n").enumerated() {
            let line = offset == 0 ? rawLine.replacingOccurrences(of: "\u{FEFF}", with: "") : rawLine
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let chars = Array(line)
            let isTag = chars.count >= 5 && chars[0].isASCII && chars[1].isASCII
                && chars[2] == " " && chars[3] == " " && chars[4] == "-"
            if !isTag {
                guard fields != nil, let tag = previousTag, line.first?.isWhitespace == true,
                      let last = fields?[tag]?.indices.last else {
                    throw BibliographyError.malformed("RIS 第 \(offset + 1) 行不是有效标签或续行。")
                }
                fields?[tag]?[last] += "\n" + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            let tag = String(chars.prefix(2)).uppercased()
            let value = String(chars.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if tag == "TY" {
                guard fields == nil, !value.isEmpty else {
                    throw BibliographyError.malformed("RIS 第 \(offset + 1) 行重复 TY 或缺少文献类型。")
                }
                fields = ["TY": [value]]; previousTag = "TY"
            } else if tag == "ER" {
                guard let record = fields else { throw BibliographyError.malformed("RIS ER 前缺少 TY。") }
                func first(_ tags: String...) -> String {
                    for tag in tags { if let value = record[tag]?.first, !value.isEmpty { return value } }
                    return ""
                }
                let date = first("PY", "Y1", "DA")
                let typeMap = ["JOUR": "article", "BOOK": "book", "CHAP": "incollection", "CPAPER": "inproceedings", "CONF": "proceedings", "THES": "phdthesis", "RPRT": "techreport"]
                var extra: [String: String] = [:]
                var supplemental: [String: String] = [:]
                if let data = record["C1"]?.first(where: { $0.hasPrefix("PaperShelf:") })?.dropFirst("PaperShelf:".count).data(using: .utf8) {
                    supplemental = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
                    if let data = supplemental["extraFields"]?.data(using: .utf8) { extra = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:] }
                }
                let page = first("SP") + (first("EP").isEmpty ? "" : "--" + first("EP"))
                records.append(Reference(title: first("TI", "T1", "CT"), authors: record["AU"] ?? record["A1"] ?? [],
                                         year: String(date.prefix(4)), journal: first("JO", "JF", "JA", "T2"),
                                         doi: first("DO"), url: first("UR"), abstract: (record["AB"] ?? []).joined(separator: "\n"),
                                         notes: (record["N1"] ?? []).joined(separator: "\n"), tags: record["KW"] ?? [],
                                         collection: supplemental["collection"] ?? "", citationKey: first("ID"),
                                         entryType: supplemental["entryType"] ?? typeMap[first("TY")] ?? "misc",
                                         volume: first("VL"), issue: first("IS"), pages: page, publisher: first("PB"),
                                         isbn: supplemental["isbn"] ?? (first("TY") == "BOOK" ? first("SN") : ""),
                                         issn: supplemental["issn"] ?? (first("TY") == "BOOK" ? "" : first("SN")), extraFields: extra))
                fields = nil; previousTag = nil
            } else {
                guard fields != nil else { throw BibliographyError.malformed("RIS 第 \(offset + 1) 行在 TY 之前。") }
                fields?[tag, default: []].append(value); previousTag = tag
            }
        }
        guard fields == nil else { throw BibliographyError.malformed("RIS 文献缺少结束标记 ER。") }
        guard !records.isEmpty else { throw BibliographyError.malformed("没有找到可导入的 RIS 文献。") }
        return records
    }
}

private struct BibParser {
    let chars: [Character]
    var index = 0
    var macros: [String: String] = ["jan": "January", "feb": "February", "mar": "March", "apr": "April",
                                  "may": "May", "jun": "June", "jul": "July", "aug": "August",
                                  "sep": "September", "oct": "October", "nov": "November", "dec": "December"]

    init(_ text: String) { chars = Array(text.replacingOccurrences(of: "\u{FEFF}", with: "")) }
    var current: Character? { index < chars.count ? chars[index] : nil }

    mutating func parse() throws -> [Reference] {
        var references: [Reference] = []
        skipSpace()
        while current != nil {
            try expect("@")
            let kind = identifier().lowercased()
            skipSpace()
            guard let opener = current, opener == "{" || opener == "(" else { throw failure("条目缺少起始括号。") }
            index += 1
            let close: Character = opener == "{" ? "}" : ")"
            if kind == "comment" {
                try skipComment(opener: opener, close: close)
            } else if kind == "preamble" {
                _ = try value(close: close); skipSpace(); if current == "," { index += 1 }
                skipSpace(); try expect(close)
            } else if kind == "string" {
                skipSpace(); let name = identifier().lowercased(); skipSpace()
                guard !name.isEmpty else { throw failure("字符串宏缺少名称。") }
                try expect("="); let content = try value(close: close); skipSpace()
                if current == "," { index += 1 }; skipSpace(); try expect(close); macros[name] = content
            } else {
                guard !kind.isEmpty else { throw failure("条目缺少类型。") }
                skipSpace()
                let start = index
                while let character = current, character != ",", character != close { index += 1 }
                let key = String(chars[start..<index]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || "{}()=".contains($0) }) else {
                    throw failure("引用键为空或无效。")
                }
                var fields: [String: String] = [:]
                if current == "," { index += 1 }
                skipSpace()
                while let character = current, character != close {
                    let name = identifier().lowercased(); skipSpace()
                    guard !name.isEmpty else { throw failure("字段缺少名称。") }
                    try expect("="); fields[name] = try value(close: close); skipSpace()
                    if current == "," { index += 1; skipSpace() }
                    else if current != close { throw failure("字段之间缺少逗号。") }
                }
                try expect(close)
                references.append(Bibliography.reference(fields, key: key, kind: kind))
            }
            skipSpace()
        }
        guard !references.isEmpty else { throw failure("没有找到可导入的 BibTeX 文献。") }
        return references
    }

    mutating func value(close: Character) throws -> String {
        var result = ""
        while true {
            skipSpace()
            guard let character = current else { throw failure("字段值被截断。") }
            if character == "{" { result += try braced() }
            else if character == "\"" { result += try quoted() }
            else {
                let start = index
                while let c = current, !c.isWhitespace, c != ",", c != close, c != "#" { index += 1 }
                let token = String(chars[start..<index])
                guard !token.isEmpty else { throw failure("字段值为空。") }
                if token.allSatisfy({ $0.isNumber }) { result += token }
                else if let macro = macros[token.lowercased()] { result += macro }
                else { throw BibliographyError.unsupportedMacro(token) }
            }
            skipSpace()
            if current == "#" { index += 1 } else { break }
        }
        return result
    }

    mutating func braced() throws -> String {
        try expect("{")
        var result = ""
        var depth = 1
        while let character = current {
            index += 1
            if character == "\\" {
                result.append(character)
                guard let next = current else { throw failure("转义字符被截断。") }
                result.append(next); index += 1; continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1; if depth == 0 { return result } }
            result.append(character)
        }
        throw failure("花括号未闭合。")
    }

    mutating func quoted() throws -> String {
        try expect("\"")
        var result = ""
        var depth = 0
        while let character = current {
            index += 1
            if character == "\\" {
                result.append(character)
                guard let next = current else { throw failure("转义字符被截断。") }
                result.append(next); index += 1; continue
            }
            if character == "{" { depth += 1 }
            if character == "}" { depth -= 1; if depth < 0 { throw failure("引号内花括号不匹配。") } }
            if character == "\"", depth == 0 { return result }
            result.append(character)
        }
        throw failure("引号未闭合。")
    }

    mutating func skipComment(opener: Character, close: Character) throws {
        var depth = 1
        while let character = current {
            index += 1
            if character == "\\", current != nil { index += 1; continue }
            if character == opener { depth += 1 }
            if character == close { depth -= 1; if depth == 0 { return } }
        }
        throw failure("注释未闭合。")
    }

    mutating func identifier() -> String {
        let start = index
        while let c = current, c.isLetter || c.isNumber || "_-:".contains(c) { index += 1 }
        return String(chars[start..<index])
    }

    mutating func skipSpace() {
        while let character = current {
            if character.isWhitespace { index += 1 }
            else if character == "%" { while let c = current, c != "\n" { index += 1 } }
            else { return }
        }
    }

    mutating func expect(_ character: Character) throws {
        guard current == character else { throw failure("预期字符 \(character)。") }
        index += 1
    }

    func failure(_ detail: String) -> BibliographyError {
        let line = chars.prefix(index).filter { $0 == "\n" }.count + 1
        return .malformed("第 \(line) 行：\(detail)")
    }
}

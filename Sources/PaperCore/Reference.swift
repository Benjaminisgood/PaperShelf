import Foundation

public struct Reference: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var authors: [String]
    public var year: String
    public var journal: String
    public var doi: String
    public var url: String
    public var abstract: String
    public var notes: String
    public var tags: [String]
    public var collection: String
    public var isRead: Bool
    public var isFavorite: Bool
    public var addedAt: Date
    public var pdfPath: String?
    public var pdfBookmark: Data?
    public var citationKey: String
    public var entryType: String
    public var volume: String
    public var issue: String
    public var pages: String
    public var publisher: String
    public var isbn: String
    public var issn: String
    public var extraFields: [String: String]
    public var rating: Int
    public var collectionIDs: [UUID]
    public var deletedAt: Date?
    public var attachments: [ReferenceAttachment]

    public init(id: UUID = UUID(), title: String = "", authors: [String] = [], year: String = "",
                journal: String = "", doi: String = "", url: String = "", abstract: String = "",
                notes: String = "", tags: [String] = [], collection: String = "", isRead: Bool = false,
                isFavorite: Bool = false, addedAt: Date = Date(), pdfPath: String? = nil,
                pdfBookmark: Data? = nil, citationKey: String = "", entryType: String = "article",
                volume: String = "", issue: String = "", pages: String = "", publisher: String = "",
                isbn: String = "", issn: String = "", extraFields: [String: String] = [:],
                rating: Int = 0, collectionIDs: [UUID] = [], deletedAt: Date? = nil,
                attachments: [ReferenceAttachment] = []) {
        self.id = id
        self.title = title
        self.authors = authors
        self.year = year
        self.journal = journal
        self.doi = doi
        self.url = url
        self.abstract = abstract
        self.notes = notes
        self.tags = tags
        self.collection = collection
        self.isRead = isRead
        self.isFavorite = isFavorite
        self.addedAt = addedAt
        self.pdfPath = pdfPath
        self.pdfBookmark = pdfBookmark
        self.citationKey = citationKey
        self.entryType = entryType
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.publisher = publisher
        self.isbn = isbn
        self.issn = issn
        self.extraFields = extraFields
        self.rating = rating
        self.collectionIDs = collectionIDs
        self.deletedAt = deletedAt
        self.attachments = attachments
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, authors, year, journal, doi, url, abstract, notes, tags, collection
        case isRead, isFavorite, addedAt, pdfPath, pdfBookmark, citationKey, entryType
        case volume, issue, pages, publisher, isbn, issn, extraFields, rating, collectionIDs, deletedAt, attachments
    }

    /// Older records lack newly introduced fields. Wrong field types still fail loudly.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            title: try values.decodeIfPresent(String.self, forKey: .title) ?? "",
            authors: try values.decodeIfPresent([String].self, forKey: .authors) ?? [],
            year: try values.decodeIfPresent(String.self, forKey: .year) ?? "",
            journal: try values.decodeIfPresent(String.self, forKey: .journal) ?? "",
            doi: try values.decodeIfPresent(String.self, forKey: .doi) ?? "",
            url: try values.decodeIfPresent(String.self, forKey: .url) ?? "",
            abstract: try values.decodeIfPresent(String.self, forKey: .abstract) ?? "",
            notes: try values.decodeIfPresent(String.self, forKey: .notes) ?? "",
            tags: try values.decodeIfPresent([String].self, forKey: .tags) ?? [],
            collection: try values.decodeIfPresent(String.self, forKey: .collection) ?? "",
            isRead: try values.decodeIfPresent(Bool.self, forKey: .isRead) ?? false,
            isFavorite: try values.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false,
            addedAt: try values.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date(timeIntervalSince1970: 0),
            pdfPath: try values.decodeIfPresent(String.self, forKey: .pdfPath),
            pdfBookmark: try values.decodeIfPresent(Data.self, forKey: .pdfBookmark),
            citationKey: try values.decodeIfPresent(String.self, forKey: .citationKey) ?? "",
            entryType: try values.decodeIfPresent(String.self, forKey: .entryType) ?? "article",
            volume: try values.decodeIfPresent(String.self, forKey: .volume) ?? "",
            issue: try values.decodeIfPresent(String.self, forKey: .issue) ?? "",
            pages: try values.decodeIfPresent(String.self, forKey: .pages) ?? "",
            publisher: try values.decodeIfPresent(String.self, forKey: .publisher) ?? "",
            isbn: try values.decodeIfPresent(String.self, forKey: .isbn) ?? "",
            issn: try values.decodeIfPresent(String.self, forKey: .issn) ?? "",
            extraFields: try values.decodeIfPresent([String: String].self, forKey: .extraFields) ?? [:],
            rating: try values.decodeIfPresent(Int.self, forKey: .rating) ?? 0,
            collectionIDs: try values.decodeIfPresent([UUID].self, forKey: .collectionIDs) ?? [],
            deletedAt: try values.decodeIfPresent(Date.self, forKey: .deletedAt),
            attachments: try values.decodeIfPresent([ReferenceAttachment].self, forKey: .attachments) ?? []
        )
    }
}

public struct ReferenceAttachment: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var path: String
    public var bookmark: Data?
    public var addedAt: Date

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil, addedAt: Date = Date()) {
        self.id = id; self.name = name; self.path = path; self.bookmark = bookmark; self.addedAt = addedAt
    }
}

public struct LibraryCollection: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var parentID: UUID?
    public var sortOrder: Int

    public init(id: UUID = UUID(), name: String, parentID: UUID? = nil, sortOrder: Int = 0) {
        self.id = id; self.name = name; self.parentID = parentID; self.sortOrder = sortOrder
    }
}

public struct LibraryTag: Identifiable, Codable, Equatable, Sendable {
    public var id: String { name }
    public var name: String
    public var colorHex: String
    public var sortOrder: Int

    public init(name: String, colorHex: String = "", sortOrder: Int = 0) {
        self.name = name; self.colorHex = colorHex; self.sortOrder = sortOrder
    }
}

public struct LibraryImport: Equatable, Sendable {
    public var references: [Reference]
    public var collections: [LibraryCollection]
    public var tags: [LibraryTag]
    public var warnings: [String]

    public init(references: [Reference], collections: [LibraryCollection] = [],
                tags: [LibraryTag] = [], warnings: [String] = []) {
        self.references = references; self.collections = collections
        self.tags = tags; self.warnings = warnings
    }
}

public enum ImportDuplicatePolicy: String, Codable, Sendable {
    case skip, replace
}

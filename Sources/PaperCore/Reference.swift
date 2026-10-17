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

    public init(id: UUID = UUID(), title: String = "", authors: [String] = [], year: String = "",
                journal: String = "", doi: String = "", url: String = "", abstract: String = "",
                notes: String = "", tags: [String] = [], collection: String = "", isRead: Bool = false,
                isFavorite: Bool = false, addedAt: Date = Date(), pdfPath: String? = nil,
                pdfBookmark: Data? = nil) {
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
    }
}

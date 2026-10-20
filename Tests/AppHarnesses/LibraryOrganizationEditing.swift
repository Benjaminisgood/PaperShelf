import AppKit
import Foundation
import PaperCore

/// Compile with the app Models, Services and Stores sources (excluding the app entry point).
/// All operations use an isolated temporary library, never the user's library.
@main struct LibraryOrganizationEditingCheck {
    @MainActor static func main() throws {
        func check(_ condition: Bool) { precondition(condition) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaperShelf-membership-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        setenv("PAPERSHELF_LIBRARY_PATH", directory.appendingPathComponent("library.sqlite").path, 1)
        let store = LibraryStore()
        check(store.error == nil)
        let database = try store.requireDatabase()
        let root = LibraryCollection(name: "Research")
        let child = LibraryCollection(name: "Catalysis", parentID: root.id)
        try database.upsertCollections([root, child])
        let attachment = ReferenceAttachment(name: "retained-attachment.txt", path: "/tmp/retained-attachment.txt")
        let first = Reference(title: "First", notes: "Keep notes", tags: ["existing"],
                              pdfPath: "/tmp/retained-paper.pdf", collectionIDs: [root.id, child.id],
                              attachments: [attachment])
        let second = Reference(title: "Second", tags: ["existing", "A,B"], collectionIDs: [child.id])
        check(store.saveBatch([first, second]))

        func saved(_ id: UUID) throws -> Reference {
            guard let item = try database.load().first(where: { $0.id == id }) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return item
        }
        func untouchedContent(_ item: Reference) {
            check(item.title == first.title && item.pdfPath == first.pdfPath)
            check(item.attachments == first.attachments)
            check(item.deletedAt == nil)
        }

        // A toggle must treat a comma-bearing imported tag as one literal name.
        check(store.setTag("A,B", for: first.id, isMember: true))
        var item = try saved(first.id)
        check(Set(item.tags) == ["existing", "A,B"])
        check(store.setTag("A,B", for: first.id, isMember: false))
        item = try saved(first.id)
        check(item.tags == ["existing"])
        check(try saved(second.id).tags == ["existing", "A,B"])
        check(try database.loadTags().contains(where: { $0.name == "A,B" }))
        untouchedContent(item)

        // A later toggle reads the latest record rather than overwriting with a stale view snapshot.
        item.notes = "Newer saved notes"
        check(store.save(item))
        check(store.setTag("new tag", for: first.id, isMember: true))
        check(try saved(first.id).notes == "Newer saved notes")

        // Removing one membership preserves the other. Removing the last must clear
        // the legacy collection label, otherwise database migration re-adds it.
        check(store.setCollection(root.id, for: first.id, isMember: false))
        item = try saved(first.id)
        check(item.collectionIDs == [child.id] && item.collection == child.name)
        check(store.setCollection(child.id, for: first.id, isMember: false))
        item = try saved(first.id)
        check(item.collectionIDs.isEmpty && item.collection.isEmpty)
        check(store.matches(item, filter: "unfiled"))
        check(try database.loadCollections().count == 2)
        check(try saved(second.id).collectionIDs == [child.id])
        untouchedContent(item)

        // Re-add and remove within a matching filter: the record remains in the
        // database even though it correctly stops matching the filtered table.
        check(store.setCollection(child.id, for: first.id, isMember: true))
        store.filter = "c:\(child.id)"
        store.selectedID = first.id
        check(store.setCollection(child.id, for: first.id, isMember: false))
        check(!store.matches(try saved(first.id), filter: store.filter))
        check(try database.load().count == 2)

        // Batch removal also only changes memberships of the addressed references.
        store.filter = "all"
        check(store.removeTag("existing", from: [first.id]))
        check(try !saved(first.id).tags.contains("existing"))
        check(try saved(second.id).tags.contains("existing"))
        check(store.removeFromCollection(child.id, referenceIDs: [second.id]))
        check(try saved(second.id).collectionIDs.isEmpty)
        check(try database.loadTags().contains(where: { $0.name == "existing" }))

        // Inline creation must not navigate away from the paper being edited.
        store.filter = "t:existing"
        check(store.saveTag(name: "  inline, literal  "))
        check(store.filter == "t:existing")
        check(store.tagRecords.contains(where: { $0.name == "inline, literal" }))
        check(store.saveCollection(name: "Research")?.id == root.id)
        check(store.collectionRecords.count == 2 && store.filter == "t:existing")

        // Membership edits participate in the same undo history as metadata edits.
        store.filter = "all"
        let undo = UndoManager()
        undo.groupsByEvent = false
        store.undoManager = undo
        undo.beginUndoGrouping()
        check(store.setTag("undo tag", for: first.id, isMember: true))
        undo.endUndoGrouping()
        check(undo.canUndo)
        undo.undo()
        check(try !saved(first.id).tags.contains("undo tag"))
        undo.redo()
        check(try saved(first.id).tags.contains("undo tag"))
        check(try saved(first.id).notes == "Newer saved notes")

        let beforeInvalidChange = try database.load()
        check(!store.setTag("invalid", for: UUID(), isMember: true))
        check(!store.setCollection(UUID(), for: first.id, isMember: true))
        check(try database.load() == beforeInvalidChange)

        // Reopening proves the inspector did not only mutate in-memory display state.
        let reopened = LibraryStore()
        check(reopened.error == nil)
        check(reopened.references == store.references)
        check(reopened.collectionRecords.count == 2)
        check(reopened.tagRecords.contains(where: { $0.name == "A,B" }))
        print("PASS: literal tag toggles, membership removal, last-collection clearing, latest-record preservation, filtered removal, scoped batch changes, inline creation, undo/redo, invalid-ID rejection and reopen persistence.")
    }
}

import SwiftUI
import AppKit
import PaperCore

extension LibraryStore {
    func collectionPath(_ id: UUID) -> String {
        var path: [String] = []; var current: UUID? = id; var seen: Set<UUID> = []
        while let value = current, !seen.contains(value), let item = collectionRecords.first(where: { $0.id == value }) {
            seen.insert(value); path.insert(item.name, at: 0); current = item.parentID
        }
        return path.joined(separator: " / ")
    }

    func sortedCollections(parent: UUID?) -> [LibraryCollection] {
        collectionRecords.filter { $0.parentID == parent }.sorted { ($0.sortOrder, $0.name, $0.id.uuidString) < ($1.sortOrder, $1.name, $1.id.uuidString) }
    }

    func editCollection(_ collection: LibraryCollection? = nil, parentID: UUID? = nil) {
        guard let name = organizationInput(title: collection == nil ? "新建文集" : "重命名文集", value: collection?.name ?? ""), !name.isEmpty else { return }
        if let value = saveCollection(name: name, collection: collection, parentID: parentID) { filter = "c:\(value.id)" }
    }

    /// Shared by inline creation and renaming. This deliberately leaves the current filter alone.
    @discardableResult func saveCollection(name: String, collection: LibraryCollection? = nil, parentID: UUID? = nil) -> LibraryCollection? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        do {
            if collection == nil, let existing = collectionRecords.first(where: { $0.parentID == parentID && $0.name == name }) { return existing }
            var value: LibraryCollection
            if let collection {
                guard let current = collectionRecords.first(where: { $0.id == collection.id }) else { return nil }
                value = current
            } else {
                value = LibraryCollection(name: name, parentID: parentID, sortOrder: (sortedCollections(parent: parentID).map(\.sortOrder).max() ?? -1) + 1)
            }
            value.name = name
            try requireDatabase().upsertCollection(value); try reload()
            status = collection == nil ? "已新建文集" : "已重命名文集"
            return value
        } catch { self.error = error.localizedDescription; return nil }
    }

    func deleteCollection(_ collection: LibraryCollection) {
        let descendants = collectionIDs(in: collection.id)
        if descendants.count > 1 {
            let alert = NSAlert(); alert.messageText = "移除“\(collection.name)”及子文集？"
            alert.informativeText = "将移除该文集及 \(descendants.count - 1) 个子文集。文献、附件和其他文集归属均保留。"
            alert.addButton(withTitle: "移除文集及子文集"); alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try requireDatabase().deleteCollection(id: collection.id, includingDescendants: descendants.count > 1)
            try reload()
            if filter.hasPrefix("c:"), let selected = UUID(uuidString: String(filter.dropFirst(2))), descendants.contains(selected) { filter = "all" }
            status = "已移除文集；文献保留在书库"
        } catch { self.error = error.localizedDescription }
    }

    @discardableResult func moveCollection(_ collection: LibraryCollection, to parent: UUID?) -> Bool {
        if collection.parentID == parent { return true }
        do {
            var value = collection; value.parentID = parent
            value.sortOrder = (sortedCollections(parent: parent).map(\.sortOrder).max() ?? -1) + 1
            try requireDatabase().upsertCollection(value); try reload(); status = "已移动文集"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func shiftCollection(_ collection: LibraryCollection, offset: Int) {
        var siblings = sortedCollections(parent: collection.parentID)
        guard let index = siblings.firstIndex(where: { $0.id == collection.id }), siblings.indices.contains(index + offset) else { return }
        siblings.swapAt(index, index + offset); _ = saveCollectionOrder(siblings)
    }

    @discardableResult func placeCollection(_ source: LibraryCollection, beside target: LibraryCollection, after: Bool) -> Bool {
        guard source.id != target.id else { return false }
        var siblings = sortedCollections(parent: target.parentID).filter { $0.id != source.id }
        guard let index = siblings.firstIndex(where: { $0.id == target.id }) else { return false }
        var moved = source; moved.parentID = target.parentID
        siblings.insert(moved, at: index + (after ? 1 : 0))
        return saveCollectionOrder(siblings)
    }

    @discardableResult private func saveCollectionOrder(_ siblings: [LibraryCollection]) -> Bool {
        do {
            let updates = siblings.enumerated().map { offset, item in var value = item; value.sortOrder = offset; return value }
            try requireDatabase().upsertCollections(updates); try reload(); status = "已更新文集顺序"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggleSubcollections() { preferences.includeSubcollections.toggle(); savePreferences() }

    func addTag() {
        guard let value = organizationInput(title: "新建标签"), !value.isEmpty else { return }
        _ = saveTag(name: value)
    }

    func renameTag(_ name: String) {
        guard let value = organizationInput(title: "重命名标签", value: name), !value.isEmpty, value != name else { return }
        _ = saveTag(name: value, renaming: name)
    }

    @discardableResult func saveTag(name: String, renaming oldName: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        do {
            if let oldName {
                guard oldName != name else { return true }
                try requireDatabase().renameTag(from: oldName, to: name)
                // Change the filter before reloading so renaming does not clear the selected paper.
                if filter == "t:" + oldName { filter = "t:" + name }
            } else if !tagRecords.contains(where: { $0.name == name }) {
                try requireDatabase().upsertTag(LibraryTag(name: name, sortOrder: (tagRecords.map(\.sortOrder).max() ?? -1) + 1))
            }
            try reload(); status = oldName == nil ? "已新建标签" : "已重命名标签"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func tagColor(_ name: String) -> Color {
        guard let raw = tagRecords.first(where: { $0.name == name })?.colorHex else { return .accentColor }
        let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard [6, 8].contains(hex.count), let value = UInt64(hex, radix: 16) else { return .accentColor }
        let rgba = hex.count == 6 ? value << 8 | 255 : value
        return Color(red: Double((rgba >> 24) & 255) / 255, green: Double((rgba >> 16) & 255) / 255,
                     blue: Double((rgba >> 8) & 255) / 255, opacity: Double(rgba & 255) / 255)
    }

    func colorTag(_ name: String, hex: String) {
        do {
            var value = tagRecords.first { $0.name == name } ?? LibraryTag(name: name)
            let input = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            value.colorHex = input.isEmpty ? "" : "#" + input.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
            try requireDatabase().upsertTag(value); try reload()
        } catch { self.error = error.localizedDescription }
    }

    func customTagColor(_ name: String) {
        guard let value = organizationInput(title: "标签颜色", value: tagRecords.first { $0.name == name }?.colorHex ?? "", detail: "输入 #RRGGBB 或 #RRGGBBAA；留空恢复默认颜色。") else { return }
        colorTag(name, hex: value)
    }

    func shiftTag(_ name: String, offset: Int) {
        var names = tags
        guard let index = names.firstIndex(of: name), names.indices.contains(index + offset) else { return }
        names.swapAt(index, index + offset); _ = saveTagOrder(names)
    }

    @discardableResult func placeTag(_ source: String, before target: String) -> Bool {
        guard source != target, tags.contains(source), tags.contains(target) else { return false }
        var names = tags.filter { $0 != source }
        guard let index = names.firstIndex(of: target) else { return false }
        names.insert(source, at: index); return saveTagOrder(names)
    }

    @discardableResult private func saveTagOrder(_ names: [String]) -> Bool {
        do {
            let updates = names.enumerated().map { offset, name in
                var tag = tagRecords.first { $0.name == name } ?? LibraryTag(name: name)
                tag.sortOrder = offset; return tag
            }
            try requireDatabase().upsertTags(updates); try reload(); status = "已更新标签顺序"; return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func deleteTag(_ name: String) {
        do { try requireDatabase().deleteTag(name: name); try reload(); if filter == "t:" + name { filter = "all" } }
        catch { self.error = error.localizedDescription }
    }

    @discardableResult func addTag(_ name: String, to ids: Set<UUID>) -> Bool {
        let values = references.filter { ids.contains($0.id) && $0.deletedAt == nil && !$0.tags.contains(name) }.map { item in var value = item; value.tags.append(name); return value }
        return !values.isEmpty && saveBatch(values, action: "添加标签")
    }

    @discardableResult func addToCollection(_ id: UUID, referenceIDs: Set<UUID>) -> Bool {
        let values = references.filter { referenceIDs.contains($0.id) && $0.deletedAt == nil && !$0.collectionIDs.contains(id) }.map { item in var value = item; value.collectionIDs.append(id); return value }
        return !values.isEmpty && saveBatch(values, action: "添加到文集")
    }

    @discardableResult func removeTag(_ name: String, from ids: Set<UUID>) -> Bool {
        let values = references.filter { ids.contains($0.id) && $0.deletedAt == nil && $0.tags.contains(name) }.map { item in
            var value = item; value.tags.removeAll { $0 == name }; return value
        }
        return !values.isEmpty && saveBatch(values, action: "移除标签")
    }

    @discardableResult func removeFromCollection(_ id: UUID, referenceIDs: Set<UUID>) -> Bool {
        let values = references.filter { referenceIDs.contains($0.id) && $0.deletedAt == nil && $0.collectionIDs.contains(id) }.map { item in
            var value = item
            value.collectionIDs.removeAll { $0 == id }
            // An empty ID list with the legacy name would be interpreted as an imported membership.
            value.collection = ""
            return value
        }
        return !values.isEmpty && saveBatch(values, action: "移出文集")
    }

    /// Resolve the current record at the moment of interaction, rather than saving a captured inspector snapshot.
    @discardableResult func setTag(_ name: String, for referenceID: UUID, isMember: Bool) -> Bool {
        guard let current = references.first(where: { $0.id == referenceID && $0.deletedAt == nil }) else { return false }
        guard current.tags.contains(name) != isMember else { return true }
        return isMember ? addTag(name, to: [referenceID]) : removeTag(name, from: [referenceID])
    }

    @discardableResult func setCollection(_ id: UUID, for referenceID: UUID, isMember: Bool) -> Bool {
        guard collectionRecords.contains(where: { $0.id == id }),
              let current = references.first(where: { $0.id == referenceID && $0.deletedAt == nil }) else { return false }
        guard current.collectionIDs.contains(id) != isMember else { return true }
        return isMember ? addToCollection(id, referenceIDs: [referenceID]) : removeFromCollection(id, referenceIDs: [referenceID])
    }

    func droppedReferenceIDs(_ payloads: [String]) -> Set<UUID> {
        Set(payloads.flatMap { $0.split(whereSeparator: \.isNewline) }.compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) })
    }

    private func organizationInput(title: String, value: String = "", detail: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
        let input = NSTextField(string: value); input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "保存"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

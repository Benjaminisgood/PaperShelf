import Foundation
import AppKit
import PaperCore

struct LibraryHistoryChange {
    let before: Reference?
    let after: Reference?
    var id: UUID { (before ?? after)!.id }
}

extension LibraryStore {
    func registerHistory(before: [Reference], after: [Reference], action: String) {
        let old = Dictionary(uniqueKeysWithValues:before.map { ($0.id,$0) })
        let new = Dictionary(uniqueKeysWithValues:after.map { ($0.id,$0) })
        let changes = Set(old.keys).union(new.keys).compactMap { id -> LibraryHistoryChange? in
            old[id] == new[id] ? nil : LibraryHistoryChange(before:old[id],after:new[id])
        }
        guard !changes.isEmpty else { return }
        undoManager?.registerUndo(withTarget:self) { target in target.applyHistory(changes,action:action) }
        undoManager?.setActionName(action)
    }

    private func applyHistory(_ changes:[LibraryHistoryChange],action:String) {
        do {
            let current = Dictionary(uniqueKeysWithValues:try requireDatabase().load().map { ($0.id,$0) })
            var upserts:[Reference] = [], deleted:Set<UUID> = [], inverse:[LibraryHistoryChange] = []
            for change in changes {
                let latest = current[change.id]
                if let before = change.before {
                    let restored:Reference
                    if let expected = change.after {
                        guard let latest else { throw LocalAPIError(409,"文献已被其他操作移除，无法安全撤销。") }
                        restored = try historyMerge(before:before,expected:expected,current:latest)
                    } else {
                        guard latest == nil else { throw LocalAPIError(409,"原记录标识已被重新使用，无法安全重做。") }
                        restored = before
                    }
                    upserts.append(restored)
                    inverse.append(.init(before:latest,after:restored))
                } else if let latest {
                    // Creation undo removes only records; redo retains current paths.
                    deleted.insert(change.id)
                    inverse.append(.init(before:latest,after:nil))
                }
            }
            try requireDatabase().applyReferenceChanges(upserting:upserts,deleting:deleted)
            undoManager?.registerUndo(withTarget:self) { target in target.applyHistory(inverse,action:action) }
            undoManager?.setActionName(action)
            refreshAfterCommit()
            selectedIDs.formIntersection(Set(references.map(\.id)))
            status = "已撤销或重做：\(action)；原始文件保留"
        } catch { self.error = error.localizedDescription }
    }

    private func historyMerge(before:Reference,expected:Reference,current:Reference) throws -> Reference {
        func object(_ value:Reference) throws -> [String:Any] { try JSONSerialization.jsonObject(with:JSONEncoder().encode(value)) as! [String:Any] }
        func equal(_ lhs:Any?,_ rhs:Any?) -> Bool {
            guard let lhs, let rhs else { return lhs == nil && rhs == nil }
            return NSDictionary(dictionary:["value":lhs]).isEqual(to:["value":rhs])
        }
        let old = try object(before), wanted = try object(expected)
        var result = try object(current)
        for key in Set(old.keys).union(wanted.keys) where !equal(old[key],wanted[key]) {
            guard equal(result[key],wanted[key]) else { throw LocalAPIError(409,"“\(current.title)”的 \(key) 已有后续更改；未覆盖该更改。") }
            result[key] = old[key]
        }
        return try JSONDecoder().decode(Reference.self,from:JSONSerialization.data(withJSONObject:result))
    }

    /// A committed save stays successful even if refreshing its view fails.
    func refreshAfterCommit() {
        do { try reload() }
        catch { self.error = "数据已保存，但界面刷新失败。请重新打开书库。\n\(error.localizedDescription)" }
    }
}

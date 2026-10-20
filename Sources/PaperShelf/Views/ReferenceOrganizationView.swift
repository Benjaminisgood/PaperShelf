import SwiftUI
import PaperCore

/// Direct membership controls for the selected paper. Each switch writes only its latest membership.
struct ReferenceOrganizationView: View {
    @ObservedObject var store: LibraryStore
    let referenceID: UUID
    @State private var creating: OrganizationKind?
    @State private var draftName = ""
    @FocusState private var focusedCreation: OrganizationKind?

    private enum OrganizationKind: Hashable { case collection, tag }
    private var reference: Reference? { store.references.first { $0.id == referenceID } }
    private var collectionRows: [LibraryCollection] {
        func descendants(of parent: UUID?) -> [LibraryCollection] {
            store.sortedCollections(parent: parent).flatMap { [$0] + descendants(of: $0.id) }
        }
        return descendants(of: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            collections
            tags
        }
        .disabled(reference == nil || reference?.deletedAt != nil)
        .onChange(of: referenceID) { _, _ in cancelCreation() }
    }

    private var collections: some View {
        let rows = collectionRows
        return VStack(alignment: .leading, spacing: 9) {
            sectionHeader("文集", kind: .collection)
            if rows.isEmpty {
                Text("按项目或主题整理文献，可建立子文集。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(rows) { collection in
                        collectionToggle(collection).padding(.horizontal, 12).padding(.vertical, 9)
                        if collection.id != rows.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                if rows.contains(where: { $0.parentID != nil }) {
                    Text("开关只更改本级文集，子文集归属会保留。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if creating == .collection { creationField(.collection) }
        }
    }

    private func collectionToggle(_ collection: LibraryCollection) -> some View {
        let isDirectMember = reference?.collectionIDs.contains(collection.id) == true
        let childIDs = store.collectionIDs(in: collection.id).subtracting([collection.id])
        let isInChild = !Set(reference?.collectionIDs ?? []).isDisjoint(with: childIDs)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(store.collectionPath(collection.id)).lineLimit(2)
                if !isDirectMember && isInChild {
                    Text("已加入子文集").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(
                get: { reference?.collectionIDs.contains(collection.id) == true },
                set: { _ = store.setCollection(collection.id, for: referenceID, isMember: $0) }
            )) { Text(store.collectionPath(collection.id)) }
            .labelsHidden().toggleStyle(.switch).controlSize(.small)
            .accessibilityLabel(store.collectionPath(collection.id))
            .accessibilityIdentifier("inspector.collection.\(collection.id.uuidString)")
            .help("打开加入文集，关闭移出文集")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tags: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("标签", kind: .tag)
            if store.tags.isEmpty {
                Text("标记主题、用途或进度，可跨文集使用。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(store.tags, id: \.self) { name in
                        HStack(spacing: 12) {
                            HStack(spacing: 8) {
                                Circle().fill(store.tagColor(name)).frame(width: 8, height: 8)
                                Text(name).lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Toggle(isOn: Binding(
                                get: { reference?.tags.contains(name) == true },
                                set: { _ = store.setTag(name, for: referenceID, isMember: $0) }
                            )) { Text(name) }
                            .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            .accessibilityLabel(name)
                            .accessibilityIdentifier("inspector.tag.\(name)")
                            .help("打开添加标签，关闭移除标签")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if name != store.tags.last { Divider().padding(.leading, 12) }
                    }
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            }
            if creating == .tag { creationField(.tag) }
        }
    }

    private func sectionHeader(_ title: String, kind: OrganizationKind) -> some View {
        HStack {
            Text(LocalizedStringKey(title)).font(.headline)
            Spacer()
            Button {
                draftName = ""; creating = kind; focusedCreation = kind
            } label: {
                Label(LocalizedStringKey(kind == .collection ? "新建文集" : "新建标签"), systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(kind == .collection ? "inspector.newCollection" : "inspector.newTag")
            .help(LocalizedStringKey(kind == .collection ? "新建并加入文集" : "新建并添加标签"))
        }
    }

    private func creationField(_ kind: OrganizationKind) -> some View {
        HStack(spacing: 6) {
            TextField(LocalizedStringKey(kind == .collection ? "文集名称" : "标签名称"), text: $draftName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedCreation, equals: kind)
                .onSubmit { createAndAssign(kind) }
                .onExitCommand { cancelCreation() }
                .accessibilityIdentifier(kind == .collection ? "inspector.collectionName" : "inspector.tagName")
            Button("添加") { createAndAssign(kind) }
                .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button { cancelCreation() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("取消")
                .accessibilityLabel("取消")
        }
        .controlSize(.small)
    }

    private func createAndAssign(_ kind: OrganizationKind) {
        guard let reference, reference.deletedAt == nil else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let saved: Bool
        switch kind {
        case .collection:
            guard let collection = store.saveCollection(name: name) else { return }
            saved = store.setCollection(collection.id, for: referenceID, isMember: true)
        case .tag:
            guard store.saveTag(name: name) else { return }
            saved = store.setTag(name, for: referenceID, isMember: true)
        }
        if saved { cancelCreation() }
    }

    private func cancelCreation() {
        focusedCreation = nil; creating = nil; draftName = ""
    }
}

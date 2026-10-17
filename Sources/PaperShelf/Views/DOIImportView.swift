import SwiftUI

struct DOIImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: LibraryStore
    @State private var doi = ""
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("通过 DOI 导入", systemImage: "link.badge.plus").font(.title2.bold())
            Text("输入 DOI 或 doi.org 链接。此操作会将该 DOI 发送给 Crossref 查询元数据。").font(.callout).foregroundStyle(.secondary)
            TextField("10.1038/nphys1170", text: $doi).textFieldStyle(.roundedBorder)
            if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
            HStack {
                if store.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction).disabled(store.isBusy)
                Button("导入") {
                    Task {
                        if await store.importDOI(doi) { dismiss() }
                        else { importError = store.error; store.error = nil }
                    }
                }.keyboardShortcut(.defaultAction).disabled(doi.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy)
            }
        }.padding(26).frame(width: 500)
        .interactiveDismissDisabled(store.isBusy)
    }
}

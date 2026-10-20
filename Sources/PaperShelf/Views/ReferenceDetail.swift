import SwiftUI
import AppKit
import PaperCore

struct ReferenceDetail: View {
    @ObservedObject var store: LibraryStore
    let reference: Reference
    var metadataDraft: Reference? = nil
    @SceneStorage("library.inspector.tab") private var tab = 0
    @State private var annotations: [PaperAnnotation] = []
    @State private var annotationStatus = ""
    @State private var reading = false
    @State private var metadataError = ""
    var body: some View {
        VStack(spacing: 0) {
            Picker("检查器", selection: $tab) { Text("元数据").tag(0); Text("标注").tag(1); Text("研读").tag(2) }
                .labelsHidden().pickerStyle(.segmented).padding(.horizontal, 18).padding(.vertical, 13)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if tab == 0 { metadata }
                    else if tab == 1 { annotationContent }
                    else { LearningView(learning: store.learning, reference: reference) }
                }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if metadataDraft != nil { tab = 0 } }
        .onChange(of: metadataDraft?.id) { _, id in if id != nil { tab = 0 } }
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 24) {
            if metadataDraft != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Label("元数据更新预览", systemImage: "arrow.triangle.2.circlepath").font(.headline)
                    Text("核对下方字段后应用；取消会保留原有元数据。").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("取消") {
                            store.editingReference = nil; store.metadataRefreshBase = nil; metadataError = ""
                            store.status = "已取消元数据更新"
                        }
                        Spacer()
                        Button("应用更新", action: applyMetadataDraft).buttonStyle(.borderedProminent)
                    }
                    if !metadataError.isEmpty { Text(metadataError).font(.caption).foregroundStyle(.red) }
                }.padding(12).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            ReferenceMetadataEditor(reference: metadataDraft ?? reference, onUpdate: updateMetadata, onRefresh: {
                guard InlineReferenceEditing.commit(), let latest = store.references.first(where: { $0.id == reference.id }) else { return }
                Task { await store.refreshMetadata(latest) }
            }, refreshDisabled: store.isBusy, isPreview: metadataDraft != nil).id(metadataDraft != nil)
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("文库")
                HStack { Text("评分").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ForEach(1...5, id: \.self) { value in Button { update { $0.rating = $0.rating == value ? 0 : value } } label: { Image(systemName: reference.rating >= value ? "star.fill" : "star").foregroundStyle(reference.rating >= value ? Color.orange : Color.secondary) }.buttonStyle(.plain).help("\(value) 星") }
                    Spacer(); Text(reference.rating == 0 ? "未评分" : "\(reference.rating) 星").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button { update { $0.isRead.toggle() } } label: { Label(reference.isRead ? "已读" : "待读", systemImage: reference.isRead ? "checkmark.circle" : "circle") }
                    Button { update { $0.isFavorite.toggle() } } label: { Label("收藏", systemImage: reference.isFavorite ? "star.fill" : "star") }
                }.buttonStyle(.borderless).font(.callout)
            }
            ReferenceOrganizationView(store: store, referenceID: reference.id)
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("内容")
                DisclosureGroup("摘要") {
                    InlineReferenceTextField(title: "摘要", value: (metadataDraft ?? reference).abstract, multiline: true) { text in
                        updateMetadata { $0.abstract = text }
                    }.id(metadataDraft != nil).padding(.vertical, 8)
                }
                DisclosureGroup("备注") {
                    InlineReferenceTextField(title: "备注", value: reference.notes, multiline: true) { text in
                        update { $0.notes = text }
                    }.padding(.vertical, 8)
                }
            }
            VStack(alignment: .leading, spacing: 12) {
                sectionTitle("附件")
                if let path = reference.pdfPath {
                    Button { store.openPDF(reference) } label: { Label(URL(fileURLWithPath: path).lastPathComponent, systemImage: "doc.richtext").lineLimit(2) }.buttonStyle(.plain)
                    HStack { Button("快速查看") { store.preview(reference) }; Button("Finder") { store.openPDF(reference, reveal: true) } }.controlSize(.small)
                }
                ForEach(reference.attachments) { attachment in
                    HStack {
                        Button { store.openAttachment(attachment) } label: {
                            Label(attachment.name, systemImage: "paperclip").lineLimit(1)
                        }.buttonStyle(.plain)
                        Spacer()
                        Menu {
                            Button("Finder") { store.openAttachment(attachment, reveal: true) }
                            Button("移除关联", role: .destructive) {
                                update { $0.attachments.removeAll { $0.id == attachment.id } }
                            }
                        } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).frame(width: 20)
                    }
                }
                HStack { Button(reference.pdfPath == nil ? "关联 PDF…" : "替换 PDF…") { store.attachPDF(to: reference) }; Button("添加附件…") { store.addAttachments(to: reference) } }.controlSize(.small)
            }
            HStack { Button("复制 BibTeX") { store.copyCitation(reference) }; Spacer(); Text(reference.addedAt, format: .dateTime.year().month().day()).font(.caption).foregroundStyle(.tertiary) }.controlSize(.small)
        }
    }
    private func sectionTitle(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
    @discardableResult private func update(_ body: (inout Reference) -> Void) -> Bool {
        guard var value = store.references.first(where: { $0.id == reference.id }) else { return false }
        body(&value)
        return store.save(value)
    }
    private func updateMetadata(_ body: (inout Reference) -> Void) -> Bool {
        if metadataDraft != nil {
            guard var draft = store.editingReference, draft.id == reference.id else { return false }
            body(&draft)
            store.editingReference = draft
            return true
        }
        return update(body)
    }
    private func applyMetadataDraft() {
        guard InlineReferenceEditing.commit(),
              let draft = store.editingReference, draft.id == reference.id,
              let latest = store.references.first(where: { $0.id == reference.id }) else { return }
        do {
            let merged = try ReferenceEdits.merge(base: store.metadataRefreshBase ?? reference, edited: draft, current: latest)
            if store.save(merged) {
                store.editingReference = nil
                store.metadataRefreshBase = nil
                metadataError = ""
            } else { metadataError = store.error ?? String(localized: "未能保存，请重试") }
        } catch { metadataError = error.localizedDescription }
    }
    private var annotationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("PDF 标注").font(.headline); Spacer(); Button(reading ? "读取中…" : "刷新") { readAnnotations() }.disabled(reference.pdfPath == nil || reading) }
            if !annotationStatus.isEmpty { Text(annotationStatus).font(.caption).foregroundStyle(.secondary) }
            if annotations.isEmpty && !reading { ContentUnavailableView("暂无标注", systemImage: "highlighter", description: Text("在外部 PDF 阅读器保存标注后，点击刷新。")) }
            ForEach(annotations) { item in
                VStack(alignment: .leading, spacing: 8) { Text("第 \(item.pageLabel.isEmpty ? String(item.page) : item.pageLabel) 页 · \(item.kind) · \(item.colorHex)").font(.caption).foregroundStyle(.secondary)
                    if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                    if !item.comment.isEmpty { Text(item.comment).font(.callout).textSelection(.enabled) }
                    if let data = item.imagePNG, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("第 \(item.page) 页区域标注") }
                    if item.textSource.contains("ocr") { Text("OCR 识别文字，请核对").font(.caption2).foregroundStyle(.secondary) }
                }; Divider()
            }
            if !annotations.isEmpty { Button("复制 Markdown") { do {
                let links = Dictionary(uniqueKeysWithValues: annotations.compactMap { item in item.imagePNG.map { (item.id, "data:image/png;base64," + $0.base64EncodedString()) } })
                let text = try PaperTemplateRenderer.render(reference: reference, annotations: annotations, templates: .init(metadata: "{{annotations}}", annotation: store.preferences.templates.annotation), imageLinks: links)
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            } catch { annotationStatus = error.localizedDescription } } }
        }.task { if annotations.isEmpty && reference.pdfPath != nil { readAnnotations() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if tab == 1 && reference.pdfPath != nil { readAnnotations() } }
        .onChange(of: store.previewURL) { _, _ in if tab == 1 && reference.pdfPath != nil { readAnnotations() } }
        .onChange(of: reference.pdfPath) { _, _ in annotations = []; if reference.pdfPath != nil { readAnnotations() } }
    }
    private func readAnnotations() {
        guard !reading else { return }
        reading = true; let item = reference; let options = PDFAnnotationOptions(ocrIfNeeded: store.preferences.annotationOCR)
        Task { do { annotations = try await Task.detached { try PDFLinks.annotations(for: item, options: options) }.value; annotationStatus = "\(annotations.count) 条标注" }
            catch { annotationStatus = error.localizedDescription }; reading = false }
    }
}

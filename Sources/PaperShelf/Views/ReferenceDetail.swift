import SwiftUI
import AppKit
import PaperCore

struct ReferenceDetail: View {
    @ObservedObject var store: LibraryStore
    let reference: Reference
    @SceneStorage("library.inspector.tab") private var tab = 0
    @State private var showMore = false
    @State private var annotations: [PaperAnnotation] = []
    @State private var annotationStatus = ""
    @State private var reading = false
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
    }
    private var metadata: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text(LocalizedStringKey(typeLabel)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { store.editingReference = reference } label: { Image(systemName: "pencil") }.buttonStyle(.plain).help("编辑全部元数据")
                Image(systemName: reference.pdfPath == nil ? "doc.badge.plus" : "doc.text").foregroundStyle(.secondary).help(reference.pdfPath == nil ? "尚未关联 PDF" : "已关联 PDF")
            }
            Text(reference.title).font(.system(size: 23, weight: .semibold, design: .serif)).textSelection(.enabled)
                .onTapGesture(count: 2) { store.editingReference = reference }
            VStack(alignment: .leading, spacing: 12) {
                Text(reference.authors.joined(separator: "; ")).foregroundStyle(.secondary).textSelection(.enabled)
                if !reference.citationKey.isEmpty { Text(reference.citationKey).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack { sectionTitle("引用"); Spacer(); Button { Task { await store.refreshMetadata(reference) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain).help("从 DOI 刷新元数据，核对后保存").disabled(store.isBusy) }
                metadataRow("年份", \.year)
                metadataRow("来源", \.journal)
                metadataRow("标识符", \.doi, monospaced: true)
                HStack(alignment: .firstTextBaseline) {
                    Text("URL").font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                    Text(reference.url.isEmpty ? "—" : reference.url).font(.callout.monospaced()).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if let url = URL(string: reference.url), ["https","http"].contains(url.scheme?.lowercased() ?? "") { Link(destination: url) { Image(systemName: "arrow.up.right.square") }.help("打开网址") }
                }
                HStack { miniField("卷", reference.volume); miniField("期", reference.issue); miniField("页码", reference.pages) }
                DisclosureGroup("更多字段", isExpanded: $showMore) {
                    VStack(spacing: 12) { metadataRow("出版者", \.publisher); metadataRow("ISBN", \.isbn); metadataRow("ISSN", \.issn)
                        ForEach(reference.extraFields.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in HStack(alignment: .top) { Text(key).font(.caption).frame(width: 70, alignment: .leading); Text(value).textSelection(.enabled); Spacer() }.foregroundStyle(.secondary) }
                    }.padding(.top, 12)
                }.font(.callout).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("文库")
                HStack { Text("评分").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    ForEach(1...5, id: \.self) { value in Button { update { $0.rating = reference.rating == value ? 0 : value } } label: { Image(systemName: reference.rating >= value ? "star.fill" : "star").foregroundStyle(reference.rating >= value ? Color.orange : Color.secondary) }.buttonStyle(.plain).help("\(value) 星") }
                    Spacer(); Text(reference.rating == 0 ? "未评分" : "\(reference.rating) 星").font(.caption).foregroundStyle(.secondary)
                }
                HStack(alignment: .top) {
                    Text("文集").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    VStack(alignment: .leading, spacing: 5) {
                        if reference.collectionIDs.isEmpty && reference.collection.isEmpty { Text("无").foregroundStyle(.tertiary) }
                        if reference.collectionIDs.isEmpty && !reference.collection.isEmpty { Text(reference.collection).foregroundStyle(.secondary) }
                        ForEach(reference.collectionIDs, id: \.self) { id in Text(store.collectionPath(id)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    Menu { ForEach(store.collectionRecords) { collection in
                        Button { update { item in if item.collectionIDs.contains(collection.id) { item.collectionIDs.removeAll { $0 == collection.id }; item.collection = "" } else { item.collectionIDs.append(collection.id) } } } label: { Label(store.collectionPath(collection.id), systemImage: reference.collectionIDs.contains(collection.id) ? "checkmark" : "folder") }
                    } } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).frame(width: 20).help("设置文集")
                }
                metadataRow("标签", text: reference.tags.joined(separator: ", ")) { value in update { $0.tags = value.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                HStack {
                    Button { update { $0.isRead.toggle() } } label: { Label(reference.isRead ? "已读" : "待读", systemImage: reference.isRead ? "checkmark.circle" : "circle") }
                    Button { update { $0.isFavorite.toggle() } } label: { Label("收藏", systemImage: reference.isFavorite ? "star.fill" : "star") }
                }.buttonStyle(.borderless).font(.callout)
            }
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("内容")
                DisclosureGroup("摘要") { Text(reference.abstract.isEmpty ? "暂无摘要" : reference.abstract).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 8) }
                DisclosureGroup("备注") { Text(reference.notes.isEmpty ? "暂无备注" : reference.notes).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 8); Button("编辑备注") { store.editingReference = reference } }
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
    private var typeLabel: String { ["article":"期刊论文", "book":"图书", "inproceedings":"会议论文", "phdthesis":"学位论文", "misc":"其他文献"][reference.entryType] ?? reference.entryType }
    private func sectionTitle(_ text: String) -> some View { Text(LocalizedStringKey(text)).font(.caption.weight(.medium)).foregroundStyle(.secondary) }
    private func miniField(_ title: String, _ value: String) -> some View { HStack { Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary); Text(value.isEmpty ? "—" : value).font(.callout).foregroundStyle(.secondary); Spacer(minLength: 4) } }
    private func metadataRow(_ title: String, _ keyPath: WritableKeyPath<Reference,String>, monospaced: Bool = false) -> some View {
        metadataRow(title, text: reference[keyPath: keyPath], monospaced: monospaced) { value in update { $0[keyPath: keyPath] = value } }
    }
    private func metadataRow(_ title: String, text: String, monospaced: Bool = false, onCommit: @escaping (String)->Void) -> some View {
        InlineMetadataField(title: title, value: text, monospaced: monospaced, onCommit: onCommit)
    }
    private func update(_ body: (inout Reference)->Void) { guard var value = store.references.first(where: { $0.id == reference.id }) else { return }; body(&value); _ = store.save(value) }
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

private struct InlineMetadataField: View {
    let title: String
    let value: String
    var monospaced = false
    let onCommit: (String)->Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title)).font(.caption).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            if editing {
                TextField(LocalizedStringKey(title), text: $draft).textFieldStyle(.roundedBorder).focused($focused).onSubmit { onCommit(draft); editing = false }.onExitCommand { editing = false }
            } else {
                Text(value.isEmpty ? "—" : value).font(monospaced ? .callout.monospaced() : .callout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).onTapGesture(count: 2) { draft = value; editing = true; focused = true }.help("双击编辑")
            }
        }.onChange(of: focused) { old, new in if old && !new && editing { onCommit(draft); editing = false } }
    }
}

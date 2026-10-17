import SwiftUI
import AppKit
import PaperCore

struct ReferenceDetail: View {
    @ObservedObject var store: LibraryStore
    let reference: Reference
    @State private var editing = false
    @State private var tab = 0
    @State private var annotations: [PaperAnnotation] = []
    @State private var annotationStatus = "点击“读取批注”检查原始 PDF。"
    @State private var reading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("文献详情").font(.headline)
                Spacer()
                Button("编辑") { editing = true }.buttonStyle(.bordered)
            }.padding(18)
            Picker("详情", selection: $tab) {
                Text("元数据").tag(0)
                Text("批注").tag(1)
            }.pickerStyle(.segmented).padding(.horizontal, 18).padding(.bottom, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if tab == 0 { metadata } else { annotationContent }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 310, idealWidth: 370)
        .sheet(isPresented: $editing) {
            MetadataEditor(reference: reference) { updated in
                if store.save(updated) { return nil }
                let message = store.error ?? "保存失败，请重试。"
                store.error = nil
                return message
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(reference.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            if !reference.authors.isEmpty { Text(reference.authors.joined(separator: ", ")).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Button {
                    var value = reference; value.isRead.toggle(); _ = store.save(value)
                } label: { Label(reference.isRead ? "已读" : "待读", systemImage: reference.isRead ? "checkmark.circle.fill" : "circle") }
                Button {
                    var value = reference; value.isFavorite.toggle(); _ = store.save(value)
                } label: { Label("收藏", systemImage: reference.isFavorite ? "star.fill" : "star") }
            }.buttonStyle(.borderless)
            Divider()
            field("年份", reference.year)
            field("期刊 / 来源", reference.journal)
            field("DOI", reference.doi)
            field("网址", reference.url)
            field("分类", reference.collection)
            if !reference.tags.isEmpty { field("标签", reference.tags.joined(separator: " · ")) }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Label("附件", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary)
                if let path = reference.pdfPath {
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.callout).lineLimit(2).help(path)
                    HStack {
                        Button("打开 PDF") { store.openPDF(reference) }.buttonStyle(.borderedProminent)
                        Button("Finder") { store.openPDF(reference, reveal: true) }.buttonStyle(.bordered)
                    }
                } else { Text("尚未关联 PDF").foregroundStyle(.secondary) }
                Button(reference.pdfPath == nil ? "关联 PDF…" : "重新关联 PDF…") { store.attachPDF(to: reference) }.font(.caption)
            }
            if !reference.abstract.isEmpty { Divider(); field("摘要", reference.abstract) }
            Divider()
            field("阅读笔记", reference.notes.isEmpty ? "暂无笔记，点击“编辑”开始记录。" : reference.notes)
            Button("复制 BibTeX") { store.copyCitation(reference) }.buttonStyle(.bordered)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.callout).textSelection(.enabled)
        }
    }

    private var annotationContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("读取 PDF 中已有的高亮、下划线、删除线和文字批注。").font(.callout).foregroundStyle(.secondary)
            Text("文字按批注边界提取，跨行或多栏内容请与原文核对；扫描件不含 OCR。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(reading ? "正在读取…" : "读取批注") { readAnnotations() }
                    .disabled(reference.pdfPath == nil || reading)
                if !annotations.isEmpty {
                    Button("复制 Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(PDFLinks.markdown(annotations), forType: .string)
                    }
                }
            }
            Text(annotationStatus).font(.caption).foregroundStyle(.secondary)
            ForEach(annotations) { item in
                VStack(alignment: .leading, spacing: 8) {
                    Text("第 \(item.page) 页 · \(item.kind)").font(.caption).foregroundStyle(.secondary)
                    if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                    if !item.comment.isEmpty { Text(item.comment).font(.callout).textSelection(.enabled) }
                }
                Divider()
            }
        }
    }

    private func readAnnotations() {
        reading = true
        let item = reference
        Task {
            do {
                annotations = try await Task.detached { try PDFLinks.annotations(for: item) }.value
                annotationStatus = "读取到 \(annotations.count) 条批注。"
            } catch { annotationStatus = error.localizedDescription }
            reading = false
        }
    }
}

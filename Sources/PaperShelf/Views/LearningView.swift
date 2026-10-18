import SwiftUI
import AppKit
import PaperCore

struct LearningView: View {
    @ObservedObject var learning: LearningStore
    let reference: Reference
    @State private var query = ""
    @State private var selectedRun: String?
    @State private var reviewing = false
    @State private var graphing = false
    @State private var supplements: [URL] = []
    @State private var book = false
    @State private var bookJSON = "{\"auto\": true}"

    private var history: [LearningRun] { learning.runs(for: reference) }
    private var current: LearningRun? { history.first { $0.id == selectedRun } ?? history.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("研读工作台").font(.title2.bold())
            Text("将全文整理为学习网页、Markdown、可追溯字段和文献 Agent。").font(.callout).foregroundStyle(.secondary)
            Picker("生成方式", selection: $learning.settings.mode) {
                Text("原文整理草稿（离线）").tag("offline")
                Text("AI 精读").tag("llm")
            }.onChange(of: learning.settings.mode) { _, _ in learning.saveSettings() }
            if learning.settings.mode == "llm" {
                Text("全文会发送到设置中的模型服务：\(learning.settings.baseURL)").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("生成资料") { learning.generate(reference, supplements: supplements, bookJSON: book ? bookJSON : nil) }
                    .buttonStyle(.borderedProminent).disabled(reference.pdfPath == nil || learning.busy)
                Menu {
                    Button("选择其他源文档…") { learning.chooseSource(for: reference) }
                    Button("添加补充材料…") { chooseSupplements() }
                    if !supplements.isEmpty { Button("清除补充材料") { supplements = [] } }
                    Button("查看输出与日志") { learning.revealRoot() }
                } label: { Image(systemName: "ellipsis.circle") }.fixedSize().disabled(learning.busy)
                SettingsLink { Image(systemName: "gearshape") }.help("模型、自定义字段与集成设置")
            }
            if !supplements.isEmpty { Text("补充材料：\(supplements.map(\.lastPathComponent).joined(separator: "、"))").font(.caption).foregroundStyle(.secondary) }
            DisclosureGroup("书籍 / 学位论文") {
                Toggle("分章生成学习资料", isOn: $book)
                if book {
                    Text("默认按 PDF 一级书签分章。没有书签时填写 chapters 数组，每章含 title、start_page、end_page，并完整覆盖所有页。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $bookJSON).font(.system(.caption, design: .monospaced)).frame(height: 80)
                }
            }
            if learning.busy {
                HStack { ProgressView().controlSize(.small); Button("取消") { learning.cancel() } }
            }
            Text(learning.progress).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = learning.error {
                Text(error.components(separatedBy: "（已保存运行记录：").first ?? error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                if error.contains("（已保存运行记录：") {
                    DisclosureGroup("处理详情") { Text(error).font(.caption).textSelection(.enabled) }
                }
            }
            if let run = current {
                Divider()
                Picker("生成历史", selection: Binding(get: { run.id }, set: { selectedRun = $0 })) {
                    ForEach(history) { item in
                        Text("\(item.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(item.statusLabel)").tag(item.id)
                    }
                }
                artifactButtons(run)
                if ["failed", "cancelled", "interrupted"].contains(run.status ?? "") {
                    HStack {
                        Text("\(run.statusLabel) · 已保存来源与日志").font(.caption).foregroundStyle(.orange)
                        if run.revisionOf != nil {
                            Button("重新校订") { selectedRun = nil; learning.revise(run, reference: reference, retry: true) }
                                .disabled(learning.busy)
                                .help("从校订前的已完成资料重新生成新版本，失败记录仍保留。")
                        } else {
                            Button("续跑生成") { learning.generate(reference, supplements: supplements, bookJSON: book ? bookJSON : nil, resumeFrom: run.directory) }
                                .disabled(learning.busy)
                                .help("仅当原文、字段、模型和分块配置一致时复用已合格的分块；否则请重新生成。")
                        }
                    }
                }
                if run.status == "partial" { Text("部分集成未完成，请查看处理提示。").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("AI 校订正文") { selectedRun = nil; learning.revise(run, reference: reference) }
                        .disabled(learning.busy || !["completed", "partial"].contains(run.status ?? "completed"))
                        .help("使用当前模型对照原文整理全文与中文译述，另存版本，保留原资料和字段。")
                    Button("校对字段") { reviewing = true }.disabled(learning.busy || run.artifacts["extraction"] == nil)
                    Button("浏览图谱") { graphing = true }.disabled(learning.graphPath(for: run) == nil)
                }
                if learning.latestReviewedExtraction(for: run) != nil {
                    Text("字段、CSV、TSV 和图谱打开最新校对版本。").font(.caption).foregroundStyle(.secondary)
                }
                if run.artifacts["upstream_paper2agent"] != nil {
                    DisclosureGroup("Paper2Agent 工作流") {
                        Text("在独立目录运行上游论文复现工作流。此任务可在窗口关闭后继续，需单独停止。").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("启动") { learning.upstreamAction("launch", run: run) }
                            Button("状态") { learning.upstreamAction("status", run: run) }
                            Button("继续") { learning.upstreamAction("resume", run: run) }
                            Button("停止") { learning.upstreamAction("cancel", run: run) }
                        }.disabled(learning.busy)
                        if !learning.diagnostics.isEmpty { Text(learning.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }
                }
                if !run.warnings.isEmpty {
                    DisclosureGroup("缺口与处理提示（\(run.warnings.count)）") {
                        ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(.vertical, 3)
                        }
                    }
                }
                if run.artifacts["agent"] != nil {
                Divider()
                Label("询问这篇文献", systemImage: "bubble.left.and.text.bubble.right").font(.headline)
                if learning.settings.mode == "llm" {
                    Text("回答使用当前设置的 \(learning.settings.model) 模型。").font(.caption).foregroundStyle(.secondary)
                }
                TextField("例如：主要方法有哪些证据？", text: $query, axis: .vertical).lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("查询证据") { learning.ask(query, run: run) }.disabled(query.isEmpty || learning.busy)
                    Button("Agent 配置") { if let path = run.artifacts["agent"] { learning.open(path) } }
                }
                if learning.answerRunID == run.id, !learning.answer.isEmpty { Text(learning.answer).font(.callout).textSelection(.enabled) }
                }
            } else {
                ContentUnavailableView("尚无学习资料", systemImage: "book.pages", description: Text("生成结果按版本保留，原始文献保持原样。"))
            }
        }
        .sheet(isPresented: $reviewing) {
            if let run = current {
                DatasetReviewView(run: run, initialExtractionPath: learning.latestReviewedExtraction(for: run)) { data, actor, path in
                    try await learning.applyReview(data, actor: actor, extractionPath: path, run: run)
                }
            }
        }
        .sheet(isPresented: $graphing) {
            if let run = current { KnowledgeGraphView(learning: learning, run: run) }
        }
    }

    private func artifactButtons(_ run: LearningRun) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110))], alignment: .leading, spacing: 8) {
            ForEach([("html", "学习网页", "safari"), ("markdown", "研读 MD", "doc.text"), ("source_markdown", "全文 MD", "doc.plaintext"),
                     ("book_index", "章节目录", "list.bullet"),
                     ("extraction", "字段与证据", "tablecells"), ("graph", "知识图谱", "point.3.connected.trianglepath.dotted"),
                     ("csv", "数据集 CSV", "tablecells"), ("tsv", "数据集 TSV", "tablecells")], id: \.0) { key, title, icon in
                if let path = learning.artifactPath(key, for: run) { Button { learning.open(path) } label: { Label(title, systemImage: icon) }.buttonStyle(.bordered) }
            }
            if learning.artifactPath("raw_source_markdown", for: run) != nil {
                Menu("来源对照", systemImage: "text.magnifyingglass") {
                    ForEach([("raw_source_markdown", "原始提取 MD"), ("source_index", "逐块来源索引"), ("paragraph_markdown", "逐段译述记录")], id: \.0) { key, title in
                        if let path = learning.artifactPath(key, for: run) { Button(title) { learning.open(path) } }
                    }
                }
            }
            Button { learning.open(run.directory) } label: { Label("全部产物", systemImage: "folder") }.buttonStyle(.bordered)
        }
    }
    private func chooseSupplements() {
        let panel = NSOpenPanel(); panel.title = "选择补充材料"; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { supplements = panel.urls }
    }
}

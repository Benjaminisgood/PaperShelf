import SwiftUI
import AppKit
import PaperCore

struct LearningView: View {
    @ObservedObject var learning: LearningStore
    let reference: Reference
    @State private var query = ""
    @State private var selectedRun: String?
    @State private var reviewRun: LearningRun?
    @State private var graphRun: LearningRun?
    @State private var sourceOverride: URL?
    @State private var supplements: [URL] = []
    @State private var book = false
    @State private var bookJSON = "{\"auto\": true}"

    private let outputs: [LearningOutput] = [.presentation, .guide, .markdown, .source, .dataset, .agent]
    private var history: [LearningRun] { learning.runs(for: reference) }
    private var current: LearningRun? { history.first { $0.id == selectedRun } ?? history.first }
    private var hasSource: Bool { sourceOverride != nil || reference.pdfPath != nil }
    private var isActiveReference: Bool { learning.activeReferenceID == reference.id.uuidString }
    private var showsOperation: Bool { isActiveReference || learning.activeReferenceID == nil }
    private var canGenerate: Bool { hasSource && !learning.busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            overview
            generationMode
            if learning.busy || (showsOperation && learning.error != nil) { operationStatus }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("生成与阅读").font(.headline)
                    Spacer()
                    Text("按需生成 · 版本保留").font(.caption2).foregroundStyle(.secondary)
                }
                ForEach(outputs) { output in outputRow(output) }
            }
            if let agentRun = latestRun(for: .agent) { agentSection(agentRun) }
            sourceOptions
            if let run = current { historySection(run) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $reviewRun) { run in
            DatasetReviewView(run: run, initialExtractionPath: learning.latestReviewedExtraction(for: run)) { data, actor, path in
                try await learning.applyReview(data, actor: actor, extractionPath: path, run: run)
            }
        }
        .sheet(item: $graphRun) { run in KnowledgeGraphView(learning: learning, run: run) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("文献研读", systemImage: "book.closed").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain).help("模型、字段与集成设置")
            }
            Text(reference.title.isEmpty ? "未命名文献" : reference.title)
                .font(.headline).lineLimit(3).textSelection(.enabled).help(reference.title)
            if !reference.authors.isEmpty || !reference.year.isEmpty {
                Text(([reference.authors.prefix(2).joined(separator: "、"), reference.year].filter { !$0.isEmpty }).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !hasSource {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "doc.badge.plus")
                    Text("先选择源文档，再生成需要的成果。")
                    Spacer(minLength: 0)
                    Button("选择…") { chooseSource() }.controlSize(.small)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var generationMode: some View {
        VStack(alignment: .leading, spacing: 7) {
            Picker("生成方式", selection: $learning.settings.mode) {
                Text("离线整理").tag("offline")
                Text("AI 精读").tag("llm")
            }.pickerStyle(.segmented).labelsHidden().disabled(learning.busy)
                .onChange(of: learning.settings.mode) { _, _ in learning.saveSettings() }
            if learning.settings.mode == "llm" {
                Text("AI 精读将全文发送至 \(learning.settings.model) 模型服务；全文 Markdown 与 Agent 创建在本机完成。")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(learning.settings.baseURL)
            } else {
                Text("保留全文与出处，生成便于编辑的草稿。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func outputRow(_ output: LearningOutput) -> some View {
        let run = latestRun(for: output)
        return LearningOutputRow(output: output, run: run,
                                 isGenerating: learning.busy && isActiveReference && learning.activeOutput == output,
                                 canGenerate: canGenerate,
                                 generate: { generate(output) },
                                 open: { if let run { open(output, run: run) } }) {
            Button(run == nil ? "生成\(output.title)" : "重新生成新版本") { generate(output) }.disabled(!canGenerate)
            if let run {
                Divider()
                artifactMenu(output, run: run)
                if output == .dataset {
                    Button("校对字段…") { reviewRun = run }.disabled(learning.busy || run.artifacts["extraction"] == nil)
                    Button("浏览知识图谱…") { graphRun = run }.disabled(learning.graphPath(for: run) == nil)
                }
                let versions = availableRuns(for: output)
                if versions.count > 1 {
                    Menu("历史版本（\(versions.count)）") {
                        ForEach(versions) { version in
                            Button(versionLabel(version)) { open(output, run: version) }
                        }
                    }
                }
                Divider()
                Button("查看产物文件夹") { learning.open(run.directory) }
            }
        }
    }

    @ViewBuilder private var operationStatus: some View {
        if learning.busy {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(isActiveReference ? "正在处理\(learning.activeOutput?.title ?? "研读任务")" : "研读任务进行中")
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 4)
                    Button("取消") { learning.cancel() }.controlSize(.small)
                }
                Text(showsOperation ? learning.progress : "其他文献正在处理，完成后即可生成。")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(11).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
        }
        if showsOperation, let error = learning.error {
            VStack(alignment: .leading, spacing: 8) {
                Label("本次处理未完成", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.orange)
                Text(error.components(separatedBy: "（已保存运行记录：").first ?? error)
                    .font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                HStack {
                    SettingsLink { Text("检查模型设置") }
                    Button("输出与日志") { learning.revealRoot() }
                }.controlSize(.small)
                DisclosureGroup("完整错误") { Text(error).font(.caption.monospaced()).textSelection(.enabled) }
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(11).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var sourceOptions: some View {
        DisclosureGroup("源文档与生成选项") {
            VStack(alignment: .leading, spacing: 12) {
                Text(sourceOverride?.lastPathComponent ?? reference.pdfPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "尚未选择源文档")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("选择其他源文档…") { chooseSource() }
                    if sourceOverride != nil { Button("恢复原附件") { sourceOverride = nil } }
                }.controlSize(.small)
                HStack {
                    Button("添加补充材料…") { chooseSupplements() }
                    if !supplements.isEmpty { Button("清除") { supplements = [] } }
                }.controlSize(.small)
                if !supplements.isEmpty {
                    Text(supplements.map(\.lastPathComponent).joined(separator: "、")).font(.caption).foregroundStyle(.secondary)
                }
                DisclosureGroup("书籍 / 学位论文") {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("按章节生成", isOn: $book)
                        if book {
                            Text("默认按 PDF 一级书签分章。也可填写 chapters 数组，每章含 title、start_page、end_page，并完整覆盖所有页。")
                                .font(.caption).foregroundStyle(.secondary)
                            TextEditor(text: $bookJSON).font(.caption.monospaced()).frame(height: 90)
                        }
                    }.padding(.top, 8)
                }
                Text("生成结果另存为新版本，原始文献与已有资料保留。")
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 10).disabled(learning.busy)
        }.font(.callout)
    }

    private func historySection(_ run: LearningRun) -> some View {
        DisclosureGroup("生成记录（\(history.count)）") {
            VStack(alignment: .leading, spacing: 11) {
                Picker("版本", selection: Binding(get: { run.id }, set: { selectedRun = $0 })) {
                    ForEach(history) { item in Text(versionLabel(item)).tag(item.id) }
                }
                Text(run.outputs?.compactMap { LearningOutput(rawValue: $0)?.title }.joined(separator: "、") ?? "完整研读资料")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Menu("打开资料") {
                        ForEach(outputs) { output in artifactMenu(output, run: run) }
                    }
                    Button("文件夹") { learning.open(run.directory) }
                }.controlSize(.small)
                if ["failed", "cancelled", "interrupted"].contains(run.status ?? "") {
                    Text("\(run.statusLabel) · 来源与日志已保存").font(.caption).foregroundStyle(.orange)
                    if run.revisionOf != nil {
                        Button("重新校订") { selectedRun = nil; learning.revise(run, reference: reference, retry: true) }.disabled(learning.busy)
                    } else {
                        Button("续跑本次生成") { resume(run) }.disabled(learning.busy)
                            .help("恢复本次运行的源文档与生成选项，使用当前模型连接设置继续处理。")
                    }
                }
                HStack {
                    Button("AI 校订正文") { selectedRun = nil; learning.revise(run, reference: reference) }
                        .disabled(learning.busy || !["completed", "partial"].contains(run.status ?? "completed") || run.artifacts["learning"] == nil)
                    Button("校对字段") { reviewRun = run }.disabled(learning.busy || run.artifacts["extraction"] == nil)
                }.controlSize(.small)
                if learning.latestReviewedExtraction(for: run) != nil {
                    Text("字段、数据表与图谱打开最新校对版本。").font(.caption).foregroundStyle(.secondary)
                }
                if run.artifacts["upstream_paper2agent"] != nil { upstreamSection(run) }
                if !run.warnings.isEmpty {
                    DisclosureGroup("处理提示（\(run.warnings.count)）") {
                        ForEach(Array(run.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).textSelection(.enabled).padding(.vertical, 3)
                        }
                    }.font(.caption)
                }
            }.padding(.top, 10)
        }.font(.callout)
    }

    private func agentSection(_ run: LearningRun) -> some View {
        DisclosureGroup("询问这篇文献") {
            VStack(alignment: .leading, spacing: 10) {
                Text("依据 \(run.createdAt.formatted(date: .abbreviated, time: .shortened)) 的文献 Agent 查询证据。")
                    .font(.caption).foregroundStyle(.secondary)
                if learning.settings.mode == "llm" {
                    Text("AI 问答将问题与相关原文发送至当前模型服务。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                TextField("例如：主要方法有哪些证据？", text: $query, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
                HStack {
                    Button("查询证据") { learning.ask(query, run: run) }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || learning.busy)
                    Button("Agent 配置") { open(.agent, run: run) }
                }.controlSize(.small)
                if learning.answerRunID == run.id, !learning.answer.isEmpty {
                    Text(learning.answer).font(.callout).textSelection(.enabled)
                }
            }.padding(.top, 10)
        }.font(.callout)
    }

    private func upstreamSection(_ run: LearningRun) -> some View {
        DisclosureGroup("Paper2Agent 工作流") {
            VStack(alignment: .leading, spacing: 8) {
                Text("独立工作目录中的论文复现任务可在窗口关闭后继续，需单独停止。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("启动") { learning.upstreamAction("launch", run: run) }
                    Button("状态") { learning.upstreamAction("status", run: run) }
                    Button("继续") { learning.upstreamAction("resume", run: run) }
                    Button("停止") { learning.upstreamAction("cancel", run: run) }
                }.controlSize(.small).disabled(learning.busy)
                if !learning.diagnostics.isEmpty { Text(learning.diagnostics).font(.caption.monospaced()).textSelection(.enabled) }
            }.padding(.top, 8)
        }.font(.caption)
    }

    @ViewBuilder private func artifactMenu(_ output: LearningOutput, run: LearningRun) -> some View {
        ForEach(output.artifactKeys, id: \.self) { key in
            if let path = learning.artifactPath(key, for: run) {
                Button(learningArtifactTitle(key)) { learning.open(path) }
            }
        }
    }

    private func availableRuns(for output: LearningOutput) -> [LearningRun] {
        history.filter { run in
            guard ["completed", "partial"].contains(run.status ?? "completed"),
                  let path = learning.artifactPath(output.primaryArtifactKey, for: run) else { return false }
            return FileManager.default.fileExists(atPath: path)
        }
    }
    private func latestRun(for output: LearningOutput) -> LearningRun? { availableRuns(for: output).first }
    private func open(_ output: LearningOutput, run: LearningRun) {
        if let path = learning.artifactPath(output.primaryArtifactKey, for: run) { learning.open(path) }
    }
    private func generate(_ output: LearningOutput) {
        selectedRun = nil
        let chapters = book && [.guide, .markdown].contains(output) ? bookJSON : nil
        learning.generate(reference, sourceOverride: sourceOverride, supplements: supplements, bookJSON: chapters, output: output)
    }
    private func resume(_ run: LearningRun) {
        selectedRun = nil
        let output = run.outputs?.count == 1 ? run.outputs?.first.flatMap(LearningOutput.init(rawValue:)) : nil
        let chapters = book && (output == nil || output == .guide || output == .markdown) ? bookJSON : nil
        learning.generate(reference, sourceOverride: sourceOverride, supplements: supplements, bookJSON: chapters, resumeFrom: run.directory, output: output)
    }
    private func versionLabel(_ run: LearningRun) -> String {
        let output = run.outputs?.compactMap { LearningOutput(rawValue: $0)?.title }.joined(separator: "、") ?? "完整资料"
        return "\(run.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(output) · \(run.statusLabel)"
    }
    private func chooseSource() {
        let panel = NSOpenPanel(); panel.title = "选择用于研读的 PDF、Markdown、Word 或其他文档"
        if panel.runModal() == .OK { sourceOverride = panel.url }
    }
    private func chooseSupplements() {
        let panel = NSOpenPanel(); panel.title = "选择补充材料"; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { supplements = panel.urls }
    }
}

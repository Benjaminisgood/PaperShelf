import SwiftUI
import PaperCore

struct KnowledgeGraphView: View {
    @ObservedObject var learning: LearningStore
    let run: LearningRun
    @Environment(\.dismiss) private var dismiss
    @State private var nodes: [GraphNode] = []
    @State private var edges: [GraphEdge] = []
    @State private var selected: String?
    @State private var query = ""
    @State private var filters = "[]"
    @State private var result = ""
    @State private var cards: [GraphSearchCard] = []
    @State private var remoteResults = false
    @State private var error: String?
    private let kinds = ["document", "record", "fact", "evidence"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("知识与证据图谱").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("本地图谱连接文献、条件记录、字段值与原句。Graphiti 查询会连接已配置的时序知识图谱服务。").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("关键词（本地留空可列出全部事实）", text: $query).textFieldStyle(.roundedBorder)
                Button("查询本地") { search(remote: false) }.disabled(learning.busy)
                Button("查询 Graphiti") { search(remote: true) }.disabled(learning.busy || query.isEmpty)
            }
            DisclosureGroup("字段过滤条件（JSON）") {
                TextField("例如 [{\"field\":\"temperature\",\"op\":\"gte\",\"value\":400,\"unit\":\"K\"}]", text: $filters).textFieldStyle(.roundedBorder)
            }
            if learning.busy { HStack { ProgressView().controlSize(.small); Text(learning.progress).font(.caption); Button("取消") { learning.cancel() } } }
            if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            HSplitView {
                ScrollView([.horizontal, .vertical]) {
                    graph.frame(width: 1120, height: graphHeight)
                }.frame(minWidth: 480)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let node = nodes.first(where: { $0.id == selected }) {
                            Text(node.label).font(.headline)
                            Text(node.details).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        if !result.isEmpty {
                            Divider(); Text("查询结果 · \(cards.count) 条").font(.headline)
                            if remoteResults {
                                Text("模型抽取结果尚未人工确认；数值、单位和公式请对照原始 PDF。来源文字可能含提取误差。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if cards.isEmpty { Text("没有找到匹配的已记录事实。").foregroundStyle(.secondary) }
                            ForEach(cards) { card in
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(card.title).font(.headline)
                                    Text(card.detail).textSelection(.enabled)
                                    if !card.source.isEmpty {
                                        DisclosureGroup("出处与时间") { Text(card.source).font(.caption).textSelection(.enabled) }
                                    }
                                    ForEach(card.sourceFiles, id: \.self) { path in
                                        Button("打开 \(URL(fileURLWithPath: path).lastPathComponent)") { learning.open(path) }
                                            .disabled(!FileManager.default.fileExists(atPath: path))
                                    }
                                    ForEach(card.warnings, id: \.self) { warning in
                                        Text(warning).font(.caption).foregroundStyle(.orange)
                                    }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            }
                            DisclosureGroup("完整数据") { Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        }
                        if selected == nil && result.isEmpty { Text("选择节点查看原始值、单位与出处。").foregroundStyle(.secondary) }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(minWidth: 280, idealWidth: 330)
            }
            Text("\(nodes.count) 个节点 · \(edges.count) 条连接 · 已校对版本优先显示；学习网页保持生成时内容。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(minWidth: 900, minHeight: 650)
        .task { load() }
    }

    private var graphHeight: CGFloat { CGFloat(max(5, kinds.map { kind in nodes.filter { $0.kind == kind }.count }.max() ?? 1)) * 78 + 70 }
    private func position(_ id: String) -> CGPoint? {
        for (column, kind) in kinds.enumerated() {
            if let index = nodes.filter({ $0.kind == kind }).firstIndex(where: { $0.id == id }) {
                return CGPoint(x: CGFloat(column) * 275 + 140, y: CGFloat(index) * 78 + 80)
            }
        }
        return nil
    }
    private var graph: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for edge in edges {
                    guard let from = position(edge.source), let to = position(edge.target) else { continue }
                    var path = Path(); path.move(to: CGPoint(x: from.x + 120, y: from.y)); path.addLine(to: CGPoint(x: to.x - 120, y: to.y))
                    context.stroke(path, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                }
            }
            ForEach(Array(kinds.enumerated()), id: \.offset) { index, kind in
                Text(["文献", "条件记录", "字段事实", "原文证据"][index]).font(.headline).position(x: CGFloat(index) * 275 + 140, y: 25)
            }
            ForEach(nodes) { node in
                if let point = position(node.id) {
                    Button { selected = node.id } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(node.label).font(.callout.weight(.medium)).lineLimit(2)
                            Text(["document": "文献", "record": "条件记录", "fact": "字段值", "evidence": "出处"][node.kind] ?? node.kind).font(.caption2).foregroundStyle(.secondary)
                        }.frame(width: 214, height: 52, alignment: .leading).padding(6)
                    }.buttonStyle(.bordered).tint(node.id == selected ? .accentColor : .secondary).position(point)
                }
            }
        }
    }
    private func load() {
        do {
            guard let path = learning.graphPath(for: run) else { throw LearningError.message("没有证据图谱文件。") }
            guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { return }
            nodes = try (object["nodes"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? String, let kind = value["type"] as? String else { return nil }
                let label = value["label"] as? String ?? value["field"] as? String ?? value["quote"] as? String ?? (kind == "document" ? run.title : id)
                let details = String(data: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? ""
                return GraphNode(id: id, kind: kind, label: label, details: details)
            }
            edges = (object["edges"] as? [[String: String]] ?? []).compactMap { value in
                guard let source = value["source"], let target = value["target"] else { return nil }
                return GraphEdge(source: source, target: target)
            }
        } catch { self.error = error.localizedDescription }
    }
    private func search(remote: Bool) {
        error = nil
        Task {
            do {
                result = try await learning.queryGraph(query, filters: filters, run: run, remote: remote)
                cards = searchCards(result, remote: remote)
                remoteResults = remote
            }
            catch { self.error = error.localizedDescription }
        }
    }

    private func searchCards(_ text: String, remote: Bool) -> [GraphSearchCard] {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return [] }
        if remote {
            return (object["facts"] as? [[String: Any]] ?? []).enumerated().map { index, fact in
                let sourceObjects = fact["sources"] as? [[String: Any]] ?? []
                let sources = sourceObjects.map { source in
                    [source["name"] as? String, source["content"] as? String].compactMap { $0 }.joined(separator: "\n")
                }.joined(separator: "\n\n")
                let times = ["valid_at", "invalid_at"].compactMap { key in
                    (fact[key] as? String).map { "\(key == "valid_at" ? "图谱生效时间" : "图谱失效时间")：\($0)" }
                }.joined(separator: "\n")
                return GraphSearchCard(id: fact["uuid"] as? String ?? String(index), title: "事实 \(index + 1)",
                                       detail: fact["fact"] as? String ?? "", source: [times, sources].filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                       sourceFiles: Array(Set(sourceObjects.flatMap { source in
                                           [source["source_path"] as? String, source["markdown_path"] as? String].compactMap { $0 }.filter { $0.hasPrefix("/") }
                                       })).sorted(), warnings: fact["source_warnings"] as? [String] ?? [])
            }
        }
        return (object["records"] as? [[String: Any]] ?? []).enumerated().map { index, record in
            let facts = record["facts"] as? [[String: Any]] ?? []
            let details = facts.map { fact -> String in
                let value: String
                if let data = try? JSONSerialization.data(withJSONObject: fact["value"] ?? NSNull(), options: [.fragmentsAllowed, .sortedKeys]),
                   let text = String(data: data, encoding: .utf8) { value = text }
                else { value = "未提取" }
                return "\(fact["field"] as? String ?? "字段")：\(value) \(fact["unit"] as? String ?? "")\(fact["status"] as? String == "conflict" ? "（证据冲突）" : "")"
            }.joined(separator: "\n")
            return GraphSearchCard(id: record["record_id"] as? String ?? String(index), title: record["label"] as? String ?? "条件记录",
                                   detail: details, source: "点击图中的原文证据节点查看页码与引用。")
        }
    }
}

private struct GraphNode: Identifiable { var id: String; var kind: String; var label: String; var details: String }
private struct GraphEdge { var source: String; var target: String }
private struct GraphSearchCard: Identifiable {
    var id: String; var title: String; var detail: String; var source: String
    var sourceFiles: [String] = []
    var warnings: [String] = []
}

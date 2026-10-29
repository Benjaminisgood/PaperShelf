import SwiftUI
import PaperCore

extension LearningOutput {
    var title: String {
        switch self {
        case .presentation: return "文献 PPT"
        case .guide: return "学习网页"
        case .markdown: return "研读 Markdown"
        case .source: return "全文 Markdown"
        case .dataset: return "字段与证据"
        case .agent: return "文献 Agent"
        }
    }

    var symbol: String {
        switch self {
        case .presentation: return "rectangle.stack"
        case .guide: return "book.pages"
        case .markdown: return "doc.text"
        case .source: return "doc.plaintext"
        case .dataset: return "tablecells"
        case .agent: return "bubble.left.and.text.bubble.right"
        }
    }

    var artifactKeys: [String] {
        switch self {
        case .presentation: return ["presentation", "presentation_preview", "presentation_outline"]
        case .guide: return ["html", "book_index", "full_html"]
        case .markdown: return ["markdown", "book_markdown_index", "full_markdown"]
        case .source: return ["source_markdown", "raw_source_markdown", "source_index", "paragraph_markdown"]
        case .dataset: return ["extraction", "csv", "tsv", "jsonl", "sqlite", "graph"]
        case .agent: return ["agent", "mcp"]
        }
    }

    var primaryArtifactKey: String { artifactKeys[0] }
}

struct LearningOutputRow<Actions: View>: View {
    let output: LearningOutput
    let run: LearningRun?
    let isGenerating: Bool
    let canGenerate: Bool
    let generate: () -> Void
    let open: () -> Void
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            Image(systemName: output.symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(output == .presentation ? Color.accentColor : Color.secondary)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(output.title).font(.callout.weight(.semibold))
                    if run != nil {
                        Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
                            .accessibilityLabel("已有资料")
                    }
                }
                if isGenerating {
                    Text("正在处理…").font(.caption).foregroundStyle(.secondary)
                }
                if let run, !isGenerating {
                    Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if isGenerating {
                ProgressView().controlSize(.small).frame(width: 48)
            } else if run != nil {
                Button("打开", action: open).controlSize(.small)
                    .help("打开最新的\(output.title)")
            } else {
                Button("生成", action: generate).controlSize(.small)
                    .buttonStyle(.borderedProminent).disabled(!canGenerate)
                    .help("仅生成\(output.title)，其他成果按需生成")
            }
            Menu(content: actions) { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).fixedSize().frame(width: 18)
                .help("\(output.title)的操作与版本")
        }
        .padding(.vertical, 12).padding(.horizontal, 12)
        .background(output == .presentation ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            if output == .presentation {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.14), lineWidth: 1)
            }
        }
    }
}

func learningArtifactTitle(_ key: String) -> String {
    ["presentation": "PowerPoint 幻灯片", "presentation_preview": "幻灯片预览", "presentation_outline": "幻灯片大纲",
     "html": "学习网页", "markdown": "研读 Markdown", "source_markdown": "全文 Markdown", "book_index": "章节目录",
     "full_html": "完整学习网页", "full_markdown": "完整研读 Markdown", "book_markdown_index": "Markdown 章节目录",
     "raw_source_markdown": "原始提取 Markdown", "source_index": "逐块来源索引", "paragraph_markdown": "逐段译述记录",
     "extraction": "字段与证据 JSON", "csv": "数据表 CSV", "tsv": "数据表 TSV", "jsonl": "数据集 JSONL", "sqlite": "数据集 SQLite",
     "graph": "知识图谱文件", "agent": "Agent 配置", "mcp": "MCP 配置"][key] ?? key
}

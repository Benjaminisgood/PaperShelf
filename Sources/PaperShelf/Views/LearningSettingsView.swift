import SwiftUI
import AppKit
import PaperCore

struct LearningSettingsView: View {
    @ObservedObject var learning: LearningStore
    @State private var section = 0
    @State private var secret = ""
    @State private var secretChanged = false
    @State private var saved = ""
    @State private var graphPassword = ""
    @State private var embeddingKey = ""
    @State private var savingCredentials = false

    var body: some View {
        VStack(spacing: 12) {
            Picker("研读设置", selection: $section) {
                Text("模型").tag(0)
                Text("自定义字段").tag(1)
                Text("运行环境").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 16)
            if section == 0 { modelSettings }
            else if section == 1 { fieldSettings.padding(.horizontal, 20) }
            else { integrationSettings }
        }
        .frame(minWidth: 680, minHeight: 520)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(learning.error ?? saved).font(.caption).foregroundStyle(learning.error == nil ? Color.secondary : Color.red).lineLimit(3)
                Spacer()
                if savingCredentials { ProgressView().controlSize(.small) }
                Button("保存设置") { save() }
                    .disabled(savingCredentials).keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            }.padding(20)
        }
    }

    private var modelSettings: some View {
        Form {
            Section("自动处理") {
                Toggle("导入或关联 PDF 后自动生成", isOn: $learning.settings.automaticallyGenerate)
                Picker("生成方式", selection: $learning.settings.mode) {
                    Text("原文整理草稿（离线）").tag("offline")
                    Text("AI 精读").tag("llm")
                }
                Text("离线模式保留原文和出处；AI 模式生成讲解、自测与字段，需要配置可用模型。").font(.caption).foregroundStyle(.secondary)
            }
            Section("模型服务 · OpenAI 兼容接口") {
                TextField("接口地址", text: $learning.settings.baseURL)
                TextField("模型名称", text: $learning.settings.model)
                TextField("密钥环境变量", text: $learning.settings.apiKeyEnvironment)
                SecureField("服务密钥（可选，保存到 macOS 钥匙串）", text: $secret)
                    .onChange(of: secret) { _, _ in secretChanged = true }
                Text("已填入阿里云 Token Plan 地址，请选择该服务支持的模型。远程模型会接收全文和问题；密钥存入钥匙串。空输入保留已有密钥。").font(.caption).foregroundStyle(.secondary)
                if ProcessInfo.processInfo.environment[learning.settings.apiKeyEnvironment]?.isEmpty == false {
                    Text("当前会话已配置密钥；退出后使用钥匙串中的设置。").font(.caption).foregroundStyle(.secondary)
                }
                Button("清除已保存的密钥") {
                    savingCredentials = true
                    Task {
                        defer { savingCredentials = false }
                        do {
                            try await Task.detached { try ProviderSecret.save("") }.value
                            saved = "已清除密钥"
                        } catch { learning.error = error.localizedDescription }
                    }
                }.disabled(savingCredentials)
                HStack {
                    Button("测试已保存的模型连接") { learning.probeProvider() }.disabled(learning.busy)
                    Button("读取可用模型") { learning.probeProvider(models: true) }.disabled(learning.busy)
                }
                DisclosureGroup("生成参数") {
                    TextField("每批原文字符数", value: $learning.settings.chunkCharacters, format: .number)
                    Text("控制单次请求大小，全部原文仍会逐批处理。更换服务时可调整下方参数。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $learning.settings.providerJSON).font(.system(.caption, design: .monospaced)).frame(height: 85)
                }
                if !learning.diagnostics.isEmpty { DisclosureGroup("连接结果") { Text(learning.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) } }
            }
            Section("读者背景") {
                TextEditor(text: $learning.settings.readerContext).font(.body).frame(height: 100)
                Text("填写研究主题、熟悉的方法及希望理解的问题，用于知识迁移部分。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func save() {
        learning.error = nil
        learning.saveSettings()
        guard learning.error == nil else { return }
        let providerValue = secretChanged ? secret : ""
        let graphValue = graphPassword
        let embeddingValue = embeddingKey
        guard !providerValue.isEmpty || !graphValue.isEmpty || !embeddingValue.isEmpty else { saved = "已保存"; return }
        savingCredentials = true
        saved = "配置已保存，正在等待钥匙串…"
        Task {
            defer { savingCredentials = false }
            do {
                try await Task.detached {
                    if !providerValue.isEmpty { try ProviderSecret.save(providerValue) }
                    if !graphValue.isEmpty { try ProviderSecret.save(graphValue, account: "graph-password") }
                    if !embeddingValue.isEmpty { try ProviderSecret.save(embeddingValue, account: "embedding-key") }
                }.value
                if secret == providerValue { secret = ""; secretChanged = false }
                if graphPassword == graphValue { graphPassword = "" }
                if embeddingKey == embeddingValue { embeddingKey = "" }
                saved = "设置和密钥已保存"
            } catch { learning.error = error.localizedDescription }
        }
    }

    private var fieldSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("字段决定提取内容、类型及表格列。未在原文找到的值保留为空，并列出出处。").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(learning.settings.fields.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                TextField("字段名", text: $learning.settings.fields[index].name).textFieldStyle(.roundedBorder)
                                Picker("类型", selection: $learning.settings.fields[index].type) {
                                    Text("文本").tag("string"); Text("数值").tag("number"); Text("整数").tag("integer")
                                    Text("布尔").tag("boolean"); Text("列表").tag("array"); Text("对象").tag("object")
                                }.frame(width: 160)
                                Button(role: .destructive) { learning.settings.fields.remove(at: index) } label: { Image(systemName: "minus.circle") }.help("删除字段")
                            }
                            TextField("提取说明", text: $learning.settings.fields[index].description, axis: .vertical).textFieldStyle(.roundedBorder)
                            HStack {
                                TextField("单位（可选）", text: $learning.settings.fields[index].unit).textFieldStyle(.roundedBorder)
                                Toggle("必填", isOn: $learning.settings.fields[index].required)
                            }
                            if learning.settings.fields[index].type == "string" {
                                TextField("允许值（可选，以逗号分隔）", text: Binding(get: {
                                    (learning.settings.fields[index].choices ?? []).joined(separator: ", ")
                                }, set: { value in
                                    let values = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                                    learning.settings.fields[index].choices = values.isEmpty ? nil : values
                                })).textFieldStyle(.roundedBorder)
                            }
                        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            HStack {
                Button("添加字段", systemImage: "plus") { learning.settings.fields.append(.init(name: "field_\(UUID().uuidString.prefix(6))")) }
                Button("导入字段 JSON…") { importFields() }
                Button("导出字段 JSON…") { exportFields() }
                Spacer()
            }
        }.padding(.top, 12)
    }

    private var integrationSettings: some View {
        Form {
            Section("运行环境") {
                TextField("Python（留空自动检测）", text: $learning.settings.pythonPath)
                Text(learning.pythonPath).font(.caption).textSelection(.enabled).foregroundStyle(.secondary)
                TextField("后端目录（留空使用内置）", text: $learning.settings.backendPath)
                HStack {
                    Button("安装运行环境") { learning.installRuntime() }.disabled(learning.busy)
                    Button("检查集成状态") { learning.command(["doctor"]) }.disabled(learning.busy)
                    Button("输出与日志") { learning.revealRoot() }
                }
                if learning.busy { HStack { ProgressView().controlSize(.small); Text(learning.progress).font(.caption); Button("取消") { learning.cancel() } } }
            }
            Section("Graphiti · 时间知识图谱") {
                Text("生成时将有出处的文献知识写入本地图数据库。默认使用本地多语言嵌入模型，首次需下载模型；也可改用独立嵌入 API。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $learning.settings.graphitiJSON).font(.system(.caption, design: .monospaced)).frame(height: 85)
                SecureField("图数据库密码（保存到钥匙串）", text: $graphPassword)
                SecureField("嵌入服务密钥（可选，保存到钥匙串）", text: $embeddingKey)
                Button("载入 Graphiti 配置示例") { loadExample("graphiti") }
                HStack {
                    Button("启动本地图谱") { learning.graphService("start") }
                    Button("服务状态") { learning.graphService("status") }
                    Button("停止服务") { learning.graphService("stop") }
                }.disabled(learning.busy)
                Text("本机部署的服务密码从受限的本地服务配置读取；远程数据库使用钥匙串。停止服务保留数据。").font(.caption).foregroundStyle(.secondary)
            }
            Section("Paper2Agent · 上游工作流") {
                Text("调用独立的 Codex / Claude 编程宿主，复现论文代码并生成工具。设置启用后会在新工作目录运行上游技能；执行日志独立保留。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $learning.settings.paper2agentJSON).font(.system(.caption, design: .monospaced)).frame(height: 85)
                Button("载入 Paper2Agent 配置示例") { loadExample("paper2agent") }
            }
            if !learning.diagnostics.isEmpty {
                Section("检查结果") { Text(learning.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
            }
        }.formStyle(.grouped)
    }

    private func loadExample(_ key: String) {
        let path = URL(fileURLWithPath: learning.backendPath).deletingLastPathComponent().appendingPathComponent("integrations/config.example.json")
        do {
            let data = try Data(contentsOf: path)
            guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var section = config[key] as? [String: Any] else { return }
            if key == "graphiti" {
                section["endpoint"] = learning.settings.baseURL
                section["model"] = learning.settings.model
                section["api_key_environment"] = learning.settings.apiKeyEnvironment
                section["omit_temperature"] = true
                section["embedding_backend"] = "fastembed"
                section["local_embedding_model"] = "sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
            }
            let json = String(data: try JSONSerialization.data(withJSONObject: section, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}"
            if key == "graphiti" { learning.settings.graphitiJSON = json }
            else { learning.settings.paper2agentJSON = json }
        } catch { learning.error = error.localizedDescription }
    }

    private func importFields() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fields = try JSONDecoder().decode([ExtractionField].self, from: Data(contentsOf: url))
            try ExtractionField.validate(fields); learning.settings.fields = fields
        } catch { learning.error = error.localizedDescription }
    }
    private func exportFields() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "fields.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ExtractionField.validate(learning.settings.fields)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(learning.settings.fields).write(to: url, options: .atomic)
        } catch { learning.error = error.localizedDescription }
    }
}

import SwiftUI
import AppKit
import PaperCore

struct LearningSettingsView: View {
    @ObservedObject var learning: LearningStore
    @State private var section = 0
    @StateObject private var credentials = SettingsCredentialStore()
    @State private var saved = ""
    @State private var savingSettings = false
    private var savingCredentials: Bool { savingSettings || credentials.loading || credentials.saving }

    var body: some View {
        VStack(spacing: 12) {
            Picker("研读设置", selection: $section) {
                Text("模型与 API").tag(0)
                Text("知识图谱").tag(1)
                Text("自定义字段").tag(2)
                Text("高级").tag(3)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 16)
            if section == 0 { modelSettings }
            else if section == 1 {
                GraphConnectionSettingsView(learning: learning,
                    graphPassword: credentials.binding(.graphPassword),
                    graphAPIKey: credentials.binding(.graphProvider),
                    embeddingKey: credentials.binding(.embedding),
                    onService: { action in save { learning.graphService(action) } },
                    credentialStatus: { account in
                        CredentialPlan.Secret(rawValue: account).map(credentials.status) ?? ""
                    })
            }
            else if section == 2 { fieldSettings.padding(.horizontal, 20) }
            else { integrationSettings }
        }
        .disabled(savingSettings)
        .frame(minWidth: 680, minHeight: 520)
        .task { await credentials.load() }
        .onChange(of: learning.settings) { _, _ in saved = "" }
        .onChange(of: credentials.values) { old, new in
            saved = ""
            if old[.provider] != new[.provider] { learning.providerConnectionStatus = ""; learning.availableModels = [] }
        }
        .onChange(of: learning.settings.baseURL) { _, _ in learning.providerConnectionStatus = ""; learning.availableModels = [] }
        .onChange(of: learning.settings.model) { _, _ in learning.providerConnectionStatus = "" }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(LocalizedStringKey(learning.error ?? saved)).font(.caption).foregroundStyle(learning.error == nil ? Color.secondary : Color.red).lineLimit(3)
                Spacer()
                if savingCredentials { ProgressView().controlSize(.small) }
                Button(savingSettings ? "正在保存…" : "保存设置") { save() }
                    .disabled(savingCredentials).keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
            }.padding(20)
        }
    }

    private var modelSettings: some View {
        Form {
            Section("模型连接") {
                Text("填入服务地址、模型名称和 API Key 即可使用。支持 OpenAI 兼容服务，也支持本地模型。")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("API 地址", text: $learning.settings.baseURL)
                    .autocorrectionDisabled()
                HStack {
                    TextField("模型名称", text: $learning.settings.model).autocorrectionDisabled()
                    if !learning.availableModels.isEmpty {
                        Menu("选择模型") {
                            ForEach(learning.availableModels, id: \.self) { model in
                                Button(model) { learning.settings.model = model }
                            }
                        }.fixedSize()
                    }
                }
                SettingsSecretField(title: "API Key", text: credentials.binding(.provider), status: credentials.status(.provider))
                Text("直接粘贴即可，保存后会记住。无需密钥的本地服务可留空。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("保存并测试连接") { save { learning.probeProvider() } }
                    Button("获取模型列表") { save { learning.probeProvider(models: true) } }
                    if learning.busy { ProgressView().controlSize(.small) }
                }.disabled(learning.busy || savingCredentials)
                if !learning.providerConnectionStatus.isEmpty {
                    Text(learning.providerConnectionStatus).font(.callout).textSelection(.enabled)
                }
                DisclosureGroup("高级连接选项") {
                    TextField("密钥环境变量", text: $learning.settings.apiKeyEnvironment)
                    Text("通常无需修改。设置页保存的 API Key 优先使用；未设置时兼容已有环境变量。")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $learning.settings.providerJSON)
                        .font(.system(.caption, design: .monospaced)).frame(height: 100)
                }
                if !learning.diagnostics.isEmpty {
                    DisclosureGroup("详细连接结果") {
                        Text(learning.diagnostics).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            .disabled(learning.busy)
            Section("研读方式") {
                Picker("生成方式", selection: $learning.settings.mode) {
                    Text("原文整理草稿（离线）").tag("offline")
                    Text("AI 精读").tag("llm")
                }
                Toggle("导入或关联 PDF 后自动生成", isOn: $learning.settings.automaticallyGenerate)
                DisclosureGroup("生成参数") {
                    TextField("每批原文字符数", value: $learning.settings.chunkCharacters, format: .number)
                    Text("控制单次请求大小，全部原文仍会逐批处理。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("读者背景") {
                TextEditor(text: $learning.settings.readerContext).font(.body).frame(height: 100)
                Text("填写研究主题、熟悉的方法及希望理解的问题，用于知识迁移部分。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func save(after action: @escaping () -> Void = {}) {
        guard !savingCredentials else { return }
        learning.error = nil
        learning.settings.baseURL = learning.settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        learning.settings.model = learning.settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        learning.settings.apiKeyEnvironment = learning.settings.apiKeyEnvironment.trimmingCharacters(in: .whitespacesAndNewlines)
        if learning.settings.apiKeyEnvironment.isEmpty { learning.settings.apiKeyEnvironment = "PAPERSHELF_API_KEY" }
        do {
            learning.settings.graphitiJSON = try GraphConnectionSettings.synchronizingMainModel(in: learning.settings.graphitiJSON,
                endpoint: learning.settings.baseURL, model: learning.settings.model, apiKeyEnvironment: learning.settings.apiKeyEnvironment)
            learning.settings.graphitiJSON = try GraphConnectionSettings.preparingCredentials(in: learning.settings.graphitiJSON,
                graphKeyChanged: credentials.hasNewValue(.graphProvider), embeddingKeyChanged: credentials.hasNewValue(.embedding),
                passwordChanged: credentials.hasNewValue(.graphPassword))
        } catch { learning.error = error.localizedDescription; return }
        learning.saveSettings()
        guard learning.error == nil else { return }
        savingSettings = true
        Task {
            defer { savingSettings = false }
            do {
                try await credentials.save()
                saved = "设置已保存"
                action()
            } catch {
                learning.error = error.localizedDescription
            }
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
                  let section = config[key] as? [String: Any] else { return }
            learning.settings.paper2agentJSON = String(data: try JSONSerialization.data(withJSONObject: section,
                options: [.prettyPrinted, .sortedKeys]), encoding: .utf8) ?? "{}"
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

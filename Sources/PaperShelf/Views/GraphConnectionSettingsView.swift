import SwiftUI

struct GraphConnectionSettingsView: View {
    @ObservedObject var learning: LearningStore
    @Binding var graphPassword: String
    @Binding var graphAPIKey: String
    @Binding var embeddingKey: String
    var onService: (String) -> Void
    var credentialStatus: (String) -> String = { _ in "" }

    private var configuration: GraphConnectionSettings? { try? GraphConnectionSettings(json: learning.settings.graphitiJSON) }
    private var usesMainModel: Bool {
        configuration?.usesMainModel(endpoint: learning.settings.baseURL, model: learning.settings.model,
                                     apiKeyEnvironment: learning.settings.apiKeyEnvironment) ?? true
    }

    var body: some View {
        Form {
            if let configuration {
                Section("知识图谱") {
                    Toggle("生成文献资料时建立知识图谱", isOn: Binding(get: { configuration.enabled }, set: { value in
                        update { $0.set("enabled", value) }
                    }))
                    Text("关联文献中的实体与关系，保留原文出处。").font(.caption).foregroundStyle(.secondary)
                }
                databaseSection(configuration)
                modelSection
                embeddingSection(configuration)
            } else {
                Section("知识图谱") {
                    Label("高级配置格式有误，请先修正下方 JSON。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            Section {
                DisclosureGroup("高级图谱配置") {
                    Text("额外参数与自定义实体类型会保留。通常只需填写上面的表单。").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $learning.settings.graphitiJSON)
                        .font(.system(.caption, design: .monospaced)).frame(minHeight: 150)
                }
            }
        }.formStyle(.grouped)
    }

    @ViewBuilder private func databaseSection(_ configuration: GraphConnectionSettings) -> some View {
        Section("图数据库") {
            Toggle("使用本机内置数据库（推荐）", isOn: Binding(get: { configuration.usesLocalDatabase }, set: { value in
                update { $0.setUsesLocalDatabase(value) }
            }))
            if configuration.usesLocalDatabase {
                Text("密码自动配置，启动后即可使用。").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("启动本地图谱") { onService("start") }
                    Button("查看状态") { onService("status") }
                    Button("停止服务") { onService("stop") }
                }.disabled(learning.busy)
            } else if configuration.backend == "neo4j" {
                TextField("数据库地址", text: text("uri", fallback: "bolt://localhost:7687"))
                TextField("用户名", text: text("user", fallback: "neo4j"))
                SettingsSecretField(title: "数据库密码", text: $graphPassword, status: credentialStatus("graph-password"))
            } else {
                Text("当前使用 \(configuration.backend)，连接参数可在高级图谱配置中编辑。").font(.caption).foregroundStyle(.secondary)
                SettingsSecretField(title: "数据库密码", text: $graphPassword, status: credentialStatus("graph-password"))
            }
        }
    }

    private var modelSection: some View {
        Section("图谱模型") {
            Toggle("使用「模型与 API」页的接口、模型和 API Key", isOn: Binding(get: { usesMainModel }, set: { value in
                update { $0.setUsesMainModel(value, endpoint: learning.settings.baseURL, model: learning.settings.model,
                                            apiKeyEnvironment: learning.settings.apiKeyEnvironment) }
            }))
            if usesMainModel {
                LabeledContent("当前模型", value: learning.settings.model)
                Text(learning.settings.baseURL).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else {
                TextField("接口地址", text: text("endpoint", fallback: learning.settings.baseURL))
                TextField("模型名称", text: Binding(get: { configuration?.string("model", fallback: learning.settings.model) ?? "" }, set: { value in
                    update { settings in
                        let oldModel = settings.string("model")
                        if settings.values["small_model"] == nil || settings.string("small_model") == oldModel { settings.set("small_model", value) }
                        settings.set("model", value)
                    }
                }))
                SettingsSecretField(title: "图谱 API Key", text: $graphAPIKey, status: credentialStatus("graph-api-key"))
            }
        }
    }

    @ViewBuilder private func embeddingSection(_ configuration: GraphConnectionSettings) -> some View {
        Section("语义检索") {
            Toggle("使用本地嵌入模型（推荐，无需 API Key）", isOn: Binding(get: { configuration.usesLocalEmbedding }, set: { value in
                update { $0.setUsesLocalEmbedding(value) }
            }))
            if configuration.usesLocalEmbedding {
                Text("首次使用会自动下载多语言模型，之后在本机运行。").font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("嵌入接口地址", text: text("embedding_endpoint", fallback: configuration.string("endpoint", fallback: "https://api.openai.com/v1")))
                TextField("嵌入模型名称", text: text("embedding_model", fallback: "text-embedding-3-small"))
                SettingsSecretField(title: "嵌入 API Key", text: $embeddingKey, status: credentialStatus("embedding-key"))
                TextField("向量维度", value: Binding<Int>(get: { configuration.integer("embedding_dimensions", fallback: 1536) }, set: { value in
                    if value > 0 { update { $0.set("embedding_dimensions", value) } }
                }), format: .number)
            }
        }
    }

    private func text(_ key: String, fallback: String = "") -> Binding<String> {
        Binding(get: { configuration?.string(key, fallback: fallback) ?? "" }, set: { value in update { $0.set(key, value) } })
    }

    private func update(_ edit: (inout GraphConnectionSettings) -> Void) {
        do {
            var configuration = try GraphConnectionSettings(json: learning.settings.graphitiJSON)
            configuration.prepareForEditing(endpoint: learning.settings.baseURL, model: learning.settings.model,
                                             apiKeyEnvironment: learning.settings.apiKeyEnvironment)
            edit(&configuration)
            learning.settings.graphitiJSON = try configuration.json()
        } catch { learning.error = error.localizedDescription }
    }
}

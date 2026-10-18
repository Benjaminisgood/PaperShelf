import SwiftUI
import AppKit
import PDFKit
import PaperCore

@MainActor
final class LearningStore: ObservableObject {
    @Published var settings: LearningSettings
    @Published private(set) var runs: [LearningRun] = []
    @Published private(set) var busy = false
    @Published var progress = "选择文献，生成可离线阅读的资料。"
    @Published var error: String?
    @Published var answer = ""
    @Published private(set) var answerRunID: String?
    @Published var diagnostics = ""
    @Published var reviewRevision = 0
    private var client: PipelineProcess?
    private var operation: Task<Void, Never>?
    private var queue: [Reference] = []
    private let root: URL
    private var persistenceAvailable = true
    private var configurationAvailable = true

    init(libraryURL: URL) {
        root = libraryURL.deletingLastPathComponent().appendingPathComponent("Learning", isDirectory: true)
        let config = root.appendingPathComponent("settings.json")
        settings = LearningSettings()
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: config.path) { settings = try JSONDecoder().decode(LearningSettings.self, from: Data(contentsOf: config)) }
        } catch { configurationAvailable = false; self.error = "研读配置无法读取，未覆盖原文件：\(error.localizedDescription)" }
        do {
            let history = root.appendingPathComponent("history.json")
            if FileManager.default.fileExists(atPath: history.path) { runs = try JSONDecoder().decode([LearningRun].self, from: Data(contentsOf: history)) }
        } catch { persistenceAvailable = false; self.error = "研读历史无法读取，未覆盖原文件：\(error.localizedDescription)" }
        recoverHistory()
    }

    private func recoverHistory() {
        guard persistenceAvailable else { return }
        let directories = (try? FileManager.default.contentsOfDirectory(at: outputRoot, includingPropertiesForKeys: nil)) ?? []
        var byID = Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for directory in directories {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
                  let recovered = try? LearningRun.recover(manifest: data, directory: directory) else { continue }
            byID[recovered.id] = recovered
        }
        runs = byID.values.sorted { $0.createdAt > $1.createdAt }
        do { try JSONEncoder().encode(runs).write(to: root.appendingPathComponent("history.json"), options: .atomic) }
        catch { self.error = "研读历史保存失败，后端运行记录保留：\(error.localizedDescription)" }
    }

    var backendPath: String {
        if !settings.backendPath.isEmpty { return settings.backendPath }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Pipeline/backend"), FileManager.default.fileExists(atPath: resource.path) { return resource.path }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("backend").path
    }
    var pythonPath: String {
        if !settings.pythonPath.isEmpty { return settings.pythonPath }
        let managed = root.appendingPathComponent("runtime/bin/python").path
        if FileManager.default.isExecutableFile(atPath: managed) { return managed }
        if let resource = Bundle.main.resourceURL?.appendingPathComponent("Pipeline/runtime.json"),
           let data = try? Data(contentsOf: resource), let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let python = json["python"], FileManager.default.isExecutableFile(atPath: python) { return python }
        let local = URL(fileURLWithPath: backendPath).deletingLastPathComponent().appendingPathComponent(".venv/bin/python").path
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        for candidate in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3.13", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return "/usr/bin/python3"
    }
    var outputRoot: URL { root.appendingPathComponent("Runs", isDirectory: true) }

    func saveSettings() {
        do {
            guard configurationAvailable else { throw LearningError.message("原配置读取失败，请先在 Finder 中检查 settings.json。") }
            try ExtractionField.validate(settings.fields)
            let graph = try object(settings.graphitiJSON)
            if graph["enabled"] as? Bool == true { try validateGraphCredentialDestination(settings, graph: graph) }
            _ = try object(settings.paper2agentJSON)
            _ = try providerConfiguration(settings)
            guard (2000...40000).contains(settings.chunkCharacters) else { throw LearningError.message("每批字符数须为 2000–40000，所有原文均会处理。") }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: root.appendingPathComponent("settings.json"), options: .atomic)
            progress = "研读配置已保存。"
        } catch { self.error = error.localizedDescription }
    }

    func runs(for reference: Reference) -> [LearningRun] { runs.filter { $0.referenceID == reference.id.uuidString } }

    func enqueue(_ references: [Reference]) {
        for reference in references where reference.pdfPath != nil {
            if !queue.contains(where: { $0.id == reference.id }) { queue.append(reference) }
        }
        startNext()
    }
    private func startNext() {
        guard !busy, !queue.isEmpty else { return }
        let reference = queue.removeFirst()
        generate(reference)
    }
    func cancel() { queue.removeAll(); client?.cancel(); operation?.cancel(); progress = "正在取消…" }
    func cancelForTermination() async {
        let process = client
        cancel()
        try? await process?.cancelAndWait()
    }

    func generate(_ reference: Reference, sourceOverride: URL? = nil, supplements: [URL] = [], bookJSON: String? = nil, resumeFrom: String? = nil) {
        guard !busy else { return }
        busy = true; error = nil; answer = ""
        var configuration = settings
        configuration.pythonPath = pythonPath; configuration.backendPath = backendPath
        operation = Task {
            defer { recoverHistory(); busy = false; client = nil; operation = nil; startNext() }
            do {
                guard persistenceAvailable else { throw LearningError.message("研读历史损坏，已停止写入；请先检查 history.json。") }
                try ExtractionField.validate(configuration.fields)
                let work = try workDirectory()
                let url = try sourceOverride ?? PDFLinks.resolvedURL(for: reference)
                let scope = url.startAccessingSecurityScopedResource()
                defer { if scope { url.stopAccessingSecurityScopedResource() } }
                let supplementaryScopes = supplements.map { ($0, $0.startAccessingSecurityScopedResource()) }
                defer { for (url, granted) in supplementaryScopes where granted { url.stopAccessingSecurityScopedResource() } }
                guard FileManager.default.fileExists(atPath: url.path) else { throw PDFLinkError.missing }
                progress = "正在准备全文与页码…"
                let pages = work.appendingPathComponent("pages.json")
                if url.pathExtension.lowercased() == "pdf" {
                    try await Task.detached {
                        guard let document = PDFDocument(url: url), !document.isLocked else { throw PDFLinkError.unreadable }
                        let content = (0..<document.pageCount).map { ["page": $0 + 1, "text": document.page(at: $0)?.string ?? ""] as [String: Any] }
                        try JSONSerialization.data(withJSONObject: content).write(to: pages, options: .atomic)
                    }.value
                }
                var request: [String: Any] = ["source_path": url.path, "output_root": outputRoot.path,
                    "reference_id": reference.id.uuidString, "title": reference.title, "reader_context": configuration.readerContext,
                    "mode": configuration.mode, "fields": try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration.fields)),
                    "chunk_characters": configuration.chunkCharacters, "provider": try providerConfiguration(configuration)]
                request["supplementary_paths"] = supplements.map(\.path)
                if let resumeFrom { request["resume_from"] = resumeFrom }
                if let bookJSON { request["book"] = try object(bookJSON) }
                if FileManager.default.fileExists(atPath: pages.path) { request["source_pages_path"] = pages.path }
                let graph = try object(configuration.graphitiJSON)
                if !graph.isEmpty { request["graphiti"] = graph }
                let p2a = try object(configuration.paper2agentJSON)
                if !p2a.isEmpty { request["paper2agent"] = p2a }
                let requestURL = work.appendingPathComponent("request.json")
                try JSONSerialization.data(withJSONObject: request, options: [.prettyPrinted, .sortedKeys]).write(to: requestURL, options: .atomic)
                let result = try await invoke(["run", "--request", requestURL.path], work: work, configuration: configuration)
                guard let status = result["status"] as? String, ["completed", "partial"].contains(status), let runID = result["run_id"] as? String,
                      let directory = result["run_dir"] as? String, let manifest = result["manifest_path"] as? String,
                      let artifacts = result["artifacts"] as? [String: String] else { throw LearningError.message("后端结果格式不完整，请查看处理日志。") }
                let run = LearningRun(referenceID: reference.id.uuidString, title: reference.title, runID: runID, directory: directory,
                    manifestPath: manifest, artifacts: artifacts, warnings: result["warnings"] as? [String] ?? [], mode: configuration.mode, status: status)
                var updated = runs; updated.insert(run, at: 0)
                try JSONEncoder().encode(updated).write(to: root.appendingPathComponent("history.json"), options: .atomic)
                runs = updated
                progress = status == "partial" ? "本地资料已生成，部分集成未完成；请查看缺口提示。" : configuration.mode == "offline" ? "原文整理草稿已生成，可查看 HTML、Markdown 和证据。" : "学习资料已生成，请核对证据和缺口。"
            } catch is CancellationError { progress = "已取消，历史产物保留。" }
            catch { self.error = error.localizedDescription; progress = "处理未完成；日志与历史产物保留。" }
        }
    }

    func chooseSource(for reference: Reference) {
        let panel = NSOpenPanel(); panel.title = "选择用于研读的 PDF、Markdown、Word 或其他文档"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        generate(reference, sourceOverride: url)
    }

    func ask(_ query: String, run: LearningRun) {
        guard !busy, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true; error = nil; answer = ""; answerRunID = run.id
        var configuration = settings
        configuration.pythonPath = pythonPath; configuration.backendPath = backendPath
        operation = Task {
            defer { busy = false; client = nil; operation = nil; startNext() }
            do {
                let work = try workDirectory()
                let provider = work.appendingPathComponent("provider.json")
                let value = try providerConfiguration(configuration)
                try JSONSerialization.data(withJSONObject: value).write(to: provider, options: .atomic)
                let result = try await invoke(["agent", "--manifest", run.manifestPath, "--query", query, "--mode", configuration.mode,
                                               "--provider-config", provider.path], work: work, configuration: configuration)
                answer = result["answer"] as? String ?? prettyJSON(result)
                progress = "回答已生成；请核对引用。"
            } catch is CancellationError { progress = "已取消。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func command(_ arguments: [String]) {
        guard !busy else { return }
        busy = true; error = nil
        operation = Task {
            defer { busy = false; client = nil; operation = nil; startNext() }
            do { diagnostics = prettyJSON(try await invoke(arguments, work: try workDirectory())); progress = "集成命令已返回。" }
            catch is CancellationError { progress = "已取消。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func probeProvider(models: Bool = false) {
        guard !busy else { return }
        busy = true; error = nil
        var configuration = settings
        configuration.pythonPath = pythonPath; configuration.backendPath = backendPath
        operation = Task {
            defer { busy = false; client = nil; operation = nil; startNext() }
            do {
                let work = try workDirectory()
                let config = work.appendingPathComponent("provider.json")
                let value = try providerConfiguration(configuration)
                try JSONSerialization.data(withJSONObject: value).write(to: config, options: .atomic)
                diagnostics = prettyJSON(try await invoke([models ? "provider-models" : "provider-probe", "--config", config.path], work: work, configuration: configuration))
                progress = models ? "模型列表已读取。" : "模型连接测试已完成。"
            } catch is CancellationError { progress = "测试已取消。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func applyReview(_ data: Data, actor: String, extractionPath: String, run: LearningRun) async throws -> String {
        guard !busy else { throw LearningError.message("请等待当前任务结束。") }
        busy = true
        defer { busy = false; client = nil; startNext() }
        let directory = URL(fileURLWithPath: run.directory).appendingPathComponent("Reviews/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corrections = directory.appendingPathComponent("corrections.json")
        try data.write(to: corrections, options: .atomic)
        let output = directory.appendingPathComponent("extraction.json")
        let source = URL(fileURLWithPath: run.directory).appendingPathComponent("source.json").path
        _ = try await invoke(["dataset-review", "--extraction", extractionPath, "--source", source,
                              "--corrections", corrections.path, "--actor", actor, "--output", output.path], work: try workDirectory())
        _ = try await invoke(["dataset-export", "--extraction", output.path, "--source", source, "--output", directory.path], work: try workDirectory())
        try Data("completed".utf8).write(to: directory.appendingPathComponent("complete"), options: .atomic)
        reviewRevision += 1
        progress = "已保存校对版本与新数据表；原始学习指南保留，未自动改写。"
        return output.path
    }

    func latestReviewedExtraction(for run: LearningRun) -> String? {
        let folder = URL(fileURLWithPath: run.directory).appendingPathComponent("Reviews")
        let directories = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return directories.map { $0.appendingPathComponent("extraction.json") }
            .filter {
                let folder = $0.deletingLastPathComponent()
                return ["complete", "extraction.json", "dataset.csv", "dataset.tsv", "evidence-graph.json"].allSatisfy {
                    FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
                }
            }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .first?.path
    }

    func artifactPath(_ key: String, for run: LearningRun) -> String? {
        let names = ["extraction": "extraction.json", "csv": "dataset.csv", "tsv": "dataset.tsv", "graph": "evidence-graph.json"]
        if let name = names[key], let reviewed = latestReviewedExtraction(for: run) {
            return URL(fileURLWithPath: reviewed).deletingLastPathComponent().appendingPathComponent(name).path
        }
        return run.artifacts[key]
    }

    func graphPath(for run: LearningRun) -> String? {
        if let reviewed = latestReviewedExtraction(for: run) {
            let path = URL(fileURLWithPath: reviewed).deletingLastPathComponent().appendingPathComponent("evidence-graph.json").path
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return run.artifacts["graph"]
    }

    func queryGraph(_ query: String, filters: String, run: LearningRun, remote: Bool) async throws -> String {
        guard !busy else { throw LearningError.message("请等待当前任务结束。") }
        busy = true
        defer { busy = false; client = nil; startNext() }
        let work = try workDirectory()
        let arguments: [String]
        if remote {
            let config = try object(settings.graphitiJSON)
            guard !config.isEmpty else { throw LearningError.message("请先在集成设置配置 Graphiti 服务。") }
            let path = work.appendingPathComponent("graphiti.json")
            try JSONSerialization.data(withJSONObject: config).write(to: path, options: .atomic)
            arguments = ["graph-search", query, "--config", path.path]
        } else {
            guard let graph = graphPath(for: run) else { throw LearningError.message("此版本没有证据图谱。") }
            arguments = ["graph-query", "--graph", graph, "--query", query, "--filters", filters]
        }
        return prettyJSON(try await invoke(arguments, work: work))
    }

    func upstreamAction(_ action: String, run: LearningRun) {
        let job = URL(fileURLWithPath: run.directory).appendingPathComponent("paper2agent").path
        command(["paper2agent-\(action)", job])
    }

    func installRuntime() {
        guard !busy else { return }
        busy = true; error = nil; progress = "正在安装文档与图谱依赖…"
        operation = Task {
            defer { busy = false; client = nil; operation = nil; startNext() }
            do {
                let source = URL(fileURLWithPath: backendPath).deletingLastPathComponent()
                let runtime = root.appendingPathComponent("runtime")
                let process = PipelineProcess(); client = process
                let work = try workDirectory()
                let result = try await process.executeCommand(executable: "/bin/bash",
                    arguments: [source.appendingPathComponent("script/setup_integrations.sh").path,
                                "--source-root", source.path, "--venv", runtime.path, "--python", pythonPath],
                    environment: [:], directory: source.path, work: work)
                diagnostics = String(data: result, encoding: .utf8) ?? "安装完成。"
                settings.pythonPath = runtime.appendingPathComponent("bin/python").path
                saveSettings()
                if error == nil { progress = "运行环境已安装，可以生成资料。" }
            } catch is CancellationError { progress = "安装已取消。" }
            catch { self.error = error.localizedDescription; progress = "安装未完成，请查看日志。" }
        }
    }

    func graphService(_ action: String) {
        guard !busy, ["start", "status", "stop"].contains(action) else { return }
        busy = true; error = nil
        let source = URL(fileURLWithPath: backendPath).deletingLastPathComponent()
        operation = Task {
            defer { busy = false; client = nil; operation = nil; startNext() }
            do {
                let process = PipelineProcess(); client = process
                let data = try await process.executeCommand(executable: "/bin/bash",
                    arguments: [source.appendingPathComponent("script/graph_service.sh").path, action], environment: [:],
                    directory: source.path, work: try workDirectory())
                diagnostics = String(data: data, encoding: .utf8) ?? ""
                progress = action == "stop" ? "本地图谱服务已停止，数据卷保留。" : "本地图谱服务操作完成。"
            } catch is CancellationError { progress = "服务操作已取消，请检查当前服务状态。" }
            catch { self.error = error.localizedDescription }
        }
    }

    private func invoke(_ args: [String], work: URL, configuration: LearningSettings? = nil) async throws -> [String: Any] {
        let configuration = configuration ?? settings
        let process = PipelineProcess(); client = process
        var environment: [String: String] = [:]
        let plan = try CredentialPlan(command: args.first ?? "", mode: configuration.mode,
                                      providerEndpoint: configuration.baseURL, providerKeyEnvironment: configuration.apiKeyEnvironment,
                                      graphJSON: configuration.graphitiJSON, parseGraph: object)
        let inherited = ProcessInfo.processInfo.environment
        let secrets = try await AsyncSecretLoader.load {
            try plan.additions(inherited: inherited) { secret in
                if secret == .graphPassword {
                    return try ManagedGraphCredential.password(for: plan.managedGraphConfiguration) ?? ProviderSecret.load(account: secret.rawValue)
                }
                return try ProviderSecret.load(account: secret.rawValue)
            }
        }
        try Task.checkCancellation()
        environment.merge(secrets) { _, new in new }
        let selectedBackend = configuration.backendPath.isEmpty ? backendPath : configuration.backendPath
        let selectedPython = configuration.pythonPath.isEmpty ? pythonPath : configuration.pythonPath
        let backendRoot = URL(fileURLWithPath: selectedBackend).deletingLastPathComponent().path
        environment["PAPERSHELF_ROOT"] = backendRoot
        let monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                if let log = try? String(contentsOf: work.appendingPathComponent("progress.log"), encoding: .utf8),
                   let latest = log.split(separator: "\n").last { self?.progress = String(latest) }
            }
        }
        defer { monitor.cancel() }
        let data = try await process.execute(python: selectedPython, backend: selectedBackend, arguments: args, environment: environment, work: work)
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LearningError.message("后端未返回 JSON 对象。") }
        return result
    }

    private func workDirectory() throws -> URL {
        let work = root.appendingPathComponent("Jobs/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }
    private func object(_ text: String) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw LearningError.message("高级配置必须是 JSON 对象。") }
        func validate(_ value: Any) throws {
            if let dict = value as? [String: Any] {
                for (key, child) in dict {
                    if ["api_key", "apikey", "password", "secret", "access_token", "authorization"].contains(key.lowercased()) {
                        throw LearningError.message("配置中不能填写原始密钥或密码（\(key)）；请使用钥匙串与 *_environment 字段。")
                    }
                    try validate(child)
                }
            } else if let array = value as? [Any] { for child in array { try validate(child) } }
        }
        try validate(result)
        return result
    }
    private func providerConfiguration(_ configuration: LearningSettings) throws -> [String: Any] {
        var value = try object(configuration.providerJSON)
        value["base_url"] = configuration.baseURL
        value["model"] = configuration.model
        value["api_key_env"] = configuration.apiKeyEnvironment
        return value
    }
    private func validateGraphCredentialDestination(_ configuration: LearningSettings, graph: [String: Any], model: Bool = true, embedding: Bool = true) throws {
        try CredentialPlan.validateGraphDestinations(providerEndpoint: configuration.baseURL,
                                                      providerKeyEnvironment: configuration.apiKeyEnvironment,
                                                      graph: graph, model: model, embedding: embedding)
    }
    private func prettyJSON(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }
    func open(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func revealRoot() { NSWorkspace.shared.activateFileViewerSelecting([root]) }
}

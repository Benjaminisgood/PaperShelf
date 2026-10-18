import AppKit
import PaperCore

extension LibraryStore {
    func startIntegrations() {
        if captureReceiver == nil {
            captureReceiver = BrowserCaptureReceiver(storageDirectory: libraryURL.deletingLastPathComponent(),
                downloadRoot: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return self.preferences.fileRoot.isEmpty ? self.libraryURL.deletingLastPathComponent() : try self.preferences.resolvedFileRoot()
                },
                snapshot: { [weak self] in .init(references: self?.references ?? [], collections: self?.collectionRecords ?? [], tags: self?.tagRecords ?? []) },
                onImport: { [weak self] value, policy in
                    guard let self, self.importReferences([value], duplicatePolicy: policy) else { return false }
                    return self.references.contains { $0.id == value.id }
                },
                onSelect: { [weak self] id in self?.filter = "all"; self?.search = ""; self?.selectedID = id },
                onStatus: { [weak self] in self?.status = $0 },
                onError: { [weak self] in self?.error = $0 })
        }
        if localAPI == nil {
            localAPI = LocalAPIServer(storageDirectory: libraryURL.deletingLastPathComponent(),
                snapshot: { [weak self] in .init(references: self?.references ?? [], collections: self?.collectionRecords ?? [], tags: self?.tagRecords ?? []) },
                save: { [weak self] in self?.save($0) ?? false },
                onStatus: { [weak self] in self?.status = $0 })
            do { try localAPI?.start(configuration: preferences.localAPI) }
            catch { self.error = error.localizedDescription }
        }
    }
    func applyAPISettings() {
        savePreferences()
        do { try localAPI?.start(configuration: preferences.localAPI) }
        catch { self.error = error.localizedDescription }
    }
    func handleURLs(_ urls: [URL]) {
        startIntegrations()
        for originalURL in urls {
            var url = originalURL
            if Bundle.main.bundleIdentifier == "local.papershelf.qa", url.scheme?.lowercased() == "papershelf-qa",
               var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                components.scheme = "papershelf"
                if let translated = components.url { url = translated }
            }
            if url.isFileURL { importURLs([url]); continue }
            guard url.scheme?.lowercased() == "papershelf" else { continue }
            if url.host == "capture" { captureReceiver?.handle([url]) }
            else if url.host == "paper", let id = UUID(uuidString: url.lastPathComponent),
                    let value = references.first(where: { $0.id == id }) {
                filter = value.deletedAt == nil ? "all" : "trash"; search = ""; selectedID = id
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
    func openResource(_ relativePath: String) {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent(relativePath)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = sourceRoot.appendingPathComponent(relativePath)
        if let bundled, FileManager.default.fileExists(atPath: bundled.path) { NSWorkspace.shared.open(bundled) }
        else if FileManager.default.fileExists(atPath: source.path) { NSWorkspace.shared.open(source) }
        else { error = "资源未安装：\(relativePath)。请重新运行项目构建脚本。" }
    }
}

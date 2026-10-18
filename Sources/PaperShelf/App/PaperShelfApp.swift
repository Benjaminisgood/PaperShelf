import SwiftUI
import AppKit

@main
struct PaperShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = LibraryStore()
    @AppStorage("library.language") private var language = "system"
    @AppStorage("library.appearance") private var appearance = "system"
    var body: some Scene {
        Window("PaperShelf", id: "library") {
            ContentView(store: store)
                .environment(\.locale, language == "system" ? .current : Locale(identifier: language))
                .frame(minWidth: 980, minHeight: 620)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
                .onAppear { delegate.connect(store); store.startIntegrations(); PaperShelfShortcuts.updateAppShortcutParameters() }
        }
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("添加文献…") { store.addManual() }.keyboardShortcut("n")
                Button("导入文件或文件夹…") { store.importFiles() }.keyboardShortcut("i")
                Button("通过标识符添加…") { store.showingIdentifier = true }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("从剪贴板导入") { store.importClipboard() }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("从 Zotero 迁移…") { store.importZotero() }
                Divider()
                Button("新建文集…") { store.editCollection() }.keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) { Button("搜索全部文献") { NotificationCenter.default.post(name: .init("PaperShelfFocusSearch"), object: nil) }.keyboardShortcut("f") }
            CommandMenu("文献") {
                Button("打开 PDF") { if let item = store.selected { store.openPDF(item) } }.keyboardShortcut("o").disabled(store.selected?.pdfPath == nil)
                Button("快速查看") { store.preview() }.keyboardShortcut("y").disabled(store.selected?.pdfPath == nil)
                Button("编辑元数据…") { store.editingReference = store.selected }.keyboardShortcut("e", modifiers: [.command, .option]).disabled(store.selected == nil)
                Button("批量编辑…") { store.showingBatchEditor = true }.disabled(store.selectedIDs.isEmpty)
                Divider()
                Button("复制 BibTeX") { if let item = store.selected { store.copyCitation(item) } }.keyboardShortcut("c", modifiers: [.command, .shift]).disabled(store.selected == nil)
                Button("复制 DOI") { store.copySelectedDOIs() }.disabled(store.selectedIDs.isEmpty)
                Button("批量刷新元数据") { store.refreshSelectedMetadata() }.disabled(store.selectedIDs.isEmpty || store.isBusy)
                Button("更新引用键") { store.regenerateCitationKeys() }
                Divider()
                Button("导出 BibTeX…") { store.export(.bibtex, selectedOnly: !store.selectedIDs.isEmpty) }.keyboardShortcut("e")
                ForEach(ExportFormat.allCases.filter { $0 != .bibtex }, id: \.self) { format in Button("导出 \(format.rawValue)…") { store.export(format, selectedOnly: !store.selectedIDs.isEmpty) } }
            }
            CommandGroup(replacing: .help) { Button("PaperShelf 使用指南") { store.openResource("Guide.md") }; Button("浏览器扩展与引用工具") { store.openResource("IntegrationsUI") } }
            CommandGroup(replacing: .appInfo) {
                Button("关于 PaperShelf") {
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "PaperShelf", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.0",
                        .credits: NSAttributedString(string: "原生文献管理与研读工作台\nSwiftUI · SQLite · PDFKit\nMarkItDown · Paper2Agent · Graphiti")])
                }
            }
        }
        Settings { LibrarySettingsView(store: store).environment(\.locale, language == "system" ? .current : Locale(identifier: language)) }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: LibraryStore?
    private var pendingURLs: [URL] = []
    func connect(_ store: LibraryStore) { self.store = store; if !pendingURLs.isEmpty { store.handleURLs(pendingURLs); pendingURLs = [] } }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func application(_ application: NSApplication, open urls: [URL]) { if let store { store.handleURLs(urls) } else { pendingURLs += urls } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        store.localAPI?.stop(); store.importTask?.cancel()
        Task { @MainActor in
            await store.cancelFileOperationsForTermination()
            await store.captureReceiver?.cancelForTermination()
            if store.learning.busy { await store.learning.cancelForTermination() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

import SwiftUI
import AppKit

@main
struct PaperShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = LibraryStore()

    var body: some Scene {
        Window("PaperShelf · 文献架", id: "library") {
            ContentView(store: store)
                .frame(minWidth: 1080, minHeight: 650)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("导入 PDF / BibTeX / RIS…") { store.importFiles() }
                    .keyboardShortcut("i", modifiers: .command)
                Button("手动添加文献") { store.addManual() }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
                Button("导出当前列表为 BibTeX…") { store.export(.bibtex) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 PaperShelf") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "PaperShelf", .applicationVersion: "0.1.0",
                        .credits: NSAttributedString(string: "独立实现的原生文献管理初版\nSwiftUI · SQLite · PDFKit\n参考公开工作流，与 Lattice 无关联。")
                    ])
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

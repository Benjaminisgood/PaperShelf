import SwiftUI
import AppKit
import PaperCore

struct LibrarySettingsView: View {
    @ObservedObject var store: LibraryStore
    @AppStorage("library.showStatusBar") private var showStatusBar = true
    @AppStorage("library.language") private var language = "system"
    @AppStorage("library.appearance") private var appearance = "system"
    var body: some View {
        TabView {
            Form {
                Picker("语言 / Language", selection: $language) {
                    Text("跟随系统 / System").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("English").tag("en")
                }
                Picker("外观", selection: $appearance) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }
                Toggle("显示状态栏", isOn: $showStatusBar)
                Toggle("文集包含子文集中的文献", isOn: $store.preferences.includeSubcollections)
                Toggle("无文本层时对标注区域执行 OCR", isOn: $store.preferences.annotationOCR)
                Text("OCR 使用本机 Apple Vision，结果会标明来源，原 PDF 保持不变。").font(.caption).foregroundStyle(.secondary)
                TextField("PDF 阅读器 Bundle ID（空为系统默认）", text: $store.preferences.readerBundleID)
                LabeledContent("书库", value: store.libraryURL.path).font(.caption)
                HStack { Button("备份…") { store.backupLibrary() }; Button("恢复…") { store.restoreLibrary() }; Button("从 Zotero 迁移…") { store.importZotero() } }
            }.formStyle(.grouped).tabItem { Label("通用", systemImage: "gearshape") }
            Form {
                HStack { Text(store.preferences.fileRoot.isEmpty ? "尚未选择文件库" : store.preferences.fileRoot).textSelection(.enabled); Spacer(); Button("选择…") { store.chooseFileLibrary() } }
                Picker("处理方式", selection: $store.preferences.fileOptions.action) { Text("原位链接").tag(PaperFileAction.link); Text("复制").tag(PaperFileAction.copy); Text("移动").tag(PaperFileAction.move) }
                Picker("组织方式", selection: $store.preferences.fileOptions.grouping) { Text("不分组").tag(PaperFileGrouping.none); Text("年份").tag(PaperFileGrouping.year); Text("文集路径").tag(PaperFileGrouping.collection); Text("作者姓氏首字母").tag(PaperFileGrouping.authorInitial) }
                Picker("布局", selection: $store.preferences.fileOptions.layout) { Text("PDF 与附件分区").tag(PaperFileLayout.pdfCentric); Text("每篇文献一个文件夹").tag(PaperFileLayout.paperFolders) }
                TextField("文件名模板（空为保留原名）", text: $store.preferences.fileOptions.renameTemplate)
                Text("变量：{auth}、{Auth}、{year}、{title}、{citekey}。缺少数据时保留原文件名。").font(.caption).foregroundStyle(.secondary)
                Toggle("导入后按规则整理文件", isOn: $store.preferences.automaticallyOrganize).disabled(store.preferences.fileRoot.isEmpty)
                Button("应用到选中文献…") { store.organizeFiles(store.selectedReferences) }.disabled(store.selectedReferences.isEmpty || store.preferences.fileRoot.isEmpty)
            }.formStyle(.grouped).tabItem { Label("文件", systemImage: "folder") }
            VStack(alignment: .leading, spacing: 12) {
                TextField("引用键模板", text: $store.preferences.citationKeyTemplate)
                Toggle("元数据改变后自动更新引用键", isOn: $store.preferences.updateCitationKeyOnEdit)
                Text("{auth}、{Auth}、{author}、{year}、{shortyear}、{title}、{title-N}；更新时处理重名。").font(.caption).foregroundStyle(.secondary)
                if let reference = store.selected ?? store.activeReferences.first {
                    Text("预览：" + (Bibliography.generateCitationKeys([reference], template: store.preferences.citationKeyTemplate).first?.citationKey ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Button("更新选中或全库引用键") { store.regenerateCitationKeys() }
                TextField("BibTeX 导出字段（空为全部，逗号分隔）", text: Binding(get: { store.preferences.bibtexFields.joined(separator: ", ") }, set: { store.preferences.bibtexFields = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }))
                HStack { Text("元数据模板").font(.headline); Spacer(); Button("恢复元数据模板") { store.preferences.templates.metadata = PaperExportTemplates().metadata } }
                TextEditor(text: $store.preferences.templates.metadata).font(.system(.body, design: .monospaced)).border(.quaternary)
                HStack { Text("标注模板").font(.headline); Spacer(); Button("恢复标注模板") { store.preferences.templates.annotation = PaperExportTemplates().annotation } }
                TextEditor(text: $store.preferences.templates.annotation).font(.system(.body, design: .monospaced)).border(.quaternary)
                if let reference = store.selected {
                    DisclosureGroup("元数据模板预览") {
                        ScrollView { Text((try? PaperTemplateRenderer.render(reference: reference, annotations: [], templates: store.preferences.templates, collectionPaths: reference.collectionIDs.map(store.collectionPath))) ?? "模板格式有误").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 150)
                    }
                }
                HStack { Text("{{字段}}，{{#字段}}非空时显示{{/字段}}。支持嵌套条件。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("恢复默认") { store.preferences.templates = .init() } }
            }.padding(22).tabItem { Label("模板", systemImage: "doc.badge.gearshape") }
            IntegrationSettingsView(store: store).tabItem { Label("集成", systemImage: "puzzlepiece.extension") }
            LearningSettingsView(learning: store.learning).tabItem { Label("AI 与研读", systemImage: "sparkles") }
        }.frame(minWidth: 720, idealWidth: 800, minHeight: 600, idealHeight: 680)
        .onChange(of: store.preferences) { _, _ in store.savePreferences() }
    }
}

struct IntegrationSettingsView: View {
    @ObservedObject var store: LibraryStore
    var body: some View {
        Form {
            Section("浏览器采集") {
                Text("Safari、Chrome、Edge 和 Firefox 可采集当前页标题、作者、标识符与 PDF 候选。点击扩展后预览，PaperShelf 中确认导入。")
                Button("打开浏览器扩展安装目录") { store.openResource("BrowserExtension") }
            }
            Section("本地 API") {
                Toggle("启用本机 API", isOn: $store.preferences.localAPI.enabled)
                Toggle("只读模式", isOn: $store.preferences.localAPI.readOnly)
                TextField("端口", value: $store.preferences.localAPI.port, format: .number.grouping(.never))
                Text("仅监听 127.0.0.1，连接信息保存在本地受限文件中。CLI、MCP 与引用工具使用随机令牌连接。").font(.caption).foregroundStyle(.secondary)
                TextField("允许的网页来源（逗号分隔）", text: Binding(get: { store.preferences.localAPI.allowedOrigins.joined(separator: ", ") }, set: { store.preferences.localAPI.allowedOrigins = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }))
                TextField("允许读取的 PDF 文件夹（每行一个）", text: Binding(get: { store.preferences.localAPI.trustedFolders.joined(separator: "\n") }, set: { store.preferences.localAPI.trustedFolders = $0.split(separator: "\n").map(String.init) }), axis: .vertical)
                HStack {
                    Button("应用 API 设置") { store.applyAPISettings() }
                    if let url = store.localAPI?.connectionURL { Button("显示连接文件") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                }
            }
            Section("自动化") {
                Text("快捷指令支持搜索、选择文献和导出笔记；命令行与 MCP 可连接本机书库服务。")
                HStack { Button("Word 引用工具") { store.openResource("IntegrationsUI/Word") }; Button("Raycast 扩展") { store.openResource("IntegrationsUI/Raycast") } }
                Button("打开使用说明") { store.openResource("Guide.md") }
            }
        }.formStyle(.grouped)
    }
}

# PaperShelf 功能覆盖与验证边界

日期：2026-10-18。需求逐项来自 [feature-matrix-input.md](feature-matrix-input.md)，涵盖其全部功能域。本表将实现位置与实际验证分开；源码存在、编译成功、单元测试通过均不等于宿主应用中的完整操作验收，也不构成“100% Lattice 复刻”声明。

比较对象为本机 Lattice 3.0 (26)，公开 Lattice_release README/CHANGELOG 的版本内容止于 2.1.6。公开需求版本、只读 REA 检查、许可与差异以输入文档和 [REA receipt](rea-lattice-receipt.json) 为准。PaperShelf 独立实现功能，不包含 Lattice 本体或其 PolyForm Shield 扩展实现代码/图形资产。

## 证据索引

- **S**：[Swift 全套日志](swift-all-tests-final.log)：2026-10-18 12:46 完成，78 项通过。专门补测另见 X；二者覆盖有重叠，不相加统计，也不等同后续 UI 的完整验收。
- **X**：[数据交换专门日志](library-exchange-tests.log)、[数据层说明](core-data-contract.md)，45 项通过，其中 21 项 exchange 测试，覆盖迁移、事务、引用键、Zotero 与备份恢复。
- **P**：[PDF/模板/文件测试 receipt](pdf-export-test-receipt.json)、[日志](pdf-export-isolated-final-tests.log)。54 项通过，含真实 PDFKit 多区域提取、系统 Vision OCR；receipt 附冻结源码哈希。这是先前独立 Core 快照，不能代替后续应用验收。
- **A**：[Local API/CLI/MCP 验证](../../IntegrationsAPI/VERIFICATION.md)：6 项 Core 测试和真实隔离 NWListener/CLI 的 40 项检查。
- **B**：[浏览器验证](../../BrowserExtension/VERIFICATION.md)：8 项 JavaScript、7 项 Core 测试，Safari 构建和临时签名核查；四种浏览器真实安装点击流程尚未完成。
- **I**：[最终打包日志](final-production-package.log)、[动作逻辑](notes-intent-harness.log)、[宿主签名限制](signing-and-hosts.md)。Apple 处理器实际生成 4 个动作；系统 Shortcuts 已实际发现四个动作，但执行因临时签名缺少 Team ID 失败；Siri/Spotlight 未验收。
- **W**：[Word 测试](word-tests.log)、[manifest 校验](word-manifest-validation.log)、[真实隔离 API/HTTPS proxy](adapters-live-api.log)；**R**：[Raycast 测试](raycast-tests.log)、[类型检查](raycast-typecheck.log)、[构建](raycast-build.log)。宿主侧载与真实文档操作不由这些证据证明。
- **L**：[学习系统验收](../learning-acceptance.md)、[本轮后端回归](backend-regression.log)。本轮 129 项中 127 通过、2 项条件性跳过；先前实机/真实服务证据保留其原运行日期与边界。
- **F**：[Store 文件事务 harness](../independent-qa/file-operations/harness.swift)、[结果](../independent-qa/file-operations/results.log)：真实临时文件/SQLite、异步取消、并发元数据/附件冲突、DB 失败回滚、共享文件保护、Zotero copy/重复/取消及引用键更新；逐项数量以该日志最后完成摘要为准，不代表文件选择面板的 UI 验收。

表中“UI 待验”表示有可调用的实现，但没有逐项记录的完整界面操作证据；不影响已经列出的 Core 或接口证据有效性。主应用局部验收见 [最终原生验收](native-final-qa.md)，覆盖三栏、Quick Look、批注、搜索、多选批量编辑与撤销、三范围导出菜单、模板独立恢复/预览、英语切换；不能扩展成全部表项通过。

## 逐域覆盖

| 功能域 | PaperShelf 实现与有意差异 | 已有验证与尚待验收 |
|---|---|---|
| 主窗口 | [ContentView](../../Sources/PaperShelf/Views/ContentView.swift)：导航侧栏、Table、可折叠检查器；元数据/批注/研读分区。 | S 编译；主代理已观察三栏与检查器，折叠/恢复状态需逐项 UI 验收。 |
| 表格 | [LibraryTable](../../Sources/PaperShelf/Views/LibraryTable.swift)：标题/作者/年份/来源/评分/备注/日期、原生列定制、排序、多选、附件子行。 | S 编译；列显隐/宽度持久化、多选拖放与附件行需 UI 待验。 |
| 搜索 | [Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)、[ContentView](../../Sources/PaperShelf/Views/ContentView.swift)、[App](../../Sources/PaperShelf/App/PaperShelfApp.swift)：字段搜索、搜索时切全库、Cmd+F 显式聚焦、保存排序。 | S 编译；Cmd+F、重启排序、各字段搜索 UI 待验。 |
| 键盘 | [Table](../../Sources/PaperShelf/Views/LibraryTable.swift)、[App](../../Sources/PaperShelf/App/PaperShelfApp.swift)：Return/Space/Delete、Cmd+I 导入、Cmd+E 导出；编辑为 Cmd+Option+E。 | 编译检查；各焦点状态下快捷键 UI 待验。 |
| 系统筛选 | [Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)、[Sidebar](../../Sources/PaperShelf/Views/SidebarView.swift)：全部/未归类/缺标识符/缺 PDF，加未读/收藏/最近删除及计数。 | S/Core 数据检查；组合条件与即时计数 UI 待验。 |
| 文集 | [Database](../../Sources/PaperCore/LibraryDatabase.swift)、[Organization](../../Sources/PaperShelf/Stores/LibraryStore+Organization.swift)、[Sidebar](../../Sources/PaperShelf/Views/SidebarView.swift)：创建/改名/删除、多归属、拖放重排/换父级。**按用户要求允许任意层级**，不保留三层上限。 | X：12 层、缺父节点、环拒绝、删除保留文献；拖放命中区域 UI 待验。 |
| 子文集 | [Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)、[Sidebar](../../Sources/PaperShelf/Views/SidebarView.swift)：默认递归包含，右键/设置切换。 | 编译与源码核对；切换后的筛选计数 UI 待验。 |
| 标签 | [Database](../../Sources/PaperCore/LibraryDatabase.swift)、[Organization](../../Sources/PaperShelf/Stores/LibraryStore+Organization.swift)：创建/改名/删除、自定义 hex/颜色重置、拖动与上下移顺序、多标签。 | X：重命名事务、颜色/order 保留、非法颜色与冲突拒绝；拖放 UI 待验。 |
| 批处理 | [Batch](../../Sources/PaperShelf/Stores/LibraryStore+Batch.swift)、[BatchEditView](../../Sources/PaperShelf/Views/BatchEditView.swift)、[Sidebar](../../Sources/PaperShelf/Views/SidebarView.swift)：批量拖放、分配、编辑、刷新、导出。 | S/X：原子写入、合并与并发字段保护；批量交互 UI 待验。 |
| 分类继承 | [Store.importReferences](../../Sources/PaperShelf/Stores/LibraryStore.swift)：当前文集/标签加入新建和导入；重复记录合并当前分类。 | X：数据库替换保留本地数据；Store 当前筛选继承与替换交互 UI 待验。 |
| 本地导入 | [Store.importURLs](../../Sources/PaperShelf/Stores/LibraryStore.swift)、[ContentView](../../Sources/PaperShelf/Views/ContentView.swift)：多 PDF/BibTeX/RIS、递归文件夹、Finder drop、读取进度与取消。 | S/P：PDF 解析；示例 BibTeX 已由主代理导入。递归/取消/拖放 UI 待验。 |
| 数据导入 | [Bibliography](../../Sources/PaperCore/Bibliography.swift)、[MetadataLookup](../../Sources/PaperCore/MetadataLookup.swift)、[ZoteroImporter](../../Sources/PaperCore/ZoteroImporter.swift)、[Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)：BibTeX/RIS、标识符、手工和 Zotero。 | X/S：格式、标识符 provider、Zotero fixture；真实出版商网络成功率与各面板 UI 待验。 |
| 重复控制 | [Database.importLibrary](../../Sources/PaperCore/LibraryDatabase.swift)、[Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)、[CaptureReceiver](../../Sources/PaperShelf/Services/BrowserCaptureReceiver.swift)：skip/replace、本批统一选择、浏览器打开已有。 | X/A：重复事务和本地字段保留；逐条与批次面板交互 UI 待验。Zotero 当前选择跳过重复。 |
| 元数据 | [PDFLinks](../../Sources/PaperCore/PDFLinks.swift)、[PDFMetadataIdentifiers](../../Sources/PaperCore/PDFMetadataIdentifiers.swift)、[MetadataLookup](../../Sources/PaperCore/MetadataLookup.swift)：本地标题/作者/标识符，Crossref→DataCite、OpenLibrary、arXiv，失败可继续编辑。 | P：全文标识符/歧义处理；X：模拟网络响应/字段映射，不能据此宣称所有在线服务实测。 |
| 数据模型 | [Reference](../../Sources/PaperCore/Reference.swift)、[MetadataEditor](../../Sources/PaperShelf/Views/MetadataEditor.swift)：文章、书/章节、会议、学位/报告、网页、数据、软件、专利、手稿、预印本等。 | X：旧 JSON/schema 迁移、类型保留；完整类型编辑 UI 待验。 |
| 扩展字段 | [Reference](../../Sources/PaperCore/Reference.swift)、[MetadataEditor](../../Sources/PaperShelf/Views/MetadataEditor.swift)：标准卷期页/出版社/ISBN/ISSN、类型相关字段、任意名称字段。 | X：BibTeX/RIS 额外字段 roundtrip；类型切换后字段保留 UI 待验。 |
| 作者 | [Bibliography](../../Sources/PaperCore/Bibliography.swift)、[MetadataEditor](../../Sources/PaperShelf/Views/MetadataEditor.swift)、[LocalAPI](../../Sources/PaperCore/LocalAPI.swift)：分号分人，姓逗号名、团体作者与 CSL family/given/literal。 | S/X/A：宏/团体名/CSL 结构；多语言姓名仍须来源核对。 |
| 状态 | [ReferenceDetail](../../Sources/PaperShelf/Views/ReferenceDetail.swift)、[Reference](../../Sources/PaperCore/Reference.swift)：备注、0–5 星、再次点击同一星清零、已读与收藏。 | X：评分范围、替换保留；重复点击清零 UI 待验。 |
| PDF 链接 | [PDFLinks](../../Sources/PaperCore/PDFLinks.swift)、[Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)：原位书签、指定 reader bundle ID/系统默认、打开/Finder/替换。 | S/P/X：书签与失效路径；不同外部阅读器启动 UI 待验。 |
| 附件 | [ReferenceAttachment](../../Sources/PaperCore/Reference.swift)、[Attachments](../../Sources/PaperShelf/Stores/LibraryStore+Attachments.swift)、[Table](../../Sources/PaperShelf/Views/LibraryTable.swift)：主 PDF 与任意文件分开存储和展示。 | P/X：任意文件书签、备份恢复与源保留；实际多附件选择 UI 待验。 |
| PDF 预览 | [ContentView](../../Sources/PaperShelf/Views/ContentView.swift)、[ReferenceDetail](../../Sources/PaperShelf/Views/ReferenceDetail.swift)：原生 Quick Look、缺文件错误、初次/手动刷新，以及激活应用/Quick Look 状态/PDF 路径改变时刷新批注。 | 实现已核对；不同外部阅读器保存后自动刷新与 Quick Look 开关流程 UI 待验。 |
| 批注 | [PDFLinks](../../Sources/PaperCore/PDFLinks.swift)：Highlight/Underline/StrikeOut/Text/FreeText/Square/Circle；读取结果整体替换。 | P/S：实际 PDFKit fixture；不同阅读器生成的注释兼容性未穷尽。 |
| 批注数据 | [PDFLinks](../../Sources/PaperCore/PDFLinks.swift)：页号/标签、区域、所选文字、评论、颜色、区域 PNG。 | P：分离 quad 不夹入中间正文，区域图像存在，原 PDF 字节不变。 |
| OCR | [PDFLinks](../../Sources/PaperCore/PDFLinks.swift)、[Settings](../../Sources/PaperShelf/Views/LibrarySettingsView.swift)：无文本区域可选本机 Vision，标明来源。 | P：真实扫描 fixture OCR；这是 PaperShelf 增强功能，输入证据没有证明 Lattice 具有 OCR。 |
| 元数据模板 | [PaperDetailedExport](../../Sources/PaperCore/PaperDetailedExport.swift)、[Settings](../../Sources/PaperShelf/Views/LibrarySettingsView.swift)：变量、嵌套非空条件、保存模板、两个模板各自恢复默认和元数据预览。 | P：条件/字面内容/自定义字段；设置保存、独立 reset/实时预览 UI 待验。 |
| 批注模板 | [PaperDetailedExport](../../Sources/PaperCore/PaperDetailedExport.swift)、[ReferenceDetail](../../Sources/PaperShelf/Views/ReferenceDetail.swift)：type/page/text/comment/color/image 逐条渲染；界面复制 Markdown 使用自定义模板和图片。 | P：模板和图像输出测试；真实长批注排版与剪贴板粘贴仍需目检。 |
| 模板链接 | [PaperDetailedExport](../../Sources/PaperCore/PaperDetailedExport.swift)：collectionPaths、paper URL、PDF URL 与兼容变量。深链目标是 PaperShelf。 | P：渲染内容；导出中实际点击各链接 UI 待验。 |
| 详细导出 | [PaperDetailedExport](../../Sources/PaperCore/PaperDetailedExport.swift)、[Files](../../Sources/PaperShelf/Stores/LibraryStore+Files.swift)：无图 Markdown、有图 TextBundle、每篇独立产物、citekey 优先/标题回退/防覆盖。 | P：每张图包含、文件碰撞不覆盖；不同目标笔记软件导入待验。 |
| 引文键 | [Bibliography](../../Sources/PaperCore/Bibliography.swift)、[Settings](../../Sources/PaperShelf/Views/LibrarySettingsView.swift)、[Store](../../Sources/PaperShelf/Stores/LibraryStore.swift)：auth/Auth/author/year/shortyear/title/title-N/id、实时示例预览、元数据更新可重算、冲突后缀。 | X：重音/中文姓名、ISO 日期、N=0/超大 N、保留原 key、大小写碰撞和保留 key；实时 UI 待验。 |
| 引文交换 | [Bibliography](../../Sources/PaperCore/Bibliography.swift)、[Files](../../Sources/PaperShelf/Stores/LibraryStore+Files.swift)、[Batch](../../Sources/PaperShelf/Stores/LibraryStore+Batch.swift)：BibTeX/RIS 文件/剪贴板、字段选择。选中、当前列表、全部文献三个范围均有明确菜单。 | X：精确 roundtrip/字段筛选；原生 UI 已观察三个范围及各格式子菜单，导出内容另有 Core 测试。 |
| BibTeX 解析 | [Bibliography](../../Sources/PaperCore/Bibliography.swift)：类型、string 宏、# 拼接、花括号/引号/裸值/圆括号，comment/preamble。 | S/X：解析和转义测试。不是完整 TeX/BibLaTeX 渲染器。 |
| 文件库 | [Preferences](../../Sources/PaperShelf/Models/LibraryPreferences.swift)、[Attachments](../../Sources/PaperShelf/Stores/LibraryStore+Attachments.swift)、[Files](../../Sources/PaperShelf/Stores/LibraryStore+Files.swift)：授权根目录、导入后规则、选中批量应用，Zotero 复制到文件库，恢复可选根目录。 | P/X：路径与安全复制；浏览器下载动态跟随设置的文件库，写入 BrowserCaptures 子目录；未配置时使用书库目录。新增路径测试通过。 |
| 文件操作 | [PaperFileOrganizer](../../Sources/PaperCore/PaperFileOrganizer.swift)：link/copy/move；命名模板与分组独立，复制保留原件。 | P：复制/移动/回滚/碰撞；移动显式确认与文件 UI 待验。 |
| 整理规则 | [PaperFileOrganizer](../../Sources/PaperCore/PaperFileOrganizer.swift)：不分组/年份/完整文集路径/姓首字母，Unsorted、缺字段保留原名、重名编号。 | P：路径、碰撞、缺字段、symlink 逃逸拒绝；大库真实组织待验。 |
| 文件布局 | [PaperFileOrganizer](../../Sources/PaperCore/PaperFileOrganizer.swift)：每篇独立目录或 PDF/Attachments 分区。 | P：Core 导出/路径测试；两种布局批量迁移 UI 待验。 |
| 文件回滚 | [LibraryFilePreparation](../../Sources/PaperShelf/Services/LibraryFilePreparation.swift)、[Attachments](../../Sources/PaperShelf/Stores/LibraryStore+Attachments.swift)：后台准备、逐篇提交、并发附件变更/DB 写失败回滚当前篇，进度/取消保留已提交篇。 | P：单文件回滚；F：实际 Store 取消/并发/写失败回滚、64 MiB 附件复制时取消。文件任务面板交互 UI 待验。 |
| 删除附件 | [Batch.trashLinkedFiles](../../Sources/PaperShelf/Stores/LibraryStore+Batch.swift)：单独明确移入系统废纸篓、共享文件检查、失败回滚；删除记录默认保留文件。 | 源码与编译；Finder 废纸篓实际恢复和失败注入 UI 待验。 |
| Zotero | [ZoteroImporter](../../Sources/PaperCore/ZoteroImporter.swift)、[Files](../../Sources/PaperShelf/Stores/LibraryStore+Files.swift)：元数据/文集/笔记/标签/附件，只读源快照；metadata-only 或只复制附件，授权外链根。 | X：提交 WAL、源字节不变、attachments: 正常/越界/符号链接/缺文件、metadata-only、取消；F：强制复制、并发重复无遗留拷贝、取消。真实 Zotero 用户库迁移 UI 待验。 |
| 备份 | [LibraryBackup](../../Sources/PaperCore/LibraryBackup.swift)：一致 SQLite snapshot、文献/分类/标签/模板设置、可含 PDF/附件、manifest 和 SHA256。 | X：哈希、关系、版本、路径、书签、长文件名、模板设置；API 权限不随备份授予。 |
| 恢复 | [LibraryBackup](../../Sources/PaperCore/LibraryBackup.swift)、[Files](../../Sources/PaperShelf/Stores/LibraryStore+Files.swift)：验证后安全备份，原子替换数据，所选目录新建唯一附件子目录；未含文件保留原路径。 | X：安全副本、选定根目录不覆盖、原文件保留、事务回滚、篡改拒绝；面板授权 UI 待验。 |
| Shortcuts | [PaperShelfIntents](../../Sources/PaperShelf/Services/PaperShelfIntents.swift)：搜索/选取一个或多个、打开、模板导出 Markdown 文件（包含批注与图像）；直接返回笔记文本并可选复制到剪贴板。 | I：4 个动作元数据与 UUID 属性；返回文本动作经过实际隔离 AppIntent harness 验证；Shortcuts 检索已发现动作，实跑被系统 Team ID 校验拒绝；剪贴板和 Siri/Spotlight 仍未验收。 |
| 本地 HTTP | [LocalAPIServer](../../Sources/PaperShelf/Services/LocalAPIServer.swift)、[LocalAPI](../../Sources/PaperCore/LocalAPI.swift)、[Settings](../../Sources/PaperShelf/Views/LibrarySettingsView.swift)：默认关闭、回环监听、随机 token、端口/只读/可信目录/Origin、JSON 能力。 | A：实际监听、鉴权、Host/Origin、只读、0600 连接文件。生产 App 启停/改端口连续操作需独立 UI 验收。 |
| 公共 API | [LocalAPI](../../Sources/PaperCore/LocalAPI.swift)、[Store Integration](../../Sources/PaperShelf/Stores/LibraryStore+Integration.swift)：status/search/detail/metadata/collections/tags/create/PDF bytes/CSL 与显式隐私字段。 | A：40 项真实隔离请求；主代理观察过主 App PDF 上传。完整生产库流程未一概验收。 |
| 深链 | [Store Integration](../../Sources/PaperShelf/Stores/LibraryStore+Integration.swift)、[build script](../../script/build_and_run.sh)：注册 **papershelf://paper/{UUID}**，聚焦对应文献。 | 构建接入和源码核对；有意不注册/劫持 lattice scheme，外部触发定位 UI 待验。 |
| 浏览器 | [BrowserExtension](../../BrowserExtension/README.md)、[CaptureReceiver](../../Sources/PaperShelf/Services/BrowserCaptureReceiver.swift)：Safari/Chrome/Edge/Firefox 打包，页面预览、分类/标签、PDF 选择、重复处理、失败保留元数据。 | B：打包/静态/fixture；没有四浏览器工具栏点击 E2E，Safari 临时签名与 Firefox 持久签名限制须保留。 |
| 浏览器连接 | [BrowserExtension](../../BrowserExtension/README.md)、[BrowserCapture](../../Sources/PaperCore/BrowserCapture.swift)：独立 **papershelf://capture** 协议，由主应用确认导入；不依赖 Local API 端口。 | B：envelope/时间/大小/网络地址测试。有意不同于 Lattice 的端口重连；本地 fake DNS 导致真实 W3C PDF 下载被拒绝，未绕过。 |
| CLI | [PaperShelfCLI](../../Sources/PaperShelfCLI/main.swift)：状态/搜索/get-paper/by-reference/CSL/metadata/分类/标签、创建/标识符添加/PDF 上传。 | A：真实二进制运行；每条命令能力以 CLI help 与服务器协商为准。 |
| AI 接口 | [PaperShelfCLI](../../Sources/PaperShelfCLI/main.swift)、[portable Skill](../../IntegrationsAPI/papershelf-library/SKILL.md)：Skill 导出、MCP 与 HTTP 同一权限策略；学习 Agent 为另一明确入口。 | A：MCP initialize/list/call、只读不宣传写入、Skill 导出与拒绝覆盖；不代表任意外部客户端全部验收。 |
| 第三方接口 | [Word](../../IntegrationsUI/Word/README.md)、[Raycast](../../IntegrationsUI/Raycast/README.md)：独立引用适配器，Word 文档内状态/CSL 与 Raycast 检索/复制功能，保持 API token 在本机。 | W/R：测试、manifest/typecheck/build、真实隔离 API；Word/Raycast 均未完成宿主侧载与交互，Word 11 项、Raycast 8 项通过，Word 无 node_modules 独立运行包与实际 HTTPS/Swift API 联通通过。 |
| 设置/帮助 | [Settings](../../Sources/PaperShelf/Views/LibrarySettingsView.swift)、[App](../../Sources/PaperShelf/App/PaperShelfApp.swift)、[Guide](../../Guide.md)：中英入口、明暗外观、阅读器、使用/快捷键说明。 | 本地化资源 plutil 与编译；语言切换覆盖、菜单/AppKit 动态文案和完整导览 UI 待验。 |
| 商业策略 | 不实现 Lattice 免费 50 篇/Pro 购买策略；不是用户要求的 PaperShelf 限制。 | 明确排除，不计为已复刻或缺失的科研功能。 |

## 原始学习增强需求继续保留

[LearningView](../../Sources/PaperShelf/Views/LearningView.swift)、[backend pipeline](../../backend/papershelf_pipeline/pipeline.py) 保留自动 HTML/Markdown、逐段来源、可编辑字段数据集、便携 Agent 和知识图谱。CATDA 只参考流程，字段 schema 由 PaperShelf 自定义，未引入其代码。MarkItDown、Paper2Agent、Graphiti 是固定版本子模块，适配代码独立，更新命令/锁与真实验证见 [upstream 集成说明](../../integrations/README.md)、[集成验收](../../integrations/VERIFICATION.md) 及 [学习验收](../learning-acceptance.md)。Lattice 功能扩充不替代这些既有成果，也不将文本覆盖率、单元测试或图谱写入成功解释成科学含义已被接受。

## 尚未完成的宿主验收与明确差异

1. 浏览器四宿主真实安装/点击、Word 文档引用/书目更新、Raycast 交互尚未验收。Shortcuts 已发现四动作但执行被缺失 Team ID 阻止；Siri/Spotlight 未验收。详见 [签名与宿主限制](signing-and-hosts.md)。
2. 浏览器采用自有 URL 协议；深链仅注册 PaperShelf；文集允许任意层级。上述是明确的产品决策，不冒充与 Lattice 内部协议一致。
3. 浏览器下载根目录已统一读取文件库设置；三范围导出菜单、模板独立恢复与预览已做原生交互观察。公开 PDF 下载仍受本机保留网段 DNS 限制，未绕过。
4. 本机目标为 macOS 27、arm64 临时签名；没有 Developer ID 公证、Intel/macOS 14 或干净系统安装验收。不得以 Lattice 的 universal/macOS 14 静态信息归于 PaperShelf。
5. 普通文献/批注/元数据与学习生成内容的技术正确性分别验证；网络元数据、OCR、模型学习稿和 Graphiti 事实仍需按来源审阅。

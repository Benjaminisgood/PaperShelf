# PaperShelf · 文献架

一个已经可以在本机运行的原生 macOS 文献管理初版。独立实现 Lattice 公开描述中的部分工作流，与 Lattice 无关联，不包含其源码、品牌或图片。REA 用于开发侧静态检查，不是应用运行依赖。

## 打开与构建

- 本机交付目录包含已构建应用 `dist/PaperShelf.app`，双击打开。Git 仓库不提交构建产物；克隆仓库后请先运行构建脚本。当前本机二进制为 Apple Silicon / arm64，版本 0.1.0，使用临时签名，未做 Developer ID 签名或公证。
- 重新构建并打开：双击 `Launch PaperShelf.command`，或运行 `./script/build_and_run.sh`。需要 Xcode / Swift 工具链。
- 只构建：`./script/build_and_run.sh --build-only`。
- 测试：`swift test`。
- 最低部署目标 macOS 14；实际构建和操作检查在当前 Apple Silicon 主机完成，未在 macOS 14 实机或 Intel Mac 上验收。
- 项目根配置了 Codex 的 Run 按钮，可直接打开该目录开发。

## 现在可以做什么

1. 从工具栏导入 PDF、UTF-8 BibTeX 或 RIS；PDF 仅保存原文件路径和安全书签，不复制、不修改。
2. 手动添加文献、编辑作者/年份/来源/DOI/摘要、记录阅读笔记，设置单层分类、多标签、已读与收藏。
3. 搜索标题、作者、来源、年份、DOI、笔记和标签；用侧边栏筛选，按导入时间或标题排序。清除搜索可点击输入框右侧叉号或按 Esc。
4. 输入 DOI 或 doi.org URL，从 Crossref 获取元数据。查询会向 Crossref 发送该 DOI；应用没有自己的后端和同步服务。
5. 打开原始 PDF、在 Finder 定位、重新关联附件。找不到附件时提示重新关联。
6. 读取 PDF 中已有的高亮、下划线、删除线和文字批注，显示页码和评论，可复制为 Markdown。文字根据批注矩形边界提取，复杂排版需核对。
7. 导出当前筛选列表或选中文献为 BibTeX，导出当前列表为 Markdown，复制单篇 BibTeX。
8. 资料库自动持久化；显式保存编辑，重复 DOI / 相同 PDF 路径的批量导入会跳过已有记录，不覆盖笔记。没有 DOI 和 PDF 的相同文献暂不做模糊去重。

快捷键：⌘I 导入、⌘N 手动添加、⇧⌘E 导出当前列表。双击列表记录打开 PDF。右键菜单可移除记录；只移除数据库记录，原 PDF 保留。初版没有撤销和回收站。

## 数据位置与范围

默认书库：`~/Library/Application Support/PaperShelf/library.sqlite`。数据包含 JSON 记录与索引，使用 SQLite WAL。完整保留标题、作者、年份、来源、DOI、URL、摘要、笔记、标签、分类、已读/收藏、时间与附件书签。应用检测到无法读取的书库时停止写入；不自动重建覆盖。

若手动备份，先完全退出应用，再备份整个 `PaperShelf` 应用支持目录。BibTeX / Markdown 是交换格式，不是完整备份，不包含附件书签、已读状态等所有本地信息。初版尚无内置备份恢复按钮。

`PAPERSHELF_LIBRARY_PATH` 环境变量可指定测试库路径。此次界面验收使用独立测试库，没有导入用户真实文献。`Examples/` 提供两篇明确标为虚构的 BibTeX 示例及一个带文字批注的合成 PDF，可自行导入试用。

## 实现结构

```text
SwiftUI 原生窗口、三栏、表格、编辑 sheet
  └─ LibraryStore（主线程状态与操作编排）
       ├─ LibraryDatabase → 系统 SQLite（事务、唯一 DOI、schema v1）
       ├─ Bibliography → BibTeX / RIS 解析、BibTeX / Markdown 导出
       ├─ DOIClient → URLSession → Crossref HTTPS API
       └─ PDFLinks → Foundation 书签 + PDFKit 读取
                       AppKit 负责文件选择、打开与 Finder 定位

开发侧 REA CLI → 检查已构建 .app 的 Mach-O / Info.plist
```

SwiftPM 构建，无第三方 Swift 依赖；使用 Swift 6.4 编译器、Swift 5 语言模式。`PaperCore` 为可测试逻辑库，`PaperShelf` 为 GUI 可执行产品。当前全部元数据载入内存后搜索，尚未引入 FTS 索引或大书库后台导入。

## 已验证与尚未完成

最新自动测试 **22 项，0 失败**：7 项格式、4 项 DOI/网络模拟、9 项数据库、2 项 PDF。原始日志 `evidence/swift-test.log` 保留在本机；可运行 `swift test` 复现。另实际完成了 BibTeX 文件导入、中文笔记/分类保存、PDF 关联、批注读取、无效 DOI 提示、真实 Crossref DOI 查询、搜索和清除、BibTeX 导出、退出再启动恢复。见 `evidence/qa.md` 和截图。Git 仓库保留验证总结，不上传含本机绝对路径的原始日志与 JSON 证据、数据库、构建缓存或 .app。

尚未完成：Zotero 数据库迁移、RIS 导出、Quick Look / Space 快捷预览、拖放与批量编辑、多级集合和一篇文献属于多个集合、自定义模板、TextBundle、Shortcuts、浏览器扩展/插件、自动归档、OCR、区域图片批注、云同步、内置备份恢复、附件移动后的自动书签刷新。未进行规模/性能、长期数据迁移、全量无障碍或公证分发验收。

格式支持边界：支持常见 BibTeX 嵌套花括号、字符串宏和拼接，以及多条/多行 RIS；不是完整 BibLaTeX 引擎。原始引用键、文献类型、卷期页码与未知字段不保留，导出统一使用 article 和生成的键；不解析 crossref/xdata 继承，不渲染任意 LaTeX，作者不区分个人与机构。跨工具的真实库迁移需要单独验收。分类使用 `papershelf_collection` 扩展字段。

## 来源与许可

- [检查与比较报告](ASSESSMENT.zh-CN.md)
- [REA 审计](evidence/rea-audit.md) / [实际 REA 运行证据](evidence/rea-local-verification.md)
- [Lattice 审计](evidence/lattice-audit.md)

本项目独立新增代码使用 MIT，见 `LICENSE`。REA 自有代码是 MIT，但其第三方组件及外部分析器分别适用各自条款；本 app 未打包 REA。Lattice 的公开仓库不等于开放源码许可，相关产品名称属于其各自权利人。

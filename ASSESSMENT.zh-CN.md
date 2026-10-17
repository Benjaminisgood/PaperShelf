# rea 与 Lattice：可行性、实现和差距

检查日期：2026-10-18（Asia/Shanghai）。本报告基于实际获取的仓库，未沿用先前聊天中未经核实的技术判断。

## 核心结论

可以借助 rea 做开发调查，并独立实现一个功能相近的原生文献管理器。不能把 rea 视为可以直接改造的文献管理器：它的主业务是分析软件，没有 Lattice 式书库模型、文献 UI 或 DOI/BibTeX 工作流。本次已采用这个判断实施 PaperShelf 0.1.0，并实际构建、运行和检查。

## 源码和许可证对比

| 维度 | rea | Lattice: Reference Manager |
| --- | --- | --- |
| 固定提交 | `3fcba07962a1f9f23130a5210dba242f6a331a5b`，版本 6.5.0 | `001dcbbc97ff40536adc0dcee8125239c071544b`，文档最新版本 2.1.6 |
| 定位 | 本地逆向分析 CLI / MCP 服务 | 原生 macOS 文献管理应用 |
| 技术栈 | TypeScript / Node.js / ESM，MCP SDK、CLI、Playwright、Babel；桥接包含 Python/Java/少量 Swift/C++ | 作者声明 Swift 原生，macOS 14+；更新日志提及 AppKit 设置界面 |
| 可核实架构 | CLI/MCP → composition → application/session → provider adapters → Hopper/Ghidra/IDA 或静态分析器 | 公开文档说明本地存储、链接 PDF、直接访问元数据服务；主 UI 框架和数据库引擎没有源码证据 |
| 功能 | Mach-O/原生程序、JS/Electron、.NET、Android、网站、SQLite、包和资源等软件分析 | 三栏书库、PDF/BibTeX/RIS/DOI/Zotero 导入、分类标签、批注、模板导出、快捷指令 |
| 源码许可 | 自有代码 MIT，保留声明即可按条款复用；第三方组件单独核查 | 未发现 LICENSE/COPYING，GitHub license:null；网站 All rights reserved；没有完整 Swift 源码 |

证据：[rea README](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/README.md#L61-L65)、[架构图](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/docs/architecture.mermaid)、[MIT](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/LICENSE)、[第三方声明](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/THIRD_PARTY_NOTICES.md)；[Lattice Swift/macOS 声明](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md#L15-L20)、[最新功能](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/CHANGELOG.md#L7-L15)、[隐私架构说明](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/docs/privacy.html#L68-L74)、[权利声明](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/docs/privacy.html#L131)。

REA 的 MIT 不授予被分析程序的版权，也不授予 Hopper、IDA、JEB 等商业分析器许可。此次没有复制 Lattice 代码、图标、图片或界面素材，没有下载/反编译它的二进制。公开功能描述用作行为参考，PaperShelf 的代码、名称和界面独立编写。这不构成对未来复制其资产或二进制内容的授权判断。

## 为什么选这个架构

以 SwiftUI、系统 SQLite、PDFKit、Foundation、AppKit 和 URLSession 组成原生应用，可直接覆盖书库与文件工作流，不需要将 Node、MCP 服务或反编译器放入用户应用。

- SQLite 保存完整 JSON 记录，另为 DOI 与 PDF 路径建索引；事务导入，重复项跳过，未来 schema 明确拒绝，损坏记录报错并禁用该次打开的写入。
- PDF 文件保留原位，数据库只存路径与安全书签；附件缺失时显式重新关联。
- 解析/导出、网络查询和数据库隔离成可测试的 PaperCore，SwiftUI 只组织视图和用户操作。
- Crossref 只在用户请求时查询 DOI；无后台上传 PDF 或笔记。
- REA 保留在开发侧。本次已经真实运行它的 `inspect-macho` 和 `inspect-plist` 检查自有应用，确认原生包元数据、arm64、最低系统版本、动态链接依赖，且检查前后文件哈希不变。它没有提供 Lattice 内部实现证据。

## 实现顺序与状态

| 优先级 | 核心能力 | 本次状态 | 后续补齐 |
| --- | --- | --- | --- |
| P0 | 可持久化本地书库 | 已实现并验证 | 内置备份/恢复、版本迁移与长期耐久性验收 |
| P0 | PDF 链接、编辑、搜索、分类标签 | 已实现基本闭环 | 批量编辑、拖放、多集合、多级分类、全文检索 |
| P0 | BibTeX / DOI 导入、BibTeX / Markdown 导出 | 已实现，有限字段映射 | 保留卷期页码、文献类型、引用键及更复杂姓名语义 |
| P1 | RIS 导入 | 已实现且有解析测试 | RIS 导出、真实大库迁移验收 |
| P1 | PDF 批注 | 已实现文字评论和边界文本读取 | 精确 quad-point 高亮、图片区域、颜色、OCR、Quick Look |
| P2 | 迁移与自动化 | 未实现 | Zotero、模板、TextBundle、Shortcuts、插件、自动归档 |

Lattice 明确偏向外部 PDF 阅读器，本初版也使用系统默认阅读器打开原文件，没有把“内置完整阅读器”列为复刻目标。Lattice 的文件策略还包括可选自动复制/移动归档，不能笼统声称它绝不会复制 PDF。

## 验证结论与交付边界

PaperShelf 已构建成可双击的 .app，并在当前机器启动。22 项自动测试通过，真实界面验收及一次真实 Crossref 查询通过，详见 `evidence/qa.md`。完整源码、样例、构建脚本和审计总结均随项目提供；含本机路径的原始 JSON 证据与测试日志只在本机保留，不随 Git 仓库上传。

这是一版可运行的基础实现，不是 Lattice 全功能复刻，也不是生产发行版。仍缺少上一表中的后续能力，未做 Intel / macOS 14 实机验收、公证分发、大规模性能和长期迁移测试。源码审计与 Mach-O 检查不代替功能验收；22 项测试也不意味着所有学术文献格式或批注提取都准确。

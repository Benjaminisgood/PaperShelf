# REA 源码与许可证审计

审计日期：2026-10-18（Asia/Shanghai）。审计对象为 `morluto/rea` 的固定提交 [`3fcba07962a1f9f23130a5210dba242f6a331a5b`](https://github.com/morluto/rea/tree/3fcba07962a1f9f23130a5210dba242f6a331a5b)，包版本 6.5.0。以下是源码和项目文档能够支持的事实；本报告不表示已运行全部功能或通过上游测试。

## 结论

REA 是本地逆向分析 CLI/MCP 工具，适合作为开发时的调查工具，不是文献管理应用的代码基础。其代码没有提供 PaperShelf 所需的书库、文献元数据、DOI/BibTeX/RIS 导入或 PDF 阅读界面。正确的技术路径是独立实现 Swift 文献管理器，按需要使用 REA 收集可追溯证据。不能把使用 REA 描述为恢复了 Lattice 的原始 Swift 源码。

## 技术栈与架构

| 项目 | 已核实事实 | 固定版本证据 |
| --- | --- | --- |
| 运行时 | TypeScript、Node.js ESM；编译为 ES2023/NodeNext，启用 strict | [tsconfig.json](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/tsconfig.json#L7) |
| 用户入口 | `rea`/`rea-agents` CLI 与 MCP stdio server；共用应用工作流和 provider/session 语义 | [package.json:40](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/package.json#L40)、[binary.ts:16](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/src/composition/binary.ts#L16) |
| 主依赖 | MCP SDK、Zod、Incur、Babel、Playwright Core、ASAR、node-pty 等 | [package.json:320](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/package.json#L320) |
| 跨语言桥 | Python 对接 Hopper/LLDB，Java 对接 Ghidra/JADX，少量 Swift macOS 工具，C++ Windows Node-API 插件；主程序不是 Swift | [package.json:48](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/package.json#L48) |
| 分层 | CLI/MCP → composition → application/BinarySession → provider adapters；contracts/domain 定义分析事实、Evidence、unknown 和生命周期 | [架构图源码](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/docs/architecture.mermaid#L2) |
| 检查工具 | Vitest、TypeScript、Oxlint/Oxfmt；构建使用 Rolldown/Turborepo | [package.json:370](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/package.json#L370) |

文档覆盖原生二进制、JavaScript/Electron、网站、.NET、Android、固件、SQLite、网络记录和 Apple 包资源分析。深度原生分析需要相应 provider；部分 bundle/Mach-O/Swift 元数据静态检查可以使用 macOS 自带工具和内置解析器。[功能表](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/README.md#L164)、[Swift/ObjC 静态元数据边界](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/docs/native-investigation.md#L373)。

Apple application graph 只投影已有 inventory、路径、哈希和部分框架提示，明确不把这些提示当成运行事实。[证据](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/docs/apple-application-analysis.md#L3)。REA 的 SQLite 模块是分析数据库副本的只读检查器，并不是可直接用于书库 CRUD 的数据库层。[实现](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/src/sqlite/SqliteDatabaseInspection.ts#L505)。

## 构建条件

运行支持 Node `^22.19.0 || ^24.11.0 || >=26.0.0`；仓库固定 Node 24.18.0、npm 11.16.0。标准源码流程是 `npm ci` 后 `npm run build:cached`。SQLite 检查还要求具备 native SQLite limits API 的 Node 24.15+ 或 26+。深层原生分析器另行提供，不能把 checkout 或一次成功 CLI 调用当成所有 provider 可用。[运行条件](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/package.json#L44)、[Node 固定版本](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/.nvmrc)、[构建提示](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/scripts/rea.mjs#L43)。

## 许可范围

- REA 自有代码为 MIT，允许使用、修改、分发和商业使用；复制实质部分须保留版权与许可声明。[LICENSE](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/LICENSE#L1)
- 此 MIT 不授予 Lattice 或其他被分析软件的权利，也不授予 Hopper、IDA、JEB 等专有工具的许可。[第三方声明](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/THIRD_PARTY_NOTICES.md#L3)、[分析输出边界](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/DISCLAIMER.md#L68)
- 分发 REA 时需要同时审查实际携带的第三方材料。Ghidra 为自行提供的 Apache-2.0/组件许可软件；Windows 插件还带有 MinGW/GCC runtime exception 条款；外部引擎不因被调用而成为 MIT。[依赖与派生代码](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/THIRD_PARTY_NOTICES.md#L18)、[外部引擎](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/THIRD_PARTY_NOTICES.md#L51)
- 上游明确记录 `clean-git-ref`、`minimisted` 和可选 Frida 的部分版权/许可原文缺失；Frida 声明 `LGPL-2.0 WITH WxWindows-exception-3.1`，补充材料不等于完整归属证明。[已知缺口](https://github.com/morluto/rea/blob/3fcba07962a1f9f23130a5210dba242f6a331a5b/THIRD_PARTY_NOTICES.md#L24)

PaperShelf 因此不打包 REA、Node、Frida 或反编译引擎；REA 仅在工作目录中用作开发工具。此次不下载、不反编译 Lattice。Lattice 的公开功能介绍可用于需求比较，源码、品牌和资源的复用权需独立核实。

## 本地执行证据

本地 REA 准备与对本项目自有 PaperShelf 构建产物的静态检查另存为同目录的 `rea-local-verification.md` 和相应原始输出。该检查仅确认所记录的命令与目标，不能证明 PaperShelf 的全部功能或 Lattice 的内部实现。

# REA 本地准备与验证

2026-10-18，本项目在开发工作目录内构建并实际运行 REA 6.5.0，固定提交 `3fcba07962a1f9f23130a5210dba242f6a331a5b`。未全局安装，未更改 agent/MCP 配置，未下载或分析 Lattice 二进制。

原始 `.log` / `.json` 文件包含本机路径，仅在本机保留，不随 Git 仓库上传；以下文件名用于定位本机记录。当前文档记录的是迁移前产物的历史静态检查，迁移后构建由 `relocation-check.md` 另行说明。

## 已执行

| 检查 | 结果 | 原始记录 |
| --- | --- | --- |
| 依赖安装 | 成功，540 packages；使用 `--ignore-scripts`，跳过第三方生命周期脚本及 Husky 注册 | `rea-dependency-install.log` |
| 源码构建 `npm run build:cached` | 成功，3/3 tasks，工具报告 4.678 秒；出现两个不影响构建的 dynamic import 分包提示 | `rea-build.log` |
| CLI 版本 | 实际返回 6.5.0 | `rea-setup.json` |
| `inspect-macho --help` | 成功；命令声明不启动 Hopper | [rea-inspect-macho-help.txt](rea-inspect-macho-help.txt) |
| `inspect-plist --help` | 成功；命令声明不启动 Hopper | [rea-inspect-plist-help.txt](rea-inspect-plist-help.txt) |
| macOS 工具 | Xcode 的 `otool`、`lipo` 和系统 `plutil` 均存在 | 本地路径检查 |
| REA 工作区 | 构建后受跟踪源码无改动 | `rea-setup.json` |

使用本机已有 Node 24.19.0 与局部 npm 11.16.0。Node 24.19.0 在仓库支持范围内，但不是 `.nvmrc` 固定的 24.18.0；未另行替换系统 Node。默认系统 Node 25.9.0 不在 REA 声明的支持范围，未用于 REA 构建和检查。依赖缓存和 REA 构建输出均保存在 `work/`；不进入 PaperShelf 应用。

REA 上游完整测试套件没有执行。本次准备验证只证明所记录版本可以在本机编译、启动并展示命令帮助。PaperShelf 自身的编译、测试和界面验证另行记录。

## PaperShelf 产物静态检查

两条实际命令均成功退出（0），provider 为 `native-macos`，stderr 为空。检查前后的可执行文件与 Info.plist 哈希一致，未发生目标变更。命令、时间、输出哈希和 Evidence ID 记录在 `rea-papershelf-verification.json`。

| 静态事实 | 观察结果 |
| --- | --- |
| 文件格式与 CPU | 64 位 little-endian Mach-O，arm64 |
| Bundle 标识 | `local.papershelf.library` |
| 版本 | 0.1.0（build 1） |
| 最低系统声明 | macOS 14.0；Info.plist 和 Mach-O build metadata 一致 |
| 已链接依赖 | 包含 SwiftUI、AppKit、PDFKit、Foundation、Combine、SQLite 和 Swift runtime |

- `rea-papershelf-macho.json`
- `rea-papershelf-plist.json`

可执行文件 SHA-256：`7d08968c8559dc884521f4234f371a6bd3259590de71553bbd74113ca24a8998`。

REA 说明导入/导出符号来自 `dyld_info` 与 `nm`，被裁剪或工具隐藏的符号可能缺失；`vtool` 结果保留为来源，规范化 build metadata 来自 `otool`。本次检查能够确认产物的静态结构和依赖，不能证明界面、文献导入等业务行为，也不涉及 Lattice 的内部实现。后续如重新构建应用，应重新生成本组证据并核对哈希。

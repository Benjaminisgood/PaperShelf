# 签名与外部宿主

2026-10-18 实测，主应用 `dist/PaperShelf.app` 为 arm64、macOS 27、ad-hoc 签名。`codesign --verify --deep --strict` 成功，主窗口与文库功能可运行。本机 `security find-identity -p codesigning -v` 没有有效签名身份。

## 快捷指令

系统快捷指令的动作检索已显示搜索、打开、Markdown 文件导出和笔记文本四个动作。创建 `PaperShelf 搜索（需开发签名）` 示例并实际运行搜索，系统显示 `LinkDaemon.ProcessRegistry.Errors 0`。系统日志明确报告 `Unable to get teamId from local.papershelf.library`，见 [签名失败日志](shortcuts-signing-block.log)。没有伪造 Team ID、修改 entitlement 或绕过系统检查。

AppIntent 逻辑另用真实隔离库执行通过，见 [notes-intent-harness.log](notes-intent-harness.log)。这不等于 Shortcuts 宿主执行成功。

有有效 Apple Development / Developer ID Application 签名身份后，正常退出 PaperShelf，运行：

```sh
PAPERSHELF_SIGN_IDENTITY='实际签名身份名称' ./script/build_and_run.sh --build-only
```

脚本签名 CLI 与主应用并校验，再打开应用重新验收快捷指令。需要使用真实证书，不能靠自行填写 team entitlement 替代。该入口尚未在本机有效证书上验证，也不等于完成公证。

## 浏览器

Safari 包已编译，但正式启用需要有效开发者签名；没有打开允许未签名扩展。Chrome/Edge 展开包可按 README 在开发模式加载；Firefox 永久安装需要 Mozilla 签名。四个浏览器均未完成真实工具栏点击验收。

## Word 与 Raycast

Word 自包含 Node HTTPS 主机、11 项测试、官方 manifest 校验及隔离 Swift API 联通已完成；加载项需可信 localhost 证书和 Word 侧载，尚未对真实文档操作。没有安装 CA 或关闭 TLS 验证。

Raycast 三个命令构建、类型检查、8 项测试和实际本地 API 检索通过；尚未在 Raycast 宿主导入/操作。

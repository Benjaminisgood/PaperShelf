# 浏览器采集验证

2026-10-18，本机 macOS 27.2 / Xcode 27.1。扩展及接收协议为独立实现，没有复制 Lattice 扩展代码。

- `node --test BrowserExtension/tests/*.test.cjs`：8 项通过。覆盖 Citation、Dublin Core、JSON-LD、直接 PDF、完整 Unicode/选中文字、危险地址、超限拒绝及最小权限。页面解析测试使用可控 DOM 样本，未冒称各出版商实站完整兼容。
- `swift test --filter BrowserCaptureTests` 的已构建测试集：7 项通过。覆盖字段完整往返、URL envelope、重复参数、未知字段、过期/未来时间、超限/控制字符、DOI/年份、回环/私有/保留 IP、IPv4 非标准表示、IPv6 过渡地址。一次失败暴露 macOS `inet_pton` 接受前导零 IPv4，已补充标准十进制八位组验证并通过重测。
- `BrowserCaptureReceiver`、`BrowserCaptureDownloader` 独立 Swift typecheck 通过。确认框完整滚动显示元数据；候选 PDF、文集、标签由用户选择；重复文献先选择跳过/替换/打开已有，下载在确认之后才开始。主应用已编译接入，下载目标动态读取设置的文件库；新增测试覆盖更换目录、唯一命名、非法根和符号链接越界。完整采集确认交互仍待验收。
- 额外使用公开 W3C dummy PDF 地址尝试真实下载；本机 DNS 将 `www.w3.org` 解析到保留网段 `198.18.0.51`，接收器按公开网络规则拒绝，未继续传输。因此本次不能宣称公开 PDF 实际下载成功；此类本地代理/虚拟 DNS 环境可保留元数据并由用户在浏览器下载后关联，未绕过限制。
- `python3 BrowserExtension/package.py` 实际生成 Chrome/Edge、Firefox、Safari Web Extension 展开目录和 zip。
- Safari 由 Apple converter 生成独立 Xcode 工程，实际 Xcode 构建成功。最终 app 与 appex 的 macOS deployment target 为 **27.0**，当前产物为 **arm64 ad hoc**。`codesign --verify --deep --strict` 通过。Xcode 27.1 converter 最初产生不匹配的父 app bundle ID，构建脚本已修正生成工程的 identifier。构建日志中 CoreSimulator 版本警告没有阻断 macOS 构建。
- `security find-identity -p codesigning -v` 返回 **0 valid identities**。未开启 Safari 的允许未签名扩展选项、未改变浏览器安全设置、未绕过文件或浏览器访问拒绝。当前没有 Developer ID/App Store 签名或公证；Safari 是否可直接启用取决于用户的开发者设置/签名环境。

稳定产物路径：`BrowserExtension/dist/chromium/`、`dist/firefox/`、`dist/PaperShelf Capture.app`、`dist/PaperShelf-Capture-Safari-app.zip`。生成工程位于 `BrowserExtension/.build/SafariProject/PaperShelf Capture/PaperShelf Capture.xcodeproj`。Safari 原始 Web Extension zip 仅为源资源包，真正 Safari 安装对象是 `.app`。

尚未完成 Safari/Chrome/Edge/Firefox 的真实工具栏安装与点击采集全流程，也未声称付费/登录 PDF 可自动下载。Firefox 持久安装仍需 Mozilla 签名；Chrome/Edge 当前使用开发者模式加载展开包。浏览器交互验收和主应用确认框交互验收需单独记录。

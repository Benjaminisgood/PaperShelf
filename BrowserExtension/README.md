# PaperShelf 浏览器采集

独立实现的 Web Extension，点击工具栏后读取当前公开页面的 Citation/Highwire、Dublin Core、PRISM、OpenGraph 和 JSON-LD 元数据，也支持直接打开的公开 PDF。弹窗提供标题、作者、年份、期刊、DOI、摘要、选中文字和 PDF 候选的预览编辑。提交后通过 `papershelf://capture` 唤起本机应用；应用再次确认，随后保存元数据，可选下载一个 PDF。采集不是科研内容核验。

扩展不联网、不读取 Cookie/登录凭据/浏览历史、不注入常驻脚本；权限只有 `activeTab` 与 `scripting`。整个流程没有本地 HTTP 监听端口。不继承浏览器、机构代理或付费平台的登录状态；受限 PDF 请先由用户保存，再关联到书库。不会自动截断超长元数据，超过限制时要求编辑。

## 安装

先安装并启动已注册 `papershelf` URL scheme 的 PaperShelf。执行 `python3 BrowserExtension/package.py` 生成 `BrowserExtension/dist/`：

| 浏览器 | 安装包 / 路径 | 安装步骤 |
|---|---|---|
| Chrome / Edge | `dist/chromium/`、`PaperShelf-Capture-chromium.zip` | 扩展管理 → 开发者模式 → 加载解压后的扩展 → 选择 `chromium` 目录。两者使用同一 MV3 包。 |
| Firefox | `dist/firefox/`、`PaperShelf-Capture-firefox.zip` | `about:debugging#/runtime/this-firefox` → 临时载入附加组件 → 选择目录内 `manifest.json`。临时安装会随浏览器退出失效；持久安装须提交 Mozilla 签名，不能把未签名 zip 声称为已签名 XPI。 |
| Safari | `build_safari.sh` 生成的 Xcode 工程及 `.app` | 执行 `bash BrowserExtension/build_safari.sh`，打开打印出的应用，随后 Safari 设置 → 扩展 → 启用 PaperShelf Capture。 |

Safari 脚本使用 Apple 的 Web Extension converter 生成独立的 macOS 容器应用和扩展 target，包含全部资源，实际执行 Xcode 构建与 `codesign --verify`。默认仅为本地 ad hoc 开发签名，需要用户在 Safari 开发者设置中允许未签名扩展。脚本不会替用户开启此选项。正常分发需在生成的工程中配置 Apple 签名身份并按分发方式进行签名/公证或 App Store 发布。可先运行 `--generate-only` 只生成工程。生成工程位于 `.build/SafariProject`；再次生成前需明确移走旧生成目录，脚本不会覆盖已编辑的 Xcode 工程。

## 应用接入

`PaperCore.BrowserCapturePayload.decode(url)` 只解析数据，无导入或下载副作用。`BrowserCaptureReceiver` 为主线程对象，可共用本地 API 的快照：

```swift
let receiver = BrowserCaptureReceiver(
    storageDirectory: libraryURL.deletingLastPathComponent(),
    snapshot: { LocalAPISnapshot(references: references, collections: collectionRecords, tags: tagRecords) },
    onImport: { reference, policy in /* 按 skip/replace 真正保存本记录及附件返回 true；失败返回 false */ },
    onSelect: { selectedID = $0 },
    onStatus: { status = $0 }, onError: { error = $0 }
)
receiver.handle(urls) // AppDelegate.application(_:open:) 或 SwiftUI.onOpenURL
```

应用需要保留 receiver、在入口未就绪时排队 URL，并在退出时 `cancel()`。`Info.plist` 注册：

```xml
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>local.papershelf.capture</string>
  <key>CFBundleURLSchemes</key><array><string>papershelf</string></array>
</dict></array>
```

协议：`papershelf://capture?payload=<base64url UTF-8 JSON>`；版本为 1。全部字段必需：`version,id,capturedAt,sourceURL,title,authors,year,journal,doi,abstract,selectedText,pdfURLs`。数据最大 48 KiB；请求有效期 24 小时、允许 5 分钟时钟误差；队列最大 20 条、会话内去重最近 512 个请求。URL 不接受多余参数或操作指令。用户取消不会导入或下载。任何网页或应用都能构造 URL，因此来源不是身份认证，确认页面不可省略。

公开地址限制：HTTP/HTTPS、标准端口、无 URL 用户名/密码；拒绝本地域名、私有/回环/保留 IP。PDF 下载先解析并检查全部 DNS 结果，使用系统 curl 的 `--resolve` 固定实际连接地址；每次重定向重新检查和固定，最多 5 次，不允许 HTTPS 降级。curl 不读取用户配置、Cookie、环境代理或凭据；下载最大 100 MiB、单次传输最大 120 秒，随后通过 PDFKit 验证，并保存在书库同级的 `BrowserCaptures/<随机 UUID>/paper.pdf`。不覆盖已有文件。下载失败可选择保留元数据。

## 验证与限制

`swift test --filter BrowserCaptureTests` 覆盖原生协议边界。`node --test BrowserExtension/tests/*.test.cjs` 覆盖独立 JavaScript 协议与页面元数据样本。测试详情及本机真实构建结果在 `VERIFICATION.md`。

不绕过浏览器禁止访问的页面、登录墙、DRM 或 PDF 查看器权限。页面元数据可能过时、不完整或恶意；候选链接不是下载成功保证。扩展代码自有；只参考 Lattice 公开功能描述，没有复制其受限许可代码。当前未实现出版商专用登录下载器或浏览器商店发布。

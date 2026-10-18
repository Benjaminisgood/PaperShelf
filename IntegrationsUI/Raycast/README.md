# PaperShelf for Raycast

本目录是原创的 Raycast 扩展：搜索 PaperShelf 本地书库、通过 `papershelf://paper/UUID` 打开文献、复制完整普通引文、BibTeX、RIS、Markdown、DOI 或 PaperShelf 链接；也可主动采集浏览器当前标签页到 PaperShelf 预览。检索采用 50 条一页的增量加载，继续滚动读取后续页，没有总结果上限。引文复制保留作者、年份、题名、期刊、卷期页、出版社与 DOI/URL；这是普通书目文本，不宣称 APA/CSL 排版。

## 安装与使用

需要用户自行安装 Raycast，以及 Node.js 22.18 或更新版本。PaperShelf 保持运行，设置中启用 Local API；只读模式足够。

```sh
cd /absolute/path/to/PaperShelf/IntegrationsUI/Raycast
npm ci --ignore-scripts
npm run typecheck
npm test
npm run build
```

构建只写入本目录 `dist/`，不会启动或激活 Raycast。用户要安装时，可在 Raycast 中运行 **Import Extension**，选择本项目目录；或在 Raycast 已安装后显式运行 `npm run dev`，按 Raycast 开发流程导入并调试。扩展没有发布到 Raycast 商店。

还提供 **Check Connection** 命令，可独立验证本机 API。

**Capture Browser Tab** 仅在用户运行该命令时读取 Safari、Chrome 或 Edge 最前窗口的当前标签页。可选择浏览器，或使用 Frontmost Browser。首次使用时 macOS 可能要求允许 Raycast 自动化控制所选浏览器；由用户决定是否授权。扩展仅调用浏览器标准 AppleScript 的 URL/title getter，不注入 JavaScript、不读取 cookie、正文或选中文字。标题和网址经 `papershelf://capture` 交给原生预览，需用户在 PaperShelf 确认导入；不会自动入库或下载 PDF。此轻量入口不代替浏览器扩展的详细元数据抽取。需要浏览器已运行，且公开域名的 HTTP(S) 页面；IP 字面量、本地地址、非标准端口和含登录信息的 URL 不接受。超长标题会报错，不截断。

启动 **Search Papers**，输入题名、作者或 DOI。回车打开 PaperShelf；`⌘C` 复制引文，`⇧⌘C` 复制应用链接。没有结果时可使用 Retry Connection。

默认自动发现 `~/Library/Application Support/PaperShelf/LocalAPI/connection.json`。使用自定义书库时，在扩展设置 **Connection File** 中填写其绝对路径（支持 `~/`）。不要把 token 填进设置。每次请求重新读取连接文件，因此 PaperShelf 重启后的新 token 无需手动更新。

## 安全与验证

连接文件须由当前用户拥有、权限为 0600；目标仅允许 `http://127.0.0.1:<port>/api/v1`。每次请求附带 bearer 认证，禁止重定向和外部服务地址。API 只调用搜索和连接状态接口，不写入书库，不读取 PDF 字节。打开操作从经过校验的 UUID 构造固定 `papershelf://` 链接。

`npm run build` 生成可分发的扩展构建；`npm run typecheck` 和 `npm test` 覆盖类型、真实 loopback 请求、鉴权、分页、路径边界、长文本、Unicode 引文、三种导出转义、浏览器脚本的只读约束及原生预览 payload。详见 `VERIFICATION.md`。**本次未安装/启动 Raycast，未验证其实际 UI 交互或全局快捷键**；构建和测试成功不能替代宿主验收。

原生 API 版本固定在 `package-lock.json`。后续更新先升级依赖、运行上述检查，再在 Raycast 中验证。无需任何 Lattice 代码、资源或许可证。

# PaperShelf for Word

本目录是一套独立实现的 Word task-pane 加载项、CSL 格式化服务和 HTTPS 本地主机。它通过 PaperShelf 的认证 Local API 搜索书库，插入正文引文和参考文献表。这里没有 Lattice 的代码、样式或素材，也没有修改 Word 安装。

当前包含：分页检索与多选、页码 locator、顺序编码、作者–年份、官方 APA 第 7 版与 IEEE CSL、自定义 CSL 文件导入、引文顺序刷新、删除引文后重编号、参考文献表刷新。数字、排序和作者年份消歧由 `citeproc-js` 处理。每份 Word 文档保存完整 CSL 元数据快照、引文 ID、样式和用户导入的 CSL，保存并重新打开该文档后可继续编辑。API token 和本地文件路径不写入文档。

## 启动（macOS）

需要 Node.js 22 或更新版本，以及支持 WordApi 1.3 的 Microsoft Word。PaperShelf 应保持运行，并在设置中启用 Local API；只读模式足够。默认连接文件为 `~/Library/Application Support/PaperShelf/LocalAPI/connection.json`。自定义书库使用环境变量 `PAPERSHELF_API_CONNECTION` 指向其 `LocalAPI/connection.json`，无需将浏览器来源加入 PaperShelf allowlist，因为认证请求从 Node 主机发出。

```sh
cd /absolute/path/to/PaperShelf/IntegrationsUI/Word
npm ci --ignore-scripts
npm run build
PAPERSHELF_WORD_TLS_KEY=/absolute/path/to/localhost-key.pem \
PAPERSHELF_WORD_TLS_CERT=/absolute/path/to/localhost-cert.pem \
npm start
```

下载的 ZIP 和应用内附带版本已经包含 `dist/server.mjs` 自包含 Node bundle；直接设置证书并运行 `npm start` 即可，不需要安装 npm 依赖。开发者从源码重新构建时使用上面的 `npm ci` 和 `npm run build`。运行时除 Node 外不依赖任何全局 npm 包；`dist`、`web`、`styles`、`locales`、`licenses` 与声明文件需一同保留。

请提供**已受当前 Word/WebView 信任**、主机名包含 `localhost` 的证书和私钥。可使用已有组织签发的开发证书，或由你自行管理的本地开发 CA。服务仅绑定 `127.0.0.1`，页面地址为 `https://localhost:29469/`。程序不会创建或安装全局 CA，不会绕过 TLS 校验，也不会改变系统信任设置。没有受信证书时，应先准备证书；不要点击绕过警告或关闭验证。私钥留在你选定的安全位置，不能提交到仓库。

`PAPERSHELF_WORD_PORT` 可更改端口；同时将 `manifest.xml` 的所有 `localhost:29469` 地址改为同一端口。首次启动先在浏览器打开这个地址，确认没有证书警告；普通浏览器会显示“请通过 Microsoft Word…打开”的提示，这是正常的。

## 在 Word 侧载

这是本地开发安装包，**并未自动安装或发布到 Office 商店**。以下步骤由用户执行：

1. 保存并关闭正在编辑的 Word 文档。
2. 将本目录 `manifest.xml` 复制到 `~/Library/Containers/com.microsoft.Word/Data/Documents/wef/`（目录不存在时创建）。保留同一个 manifest ID，文档设置才能关联到同一个加载项。
3. 启动 Word，在“插入 → 加载项 → 我的加载项”的开发人员加载项中选择 **PaperShelf Citations**。具体入口随 Office 版本、语言和组织策略变化；组织禁用侧载时需使用组织许可的部署方式。
4. 连接成功后检索文献，选择一篇或多篇，点击“在光标处插入引文”。插入发生在当前选择末端，不会替换选中的正文。
5. 将光标移到参考文献区域，点击“插入参考文献表”；已有 PaperShelf 文献表会被刷新。选择新样式后点击“刷新文档 / 应用格式”。
6. 保存 Word 文档。删除或移动引文后，点击刷新。不要手动编辑 PaperShelf 引文控件的文字。

官方侧载说明：<https://learn.microsoft.com/office/dev/add-ins/testing/sideload-an-office-add-in-on-mac>。

## 自定义 CSL 与同步

面板中的“导入自定义 CSL”选择本地 `.csl` 文件，校验通过后将整个样式保存到**当前 Word 文档**。支持独立的 `class="in-text"` 样式；不支持只有父样式链接的 dependent 样式、外部实体或脚注式样式。1 MiB 上传上限会明确报错，不会截断。导入后点击刷新应用。

也可在启动前设置 `PAPERSHELF_WORD_STYLE_DIR=/absolute/custom-styles`，加载该目录下文件名只含字母、数字、下划线、连字符的 `.csl` 文件。不要与内置文件重名。此方式的样式文件由用户管理，重新打开文档前需启动相同样式目录；面板导入方式则随文档携带。

`package-lock.json` 固定 citeproc 版本。APA 样式、locale 的 upstream URL、revision 和许可保留在 `THIRD_PARTY_NOTICES.md`；更新时从各自原项目获取，保留许可，执行测试并检查真实 Word 文档。PaperShelf 自有 `numeric.csl` 和 `author-year.csl` 不依赖其他软件的实现。

## 边界与验证

- 本地 HTTPS 服务只提供固定的只读 API 代理和格式化接口。每次启动生成 task-pane nonce；Host/Origin 必须精确匹配，拒绝跨站请求。真实 PaperShelf bearer token 仅从 0600 连接文件读取，在服务端使用；无 token URL、无写入书库路由、无任意文件代理。
- 已保存引文的元数据是文档快照。刷新格式不会静默替换为后来改变的书库数据；重新从书库插入同一文献可更新这份文档的快照。
- 复制粘贴同一引文控件导致相同 ID 时会报错，请删除复制品并从面板重新插入。其他文献管理器的字段不会转换。
- Word 使用经过白名单清洗的 citeproc HTML，支持文字、标点、排序、编号、消歧、斜体、粗体、上下标和小型大写字母；参考文献悬挂缩进同时应用 HTML 段落样式与 Word 段落属性。清洗会拒绝脚本、链接/URL 属性、图片、事件属性和任意 CSS。正文控件之外的脚注、尾注、跨文档复制以及多人协作/修订模式尚未做宿主验收。实际出版排版仍需在 Word 中核对。
- 文档状态请求最大 4 MiB；超限明确报错，不截断内容。搜索可翻页，无总结果截断。
- `npm test` 验证真实 citeproc、APA/IEEE/自定义 CSL、文档状态重排/删除/重复检测、长文本完整性、实际 loopback HTTP 鉴权和连接文件权限。证据见 `VERIFICATION.md`。这些测试不等同于 Word 宿主交互验收；本次未安装证书、未侧载到 Word，也未操作真实用户文档。

不要提交连接文件、TLS 私钥或用户文档。停止使用时终止 `npm start`，移除自己侧载的 manifest 即可；不会修改 PaperShelf 数据。

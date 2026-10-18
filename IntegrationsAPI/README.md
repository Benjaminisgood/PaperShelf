# 本地 API、CLI、MCP 与 portable Skill

这套接口由 PaperShelf 独立实现。应用启动时 API 默认关闭；启用后只绑定 `127.0.0.1`，默认只读、端口 `29468`。端口 `0` 表示分配空闲端口。每次启动生成新的 256-bit bearer token，保存在当前书库目录的 `LocalAPI/connection.json`，目录权限 0700、文件权限 0600。关闭服务移除此文件。不要将该文件上传、放入版本库或贴进聊天。

CLI 通过连接文件发现地址与令牌，不扫描端口。原生应用需保持运行。默认书库示例：

```sh
PaperShelfCLI status
PaperShelfCLI search 'chemical reaction' --include abstract --limit 50 --offset 0
PaperShelfCLI get-paper PAPER_UUID --include abstract,pdfPath,library
PaperShelfCLI get-paper-by-reference 10.1234/example
PaperShelfCLI get-csl-item PAPER_UUID
PaperShelfCLI lookup-metadata 10.1234/example
PaperShelfCLI collections
PaperShelfCLI tags
```

自定义书库在任意命令前指定 `--connection /absolute/library/LocalAPI/connection.json`，或设置 `PAPERSHELF_API_CONNECTION`。CLI 始终输出 JSON；诊断写入 stderr。`search` 返回 `total/offset/limit/hasMore`，要完整遍历必须继续请求后续页。

写入需用户在应用中关闭 API 的只读模式：

```sh
PaperShelfCLI create-paper --json-file paper.json --duplicate-policy skip
PaperShelfCLI add-by-identifier 10.1234/example
PaperShelfCLI attach-pdf PAPER_UUID --file /absolute/selected.pdf
PaperShelfCLI attach-pdf PAPER_UUID --path /approved-folder/paper.pdf
```

`--file` 上传本次明确指定的 PDF 字节；`--path` 让服务读取配置的 Trusted Folders 内文件。服务规范化路径并解析符号链接，拒绝越界文件，不能把 `/` 设为信任根。上传保存新副本，原始文件不动；替换已有 PDF 另需 `--force`。`duplicatePolicy` 默认为 `skip`；`replace` 保留原有 PDF/附件、阅读状态、评分、收藏，合并分类、标签与扩展字段，未明确提交的笔记和缺失的引文键也保留。

## HTTP 协议

所有实际请求都需 `Authorization: Bearer <token>`。Host 只允许服务实际端口上的 `127.0.0.1` 或 `localhost`。浏览器 Origin 必须在应用的精确 allowlist 内；默认空。无 wildcard CORS，不接受 `null` Origin。合法白名单来源的 OPTIONS 只返回预检能力、不返回书库内容。不要把令牌放进 URL。

| Method / route（前缀 `/api/v1`） | 请求 / 结果 |
|---|---|
| GET `/status` | 版本、只读策略、能力、数量与大小上限 |
| GET `/search?q=...&offset=0&limit=50` | `{items,total,offset,limit,hasMore}`；limit 1–500 |
| GET `/papers/{uuid}` | 基本文献数据；`include=abstract,pdfPath,library,collections,tags` 按需扩展 |
| GET `/papers/by-reference?reference=...` | 精确 DOI、citekey 或 UUID |
| GET `/papers/{uuid}/csl` | CSL-JSON；不猜测无逗号作者姓名的 family/given |
| GET `/metadata?identifier=...` | DOI、ISBN、arXiv 在线补全；只查询，不保存 |
| GET `/collections`、`/tags` | `{items:[...]}` |
| POST `/papers` | `application/json`；返回 `{status,paper}` |
| POST `/papers/by-identifier` | `{identifier,duplicatePolicy?}`；在线补全后写入 |
| PUT `/papers/{uuid}/pdf?force=true` | `application/pdf` 字节，或 `application/json` 的 `{path}`；需 Trusted Folder 的仅为 path 方式 |

创建字段：`title` 必需；可选 `authors` 字符串数组、`year,journal,doi,url,abstract,notes,citationKey,type,volume,issue,pages,publisher,isbn,issn` 字符串、`tags` 字符串数组、`collectionIDs` 已有 UUID 数组、`extraFields` 字符串映射、`duplicatePolicy`。不接受任意文件路径、书签或额外指令字段。JSON 最大 1 MiB，PDF 最大 100 MiB，需真实可读取且未锁定的 PDF。服务最多同时处理 4 个连接，120 秒超时；拒绝重复 HTTP 头、Transfer-Encoding、Expect、管线请求和额外尾随字节。

错误状态使用 401 未鉴权、403 策略不允许、404 未找到、409 附件/导出冲突、413 超限、422 字段或 PDF 无效。默认不返回摘要、书库笔记、分类与本地路径；安全书签永不出现在 API 输出。

## MCP 和 Skill

MCP 配置示例（路径替换为实际安装位置）：

```json
{"mcpServers":{"papershelf":{"command":"/Applications/PaperShelf.app/Contents/MacOS/PaperShelfCLI","args":["mcp"]}}}
```

支持 JSON-RPC stdio、initialize、ping、tools/list、tools/call；只读服务不在 tools/list 中宣传写入工具，服务端仍独立强制只读。工具为 status/search/get_paper/get_paper_by_reference/get_csl_item/lookup_metadata/collections/tags/create_paper/add_by_identifier/attach_pdf。MCP 的 attach_pdf 只使用 Trusted Folder path，不能借工具上传任意本地文件。

`PaperShelfCLI export-skill /new/papershelf-library` 导出自包含的 `SKILL.md` 与 `scripts/papershelf.sh`。目标存在时拒绝覆盖。launcher 通过 `PAPERSHELF_CLI`、PATH 中的 `papershelf` 或标准应用安装路径发现 CLI，不嵌入开发者机器路径或令牌。安装/导出 Skill 不会自动打开 API 或授予写入权限。

## 维护与验证

Core 协议/鉴权/隐私字段/路径边界测试在 `Tests/PaperCoreTests/LocalAPITests.swift`。`tests/server-harness.swift` 使用独立内存书库和临时 PDF；`tests/live_api.py` 对真实 Network listener、CLI 和 MCP 执行只读/写入、错误输入、重复替换、附件、隐私和 Skill 导出检查，不接触生产书库。实际结果见 `VERIFICATION.md`。

浏览器扩展独立使用 `papershelf://`，不要求启用 API。Word/Raycast 等客户端必须走上述鉴权和 Origin 约束；本文不代表这些独立客户端已经完成宿主交互验收。

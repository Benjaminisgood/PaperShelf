# Local API / CLI / MCP 验证

2026-10-18，本机 macOS 27.2。验证使用临时目录与独立内存书库，没有读取或改写生产文献库；没有向外部服务发送测试文献。

- `swift build --product PaperShelfCLI` 实际通过。
- `LocalAPIServer`、BrowserCapture 服务独立 Swift typecheck 通过。
- `LocalAPITests` **6 项通过**：鉴权/Host/Origin 独立门槛、HTTP 请求走私与超限、默认关闭只读、隐私 opt-in、CSL 作者结构、创建字段类型与路径注入、可信目录边界/符号链接。
- `tests/live_api.py` 对真实 `Network.NWListener` 服务和真实 CLI 二进制执行 **40 项检查，全部通过**。含无 token 拒绝、错误 Host/Origin 拒绝、受信 Origin 预检、实际只读策略、搜索/隐私字段、CSL、CLI、MCP initialize/list/call、只读不宣传写入工具、只读写入拒绝、创建、重复 skip/replace、用户笔记/评分/状态/citekey/扩展字段保留、无效 PDF/可信文件夹/显式覆盖、原 PDF 不变、Skill 导出与拒绝覆盖。
- API 日志及响应不包含 bearer token。连接文件权限实际核对为 **0600**。
- `PaperShelfCLI export-skill` 实际生成 `IntegrationsAPI/papershelf-library/`；该目录可分发，不含本机绝对路径或密钥。
- skill-creator 的 `quick_validate.py` 使用项目 Python 运行，验证通过；系统 Python 缺少 PyYAML，未为此修改系统环境。

复现隔离网络测试（在项目已构建后）：

```sh
swift build --product PaperShelfCLI
swiftc -parse-as-library -I .build/out/Products/Debug -I Sources/CSQLite \
  -L .build/out/Products/Debug -lPaperCore \
  Sources/PaperShelf/Services/LocalAPIServer.swift \
  IntegrationsAPI/tests/server-harness.swift -o .build/local-api-qa/server-harness
python3 IntegrationsAPI/tests/live_api.py \
  .build/local-api-qa/server-harness .build/out/Products/Debug/PaperShelfCLI
```

以上 `.build/out/Products/Debug` 是本机 Xcode SwiftPM runtime 输出位置；其他环境以 `swift build --show-bin-path` 为准。生产 App 设置、主库变更后的实时刷新、Word/Raycast 宿主交互、跨 Mac 架构/系统版本不由这些隔离检查证明；需要根任务单独验收。科学准确性与软件接口测试分开。

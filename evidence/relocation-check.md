# 独立项目迁移复验

2026-10-18，PaperShelf 移至桌面的独立项目目录，并建立独立 Git 仓库。应用源码未因迁移改变；原有 SwiftPM 构建缓存留在旧工作区，从新路径重新构建。

- `swift test`：22 项、0 失败。
- `./script/build_and_run.sh --verify`：构建成功，本机签名成功，新目录中的 .app 启动并通过进程检查。
- `codesign --verify --deep --strict dist/PaperShelf.app`：通过。
- `plutil -lint dist/PaperShelf.app/Contents/Info.plist`：通过。
- 脚本按自身目录定位项目，仓库内运行配置使用相对路径。
- Git 排除了 .build、dist、数据库、环境文件及含本机路径的原始日志/JSON。源码、测试、示例和验证总结纳入版本控制。
- 合成示例 PDF 的批注作者统一为 `PaperShelf demo`，避免携带本机账户作者名；重新打开核对成功。

迁移复验原始日志仅保存在本机 `evidence/relocation-test.log` 和 `evidence/relocation-build.log`。原 `rea-local-verification.md` 描述迁移前产物的历史检查，其 SHA-256 不代表新路径重新构建的产物；本次未重新执行 REA 分析。

本次没有重新逐项执行原界面验收。先前界面验证范围与未完成项仍以 `qa.md` 为准。

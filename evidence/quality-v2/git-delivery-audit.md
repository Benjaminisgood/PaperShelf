# Git 交付只读审计

> 本文保留首次交付前的历史快照。下述 `fac8bb7`、未提交文件数量和远端未同步结论已被后续交付取代：增强代码及原创图标已推送，2026-10-18 再次确认远端包含 `7f1b896`、`e1ec529`、`05c2c10`、`5978b5d`、`d868df5`。以最终交付记录和实时 Git 状态为准；不将此历史审计当作当前未同步证明。

审查日期：2026-10-18。未 stage、commit、push、fetch 或更新子模块；只用 `git status`、`ls-files`、`diff`、`rev-parse` 和 `ls-remote` 读取本项目状态。扫描不包含忽略目录、生产书库、钥匙串或其他项目。报告不包含真实密钥值。

## 版本状态

- 分支 `main`；HEAD 与本机 `origin/main` 为 `fac8bb7c95037ae7323c95d74eaa5f2991d8cc1d`，ahead/behind 为 0/0。
- 实时 `git ls-remote origin refs/heads/main` 返回同一提交。因此远端目前仍只有初始提交，增强工作没有交付到 Git。
- origin 为 `https://github.com/Benjaminisgood/PaperShelf.git`。
- 暂存区只有 `.gitmodules` 和 3 个 gitlink；其余修改和新增文件尚未暂存。只提交当前暂存区会漏掉实际增强。

## 候选文件与忽略边界

`git ls-files --cached --others --exclude-standard` 中普通文件 412 个，合计 79,867,095 字节。该统计是本轮开始时快照，后续新增审计报告/并行修改会改变数量。

| 分组 | 文件数 | 字节数 | 建议 |
|---|---:|---:|---|
| HTML/ | 46 | 69,062,832 | 学习成品示例与源码模板分开；不要把全部成品 HTML 默认当应用源码提交 |
| evidence/ | 150 | 5,415,750 | 保留精简复现脚本和验收文档；日志、参考应用分析 dump、截图、旧 patch 单独归档 |
| Examples/ | 4 | 3,729,629 | sample.pdf/sample.bib 已跟踪；两篇真实 PDF 为新增原始输入，应明确排除或单独决定分发范围 |

新增真实 PDF：`Examples/2002.09062.pdf`（1,170,448 字节）、`Examples/d2cp05083h.pdf`（2,547,685 字节）。HTML 单文件最大约 13.85 MB；共 69.1 MB 的样例成品不应因 `git add -A` 意外进入主源码交付。它们包含全文/页图，当前没有逐文献分发许可清单。

`.gitignore` 已排除 `.build`、`dist`、`.venv`、SQLite、`.env`、Python cache，以及部分 learning/Graphiti 运行目录。**`evidence/*.log` 与 `evidence/*.json` 只匹配 evidence 根目录**：例如 `evidence/lattice-parity/*.log` 和大量嵌套 JSON 仍在候选集合。还存在 `.vscode/launch.json` 本地调试文件。已有跟踪的 `evidence/papershelf-ui.png` 不会因为新增 ignore 自动退出 Git。

建议提交集合：App/Core/CLI 源码、后端源码与合成测试、原生/浏览器/Word/Raycast 适配器源码、打包脚本、用户文档、清理后的验收摘要、submodule gitlinks + `.gitmodules` + lock + 许可证。若保留 `HTML/lit-html-guide/`，单独核对其源文件许可与模板复用范围；不必连带提交 HTML 成品。

## 凭证和隐私模式扫描

仅扫描上述 Git 候选中的 391 个 UTF-8 文本文件，不打印匹配原文。

- 私钥块、长 `sk-` provider key、GitHub token、AWS Access Key 高置信模式：均 0。
- 带签名/访问令牌查询参数的 URL 模式：0。
- 通用 credential 赋值模式：5 个候选，位于 `Sources/PaperShelf/Services/CredentialPlan.swift`、3 个 backend 测试文件和 `evidence/independent-qa/credential-plan-harness.swift`。进一步 token 形态过滤仅剩 `backend/tests/test_agent.py` 的 1 个固定测试值，位于 `test_pure_chinese_query_repairs_only_missing_citations_with_full_evidence`。未发现可确认真实凭证。
- 14 个候选文件包含 `/Users/ben` 本机绝对路径，均在 evidence 下；其中包括运行摘要、构建日志和参考应用 receipt。应在共享验收摘要中改为相对路径或书库占位符，保留本地原始日志不入 Git。
- 16 个文本文件含邮箱形态。未把论文作者邮箱等模式自动认定为个人凭证；如提交完整论文示例，需额外确认其必要性。

这些是有边界的模式检查，不是“绝无秘密”的保证。最终 root 应在明确 stage 集合之后再次扫描实际暂存文本及查看 diff，避免并行工作引入新产物。

## 上游跟踪与实际远端头

三个 submodule 工作树均干净，checkout 与 `integrations/upstreams.lock.json` 完全一致；没有把 PaperShelf 定制写入上游。`.gitmodules` 和 lock 保存原始 GitHub 来源。

| 上游 | 本项目 pin | 实时 main | 状态 |
|---|---|---|---|
| Paper2Agent | `8c2d059165ef8cdcb70dbea76655b9c2b55b38e6` | 同 pin | 当前 |
| MarkItDown | `4cc9fa17653d695d64fb9eee5b33d4de55ff84e8` | 同 pin | 当前 |
| Graphiti | `a107b622205733c0a53617ce0cd79fe4461cdb35` | `417c3a125ae3ac53c19b8e53fffaccf3e665a88e` | 有新上游提交 |

本轮没有拉取或改变 Graphiti。现有已验证 pin 可以随本次增强交付；新头应另做选择性比较、兼容测试及真实服务验证，再同步指针与 lock，不能仅因发现更新就改 pin。`script/sync_integrations.py` 有来源一致、干净上游、lock一致和 fast-forward 检查，更新路径符合后续可同步要求；其 `--check` 会 fetch，故此次只读审计使用 `ls-remote`。

## Root 交付前检查清单

1. 明确排除 HTML 成品、两篇真实输入 PDF、运行日志/图像/参考应用 dump/旧 patch 和本地调试配置；保留文件，不删除用户资料。
2. 用显式路径 stage 应交付源码与文档，避免只提交当前 4 个 staged entries 或直接 add -A。
3. 核对 `.gitmodules`、3 个 gitlink、`upstreams.lock.json`、许可证同时提交，并保存当前兼容 pin。
4. 针对 staged 文本重跑安全/绝对路径检查，核对 `git diff --cached --stat` 与实际 diff。
5. Root 完成最终相关测试和产物验证后 commit/push；以远端 HEAD 与本地提交一致确认同步完成。

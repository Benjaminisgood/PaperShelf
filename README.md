# PaperShelf · 文献架

PaperShelf 0.4.0 是面向 macOS 27 的原生文献管理与研读工作台：管理文献和附件，把完整来源整理成原语言全文、中文学习 HTML / Markdown、自定义字段数据集、文献 Agent 和知识图谱。

[使用指南](Guide.md) · [后端与产物契约](backend/README.md) · [上游维护](integrations/README.md) · [自动化接口](IntegrationsAPI/README.md) · [功能核对表](evidence/lattice-parity/feature-parity.md)

## 构建与打开

```sh
git submodule update --init --recursive
./script/setup_integrations.sh
./script/build_and_run.sh
```

构建需要 Xcode / Swift 工具链。脚本生成 `dist/PaperShelf.app` 并打开；也可双击 `Launch PaperShelf.command`。只构建使用 `./script/build_and_run.sh --build-only`。Git 不保存 `.app`、虚拟环境和运行缓存。

最低部署目标为 macOS 27，当前构建面向 Apple Silicon / arm64。默认采用 ad-hoc 临时签名，没有 Developer ID 公证。已有应用运行时脚本显示现有窗口；重新构建前应正常退出，应用会取消并等待文件与研读任务收尾。有效签名的配置方式和外部宿主限制见 [签名说明](evidence/lattice-parity/signing-and-hosts.md)。

## 文献管理

- 导入 PDF、BibTeX、RIS、文件夹或剪贴板；通过 DOI、ISBN、arXiv 获取元数据。重复记录可选择跳过或替换，保留本地笔记和阅读状态。
- 文献可属于多个层级文集，支持标签、颜色、排序、多选、拖放、评分、收藏、已读和批量编辑。搜索涵盖标题、作者、年份、标识符、笔记和扩展字段。
- 保留引用键、文献类型、卷期页、出版者、ISBN/ISSN 与自定义字段。引用键支持模板、重名处理和可选的元数据变化后更新；显式手工修改的键不会被该选项覆盖。
- 支持元数据、新建与导入记录的撤销/重做。“最近删除”可恢复；永久删除记录与把关联文件放入系统废纸篓是独立操作。普通删除保留原文件。
- 主 PDF 和附加代码、数据、文档可以原位链接，也可按规则复制或移动到文件库。文件整理在后台逐篇提交，提供进度与取消；取消保留已完成文献并回滚当前未提交操作。
- PDF 可用系统或指定阅读器打开，并支持 Quick Look。读取文本与区域批注、按多边形提取高亮文字、导出区域图片；无文本层的批注区域可选择本机 Vision OCR，结果标明来源。
- 导出选中、当前列表或全部活动文献为 BibTeX、RIS、Markdown；详细笔记使用自定义元数据/批注模板，有区域图片时输出 TextBundle。
- 内置备份与恢复。恢复前校验备份并保存当前书库快照，附件恢复到用户选择目录下的独立文件夹。Zotero 导入支持仅元数据或复制附件，以及自选外部链接附件根目录，始终保留 Zotero 原文件。

文件路径与数据库记录一同维护；文件移动不是仅撤销一个路径的普通文本编辑。移动或删除仍被其他文献引用的文件会被拒绝，避免破坏共享关联。更多操作和快捷键见 [使用指南](Guide.md)。

## 文献研读

选中文献，在检查器的“研读”页面生成资料；设置中可启用导入或关联 PDF 后自动排队。每次创建独立运行目录，保存来源哈希、页图、完整提取、模型设置、审阅记录和日志，原始文件保持不变。

0.4 的阅读资料区分三个用途：

| 产物 | 用途 |
|---|---|
| `source.json` / `source.md` | 完整原始来源、稳定 ID、页码与版面证据，供逐项追溯 |
| `fulltext.md` | 可连续阅读的原语言全文，正文与附属内容分层，保留来源对应关系 |
| `learning.html` / `learning.md` | 按研究问题、方法、条件、证据和局限组织的中文研读，附逐段对照、公式、图表与自测 |

原文页码、重复页眉与图轴碎片不应作为独立科学讲解充满主阅读流程；完整来源仍保留。内部重试和分块处理诊断与读者需要核验的学术问题分别记录。离线模式整理来源，不宣称完成 AI 清洁全文或中文分析。AI 模式的覆盖、引文和类型校验不能证明语义正确；读者仍需核对数值、单位、条件、符号与科学结论。

自定义字段支持类型、说明、原文单位、枚举和嵌套结构；按样品/条件保存记录与原句证据，导出 CSV/TSV。字段校对另存版本并保留操作者、理由和前后值。未提取到值不等于原文没有报告。CATDA 仅提供工作流思路，这部分由 PaperShelf 独立实现。

生成的阅读 Agent 可在应用内问答，也可通过输出目录的 `agent/run.py` 和 MCP 独立运行。Paper2Agent 的科研代码复现及科学工具生成使用独立上游流程；“任务已准备”或主机退出码为零不等于科研复现已验收。

本地证据图谱关联文献、条件、字段与原句。Graphiti 可连接 Neo4j/FalkorDB，提供跨文献的时序图谱和来源查询；模型抽取出的关系仍需核验。

## 模型与运行环境

设置 → 研读可配置 OpenAI 兼容服务、模型、读者背景和字段。当前默认服务为 `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`，默认模型为 `qwen3.7-plus`，均可更改。AI 模式会把文献内容发送到所选服务。密钥通过 macOS 钥匙串、会话凭据或环境变量提供，不写进请求 JSON 或资料；已有实测使用会话凭据，重启后的钥匙串持久读取仍需按实际系统授权验证。

应用随包携带 Python 后端、三个上游源码快照及许可证。Python 3.11–3.14 运行环境可在设置中安装到当前书库父目录的 `Learning/runtime`。Graphiti 默认使用本机多语言 MiniLM 嵌入（384 维），首次需要下载模型；在线图谱抽取仍需模型服务，图数据库需单独运行。详细部署和依赖边界见 [集成说明](integrations/README.md)。

## 浏览器与自动化

- [浏览器扩展](BrowserExtension/README.md)：Safari、Chrome、Edge、Firefox 采集网页元数据和公开 PDF 候选；主应用预览确认后导入。采集不依赖本地 API，也不继承浏览器 Cookie 或机构权限。
- [本地 API / CLI / MCP / Skill](IntegrationsAPI/README.md)：API 默认关闭、默认只读，仅监听 `127.0.0.1`，使用私有连接文件和随机令牌。
- [Word](IntegrationsUI/Word/README.md) 与 [Raycast](IntegrationsUI/Raycast/README.md)：独立宿主适配器，需按各自说明安装与授权。
- 快捷指令提供搜索、打开、Markdown 导出与笔记文本四个动作。系统已能发现动作；当前 ad-hoc 签名缺少 Apple Team ID，宿主执行受到系统限制。

Safari 正式启用、Firefox 永久安装及 Word/Raycast 宿主操作另有签名或安装要求，不能把编译与接口测试当作已完成全部宿主验收。具体实测边界见 [签名与宿主说明](evidence/lattice-parity/signing-and-hosts.md)。

## 数据与维护

默认书库为 `~/Library/Application Support/PaperShelf/library.sqlite`，使用 SQLite WAL 与版本化 schema。文献、文集、标签和附件信息持久化；设置或书库无法读取时报告错误并保留原文件。`PAPERSHELF_LIBRARY_PATH` 可指定独立测试书库。研读设置、历史、环境和产物位于该书库父目录的 `Learning/`。

BibTeX、RIS、Markdown 是交换格式，不能代替完整书库备份。完整备份应使用应用备份入口；手动复制时先正常退出应用。`Examples/sample.bib` 与 `Examples/sample.pdf` 是合成测试资料。

Paper2Agent、MarkItDown 和 Graphiti 通过独立 Git submodule 固定版本，提交记录在 `integrations/upstreams.lock.json`。所有定制适配位于上游目录之外。后续同步先比较具体 revision、更新 pin 与 lock，再安装和测试；不自动追随主分支。

```sh
python3 script/sync_integrations.py --check
swift test
PYTHONPATH=backend .venv/bin/python -m unittest discover -s backend/tests -v
```

`--check` 会 fetch 远端但不改变上游 checkout。更新、验证及单独提交的完整步骤见 [上游维护](integrations/README.md)。

## 验证与限制

[功能核对表](evidence/lattice-parity/feature-parity.md) 记录文库与扩展范围；[研读验收](evidence/learning-acceptance.md) 和 [质量复审](evidence/quality-v2/review.md) 记录真实文献的历史证据与发现的问题。旧运行的通过项不自动适用于新的阅读结构或重新生成内容。最终应分别报告构建、测试、宿主/视觉操作和内容核验状态。

当前搜索在内存中进行；未宣称大型文库性能、云同步、长期迁移、全量无障碍、Intel 或公证分发已验收。BibTeX 支持常见宏、嵌套花括号和扩展字段，不是完整 BibLaTeX 引擎；不解析任意 crossref/xdata 继承或任意 LaTeX。不同工具的真实库交换仍需核对。

本项目独立新增代码采用 MIT，见 [LICENSE](LICENSE)。上游与其依赖各自适用原许可证。Lattice 仅作为公开功能参考，与本项目无关联，未包含其源码、品牌或图片。

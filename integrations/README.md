# 可同步的上游能力

本目录以 Git submodule 保留四个上游完整源码，PaperShelf 的适配代码位于 `backend/papershelf_pipeline/integrations.py` 与 `presentation.py`。不向上游目录写定制逻辑。固定提交、来源和许可证见 `upstreams.lock.json`，许可证副本见 `licenses/`。CATDA 不在依赖中；自定义字段提取由 PaperShelf 独立实现。

## 安装运行环境

```sh
git submodule update --init --recursive
./script/setup_integrations.sh
.venv/bin/python -m papershelf_pipeline.integrations doctor
```

需要 Python 3.11–3.14（当前 Paper2Agent 脚本要求 3.11 起）。脚本把当前固定源码安装到 `.venv`，包含 MarkItDown 的 PDF、DOCX、PPTX、XLSX、XLS 转换依赖以及 Graphiti 的 Neo4j/FalkorDB 客户端，还会读取官方 Paper2Agent 脚本的 PEP 723 元数据安装其固定版本依赖。构建前将 backend 与四个上游复制到运行时目录的私有临时 staging，禁写 pyc，结束自动清理；不会在应用包内写 egg-info 或 build 文件，支持只读签名资源。HTML、Markdown 等基础格式也可转换。没有启用 MarkItDown 外部插件、云 OCR 或媒体转写；图片型 PDF 需先 OCR。首次安装从 Python 包索引下载依赖，通常需数分钟。日常运行无需重复安装。

独立应用随包携带源码快照，可以把依赖装到可写的用户目录，无需 Git：

```sh
/path/to/Resources/Pipeline/script/setup_integrations.sh \
  --source-root /path/to/Resources/Pipeline \
  --venv "$HOME/Library/Application Support/PaperShelf/Learning/runtime" \
  --python /opt/homebrew/bin/python3
```

`PAPERSHELF_ROOT` 可指定包含 `integrations/` 的源码/资源根目录。适配器 API 按需导入依赖，`doctor` 只检查版本、配置和环境变量是否存在，不连接服务、不输出密钥。

上述路径对应默认书库。原生应用实际使用书库所在目录的 `Learning/runtime`，配置、处理历史和产物分别在同级 `Learning/settings.json`、`Learning/history.json`、`Learning/Runs/`。自定义书库位置时，这些路径随书库父目录变化；同一父目录中的书库共用该 `Learning` 目录。构建后的 `.app` 携带最新 backend 和四个上游源码，Python 虚拟环境留在可写的书库目录，不放进应用包。

原生应用通过 `PYTHONPATH` 优先加载所选 backend（默认是当前应用包内的 `Pipeline/backend`），因此仅更新 PaperShelf 后端时，重新构建应用即可，不必手工复制到虚拟环境的 site-packages。更新上游 pin 或 Python 依赖后，应再次运行“安装运行环境”。从终端直接运行虚拟环境的 Python、且未设置 `PYTHONPATH` 时，会使用安装时的 backend；需要使用最新代码时，应先重新安装，或明确设置 `PAPERSHELF_ROOT` 与 `PYTHONPATH` 指向同一份源码/应用资源。

## Paper2Agent 的真实上游流程

当前上游主分支交付的是完整 Coding Agent Skill，包含 paper2skill 和 paper2mcp，并非一个可直接 `pip install` 后运行的 Python 生成器。PaperShelf 将整套官方 Skill 放入独立任务目录，保留输入副本、源文件 SHA-256、上游提交、提示词和运行日志。支持 Codex 或 Claude Code 主机。原文仅有论文时走 paper2skill；提供 `paper2agent.repository` 时同时走 paper2mcp。

```sh
.venv/bin/python -m papershelf_pipeline paper2agent-prepare paper.pdf /tmp/my-paper-agent --config integrations/config.example.json
.venv/bin/python -m papershelf_pipeline paper2agent-launch /tmp/my-paper-agent
.venv/bin/python -m papershelf_pipeline paper2agent-status /tmp/my-paper-agent
.venv/bin/python -m papershelf_pipeline paper2agent-cancel /tmp/my-paper-agent
.venv/bin/python -m papershelf_pipeline paper2agent-resume /tmp/my-paper-agent
```

生成页面中的普通本地文献检索 Agent 与这个上游科研工具生成流程分别报告。`prepared` 仅表示已备好任务；`running` 表示主机执行中；`host_completed` 只表示主机退出码为零，必须继续阅读上游生成的验证报告，不能当作科研正确性验收。`failed` / `interrupted` 保留原始日志。任务目录非空时不会覆盖，重复启动被拒绝。

主机需已安装、登录且支持上游要求的并行子代理。可在配置设置 `paper2agent.host_executable` 为 CLI 绝对路径。Codex 使用 `workspace-write` 沙箱，不关闭审批。Claude 使用其默认权限模式；权限、网络、API、研究软件或数据条件不足会明确失败/记录阻碍。PaperShelf 不把密钥写入任务或生成代码，不自动安装用户全局 Skill，不自动连接生成的 MCP 服务。主机请求使用现有账户，可能产生模型费用。

取消前校验 worker 命令、任务目录和独立进程组身份，再向该任务进程组发送终止信号。保留部分输出和日志；不会终止其他 Codex/Claude 会话。恢复仅允许已终止任务，旧日志和最终回复归档到 `run-history/`，原文和已有 review 工作保留，再启动真实主机继续检查。准备任务时会记录已安装的 Python 解释器，主机直接使用该解释器运行上游脚本，无需再次下载相同依赖。

## Graphiti 时序知识图谱

Graphiti 引擎本身随源码并安装；图数据库与模型服务由用户配置。支持 Neo4j（URI、用户、密码环境变量）和 FalkorDB（host、port、database），以及 OpenAI 或兼容的 Chat Completions 和 embedding 服务。LLM 需要可靠的结构化输出；`structured_output_mode` 可选择 `json_schema` 或兼容性模式 `json_object`。配置模板 `config.example.json` 仅保存环境变量名，不保存秘密。模型请求会发送当前文献内容，图数据库保存原文 episode 和来源关系。

模板使用本项目用户指定的百炼 Token Plan 地址 `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1`，显式模型 `qwen3.7-plus`、`enable_thinking: false`、240 秒调用超时，密钥环境变量 `PAPERSHELF_API_KEY`。适配器按 `omit_temperature: true` 省略 temperature。默认 `embedding_backend: "fastembed"`，使用本机多语言 `sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2`（384 维），无需额外 embedding 密钥。首次运行下载约 220 MB 模型到 `~/Library/Application Support/PaperShelf/models`；已缓存后向量化与默认混合检索可离线运行，Graphiti 入库提取仍调用在线模型。真实服务和文献验证范围见 `VERIFICATION.md`。

默认 `graph-search` 使用 Graphiti 的本地 embedding、BM25 与 RRF 排序；选择 FastEmbed 时只需数据库密码，无需模型 API 密钥。图谱写入仍会调用在线模型。复杂文献的 `auto` 路由曾持续返回空正文，因此模板显式选择模型。`graphiti.extra_body` 可设置兼容服务支持的参数，`timeout_seconds` 设置调用超时。此适配使用上游公开 client 注入点，保留结构化请求 schema，拒绝覆盖消息、模型和凭据。若端点返回合法 JSON 但字段不符合 schema，外部适配器最多请求两次纠正，保留完整原文和完整前次响应；不猜测字段、不静默丢弃记录，重试后仍无效则明确失败并保留已完成 episode。

如需远程 embedding，将 `embedding_backend` 设为 `openai-compatible`，并配置 `embedding_endpoint`、`embedding_model`、`embedding_dimensions`、`embedding_api_key_environment`。例如独立标准 DashScope 服务可使用 endpoint `https://dashscope.aliyuncs.com/compatible-mode/v1`、model `text-embedding-v4`、dimensions `1024`、环境变量名 `PAPERSHELF_EMBEDDING_KEY`；需用户自己的有效凭据，本项目未验证该远程组合。Token Plan endpoint 对该 embedding 模型返回不支持，Token Plan 密钥与额度也不能自动视作标准 DashScope 的凭据。切换 embedding 模型/维度前需为已有图谱另建独立数据库或重建向量索引。配置示例的 `enabled: true` 表示显式用于生成请求时执行该集成；Paper2Agent 仍仅准备任务，需要另点启动。

已提供 Neo4j 的 `compose.yaml`，生产项目名 `papershelf-graph`，使用独立卷 `papershelf-graph_papershelf-neo4j`，仅绑定本机端口 17474/17687，避免占用常用的 7474/7687。服务有 `unless-stopped` 重启策略。本机已生成随机数据库密码并写入 `~/Library/Application Support/PaperShelf/graph-service/neo4j.env`（目录 0700，文件 0600）；应用通过 `ManagedGraphCredential` 读取该受控文件：仅允许固定本机 Neo4j URI、当前用户所有的普通私有文件，拒绝其他 backend、远程地址及符号链接。现有钥匙串权限问题不会阻塞本地数据库密码读取。新机器需创建自己的同名安全环境文件（`NEO4J_PASSWORD=...`），并在应用设置保存同一个图数据库密码。不要把秘密提交到仓库。

```sh
./script/graph_service.sh start
./script/graph_service.sh status
# 暂停服务，保留资料卷
./script/graph_service.sh stop
```

脚本自动发现 Docker Desktop CLI，支持 `PAPERSHELF_DOCKER` 和 `PAPERSHELF_GRAPH_ENV` 覆盖路径，停止服务保留数据卷，不操作其他 Docker 项目。模板 URI 为 `bolt://127.0.0.1:17687`。Neo4j 镜像固定在 5.26 维护系列，数据库数据不打包进应用。FalkorDB 用户可把 `backend` 设为 `falkordb`，配置 `host`、`port`、`database` 以及可选的用户名/密码环境变量连接已有服务。

```sh
.venv/bin/python -m papershelf_pipeline graph-ingest /path/to/source.md --config /path/to/my-config.json --title 'Paper title'
.venv/bin/python -m papershelf_pipeline graph-search '催化剂温度和速率的关系' --config /path/to/my-config.json
```

按 `episode_characters` 分批传入全部文本，不抽样、不截断。每批携带源 SHA、字符偏移和元数据。确定性 UUID 同时包含提取配置指纹：字段 schema、提取指令、模型/端点、分块规则等相同才跳过已完成 episode；修改自定义字段或提取规则会建立新版本，保留旧 episode。密钥环境变量名和并发数不影响版本。中断后可重跑继续。旧版无指纹的 episode 保留，新版首次再导入会生成可追溯版本。

每个完成 episode 的实体属性、关系、来源和完整提取配置另存为不可变 JSON 快照，位于图数据库 `papershelf_extraction_snapshot` 属性及返回结果的 `extraction_snapshot`（应用保存在 `graphiti.json`）；只排除可重算的 embedding 向量，不删提取字段。后续 Graphiti 合并实体、更新当前属性时，旧快照仍可复查。`reference_time` 默认是导入时间，可在 API 元数据指定带时区的时间；它不等于自动推断论文发布日期。Graphiti 返回事实中的 `valid_at`、`invalid_at`、`expired_at` 和 `episodes` 等字段，保留时序与来源。搜索严格使用配置的 `group_id`。

检索结果每条 fact 的 `sources` 包含完整 episode 原文、标题、原始 PDF 路径、本地 Markdown 路径、字符偏移、SHA 和时间信息，支持从事实返回论文证据；原文不截断。数据库查询和适配器返回值都检查 `group_id`，不把其他分组的事实或来源混入当前结果。缺失的来源会显示警告。

`entity_types` 支持自定义实体类型；生成请求的 `fields` 自动通过 `entity_fields` 成为 Graphiti 的 `PaperRecord` 类型。字段支持 string/text、number、integer、boolean、array、object，包含嵌套类型、enum 和 required_properties；未报告的字段为 null。中文字段可直接保留，空格、符号和图引擎保留名称使用稳定的存储键，返回结果中的 `entity_field_mapping` 与 schema title 保留原始名称。Neo4j/FalkorDB 属性不支持嵌套对象，适配器仅在持久化边界把对象/复杂数组无损编码为带 `papershelf-json:` 前缀的 JSON，模型提取与验证仍使用完整的类型 schema，后续读取验证可解码。此兼容层留在 PaperShelf，未改上游源文件。

可设置 `extraction_instructions` 和 `update_communities`。上游遥测默认关闭。Graphiti 模型提取及矛盾判断仍须核对原文，成功运行不代表科学结论已经确认。

## PPT Master 文献汇报

`ppt-master` 作为完整、未修改的 Git submodule 内置，当前上游版本 6.7.2。适配器使用官方 `skills/ppt-master/scripts/svg_to_pptx` 的公开 `create_pptx_with_native_svg` API，将来源明确的 SVG 页面转换为可编辑的 PowerPoint DrawingML 文字与形状，并嵌入逐页讲稿。导出前执行上游 attribution integrity guard，先执行上游 SVG 最终质量检查，导出后执行上游 `audit_pptx_delivery` 与本地页数/可编辑文字检查。为避免 Office/LibreOffice 替代中文字体时把单行标题意外换行，PaperShelf 只将自身单行文字框扩到页面预留区域，保留位置、字号、文字与媒体，并在 `layout-adjustments.json` 记录每个框的原始/调整宽度，随后再做上游包检查。完整官方 Skill、署名、许可证、模板和工具随应用保存；应用不改写它们，不自动安装全局 Skill。

研读面板可独立选择「文献 PPT」。请求 `outputs: ["presentation"]` 不要求先生成其他研读资料。离线模式完整分页保留原文，明确标为原文摘录；AI 模式复用当前 Provider，按所有原文块分批生成研究问题、方法、结果和局限。每个要点必须引用实际原文块且提供可逐字匹配的引句，每个输入块须有明确的采用/上下文记录。每批模型响应、完整来源、提纲和逐页讲稿均保留，失败不会删除已完成内容。续跑仅复用源哈希、来源分块、完整请求与模型配置、响应哈希都一致且重新通过引用校验的批次；配置变化或损坏缓存会重新计算。AI 归纳仍需研究者核验；证据匹配与 PPTX 包检查不是科学验收。

结果保存到本次运行的 `presentation/`：`presentation.pptx`、可离线打开的 `preview.html`、`outline.md`、`manifest.json`，以及 SVG、讲稿、上游转换 trace 和交付检查报告。manifest 记录上游固定提交、源 SHA、全块覆盖、图像原始字节 SHA 与产物 SHA。预览是 SVG 页面预览，PowerPoint 的字体替代可能与浏览器不同，需在实际播放设备检查。原文图表使用本次运行提取的图片原始字节，关闭上游图片压缩/尺寸优化；不会重绘或补造图中数据。自动裁剪存在漏图和边界误差，保留页码与区域坐标供复查。

当前内置的是文献证据编排、原生 PPTX 导出、讲稿与检查。上游 Coding Agent 的任意模板复刻、联网补图、AI 生图、动画和旁白不作为此按钮的自动流程。导出无需联网，只有 AI 模式的模型请求使用设置中的现有服务。首次安装环境安装最小导出依赖，不安装上游可选的云图片/网页/语音服务。

```sh
python3 script/sync_integrations.py --update ppt-master
./script/setup_integrations.sh
PYTHONPATH=backend .venv/bin/python -m unittest discover -s backend/tests -p 'test_presentation.py' -v
```

适配器 API：`create_presentation(source, learning, request, run_dir, provider=None, progress=None)` 返回四个具名产物；`learning` 可为空字典。`presentation.chunk_characters` 可控制 AI 批次大小（至少 500），不会截断长块或限制处理块数。配置不会传给上游执行器，文献里的指令也不成为执行命令。

## 同步上游

```sh
python3 script/sync_integrations.py --check
python3 script/sync_integrations.py --update markitdown
python3 script/sync_integrations.py --update graphiti --ref origin/main
./script/setup_integrations.sh
PYTHONPATH=backend .venv/bin/python -m unittest discover -s backend/tests -v
swift test
git diff --submodule=log
```

更新只允许干净工作树、来源一致、lock 与 checkout 一致的上游，并要求目标为当前提交的后继。脚本修改一个 submodule 的固定提交和 lock，不提交 Git，不触碰 PaperShelf 定制代码。验收后将指针与 lock 一起提交。`git clone --recurse-submodules` 即可复现上游版本。发行包携带上游许可证；额外 Python 包继续适用各自许可证。不要把任务产物、密钥、环境、运行缓存提交进上游目录。

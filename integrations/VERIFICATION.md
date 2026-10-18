# 上游集成验证 · 2026-10-18

当前固定版本见 `upstreams.lock.json`。在 Apple Silicon、Python 3.14.7 下从固定源码成功安装 MarkItDown 0.1.8 和 Graphiti 0.31.1，`pip check` 无损坏依赖。`sync_integrations.py --check` 真实 fetch 三个 origin，当前 pin 均等于 upstream main，三个源码目录保持干净。

`backend/tests/test_integrations.py` 最新 **18 项通过，无失败、无跳过**，图像几何和原始表格回归 `backend/tests/test_figures.py` **5 项通过**，同次执行共 **23 项通过**，日志为本地 `evidence/integrations-final-tests.log`。独立 Neo4j QA 服务上的 `backend/tests/test_graphiti_live.py` 最新 **1 项通过**，日志为 `evidence/integrations-live-final-tests.log`；真实 HTTP 服务首次故意返回错误字段名，验证完整纠正请求后入库成功。真实生产配置去除 API 环境变量后成功完成数据库检索（当时首块尚未写完，返回 0 条事实）。覆盖：

- 真实 MarkItDown HTML 转换保留中文与表格内容。
- 完整上游 Paper2Agent Skill 复制、输入校验、不覆盖目录、未运行状态，以及独立假主机进程的启动/状态/取消。Codex 使用 workspace-write 沙箱。
- 恢复任务保留原文/review，并归档旧日志和最终回复，清除旧 finished_at、exit_code、error；运行中的任务不能恢复。
- Graphiti 真实 SDK 客户端和自定义字段 schema；中文/特殊名称映射、嵌套对象、array、enum、required_properties 的类型校验。
- 全文分批不丢字符，来源 SHA/字符偏移、重复提交与中断完成标记。
- Token Plan `auto` 请求省略 temperature；本地 FastEmbed 分批向量化不依赖额外的远程 embedding 密钥。
- 兼容端点的 provider options 保留 schema，并拒绝凭据/消息覆盖。合法 JSON 字段错误时最多请求两次完整纠正；原文和前次响应未截断，持续错误仍抛出验证失败。远程 embedding 检索只读取独立或继承的 embedding 密钥，本地检索不读取模型 API 密钥。
- 同文献相同字段保持幂等；新增自定义字段生成新的配置指纹/episode，保留旧 episode 与不可变提取快照；模拟后续实体属性更新后，旧版本字段仍原样可查。密钥环境变量名轮换不触发重提取。
- 混合检索随每条事实返回完整原文 episode、PDF/Markdown 路径和来源元数据；数据库查询及结果组装都隔离当前 group，回归验证 1500 行来源未截断且跨 group 内容不外泄。
- **真实 Neo4j 5.26 数据库 + 真实 Graphiti SDK + 本地合成 HTTP 模型/embedding 服务**：写入 2 个实体与 1 条关系，保存包含中文嵌套对象的属性，重复导入跳过，混合检索返回事实、valid_at 和原始 episode UUID。测试分组在结束时清理；QA Docker 服务随后关闭，未修改已有其他容器。

以上本地合成 HTTP 模型服务是明确构造的固定响应，目的是验证请求协议、数据库、数据类型和调用链，**不是在线模型效果或科研提取准确性验收**。

安装脚本已验证从只读 app-like 资源副本安装：867 个文件/目录的内容 SHA 和权限在真实 pip 安装前后全部一致，退出码 0，私有 staging 自动清理。依赖从既有环境只读复用，三个本地源码包均构建安装到独立 QA venv。证据为 `evidence/setup-readonly-verification.json` 与 `.build/integration-qa/setup-readonly-20261018-044613/`；该检查证明安装不在源资源中写 egg-info/build/pyc，不替代应用签名验收。

随后完成了**真实 Token Plan 在线 `auto` + 本地 FastEmbed 多语言模型 + 真实 Neo4j + 真实 Graphiti** 的完整验证：一段明确虚构的软件 QA 文字产生 1 个 episode、3 个实体和 2 条关系，重复导入跳过，查询返回 2 条事实。证据为本地 `evidence/graphiti-token-plan-live.json` 与 `.log`。测试分组已清理。实际 Token Plan endpoint 不提供测试的 `text-embedding-v4`，因此默认采用本地 384 维模型；未宣称标准 DashScope embedding 已验证。

真实论文 `d2cp05083h.pdf` 的两条方法事实已对照原 PDF 视觉抽查：CRNN 将质量作用定律编码进网络（PDF 第 2 页/刊页 3707），以及 VI 使用独立 Gaussian 的 mean-field 近似（第 5 页/3710），均有直接原文支持。这不构成整篇或整个图谱的科学验收。固定 12000 字符分块在本篇的三个边界分别切开词组、句子和页间过渡，未丢字符，但仍存在上下文割裂风险。

该论文的 **qwen3.7-plus 全篇导入已完成**：运行 `evidence/graphiti-real/d2cp05083h/20261017T204526Z-fe61e049e8`，4 个 episode 完整重构 47722 字符，关联 64 个实体和 56 条关系；源 PDF/Markdown SHA、全部完成标记、配置指纹及每段数据库快照与本地 `graphiti.json` 完全一致。三个真实 Graphiti 混合查询分别返回 12 条事实，逐条核对完整 episode 内容及原 PDF 路径，无来源截断；验证查询使用本地向量，未调用在线模型。此前 `auto` 空回复运行已明确取消，第一次 qwen 运行在第 2 段字段验证失败，均保留历史；最终运行复用第 1 段，完成后续全部文本，第 4 段的一次 `EdgeDuplicate` 字段错误经完整纠正请求后成功。验证 receipt：`evidence/graphiti-real/d2cp05083h-verified.json`。

第二篇 **CRNN `2002.09062.pdf` 全篇也已入库并验证完成**：运行 `evidence/graphiti-real/2002.09062/20261017T205337Z-a89ce6190d`，29 页、467 个来源段落，5 个 episode 完整重构 49117 字符，关联 51 个实体和 45 条关系；全文 SHA、完成标记及版本快照与数据库一致。三条真实混合查询各返回 12 条事实，其中包含两篇论文的跨文献结果；每条来源均核对各自原 Markdown 切片、完整内容和 PDF SHA。该验证保持知识库内原文与关系不变，不删除先前 BCRNN 数据。验证 receipt：`evidence/graphiti-real/2002.09062-verified.json`，其中 `cross_paper_sources_verified: true`；`scientific_acceptance` 仍为 false。

抽查同时发现一个**实际单位错误**：关系 `407165f3-65ed-4484-8c2b-a652278404e7` 将 `Ea = [14.54,14.42,6.47]` 的单位写为 `kcal mol1`；第 6 页/3711 的原 PDF 清楚显示 `kcal mol⁻¹`。PDF 文本层把负号编码为 U+0003，Markdown 保留该异常字符，模型输出又省略了它。该关系及原文证据保持不改，标记为待人工核对，未静默纠正或删弃。原生 Graphiti 界面明确提示模型抽取尚未人工确认，数值/单位/公式需对照原 PDF。检索适配器还会为含非空白 C0 控制字符的 episode 生成具体来源警告，保留全部原文和事实不改；新增检查与来源隔离回归共 2 项通过，见 `evidence/source-warnings-tests.log`。完整抽查记录与来源片段见本地 `evidence/graphiti-real/d2cp05083h-method-review.json`。

真实 Paper2Agent Codex 主机已完成上游 paper2skill 流程（退出码 0，`host_completed`）：第一次运行因缺少 pymupdf4llm 且沙箱无法访问 PyPI 而明确阻塞；安装官方固定依赖后，在同一任务保留旧证据恢复。任务位于 `.build/integration-qa/real-paper2agent-20261018-040152`，最终阅读 Skill 为 `dist/fixture-paper`。`verify --strict`、`build --require-reviewed`、独立图文复核、仅依据生成包的检索 QA 和 Skill 格式校验均通过；最终 5 个文件 SHA 与独立复核的 staging 全部一致。状态为 `reviewed_with_limitations`：两个图注数字计数差异以源页面视觉核对和精确 fingerprint 的 adjudication 解决，未隐藏检查项。完整验收见该任务 `job.json`、`final-response.md`、`review/REPORT.md` 和 `review/resume-pinned-runtime/`。该输入是合成 QA 文献，无代码仓库；此结果不表示真实科研软件、paper2mcp 或科学结论已通过验收。

生产 Neo4j 与 QA 分离：`papershelf-graph-neo4j-1` 已通过健康检查和实际 Bolt 密码认证，生产卷为 `papershelf-graph_papershelf-neo4j`，仅开放 loopback 17474/17687。密码保存在应用数据目录的 0600 文件；尝试新 `graph-password` Keychain 项目超时后已停止该操作。应用新增受限的 `ManagedGraphCredential` 本地读取（固定 Neo4j loopback、当前用户普通私有文件）；模型 API 的钥匙串状态仍单独处理。已有其他项目容器未改动。操作命令见 README。

PDF 图表提取已用两个实际来源核对：`d2cp05083h.pdf` 12 页识别 Figure 1–14；`2002.09062.pdf` 29 页识别 Figure 1–13、Table 1–4、S1–S3。修复了数学公式跨块图注和图注内交叉引用导致的裁剪截断；原始表格直接保留所有单元格。裁剪图及 PDF 坐标仅是可复查的候选，覆盖标记仍为 `heuristic_not_exhaustive`，保留完整页面和人工框选入口。

已处理两项上游接口事实，未修改上游源码：Graphiti 当前依赖元数据遗漏直接导入的 `httpx`（OpenAI 3 改用 httpx2），因此外置 `adapter-requirements.txt` 补齐；`add_episode(uuid=...)` 当前要求 episode 已存在，因此先保存原文，再执行抽取，成功后写完成标记。图数据库不支持嵌套 map 属性，适配器在保存边界无损 JSON 编码，类型 schema 和后续校验保留。

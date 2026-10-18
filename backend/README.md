# PaperShelf 0.4.0 文献学习后端

从完整文献生成可追溯的原语言全文、中文主题研读、自定义字段数据集和可运行文献 Agent。0.4 将原始证据、阅读正文、主题讲解和处理诊断分开，避免页码、重复版权页脚及分块日志占据主学习页面。全部来源仍保留；阅读整理不是原文覆盖或数据抽样。

安装项目根目录的共享运行时（MarkItDown、Graphiti 来自锁定的上游源码版本）：

```sh
./script/setup_integrations.sh
.venv/bin/python -m papershelf_pipeline doctor
.venv/bin/python -m papershelf_pipeline run --request request.json
```

请求示例（密钥仅从环境变量读取，不能放到 JSON）：

```json
{
  "source_path": "/absolute/paper.pdf",
  "supplementary_paths": ["/absolute/supporting-information.pdf"],
  "output_root": "/absolute/learning-runs",
  "reference_id": "library-reference-id",
  "title": "论文题目",
  "reader_context": "我的研究背景与希望理解的问题",
  "mode": "llm",
  "provider": {
    "base_url": "http://localhost:11434/v1",
    "model": "your-installed-model",
    "api_key_env": "PAPERSHELF_API_KEY",
    "timeout": 180,
    "json_mode": true
  },
  "fields": [
    {"name": "catalyst", "type": "string", "description": "样品名称", "required": true},
    {"name": "temperature", "type": "number", "description": "反应温度，保留原文单位", "unit": "K"},
    {"name": "products", "type": "array", "items": {"type": "string"}, "description": "报告的产物"}
  ],
  "paper2agent": {"enabled": false},
  "graphiti": {"enabled": false}
}
```

可用 `"outputs": ["presentation"]` 单独生成 PPT。允许的成果名为 `guide`（HTML）、`markdown`（研读 Markdown）、`source`（完整原文 Markdown）、`dataset`（字段与证据）、`agent`、`presentation`。数组必须非空且不重复；省略时兼容原有完整研读包，不自动生成 PPT。源文档与 provenance 是共享必要输入，不意味着自动启动其他成果任务。原生界面每次仅选择一个成果，分别聚合最新可用版本。

`source` 和 `agent` 创建只执行本地提取，即使请求 `mode=llm` 也不调用模型。`dataset` 使用独立字段提取与 `extraction-chunks` 缓存；`presentation` 使用独立全块汇报编排及上游原生 PPTX 导出。`guide` / `markdown` 单独请求不提取字段、不创建 Agent、不运行 Graphiti。书籍章节、校订和概览审阅保持原请求的格式选择。

PPT 结果包含 `artifacts.presentation`、`presentation_preview`、`presentation_outline`、`presentation_manifest`，原始 SVG、逐页讲稿、引用记录和上游交付检查也保存在本次运行。上游锁定与更新命令见 [集成文档](../integrations/README.md)。

`mode=offline` 完整保存来源与页图，执行可追溯的版面整理，生成原语言阅读版、未填写字段模板和离线检索 Agent；明确不代表 AI 校订或中文讲解。`mode=llm` 要求可用模型，生成原语言清洁正文和中文研读。服务失败、无效 JSON、阅读覆盖不完整、无法核对的引文/页码、字段类型错误或截断等未能通过校验时，保留失败记录，不把离线资料冒充 AI 成功结果。兼容 OpenAI Chat Completions 协议；本地 Ollama 等可不提供密钥。原文发送到所配置的服务，使用前选择适合数据要求的地址。

字段支持 `string/number/integer/boolean/array/object`，可配置枚举、数组元素与对象属性。每条记录代表独立样品/条件组合。字段 `unit` 为期望单位提示，提取值保留模型报告的原文单位，单位不一致写入警告，禁止静默贴换单位。原文证据按来源块、页码和规范空白后逐字匹配检查；这个技术检查不保证科学解释已正确。编辑和审阅使用 `dataset-review`，保留原因、操作者与前后值历史。

## 来源、阅读层与产物契约

每次创建独立运行目录。`manifest.json` 记录来源和产物哈希、页数、覆盖指标、模型调用及问题状态。原始主文和 SI 不修改；所有原始块、页图与阅读分组均保留，不按比例抽样，也不以摘要替代全文处理。

| 文件或字段 | 内容与边界 |
|---|---|
| `source.json → raw_blocks / blocks` | 未改写的提取文本、原始 ID、页码、行偏移、坐标及文档身份；是引文校验的依据 |
| `source.json → reading_blocks` | 可阅读的分组，`source_ids` 映射到原始块，保留页码和文档身份；包含阅读文字、角色和整理记录 |
| `source.json → reading_main_blocks` | 主正文分组入口；AI 清洁阅读覆盖这些分组，公式/版面碎片等仍保留在其他来源视图 |
| `source.json → reading_fragments` | 不猜改的短公式、符号或图轴片段；保留来源并单独呈现，不作为连续正文，也不删除 |
| `source.json → reading_excluded` | 页眉页脚、出版信息等版面附属内容；仍有原始 ID 和角色，不能当作原文被删除 |
| `source.json → reading_layer` | 阅读层版本、角色/数量统计及验收边界 |
| `learning.json → clean_reading` | 覆盖全部主正文分组的同源语言 AI 清洁阅读文本，含 `source_ids`、`editing_notes`、`validation` 和 `status: ai_edited_unreviewed`；离线运行不宣称存在 AI 校订 |
| `learning.json → thematic_sections` | 围绕研究问题、方法、条件、证据和局限的中文主线研读，内容须能返回来源 |
| `learning.json → paragraphs` | 逐段中文对照资料，保留来源关系；其覆盖不是科学正确性证明 |
| `learning.json → process_notes` | 分块处理、提取和生成诊断；与学术层面的待核验问题区分 |
| `source.md` | 完整原始提取文本 |
| `source-index.md` | 带稳定来源锚点的逐块索引 |
| `fulltext.md` | 原语言连续全文；AI 模式使用清洁阅读版本，离线模式使用可追溯的版面整理版本；附属来源单独列出 |
| `layout-fragments.md` | 有片段时生成；完整保留暂不能安全重组为正文的公式、符号和图表文字，并链接原始来源 |
| `learning.html / learning.md` | 中文主题学习资料，保留公式、图表、自测和来源入口 |
| `paragraphs.md` | 可单独阅读的逐段对照 |
| `reading-content.md` | 原语言清洁正文与来源 ID，供知识提取使用；不混入界面、校订日志或处理提示 |
| `extraction.json / dataset.csv / dataset.tsv` | 自定义条件记录、字段值及证据；审阅历史保存在 JSON 中 |
| `evidence-graph.json / agent/` | 本地证据关系及可独立运行的阅读 Agent |

`clean_reading` 项包含 `{id, source_ids, text, kind, pages, editing_notes, validation, status}`。`thematic_sections` 项包含 `{id, title, paragraphs, source_ids}`；每个中文段落为 `{text, source_ids, kind}`，`kind` 区分 `source/background/inference/uncertain`，节级来源为段落来源并集。`process_notes` 为流程注记字符串数组，`gaps` 保存学术或原文疑点。正文覆盖以 `reading_main_blocks` 为依据；不会要求每个页码、公式残片都生成独立译文。

`artifacts.source_markdown` 在 0.4 指向 `fulltext.md`；`artifacts.raw_source_markdown` 指向 `source.md`，`source_index` 和 `paragraph_markdown` 分别指向来源索引和逐段对照。有公式或版面片段时，`layout_fragments` 指向 `layout-fragments.md`。消费者应使用 manifest 返回的路径，不能把 `source_markdown` 硬编码为旧版文件名。可用时还保留 MarkItDown 的独立转换结果 `markitdown.md`。

原始 PDF 布局段落先按列、字体、间距组合，`raw_blocks` 和行切片仍可逐字符追溯；阅读层再分类和整理空白、断词与阅读顺序。阅读层中的每次可追溯变换不改 `blocks.text`。无法确定的数学控制字符或连字符不能猜改；公式碎片和图轴数字应结合所属图表核验，而非仅因短小就删除。

AI 原语言清洁用于阅读，不能成为改写原始引文的依据。自定义字段的证据仍按未改写来源块、页码和规范空白后的逐字文本验证。模型需保留数字、单位、条件、符号和限定语；存在 source ID 或原文锚点，只能证明位置对应，不能保证译述相关性或语义忠实性。

长段译述可采用稳定的 `translation_units`，逐项要求完整译述，再合成为段落。主线研读负责组织主题；逐段对照与原语言全文负责覆盖。原始块与被归入附属来源的内容均可访问，不把页码、版权或空白标记强行解释为科学结论。流程诊断单独保留，不能将“本分块没有实验内容”写成整篇论文的研究缺失。

## 内容审阅与可追溯修正

应用中的 **AI 校订正文** 使用当前模型，对已完成的资料另存新版本。CLI 对应：

```sh
python -m papershelf_pipeline revise --manifest /absolute/run/manifest.json
```

校订独立执行完整原语言重排与逐句中文直译，再对照 canonical 原文重新组织主题。原句中的变量定义、数值、条件和论断强度必须保留；英文明确断词如 `challen-ging` 可以修复，数学符号疑点必须记录。正文中的重复页眉、版权和仓储封面保留在来源索引，独立公式和图轴保留在版面附录。旧版本不覆盖，自定义字段及其证据不经生成模型改写。旧译述和整理稿保存在新版本 `draft/`，校订前后稿及每次模型响应可追溯。源文件改变时拒绝混用版本；失败或取消保留状态与已完成响应。

已对照原页核实的文字、译文或公式可在完整校订版上另存，无需再次调用模型：

```sh
python -m papershelf_pipeline revise --manifest /absolute/run/manifest.json \
  --editorial-only --editorial-corrections /absolute/source-reviewed-corrections.json
```

校核包绑定原文 SHA256、来源 ID 和原页图 SHA256。`content_corrections` 必须提供字段完整原值、新值及理由；`clean_reading` 修正还需 `reading_group_id`。完整译文有逐句单元时，`required_follow_through` 必须同时提供 `translation_units_original` / `translation_units_corrected`，保留全部单元 ID 和顺序，新单元连接后须等于新译文。编辑说明可同样提供 `editing_notes_original` / `editing_notes_corrected`。精确值不匹配时另存失败，不覆盖原版本；历史约束不应冒充本次精确替换。新版本保留修订前稿、实际应用位置和关联译文，重新生成 HTML、Markdown 与 Agent，并记录零模型调用。原始提取字形如 `2` 经原页确认改为 `∈` 后，数值校验标记为来源核验修订，同时保留原校验记录；这不代表用户已接受科学内容。

仅修改编辑备注时使用 `annotation_corrections`，指定 `reading_group_id`、`field: editing_notes`、完整 `original`/`corrected` 数组及同样的来源核验信息。行内公式恢复可补充 `additional_evidence_source_ids`，但这些 ID 必须已在该阅读组的 `linked_layout_source_ids` 中，且逐字引文、文档与原页图哈希都须通过验证。后续 AI 校订从上一版实际展示的综合条目继续，旧模型卡片留在 `draft/` 中，不重新作为当前草稿。

主题正文的精确修正用 `section: thematic_paragraphs`、`field: text` 定位段落。普通学习条目可提供 `corrected_source_ids` 同步修正引用，每个新加入的来源必须附逐字 `source_evidence`，所有原、新来源都须通过页图核验；主题的来源并集会随段落重算。全文阅读组的来源映射不能通过该字段改写。

`--provider-config` 可选择无密钥的当前服务配置。`--editorial-corrections` 可提供独立核验记录：绑定原 PDF SHA256、来源 ID、实际页图 SHA256、审阅者和核验方法；公式修正保留前后值，正文修正只匹配精确旧值。核验过的公式按原文位置重新进入全文 MD，未可靠重建的公式保留原始证据，不以乱码冒充可读 LaTeX。新版本的 Graphiti/Paper2Agent 回执仍明确引用之前的独立任务，不隐式重写远端知识库或重复执行科学工具。

复核后可在请求提供 `review_corrections_path`（精确原值/新值/原因/来源 ID）和 `layout_observations_path`（原 PDF SHA256/来源 ID/原版面观察/核验记录）。前者修改讲解文字、逐句译述或公式及符号解释，保存 `chunks/*-before-review.json` 与 `learning-review.json`；后者把经独立核验的提取误差或原文冲突显式提供给生成器。字段事实使用独立的 `extraction_corrections_path`：每项须有 paper、source_sha256、record_id、field、完整 original/corrected 单元格、reason、actor；源文件及原值匹配后再次严格核验类型与逐字引文/页码，并通过既有数据集审阅机制保留哈希审计链。它在所有导出和 Agent 生成前应用，保存 `extraction-before-review.json`、`extraction-review.json`，明确不代表研究者科学验收。旧运行不会被覆写，未核验图像不得被称作已阅读。

HTML 是离线单文件，严格白名单过滤的 MathML 公式不需要远程库，每一 PDF 页都以图像嵌入以保留向量图表和扫描页。图表清单根据图注和版面图元检测，保留候选框、置信度、裁图 PNG、原矢量裁图 PDF 与完整页图，供检查遗漏、分图及裁剪边界。手工坐标可通过 `figure_boxes` 覆盖。注释依据可提取文字，自动候选不等于科学或视觉验收。扫描页会报告 OCR 缺口，全文扫描且 LLM 模式时拒绝无来源生成。

图、表、公式引用只链接到实际存在的唯一目标；未解析引用显示为缺口。支持返回栈、悬停预览、图片灯箱，跨元素划线跳过数学公式内部，划线颜色/笔记/编辑/删除，以及严格验证文献身份的 JSON 导入导出。笔记身份包含主文与全部 SI 的哈希，换 SI 不会将旧笔记贴到新附件。所有资料原文块完整保留，不使用字数上限裁掉来源。

`calculations` 由模型提出可复算算式和原文变量证据，后端用 AST 白名单解释器实际计算。仅允许基本算术与 exp/log/log10/sqrt/sin/cos/tan/abs；不执行模型代码。原始变量数值须出现在原文引文中，单位换算写在算式里。HTML 固定计算器允许修改输入探索；空白、非法数字、分母零及超出函数定义域时显示校验信息，不显示 NaN/Infinity。

书/学位论文可设置 `"book":{"auto":true}` 从 PDF 一级书签建章，或设置 `"book":{"chapters":[{"title":"第一章","document_id":"main","start_page":1,"end_page":10},...]}`。范围必须恰覆盖全部文档页，不允许重叠或缺页；SI 文档 ID 为 s1/s2。生成 `index.html`、每章 HTML/Markdown 和 `book.json`，每章保留跨章证据链接，完整单文件学习稿仍可用。

失败或取消后可在新请求加 `"resume_from":"/absolute/previous-run"` 复用先前成功分块；主文/SI 哈希、来源段落分组及其编号和文本、字段、读者背景和分块大小必须完全匹配；服务设置改变时重新生成，不复用旧服务分块，并重新核验每个已有分块。版面分组改变后必须重新生成，不能把旧解释迁移到新编号。重试创建新目录，保留原失败记录。SIGTERM 取消会将 manifest/index 标记 cancelled，并保留完成的分块。可选 Graphiti/Paper2Agent 准备失败时返回 partial 与 integration_errors，本地完成的资料仍可查看。

综合概览与阅读路线可在生成后确定性审阅，无需再次调用模型：`python -m papershelf_pipeline summary-review --manifest /absolute/run/manifest.json --corrections /absolute/summary-corrections.json`。修正文件为数组，每项包含 `field`（`overview` 或 `reading_route`）、完整 `original`/`corrected`、`source_sha256`、`source_ids`、`actor`、`reason`。可另用 `--paragraph-corrections` 提供相同来源绑定的单段 `explanation`/`reasoning` 修正；它们会再次通过当前段落校验并同步分块与导出。命令验证已有产物哈希和精确旧值，生成新运行目录并重渲染 HTML/Markdown；原运行及模型响应不变。`summary-review.json`、`learning-before-summary-review.json` 与 `chunks/*-before-final-review.json` 保留审计；原 Graphiti/Paper2Agent 回执被复用，不重新执行集成，也不代表研究者科学验收。

## CLI 与阅读 Agent

CLI stdout 始终为最终单个 JSON，进度在 stderr。结果 `{status,run_id,run_dir,manifest_path,artifacts,warnings,metrics}`，所有 `artifacts` 值都是绝对文件路径。失败返回 `{status:"failed",error}` 且非零退出。`source_pages_path` 可指向 PDFKit 提供的 `[{page:1,text:"..."}]` 或 `{pages:[...]}`，只在 PyMuPDF 不可用时使用。

```sh
.venv/bin/python -m papershelf_pipeline agent --manifest /run/manifest.json --query "rate constant"
.venv/bin/python -m papershelf_pipeline agent --manifest /run/manifest.json --query "本文模型有什么边界？" --mode llm
python3 /run/agent/run.py --stdio
.venv/bin/python -m papershelf_pipeline graph-query --graph /run/evidence-graph.json --query "temperature"
.venv/bin/python -m papershelf_pipeline provider-probe --config /absolute/request.json
.venv/bin/python -m papershelf_pipeline provider-models --config /absolute/request.json
.venv/bin/python -m papershelf_pipeline dataset-export --extraction /run/extraction.json --source /run/source.json --output /new-export
```

`agent/` 可复制到其他位置独立运行（Python 3.10+，无第三方依赖）。MCP 客户端使用 `agent/mcp.json`；移动目录后更新其中的绝对启动路径。可调用 `search_paper`、`read_page`、`get_extraction`、`ask_paper`。这是实际可调用的阅读证据 Agent；Paper2Agent 上游科学代码复现、测试和 MCP 科学工具生成使用独立 upstream 工作流，不能将“任务已准备”宣称为“科学工具已验证”。

## 验证

结构检查、真实模型输出、浏览器视觉效果与科学内容审阅分别记录。新阅读层的代码测试不能直接继承旧版真实论文的内容验收；相关已发现问题见 [独立质量复审](../evidence/quality-v2/review.md)。

```sh
.venv/bin/python -m unittest discover -s backend/tests -v
```

# 全篇合并契约只读复核

复核日期：2026-10-18。范围：`backend/papershelf_pipeline/synthesis.py` 中 `consolidate_learning` 的覆盖/引用纠正契约，以及 B-CRNN 运行 `20261018T063426Z-87327486c7` 的 `source.json`、完整 `chunk-????.json` 和三份 `consolidation-2-invalid-*.json`。

状态：**本记录不代表最终生成成功、全篇验收或人工科学验收。** 本轮未修改校验守卫，未修补或接受任何无效模型响应。CRNN 最终 149 组阅读投影的中英文与全篇合并结果尚待实际最终运行完成后独立审核。

## 当前案例能否在现有契约内清理

可以。现有动作只有 `retained`、`merged`、`excluded`，没有 `corrected`。错误内容可依原文改写，以 `retained` 或 `merged` 记录；原引用错误时，在**对应原始输入项**的 coverage 上附 `citation_correction`。这不要求把错误草稿继续展示在学习正文中。

| 输入项 | 原始证据与判断 | 合理处理 |
| --- | --- | --- |
| `glossary-12` | 草稿将 B-CRNN 展开为 “Bayesian Convolutional Recurrent Neural Network”；引用 `p6-g226` 和 `p7-g246`。前者讨论温度依赖的生物柴油体系，后者是缺失 DG 浓度信息的 Fig. 6 图注，均不支持该全称。 | 依据正确全称改写后，`merged` 到明确的 B-CRNN 定义。引用纠正应挂在 `glossary-12`，完整保留原始引用审计。 |
| `glossary-4` | 原草稿已写 “Bayesian Chemical Reaction Neural Networks”，原引用只有 `p3-g37`。 | 与其他正确 B-CRNN 定义合并；不得把 `glossary-12` 的原引用伪装成该项原引用。 |
| `critique-7` / `critique-8` | 都指出 Fig. 5(c) 的活化能/对数活化能描述冲突。7 引用 `p6-g238`、`p7-g247`，8 引用 `p7-g247`，为近重复。 | 两项均标 `merged`，保留两处来源及“需核对原始数据或作者意图”的边界，无需重复展示。 |
| `glossary-2` / `glossary-19` | 都为 UQ 释义；19 的原引用 `p9-g348`、`p9-g349` 涉及对选定参数做 UQ。 | 可合并到显式 UQ 定义并核对引用。“正文隐含、较通用”不足以说明具体承接位置或来源纠正。 |

正确全称有直接原文依据，逐字证据分别为：

- `p3-g37`，第 3 页：`resulting in the Bayesian chemical reaction neural networks\n(B-CRNN)`。
- `p10-g359`，第 10 页：`Bayesian chemical reaction\nneural network (B-CRNN)`。

因此，对 `glossary-12` 的合理纠正可使用原始来源 `p6-g226,p7-g246`、纠正来源 `p3-g37,p10-g359`，并逐一附对应来源的真实引文。错误全称留在不可变草稿和纠错审计中即可，不应被说成论文原文自身的歧义。

## 三次响应存在的独立缺陷

仅放开 `excluded` 并不能令这些响应有效：

- **第 1 次**：coverage 声称 BBB、HMC 已合并，MAPK 和 Model Mixing 已保留，但实际术语表只有 B-CRNN、VI、ELBO、通道选择矩阵四项。`glossary-12` 的纠正来源列出 `p3-g37,p10-g359`，证据却只引用 `p1-g2`，不对应纠正来源。重复的 `critique-8` 使用 `excluded`。
- **第 2 次**：B-CRNN 定义谎称“原文中亦曾”将其展开为 Convolutional Recurrent，把模型草稿错误归给原文。引用纠正错挂到 `glossary-4`，却使用 `glossary-12` 的原始引用。
- **第 3 次**：把 `glossary-12`、`transfer-1` 等输入项 ID 当成 canonical 来源 ID；B-CRNN 的 `corrected_source_ids` 为空。
- **跨尝试问题**：部分 `transfer-1` 证据插入人工省略号，不能按原文逐字核验；第 2、3 次 HMC 释义把目标分布本身当成势能，未保留负对数后验约定。

应让模型重做有缺陷的响应，保留失败记录；不能为了使运行通过而降低证据约束。

## 后续契约建议（本轮未实施）

当前守卫按原引用块的 `reading_role` 禁止排除科研项，保护了原文科学条件，但“引用了正文”并不能证明草稿断言真实。完全虚构或不适用的草稿内容，长期不宜被迫改造成另一个科学条目。

后续可增加明确的草稿驳回契约，例如 `rejected_draft`，区分 `unsupported_claim`、`source_contradiction`、`irrelevant_inference`：

1. 原始草稿、原引用、原文及来源身份永久保留；记录具体被移除的断言。
2. 记录真实支持/反证段落、审查范围及不保留的理由。单段未提及某断言不等于证明全文不存在；“不受支持”仍属于需审查的语义判断。
3. 有受支持的部分须保留；不得用驳回绕过独有实验条件、数字、限定或原文疑点。
4. 重复项与可纠正项优先显式映射到实际输出项；纠正来源继续逐项提供可核验引文。

还应将 coverage 加强为 `input_id → output_id` 映射。当前校验使用同一输出章节内的来源 ID 并集，能查出一部分来源遗漏，却不能证明某个输入的独有语义真正进入哪个输出。即使映射和逐字证据全部通过，也只是技术审计，不是自动科学验收。

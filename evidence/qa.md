# PaperShelf 0.1.0 验证记录

日期：2026-10-18（Asia/Shanghai）。机器：Apple Silicon / arm64；Apple Swift 6.4；部署目标 macOS 14。

原始日志仅在本机保留，Git 仓库仅发布此验证总结与测试源码。迁移后的复验见 `relocation-check.md`。

## 构建与自动测试

- `swift test`：22 项、0 失败。完整原始输出为 `swift-test.log`。
- 7 项 Bibliography：嵌套 BibTeX、宏、导出往返、个人作者输出、截断/非法输入、RIS 多记录/多行、Markdown 字符转义。
- 4 项 DOI：规范化、Crossref 映射/编码、HTTP/响应错误、超时传播。此组使用模拟网络，不依赖外网。
- 9 项 SQLite：重启恢复、更新删除、重复 DOI/PDF、编码 URL 去重、冲突不覆盖、事务回滚、损坏记录、未来 schema 和非 SQLite 文件保持原样。
- 2 项 PDF：合成 PDF 的元数据、书签持久化、评论/页码、原文件字节不变、删除记录后原 PDF 存在；无效和缺失附件错误。
- 故意读取无效 PDF 的负例触发一条系统 CoreGraphics 日志；对应测试通过，不是正常 PDF 流程失败。
- `script/build_and_run.sh --build-only`：构建和本机临时签名成功，见 `build.log`。早期 `--verify` 成功，最后版本另通过实际启动和界面操作检查。

## 原生界面与外部服务

使用独立测试数据库，未读取或修改用户既有文献库。

| 检查 | 实际观察 |
| --- | --- |
| 空书库窗口 | 原生三栏、导入按钮、搜索与工具栏可见；检查了实际渲染 |
| BibTeX 导入 | 系统文件选择器打开 sample.bib，显示导入 2 条，列表/作者/年份/标签正确 |
| 编辑 | 保存中文分类“测试分类”和中文笔记，界面显示保存后的值 |
| PDF 关联 | 系统文件选择器关联合成 sample.pdf，显示文件名和打开/Finder/重新关联按钮 |
| 批注 | 点击读取批注，显示 1 条、页码 1、预置 Text 评论内容 |
| 无效 DOI | invalid-doi 在 DOI sheet 内直接显示错误；可继续修改输入 |
| 真实 DOI | 10.1038/nphys1170 成功查询 Crossref，返回 Measured measurement / Aspelmeyer, Markus / 2009 / Nature Physics |
| 搜索 | Kinetics 过滤至 1 条；Methods 切换到另一条；隐藏的选中项详情清空 |
| 清除搜索 | Esc 与实际鼠标点击搜索叉号均恢复 3 条。辅助功能 AX press 对叉号曾只清空可见文本；随后用真实坐标点击验证了完整行为 |
| 分类 | 点击分类与全部文献，标题和筛选范围切换 |
| 导出 | 从当前筛选列表导出 1 条 BibTeX，核对中文笔记、作者、分类字段。文件另存为 evidence/ui-export.bib。自动化输入保存名称时出现冒号路径，已仅移动该测试产物至此处 |
| 重启 | 正常退出后使用同一测试库启动，恢复 3 条、中文分类/笔记及附件路径 |

截图：`papershelf-ui.png`（示例数据界面）。测试库不作为用户默认书库发放，默认应用以自己的空书库开始。

## 尚未验收

未逐项人工验证所有右键命令、删除确认、默认阅读器/Finder 回跳、全部排序和复制操作；未进行全量无障碍、多系统/Intel、大量文献、长期数据和异常断电测试。未验证复杂 PDF quad-point 高亮、图片批注、OCR、移动文件后的书签刷新或沙盒签名运行。

常规 PDF 导入与 RIS 导入逻辑有自动测试；本次 UI 直接验证的是 BibTeX 导入及已有记录的 PDF 关联。不能把未走过的 UI 路径称为完整人工验收。

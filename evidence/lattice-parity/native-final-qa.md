# 最终原生界面验收

2026-10-18，macOS 27.2，使用 CUA 操作实际 `.build/lattice-qa/PaperShelfQA.app`。该 QA bundle 默认固定为同目录下 `library/library.sqlite`，避免误触生产书库。检查时显示 3 篇测试记录。

实际观察和操作：

- 窗口使用系统导航侧栏、四列默认表格和可折叠检查器；标题为衬线字体，工具栏采用当前系统按钮。截图已在当前会话中目检。
- 选中 Rivera 示例，按 Space 打开 Quick Look；能读到合成 sample PDF 内容，关闭后返回原选择。
- 切到标注页面，显示 1 条第 1 页 Text 批注，文字为 `Sample comment: verify page 1 and preserve the original PDF.`。
- Cmd+F 输入 Rivera，列表收敛为 1 篇；清除恢复 3 篇。收起检查器后表格自动扩展。
- Cmd 多选两篇，批量添加 `QA checked` 标签，侧栏计数立即为 2；Cmd+Z 后计数归零，两篇原有分类保留。
- 导出菜单实际显示选中文献、当前列表、全部文献三范围，以及 BibTeX/RIS/Markdown/TextBundle 子项。未将菜单可见性当作实际文件导出验收。
- 模板中修改批注模板后单独恢复元数据模板，批注自定义内容仍保留；单独恢复批注后默认模板恢复。展开元数据预览，看到实际题名、作者、来源、引用键和 PDF/应用链接。
- 设置中英语切换立即更新 General、File、Templates、Integrations、Study 与主要通用设置文本；随后恢复跟随系统。AppKit 提示和动态状态文字并未全部英文化，不宣称完整双语验收。
- 学习设置仅有内部 Model/Fields/Runtime 分段与外层五个设置标签，先前重复标签问题已消失。
- 正常 Cmd+Q 退出，进程结束；没有强制杀死应用。

尚未覆盖：四浏览器安装点击、外部阅读器新写入批注的自动刷新、多文集拖放/文件面板/恢复流程的全部交互，Word/Raycast 宿主、Siri/Spotlight 的实际动作执行。Shortcuts 后续已实际发现四动作，但执行因缺少 Team ID 失败，详见 [签名记录](signing-and-hosts.md)。Core、Store harness 与接口测试分别见其他日志，不能代替这些交互。

生产库升级前已保存可恢复备份，见 [备份收据](production-backup.log)。测试库中的 QA 标签和记录不写入生产库。

正式版随后已启动，原有两篇真实文献、PDF、生成历史及 HTML/Markdown/字段/图谱/Agent 入口仍可见；没有重新生成或修改原学习内容。

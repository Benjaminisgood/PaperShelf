# Lattice 功能核对输入

检查日期：2026-10-18，主机 macOS 27.2。此表是独立实现的需求输入，不是 PaperShelf 完成声明。公开文档、应用附带帮助和静态结构只证明声明或存在性；交互行为由根代理实机核查。

## 来源与版本

- **R**：[Lattice_release README](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/README.md)，本次实时 HEAD 为 `001dcbbc97ff40536adc0dcee8125239c071544b`。本地 `public-README.md`。
- **C**：[公开 CHANGELOG](https://github.com/stringer07/Lattice_release/blob/001dcbbc97ff40536adc0dcee8125239c071544b/CHANGELOG.md)，内容止 v2.1.6。本地 `public-CHANGELOG.md`。
- **A**：[App Store 官方版本记录](https://apps.apple.com/us/app/lattice-reference-manager/id6761349832?mt=12)，最新 3.0，2026-09-28；与本机 Info.plist 的 3.0 (26) 一致。
- **H**：本机 `/Applications/Lattice.app/Contents/Resources/zh-Hans.lproj/Help.strings`，通过 plutil 只读解析其英文帮助键与中文翻译。
- **L**：同目录 `Localizable.strings`，614 个本地化条目。只有文案线索，不证明流程执行成功。
- **B**：本机 Safari 扩展的 Info.plist、manifest.json、`_locales/en/messages.json`，只读审查元数据和用户可见提示，未读取/复制扩展实现代码。
- **K**：本机 `Contents/Resources/lattice-cli/SKILL.md` 及三个 sidecar，作为产品附带接口文档阅读，未执行其中配置/写入操作。
- **E**：[官方扩展仓库](https://github.com/stringer07/Lattice_extension/tree/ef97ab8fd4b9bb966204ff05f92debd195254398)，本次实时 HEAD `ef97ab8fd4b9bb966204ff05f92debd195254398`；公共 API、Word、Raycast 文档已保存到本目录 `extensions-*`。

R/C 比本机新版本滞后。E 的 API 文档也滞后：称 detail 不返回 abstract/collections/tags/pdfPath，而本机 3.0 H/K 明确支持 opt-in。不能以旧文档删去 3.0 功能。

## 功能矩阵

| 域 | 必须核对的行为 | 版本/证据 |
|---|---|---|
| 主窗口 | 三栏：分类、文献表、元数据/批注详情；可折叠检查器 | R/H |
| 表格 | 标题、作者、年份、评分、来源、备注、添加日期；列显隐/宽度、排序、批量选择 | R/C 2.1.6 |
| 搜索 | 标题/作者/来源/年份/citekey；Cmd+F 聚焦并搜索全库；排序状态保存 | R/A 2.0.1、2.3.0/K |
| 键盘 | Return 打开 PDF、Space Quick Look、Delete 删除、Cmd+I 导入、Cmd+E 导出 | R/H |
| 系统筛选 | 全部、未归类、缺 DOI/ISBN 标识符、缺 PDF；及时计数 | R/H |
| 文集 | 创建/改名/删除、多归属、最多三层、拖动更换父级和同层顺序 | R/C/H |
| 子文集 | 父级默认含后代，右键可切换是否包含 | C/H |
| 标签 | 创建/改名/删除、颜色含自定义 hex、顺序拖动、多标签 | R/H |
| 批处理 | 文献拖入文集/标签；批量分配、刷新元数据、导出 | R/H |
| 分类继承 | 在选中文集/标签时导入或创建即归入；替换重复记录也增加当前分类 | C/H |
| 本地导入 | 单/多 PDF、递归文件夹、Finder 拖放；进度和取消 | R/C/H |
| 数据导入 | 多 BibTeX、RIS、DOI、手工录入、Zotero | R/C/H |
| 重复控制 | Skip/Replace/批量 apply-all；浏览器另可打开已有条目 | R/H |
| 元数据 | PDF 本地标题/作者/DOI/ISBN/arXiv；在线多源补全；失败保留可编辑记录 | R/H/A |
| 数据模型 | 可编辑类型；article/book/inbook/incollection/inproceedings/proceedings/thesis/report/online/dataset/software/patent/manuscript/preprint/misc | A 2.3.0/K |
| 扩展字段 | 类型相关动态字段、volume/issue/pages/publisher/ISBN/ISSN 等，不能只保留最小文章字段 | A 2.3.0/H/K |
| 作者 | 分号分隔人员，保留姓逗号名；CSL family/given/literal | C/E |
| 状态 | 备注、1–5 星、重复点击清空评分 | R/H |
| PDF 链接 | 原位链接/安全书签、选择阅读器、外部打开、Finder 显示、替换/新附加 | R/H |
| 附件 | 主 PDF 与任意附加文件区分；可添加代码/数据/Markdown 等非 PDF 文件 | A 2.4.0/3.0/L |
| PDF 预览 | 原生 Quick Look；开关/打开时刷新批注；缺文件有明确提示 | R/C/H |
| 批注 | Highlight/Underline/StrikeOut/Text/FreeText/Square/Circle；全文替换刷新 | R/H |
| 批注数据 | 页号、页标签、位置、选中文字、评论、颜色；方形/圆形区域 PNG | R/H |
| OCR | 本次未找到 Lattice 文档或资源能证明 OCR；PaperShelf 可额外实现系统 Vision，不能称已确认的 Lattice 功能 | 未证实 |
| 元数据模板 | 变量替换和非空条件块，独立保存/还原；标题/作者/摘要/标识符/备注/评分/分类/标签/批注 | R/H |
| 批注模板 | type/page/text/comment/color/image，逐批注渲染 | R/H |
| 模板链接 | collectionPaths 层级路径、latticeURL 深链、pdfURL；模板刷新入口 | A 2.0.1/H |
| 详细导出 | 无图 .md，有图 .textbundle；每篇独立文件，citekey 优先、标题回退、防文件名冲突 | R/H |
| 引文键 | auth/Auth/year/shortyear/title/title-N 模式、实时预览、a/b/c 冲突后缀、元数据变化重算 | R/H |
| 引文交换 | BibTeX/RIS 文件与剪贴板；选中/当前筛选/全库三种范围；字段导出控制 | R/C/H/L |
| BibTeX 解析 | 常用条目、@string 宏、# 拼接、花括号/引号/裸值/圆括号；忽略 comment/preamble | H |
| 文件库 | 用户授权单一目录供本地整理/浏览器/Zotero/恢复；配置变化只影响以后，现有文件可明确批量应用 | A 2.6/H |
| 文件操作 | 原位/拷贝/移动；重命名规则与组织规则独立；复制保留源 | C/H |
| 整理规则 | 无分组/年份/文集完整路径/首作者姓首字母；无值入 Unsorted；重名自动编号 | C/H |
| 文件布局 | 每篇单独目录保存 PDF 与附件；或 PDF 与 Attachments 分区，均按组织规则分组 | A 3.0/L |
| 文件回滚 | 文献并发变化/位置保存失败时回滚已完成文件操作；取消进度 | L/H |
| 删除附件 | 可选连带将主 PDF/附件移入废纸篓；默认单独明确行为 | C/H |
| Zotero | 迁移元数据、层级文集、PDF；只复制源文件，永不移动/删；外部链接 PDF 需文件夹授权；可仅迁移元数据 | C/H/L |
| 备份 | 数据/批注/分类/模板；可包含主 PDF 与附件；有 manifest、版本/关系/完整性校验 | C/H/L |
| 恢复 | 完全替换库数据；包含文件时指定/授权恢复目录；不含文件则原路径重新连接 | H/L |
| Shortcuts | 选一或多篇、搜索选择、可包含批注，按模板返回文本/复制剪贴板；Siri/Spotlight 入口 | R/C/H |
| 本地 HTTP | 可启用/关闭、端口设置、只读模式、Trusted Folders、JSON、能力协商 | E/H/K |
| 公共 API | status/search/detail/metadata/collections/tags；创建和 PDF bytes 上传；CSL-JSON | E/K |
| 深链 | lattice://paper/{UUID} 聚焦文献，注册 lattice scheme | E/REA plist |
| 浏览器 | 内置 Safari Reference Saver、当前页元数据/PDF、预览、分类/标签、重复处理、元数据-only 回退 | B/H/A 2.2–3.0 |
| 浏览器连接 | 启用 Local API 即可；端口变化自动重新连接；Safari 设置启用扩展 | H/B |
| CLI | status、search、get-paper、get-paper-by-reference、get-csl-item、lookup-metadata、collections、tags；create-paper/add-by-identifier/attach-pdf | K/A 3.0 |
| AI 接口 | portable Skill 导出、MCP；与 Local API 只读策略一致 | K/L/A 3.0 |
| 第三方接口 | Word 插件：搜索、内文引用、文末书目、IEEE/APA/自定义 CSL、文档内保存状态；Raycast：搜索/引用格式/当前网页识别/连接检查 | E；外部插件 |
| 设置/帮助 | 中英语言、明暗外观、默认阅读器、导览、快捷键帮助 | C/H/L |
| 商业策略 | Lattice 免费50篇、首次Zotero导入豁免、Pro购买；不是 PaperShelf 复制目标的必要功能 | A/L |

## 浏览器安装与协议

已证实的官方浏览器分发是主应用内置 **Safari Web Extension**：`com.aurelian.Lattice.SafariExtension`、3.0 (26)，扩展点 `com.apple.Safari.web-extension`。在 Safari → Settings → Extensions 启用 **Lattice Reference Saver**；Lattice 的 Integrations → Local API 需启用。当前未找到可验证的官方 Chrome/Edge 商店入口，搜索命中的同名“Lattice”AI 对话扩展是其他产品，不能引用。

MV3 manifest 权限为 `activeTab`, `storage`, `scripting`；固定 host `http://127.0.0.1/*`，可选 host `<all_urls>`。这些声明不证明扩展实际读取了所有站点。

公开 Local API 在 `http://127.0.0.1:29467/api/v1`，默认端口可配置：GET `/status`, `/search`, `/papers/{uuid}`, `/metadata`, `/collections`, `/tags`；POST `/papers`；PUT `/papers/{uuid}/pdf`；OPTIONS。PDF上传要求 `application/pdf`、真实 `%PDF-` 开头、200000000 bytes 上限及 `pdf-upload` 能力；默认重复 skip，已有PDF替换需 force。公开插件静态托管位于 `/plugins/{name}/...`。

E 明确排除浏览器内部路由文档，因此这里不编造其私有握手。PaperShelf 应独立设计受限回环连接协议。3.0 帮助确认的用户流程：首次文件库选择、仅元数据、文件库失效提示、重复跳过/替换/打开原条目、PDF下载或上传失败仍报告元数据保存状态。跨域阻止、超时、HTTP失败、非PDF、超限均有单独结果。

3.0 K 读接口 opt-in 为 `get-paper --include abstract|pdf_path|collections|tags|library`，HTTP 帮助示例为 `?include=library,pdfPath,abstract`。公共旧文档与新包不同，应按实际实现能力响应设计自己的兼容层。

## REA 实际只读检查

复用已有干净 REA 6.5.0，提交 `3fcba07962a1f9f23130a5210dba242f6a331a5b`，Node 24.19.0。已观测新上游 HEAD `2c4338db1fdb7773e05376301c558cff2a0b4b80`，本次没有把旧构建冒称最新版。

`inspect-plist`, `inspect-macho`, `inspect-signature`, `inspect-artifact` 均实际退出 0、stderr 为空。命令、Evidence IDs、输出哈希与目标前后哈希见 `rea-lattice-receipt.json`。目标主程序、Info.plist、Help.strings、浏览器 manifest 哈希前后一致。

静态事实：App Store 签名、bundle `com.aurelian.Lattice`、arm64/x86_64 universal、minimum macOS14、SDK27；sandbox、app-scope bookmarks、user-selected read-write、network client/server。包内有 Lattice、LatticeCLI、LatticePicker、Safari appex、AppIntents 元数据。没有反编译、复制私有源码/图形资产或接触 Lattice 用户数据。根代理独占 GUI 调查。

## 复用边界

Lattice_release 未提供可复用本体源码许可。扩展仓库是 PolyForm Shield 1.0.0 并声明同类竞品使用限制。此任务采用行为/公开协议作为需求，独立实现 PaperShelf；不纳入其代码、图标或图形资源。这里只把 API/CLI 文档当外部规格证据。

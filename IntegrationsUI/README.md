# 引用工具与启动器

- [Word](Word/README.md)：文内引文、参考文献表、APA/IEEE/自定义 CSL、保存文档状态与更新引用。附带自包含 Node 运行包；需要受 Word 信任的 localhost 证书。
- [Raycast](Raycast/README.md)：搜索、打开、复制 BibTeX/RIS/Markdown/普通引文、连接检查，以及主动采集 Safari/Chrome/Edge 当前标签页。
- [安装 ZIP](dist)：可分发源码与已构建运行文件，未包含密钥、证书或 node_modules。

主应用设置中启用本机 API 后使用，只读模式即可搜索与引用。浏览器扩展通过独立深链工作，见 [浏览器扩展](../BrowserExtension/README.md)。

这些是原创适配器，没有复用 Lattice 代码。测试结果和真实宿主验收边界分别见 [Word 验证](Word/VERIFICATION.md) 与 [Raycast 验证](Raycast/VERIFICATION.md)。

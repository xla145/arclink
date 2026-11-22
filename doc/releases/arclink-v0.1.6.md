## 本次更新

- **统一项目与对话**：桌面客户端新增托管工作区，集中查看项目、对话和执行状态，手机与 Mac 使用同一套托管记录同步。
- **支持 Codex 与 Claude CLI**：托管对话支持选择 Agent 和对应模型，在同一对话空闲时切换 Agent，并保留公开对话上下文。此功能需要配套新版 iOS 客户端。
- **从手机创建项目**：支持在选定 Mac 上浏览、新建项目文件夹，再创建对应的托管对话；已有对话继续归属原设备。
- **改进执行与同步**：增加托管执行记录、增量同步和 Git 工作区支持；项目目录不存在时给出路径提示。

本次发布为 macOS 安装包，iOS 客户端需单独构建安装。历史导入对话保持只读；iOS 后台持续连接及通知推送不在本次发布范围。

## 客户端下载

- [Apple 芯片 Mac（arm64）](https://github.com/xla145/arclink/releases/download/arclink-v0.1.6/ArcLink-macos-arm64.dmg)
- [Intel Mac（x64）](https://github.com/xla145/arclink/releases/download/arclink-v0.1.6/ArcLink-macos-x64.dmg)

已有客户端可在「设置 → 应用」中检查更新。也可下载对应架构的 DMG 安装包。

[完整更新记录](https://github.com/xla145/arclink/compare/arclink-v0.1.5...arclink-v0.1.6)

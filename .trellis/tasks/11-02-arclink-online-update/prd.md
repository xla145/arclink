# ArcLink 客户端在线更新

## 目标
用户可在 macOS ArcLink 客户端中发现新版本、下载可信更新并完成安装，无需手工到网页重新下载安装包。

## 已确认事实与约束
- 用户要求继续实现在线更新，明确不使用 Apple 开发者签名或公证，并已同意创建任务。
- 当前桌面客户端采用 Tauri 2；支持 macOS Apple Silicon、Intel，最低 macOS 13。
- `.github/workflows/arclink-release.yml` 已配置两种 DMG 的构建与 GitHub Releases 发布，尚未实际运行云端验证。
- `agent-bridge/desktop/src-tauri/tauri.conf.json` 与 Cargo/package.json 当前版本均为 0.1.0；目前无 updater 配置。
- 更新包来源验证使用独立更新密钥，不依赖 Apple 证书。私钥不得进入仓库、前端或日志。
- `agent-bridge/desktop/src-tauri/src/commands.rs:193` 的 request_exit 调用 runtime::request_shutdown。
- `agent-bridge/crates/agentd/src/lib.rs:758` 的 shutdown 阻止新操作、取消配对并停止进程；更新重启必须遵守该生命周期，避免绕过清理。

## 需求
1. 提供版本检查、版本说明和更新状态，并清晰呈现网络失败及可重试状态。
2. 下载适配当前 CPU 架构的更新包，验证签名通过后才允许安装。
3. 更新发布与现有安装包使用同一版本，并在两个架构产物齐备后发布；保留网页下载地址。
4. 更新保留应用标识、配对关系、用户设置与现有数据。
5. 发布文档说明更新密钥生成、GitHub Secrets、公钥配置和首次启用步骤。

## 验收标准
- 高版本可发现；当前/旧版本不触发升级；失败不伪装为最新版本。
- 下载失败、签名错误不覆盖应用；重复点击不启动并行安装。
- 更新清单包含两个架构的版本化下载地址和签名。
- 重启前完成受控的服务清理；活动任务的处理符合用户确认的策略。
- 前端测试、生产构建、Rust 检查及清单验证通过；明确区分本地验证与尚待真实两版本升级验证。

## 不包含
Apple 开发者签名/公证、iOS 更新、Windows/Linux 支持、强制升级、灰度渠道或独立更新服务器。

## 已确认的更新策略
启动时后台检查并允许手动检查，用户确认后下载、安装并重启；活动 Agent 任务存在时明确提示中断影响并二次确认。用户在此方案后明确指示“开始吧”，授权进入实现。

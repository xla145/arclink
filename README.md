# ArcLink 弧连

ArcLink 连接手机与 Mac 上的本地 AI Agent。桌面客户端提供设备配对、Agent 发现与运行、会话转发；iOS 客户端用于连接和操作已配对的主机。

- 官网：https://arclink.classktv.com
- 源码：https://github.com/xla145/arclink
- [安装包与版本记录](https://github.com/xla145/arclink/releases)
- [自动构建、发布与在线更新说明](agent-bridge/desktop/RELEASING.md)

macOS 客户端支持 Apple Silicon 与 Intel，最低 macOS 13。首个 GitHub Release 发布后可通过官网或 Releases 下载；客户端支持启动检查更新和手动下载安装。当前不使用 Apple 开发者签名或公证。

## 目录

| 路径                    | 内容                                                 |
| ----------------------- | ---------------------------------------------------- |
| `agent-bridge/`         | 桌面宿主和 iOS 工程，说明见 `agent-bridge/README.md` |
| `agent-bridge/desktop/` | Tauri 2 + React 面板                                 |
| `agent-bridge/ios/`     | SwiftUI 客户端，说明见 `agent-bridge/ios/README.md`  |
| `agent-bridge/crates/`  | ABP 协议、Agent 适配、daemon 和测试                  |
| `doc/`                  | 方案和客户端设计文档                                 |

## 桌面端

```sh
cd agent-bridge/desktop
corepack pnpm install --frozen-lockfile
corepack pnpm tauri dev
```

## iOS

用 Xcode 打开 `agent-bridge/ios/AgentBridge.xcodeproj`，选择 iPhone 模拟器运行。模拟器编译可以不签名：

```sh
cd agent-bridge/ios
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

本地构建产物在 `agent-bridge/ios/work/`，已被 Git 忽略。配对时由 Mac 显示二维码，手机扫描。

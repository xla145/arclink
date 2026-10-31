# mac-dev

Agent Bridge 的工作仓库。桌面端负责发现本机 Agent、授权设备和转发进程输入输出。iOS 端目前是 SwiftUI 壳，会话和审批只记在手机本机，还没有连上桌面 daemon。

## 目录

| 路径 | 内容 |
| --- | --- |
| `agent-bridge/` | 桌面宿主和 iOS 工程，说明见 `agent-bridge/README.md` |
| `agent-bridge/desktop/` | Tauri 2 + React 面板 |
| `agent-bridge/ios/` | SwiftUI 客户端，说明见 `agent-bridge/ios/README.md` |
| `agent-bridge/crates/` | ABP 协议、Agent 适配、daemon 和测试 |
| `doc/` | 方案和客户端设计文档 |

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

本地构建产物在 `agent-bridge/ios/work/`，已被 Git 忽略。

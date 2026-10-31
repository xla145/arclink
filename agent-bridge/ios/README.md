# Agent Bridge iOS

iPhone 上的 SwiftUI 客户端壳。当前版本在本机记录项目、会话、消息和审批，不连接桌面 daemon，也不会通过 iroh 启动 Claude Code 或 Codex。

## 打开

用 Xcode 打开 `AgentBridge.xcodeproj`，选 iPhone 模拟器后运行。

命令行编译（不签名，只适合模拟器）：

```sh
cd agent-bridge/ios
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 现在能做什么

- 按 Agent 查看和搜索项目，添加、修改、删除项目。
- 在项目里新建会话，发送文字和相册图片。
- 发送任务后生成一条待审批；批准或拒绝会写回会话状态。
- 终端页显示这个会话自己的记录，不是写死的示例输出。
- 设置里可以改权限、通知、外观和会话保留天数。权限会限制能否发送和审批。
- 未配对页和「我的 Mac」在当前页面显示二维码。确认配对只写入本机状态。

这些数据保存在 App 的 Application Support 目录 `AgentBridge/state.json`。关掉再打开还在。`ios/work/` 是本地构建和截图目录，已在仓库 `.gitignore` 里忽略。

## 还没有的

- 没有连接 Mac 上的 `agentd`。
- 批准不会修改桌面文件，也不会执行命令。
- 真机安装需要在 Xcode 里登录 Apple 开发账号。本仓库的模拟器构建默认不签名。

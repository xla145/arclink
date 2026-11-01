# 执行计划：真实终端输出

## 顺序检查清单

1. `AgentKind.agentId` 映射（`AppModel.swift`）。
2. `SessionItem` 新增 `realProcessId`/`realGeneration`（含自定义 `init(from:)` 的
   `decodeIfPresent`），`Snapshot`/`persist`/`load` 不用改（`SessionItem` 自己是
   `Codable` 数组元素，不需要在 `Snapshot` 里单独列字段）。
3. 新建 `TerminalSession`（`@MainActor @Observable`）+ 私有 `TerminalCallback`
   （`AgentIoCallback` 实现），按 design.md 的签名。
4. 共享的中文错误映射：把 `AppStore.localizedPairError` 提出来给 `TerminalSession` 也能用
   （保持一张表，不复制）。
5. `TerminalView` 改动：
   - 判断真实通路可用性（`connectionState == .connected` && Agent `verified`）。
   - 有 `realProcessId` 就 `.onAppear` 调 `attach`；没有就展示"启动"按钮，点击调用
     `start`（`operation_id = session.id`），成功后把 `processId`/`generation` 写回
     `store.sessions[...]` 并 `persist()`。
   - "停止"按钮调用 `stop`，`.onDisappear` 调 `detach()`。
   - 真实输出和 mock `lines` 分开渲染区域，不混在一起拼接。
6. 模拟器 + 真机 Debug 构建都跑一次。
7. 手动验证 PRD 的 6 条 Acceptance Criteria，记录哪些在真机上实测过、哪些降级验证。
8. 更新 `agent-bridge/ios/README.md`（"还没有的"那一节去掉"没有把 StartProcess/StopProcess/
   AgentIO 接到任何会话或终端 UI 上"这条，换成新的边界说明：裸字节能看，但没有语义解析）。

## 回滚点

- 第 2-5 步出问题：撤掉 `TerminalSession`/`TerminalView` 新增代码和 `SessionItem` 新
  字段引用，`decodeIfPresent` 保证旧 `state.json` 不受影响。

## 验证命令

```sh
cd agent-bridge/ios
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

真机构建按 `.trellis/spec/frontend/agent-bridge-ios.md`"真机签名"一节的做法（打开签名
+ `DEVELOPMENT_TEAM` + 显式链接 `SystemConfiguration.framework`）。

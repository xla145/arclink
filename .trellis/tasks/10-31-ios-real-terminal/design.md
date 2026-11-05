# 设计：真实终端输出

## 边界

- 只改 `agent-bridge/ios/AgentBridge/`。不碰 `agent-bridge/crates/`（Rust 层已经够用，
  `BridgeConnection.startProcess/stopProcess/getProcessStatus/attachIo` 和
  `AgentIoCallback`/`IoHandle` 都已经在 `10-31-ios-iroh-transport` 任务里实现并测试过）。

## 数据模型改动

`AppModel.swift` 的 `SessionItem` 新增两个可选字段：

```swift
struct SessionItem: Identifiable, Hashable, Codable {
    ...
    var realProcessId: String?
    var realGeneration: String?
}
```

跟 `Snapshot.macEndpointId` 用一样的套路：`Codable` 自动合成对 `Optional` 属性用
`decodeIfPresent`，旧 `state.json` 没有这两个字段时解码出 `nil`，不需要迁移、不会清空
已有数据。`SessionItem` 已经有自定义 `init(from:)`（见 `createdAt` 的兼容写法），新字段
也要走同一个自定义 decoder 的 `decodeIfPresent`，不能只加 `CodingKeys` 不改 `init(from:)`。

## Agent 类型 → `agent_id` 映射

```swift
extension AgentKind {
    var agentId: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .herdr: "herdr"
        }
    }
}
```

对照 `agent-adapters::discover_specs()` 里的三个 id 字符串，这是协议常量，不会变。

## 终端会话控制器

新增一个 `@MainActor @Observable` 的 `TerminalSession` 类（放 `AppModel.swift` 或新文件
`TerminalSession.swift`），每个 `TerminalView` 实例持有一个，生命周期跟视图绑定：

```swift
@MainActor
@Observable
final class TerminalSession {
    enum RunState { case idle, starting, running, stopping, stopped, failed(String) }
    var runState: RunState = .idle
    var liveLines: [String] = []     // 累积的 stdout/stderr 行，和 mock lines 分开存
    private var handle: IoHandle?
    private var callback: TerminalCallback?

    func start(bridge: BridgeConnection, session: SessionItem, cwd: String, agentId: String) async -> (processId: String, generation: String)?
    func attach(bridge: BridgeConnection, processId: String, generation: String) async
    func stop(bridge: BridgeConnection, processId: String, generation: String) async
    func detach()  // 调 handle?.close()，View .onDisappear 调
}

private final class TerminalCallback: AgentIoCallback {
    weak var owner: TerminalSession?
    func onStdout(data: [UInt8], cursor: UInt64, offset: UInt64) { /* 回到主线程 append */ }
    func onStderr(...) { ... }
    func onGap(...) { ... }          // 显示一行 "# 丢失了一段输出"
    func onExit(exitCode: Int32?) { ... }  // runState = .stopped
    func onError(code: String, message: String) { ... }
}
```

`AgentIoCallback` 的方法是同步、非 `@MainActor`（UniFFI 回调从 Rust 的后台任务线程直接调
Swift），回调实现内部必须 `Task { @MainActor in owner?.append(...) } }`，不能直接碰
`@Observable` 状态——这是和 `BridgeConnection`/`IoHandle` 本身（`async` 方法，天然在
调用处的 actor 上下文里跑）不同的地方，容易漏。

`start`/`stop` 的错误（`BridgeError`）复用 `AppStore.localizedPairError(code:message:)`
的做法：翻成中文，不直接展示 `message`（可以把那个函数从 `private` 提升成
`fileprivate`/搬到一个共享的小文件，两处都用同一张映射表，不要复制一份）。

## `operation_id` 策略

- 启动：`operation_id = session.id`（`SessionItem.id` 本身已经是 `UUID().uuidString`，
  稳定不变）。命中 `agentd::start_process` 的 `existing_operation` 去重分支时，Mac 返回
  的是已有进程信息（可能是运行中，也可能已经退出/lost）——`TerminalSession.start` 要能
  处理"返回的进程已经不是 running"这种情况，直接按 `GetProcessStatus` 的结果显示，不要
  硬编码假设第一次启动的进程还活着。
- 停止：新生成一个 `UUID().uuidString`，不需要跨多次停止请求保持稳定。

## TerminalView 改动

- `@Environment(AppStore.self)` 之外新增 `@State private var terminal = TerminalSession()`。
- 展示逻辑：如果 `session.realProcessId` 有值，优先走真实订阅（`.onAppear` 里
  `attach`，没有真实进程信息就展示"启动"按钮；`.onDisappear` 里 `detach()`）；否则维持
  现在这套从 `store.messages`/`store.approvals` 拼出来的 mock 回放（`lines` 计算属性保持
  不变，只是外面包一层条件判断）。
- 启动按钮只在 `store.connectionState == .connected` 且项目 Agent 在 `store.macAgents`
  里 `validation == "verified"` 时出现；否则按钮不显示（沿用现有 mock 终端页，不额外
  报错阻断——这是 PRD Constraints 里"未连接/未验证继续走 mock"的要求）。

## 测试策略

- 这次改动都在 Swift 侧，没有 Rust 新代码，不需要新增 `cargo test`。
- 验证方式是真机/模拟器手动走一遍 PRD 的 Acceptance Criteria；如果真机当时不可用，
  至少要在模拟器 + 本机 `agent-bridge-desktop`（`cargo tauri dev`）或
  `abp-test-harness` 对端上走通一次"启动一个真实命令 → 看到输出 → 停止"。

## 回滚点

- `SessionItem` 新字段是纯新增可选字段，`decodeIfPresent` 保证旧数据兼容；回滚只需要
  撤掉 `TerminalSession`/`TerminalView` 里新增的调用点，不影响已有 mock 流程。

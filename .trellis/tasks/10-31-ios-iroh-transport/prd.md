# iOS iroh 传输层：持久连接、Control RPC、AgentIO 流

## Goal

`agent-bridge/crates/agent-bridge-client`（iOS 的 Rust/UniFFI 核心）目前只实现了一次性的
`pair_over_iroh`：配对成功后连接就被丢弃，之后聊天、审批、创建会话全部是 `AppModel.swift`
里的本地 mock（代码里写明"桌面 Agent 还没接上"）。但 Mac 侧 `agentd::network` 早已实现了完整的
`STREAM_CONTROL`（Ping / GetSystemInfo / ListAgents / ListProcesses / StartProcess /
StopProcess / GetProcessStatus）和 `STREAM_AGENT_IO`（stdin/stdout/stderr/exit，带缺口检测与
游标），并有 `abp-test-harness` 验证过服务端行为。

本任务把 iOS 的 iroh 使用范围从"只配对"扩展到"配对后维持一条可复用、可重连的连接，能发
Control RPC、能收发 AgentIO 原始字节流"，让 Rust/UniFFI 层具备真正驱动一个 Mac 进程的能力。

## Non-goals（明确排除，留给后续任务）

- 不解析 Claude Code / Codex 自己的 stdout 协议（不做 `doc/agent-bridge-ios-client.md` 里
  §05 的 `agent/claude_code.rs`、`agent/codex.rs` 语义事件解析）。
- 不做本地 SQLite 持久化（§06 的会话/审批/事件/去重表）。
- 不做图片附件上传/下载（§08）。
- 不实现 `respond_approval` 之类审批 RPC——Mac 侧 `agentd::network::rpc` 目前没有这个方法，
  审批语义属于上层协议，不在这次传输层范围内。
- 不改变现有 SwiftUI 导航结构、审批/会话 mock 数据模型（`ApprovalItem`/`SessionItem` 等）；
  只新增一小块"真实设备信息 + 真实进程终端输出"的验证面，证明传输层打通，不要求替换现有
  全部 mock 交互。

## Requirements

### R1 持久连接（取代一次性 Endpoint）

- 新增一个可在 Swift 侧长期持有的连接对象/状态（UniFFI `Object`），绑定一次 iroh
  `Endpoint`（复用现有 `irohKeyPath` 密钥文件，保证节点身份与配对时一致，才能通过
  `agentd` 的 `authorize` 校验），对 Mac 的 `endpoint_id` 发起 `connect`。
- 配对成功后持久化 Mac 的 `endpoint_id`（目前 `AppModel.finishPair` 没有存，每次都要重新
  扫码才知道连哪）。连接对象可以在没有重新扫码的情况下，用持久化的 `endpoint_id` 重连。
- 连接断开（App 进后台太久、Mac 睡眠、网络切换）后，提供显式的 `reconnect`/状态查询接口，
  不在 Rust 内部做无限重试；重试节奏由 Swift 侧结合 `ScenePhase` 决定何时调用。
- 暴露连接状态（connecting / connected / disconnected / failed，附错误码/消息）给 Swift，
  替换 `AppStore.online` 当前的"配对成功就等于一直在线"的假设。

### R2 Control RPC 客户端

- 在持久连接上按需开 `STREAM_CONTROL`，支持调用 Mac 已实现的方法：`Ping`、
  `GetSystemInfo`、`ListAgents`、`ListProcesses`、`StartProcess`、`StopProcess`、
  `GetProcessStatus`。
- 每次 RPC 走独立的双向流（与 `abp-test-harness::Peer::rpc` 一致的开流→Hello→Open→
  Request→Response 模式），而不是在一条流上背靠背复用，避免一次超时拖死后续调用。
- RPC 结果以 UniFFI `Record`/`Enum` 返回给 Swift（结构化，不是裸 JSON 字符串），错误区分
  网络错误 / 协议错误 / Mac 侧业务错误（`error_code`/`error_message`）。
- 超时、未授权（配对被 Mac 撤销）、协议不兼容等失败路径都要有确定性的错误返回，不能挂住
  调用方。

### R3 AgentIO 原始流

- 支持对一个已知 `process_id`/`generation` 开 `STREAM_AGENT_IO`：
  - 发送侧：Swift 传入字节 → Rust 按 `CHANNEL_STDIN`、`MAX_IO_BYTES` 分片写入。
  - 接收侧：Rust 收到 stdout/stderr/gap/exit frame 后，通过 UniFFI 回调接口
    （`callback_interface`，仿照 doc 里的 `EventCallback`）推给 Swift，携带 channel、
    cursor、offset、lost_bytes、exit_code 等字段，不做语义折叠。
- 流的生命周期与 Swift 侧的订阅绑定：Swift 取消订阅时，Rust 侧要能干净地结束读写任务，
  不留后台任务常驻。
- 对 Mac 侧返回的 gap/exit frame 要能让 Swift 分辨"正常结束"和"丢数据"，不能静默吞掉。

### R4 Swift 侧最小打通验证

- 设置页「我的 Mac」或首页展示来自真实 `Ping`/`GetSystemInfo`/`ListAgents` 的在线状态和
  Agent 列表，替换当前纯本地的 `online`/`hostName` 字段来源（配对成功后主动查一次）。
- 提供一个可操作的最小通路：调用 `StartProcess` 启动一个真实的 Mac 进程（如
  `ListAgents` 里返回的某个已安装 Agent，或退化为一个允许的简单命令），把 AgentIO 的
  stdout/stderr 原始字节实时显示在现有终端页（`Route.terminal`），`StopProcess` 能停止它。
  这一步只是证明链路可用，不要求产出结构化聊天气泡。
- App 进后台再回前台时，连接状态字段能反映真实情况（不是停留在 pairing 时的快照）。

### R5 构建与依赖

- `scripts/ios-build-client.sh`、`third_party/netdev`/`third_party/netwatch`（iOS 平台的
  iroh 传输依赖补丁）、`ios/Frameworks/AgentBridgeClient.xcframework` 当前均为未提交的
  工作区变更；本任务要确认它们在新增代码后仍能完整走通构建脚本生成新的 xcframework 和
  Swift 绑定，并给出一次干净的构建记录（日志路径），不要求现在提交 git（提交交给
  3.4 完成阶段按用户指示处理）。

## Constraints

- 只改 `agent-bridge/crates/agent-bridge-client/`、`agent-bridge/ios/`、
  `agent-bridge/scripts/ios-build-client.sh` 及其直接依赖；不改 `agentd` 的协议/RPC 实现
  （Mac 侧已完成且属于另一任务 `10-30-agent-bridge-mac-client` 的范围），如确有协议缺口
  （例如新增 RPC 方法），先在设计阶段记录缺口，不擅自改 `agentd`。
- 不引入 SQLite 或其他新的第三方持久化依赖。
- 保持手机侧密钥文件方案（`Application Support/AgentBridge/iroh-key`）不变。
- 模拟器 Debug 构建继续关闭签名；真机验证如不可行需明确说明并降级为模拟器 + 真实局域网/
  公网 Mac daemon 的验证。

## Acceptance Criteria

- [ ] `cargo test -p agent-bridge-client` 通过，新增的连接/RPC/IO 代码有单元测试覆盖
      （至少：帧编解码边界、分片逻辑、断线后的错误分类）。
- [ ] `agent-bridge/scripts/ios-build-client.sh` 能重新生成 xcframework + Swift 绑定，
      iOS 模拟器 Debug 构建成功（`xcodebuild ... CODE_SIGNING_ALLOWED=NO`）。
- [ ] 真实跑一次 Mac `agentd` + iOS 模拟器：扫码配对后，首页/设置能展示来自
      `Ping`/`ListAgents` 的真实在线状态与 Agent 列表（不是本地写死的 `hostName`/`online`）。
- [ ] 能对一个真实 Mac 进程发起 `StartProcess`，终端页实时显示该进程的 stdout（及 stderr），
      `StopProcess` 能让它停止，且状态变化能在 UI 上看到。
- [ ] 杀掉/重启 Mac 端 `agentd` 或断开网络再恢复，iOS 连接状态字段能如实反映
      connecting/disconnected/failed，再手动触发一次重连能恢复，而不是停在旧状态。
- [ ] App 进后台超过一段时间再回前台，不崩溃，能重新建立连接或明确提示未连接。

## Notes

- 目标终态参考 `doc/agent-bridge-ios-client.md`（尤其 §05 `agent-bridge-client` 模块划分、
  §07 连接生命周期/断线处理表），但本任务只做其中「连接 + Control RPC + AgentIO 透传」部分，
  其余（会话/审批状态机、SQLite、Agent 专属协议解析、图片）留给后续子任务。
- Mac 侧已实现的协议参考：`agent-bridge/crates/agentd/src/network.rs`（服务端）、
  `agent-bridge/crates/abp-test-harness/src/lib.rs`（`Peer`/`Stream`，是本任务 Rust 客户端
  实现的最佳参照模板）、`agent-bridge/crates/abp-protocol/src/lib.rs`（帧与常量定义）。
- 现有已完成的配对代码：`agent-bridge/crates/agent-bridge-client/src/lib.rs`
  （`pair_over_iroh`）、`agent-bridge/ios/AgentBridge/AppModel.swift:314-358`（`pair`）。

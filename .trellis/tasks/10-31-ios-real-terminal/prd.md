# 接通真实 Codex/Claude Code 进程到终端页

## Goal

首页"项目"一直是手动添加的本地记录（文件夹路径 + Agent 类型），跟 Mac 上装了什么、Codex
能不能跑完全无关。本任务让一个真实已配对、已连接的 Mac 上的会话能真正跑起来一个 Agent
进程：终端页显示来自 `STREAM_AGENT_IO` 的真实 stdout/stderr，而不是本地拼出来的消息记录
回放。**不**解析 Codex/Claude Code 自己的协议语义（没有结构化步骤/工具调用气泡），只做
"起停裸进程 + 看裸字节"这一层——`agent-bridge-client` 的 Rust/UniFFI 层（`startProcess`/
`stopProcess`/`attachIo`）已经实现并有 loopback 测试覆盖，这次只补 Swift 调用点。

## Requirements

### R1 Agent 类型到 Mac `agent_id` 的映射

- `AgentKind.claude`/`.codex`/`.herdr` 映射到 Mac `agentd` 认的 id 字符串
  `"claude"`/`"codex"`/`"herdr"`（对照 `agent-adapters::discover_specs()`）。

### R2 启动真实进程

- 终端页（或会话页）在已连接（`connectionState == .connected`）且该会话所属项目的
  Agent 在 `macAgents` 里状态为 `installed`/`running`/`available`（`validation == "verified"`
  才能真正启动，否则提示"这个版本还没验证过，不能启动"）时，提供一个"启动"按钮。
- `operation_id` 使用该会话的 `sessionId`（稳定、可重放）：重复点击或 App 重启后再点
  "启动"，命中 Mac 侧的操作去重，回填已存在进程的信息，而不是起第二个进程。
- `cwd` 用项目的 `path`；路径在 Mac 上不是已存在的绝对目录会被 `agentd` 拒
  （`invalid_params`），要把这个错误用中文显示出来，不能让按钮看起来"按了没反应"。
- 启动成功后持久化 `process_id`/`generation` 到这个 `SessionItem`（新增两个可选字段，
  `decodeIfPresent` 兼容旧 `state.json`），下次打开终端页可以直接 `attach_io` 重新接上，
  不需要重新启动。

### R3 实时终端输出

- 终端页用 `attachIo(processId:, generation:, callback:)` 订阅真实字节流，按
  `stdout`/`stderr`/`gap`/`exit`/`error` 分别展示（复用现有单色终端排版，stderr 可以用
  区分色）。字节原样展示（当前阶段允许非 UTF-8 片段用占位符替代，不要求完整终端转义处理）。
- 离开终端页（视图消失）要调用 `IoHandle.close()`，不留后台订阅。
- `exit` 收到后更新这个会话的真实状态（运行中 → 已完成/已停止），并停止继续渲染更多输出。

### R4 停止真实进程

- 终端页提供"停止"按钮，调用 `stopProcess`（`operation_id` 同样可以用一个新的
  `UUID().uuidString`，去重边界不要求跨这一次停止请求保持稳定）。
- 停止中/已停止的状态要在 UI 上能看出来，不能停了却还显示"运行中"。

## Constraints

- 不新增任何 Mac 侧 (`agentd`) 的协议/RPC；本任务只调用已有的
  `Ping`/`GetSystemInfo`/`ListAgents`/`ListProcesses`/`StartProcess`/`StopProcess`/
  `GetProcessStatus`/`STREAM_AGENT_IO`。
- 不解析 Agent 自己的输出语义（没有步骤/工具调用/审批结构化卡片）——这是单独一块更大的
  工作（`doc/agent-bridge-ios-client.md` §05 的 `agent/claude_code.rs`/`agent/codex.rs`），
  本任务只做裸字节透传。
- 不改变现有 mock 会话/审批/聊天流程；真实进程是在已有会话之上的"附加能力"，mock 发消息/
  审批继续按原样工作，互不冲突。
- 未配对、未连接、Agent 未验证这几种情况下，终端页继续展示现在这套本地 mock 回放内容，
  不强行报错或留空。

## Acceptance Criteria

- [ ] 真实配对、连接成功、Codex 已验证可用的前提下：在一个指向 Mac 上真实存在目录的
      项目里，终端页能启动一个真实进程，看到真实的 stdout（例如 `echo`/一个简单命令的
      输出，不要求跑通完整 Codex CLI 交互）。
- [ ] 同一个会话重复点"启动"（或杀掉 App 重开后再点）不会在 Mac 上起第二个进程
      （用 `ListProcesses`/手动检查 Mac 上的进程数核对）。
- [ ] 项目路径在 Mac 上不存在时，启动按钮点击后显示中文错误提示，不是静默无反应。
- [ ] 点"停止"后，Mac 上的真实进程退出；终端页状态更新为已停止，不再显示"运行中"。
- [ ] 离开终端页再回来，不会残留重复的后台订阅或内存增长（用 Xcode Memory Graph /
      反复进出几次观察）。
- [ ] `cargo fmt`/`clippy`/`test`（如果 Rust 侧需要新增任何小改动）和 iOS 模拟器 +
      真机 Debug 构建都通过。

## Notes

- 真机验证仍然依赖真实运行中的 Mac `agentd`；如果真机环境当时不可用，降级为模拟器 +
  本机 `agentd`/`abp-test-harness` 验证，并在报告里写清楚哪些场景没有真实验证过。
- 这是 `10-31-ios-iroh-transport` 任务里 `trellis-check` 标记为未完成的那个真实缺口
  （PRD 的 R4/AC：真实进程终端输出），在这里补完。


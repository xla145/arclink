# ArcLink 多 Agent 与多端实时协同改造

## Goal

将 ArcLink 从“设备持有的远程 Agent 进程控制”升级为“Mac Environment Server 持有项目、Thread、Run 和 Provider 会话状态，iOS 与桌面共同控制并实时同步”的架构。

## Confirmed facts

- `agentd` 当前以 `ProcessInfo`、AgentIO、generation 和 SQLite 操作回执为核心。
- ABP 已支持 iroh 传输、快照 revision、stdout/stderr cursor、offset resume 和设备权限。
- iOS 当前在 `CodexChatSession.swift` 直接驱动 Codex app-server 协议；桌面只展示设备、Agent 和进程管理页面。
- `agent_projects.rs` 读取第三方 Provider 的历史记录，是只读导入，不是统一 Thread 状态库。
- backend host spec 要求旧 Process RPC、owner 校验、1 MiB 帧上限和现有 AgentIO 兼容。

## Requirements

1. 增加 Project、Thread、ProviderSession、Run、Message、Approval 的服务端模型和 SQLite 迁移。
2. 将 ProcessManager 降为 ProviderSession 的运行时层，保留旧 Process RPC 兼容。
3. 将 Codex 握手、thread start/resume/fork、turn、审批和事件归一化迁入 agentd；iOS 只提交业务命令并订阅状态。
4. 增加 Thread/Project 订阅、snapshot、增量 replay 和游标恢复；支持手机与桌面同时连接。
5. 移除新 Thread 对创建设备的永久独占，保留原始终端输入 lease；按设备权限控制 Thread 操作。
6. 所有新写命令支持 command_id、请求指纹和 outcome_unknown；不得在不确定时自动重放用户输入。
7. 桌面增加 Thread 详情、运行状态、审批和中断入口；iOS 将消息状态改为服务端事件 reducer + 本地缓存。
8. 首期只实现 ArcLink 手机与 ArcLink 桌面共享 Codex Thread；Claude、worktree、handoff、merge_back 作为后续阶段，协议和模型预留能力字段。
9. 不改变 iroh/ABP 的现有帧语义；通过能力协商增加 Thread API。

## Out of scope

- 不同步第三方 Codex/Claude 桌面 GUI 的实时状态。
- 不在本期实现独立后台服务拆分、跨 Mac Peer Link 或云端中继改造。
- 不在本期实现多个活跃 Run 的自动排队。
- 不复制 Provider 私有推理、工具内部状态或凭证。
- 不在本期实现自动 Git 合并和冲突解决 UI。

## Acceptance criteria

- 手机创建 Thread 并发送 Codex 消息后，桌面可在同一 Thread 看到用户消息、流式响应、工具状态和最终状态。
- 手机断网期间 Mac 继续运行；手机恢复连接后通过 snapshot/replay 得到一致消息，不重复、不丢失已提交事件。
- 手机和桌面同时审批或停止同一 Run 时，只有一次生效，另一端收到明确的已处理结果。
- Mac agentd 重启后，已完成会话仍可读取；未完成会话进入可解释的 lost/recovering/outcome_unknown 状态，不能自动重复发送用户消息。
- 旧 Process RPC、配对、AgentIO 原始流和现有客户端测试保持兼容。
- 新增 Rust、协议和跨端集成测试覆盖命令幂等、订阅恢复、权限和 Provider 驱动故障场景。

## Risks and deferred decisions

- Provider 外部 I/O 与 SQLite 事务无法原子化；通过 provider 对账能力和 outcome_unknown 处理。
- 关闭桌面应用是否仍保持 Agent 执行暂不改变，首期保持当前内嵌 Daemon 生命周期。
- 首期 Thread 每个只允许一个活跃 Run；排队机制留待后续产品决策。

## Approved extension — Claude CLI (2026-11-21)

The user requested Claude CLI in the same managed architecture. Extend shared projects with Claude Threads selectable on desktop and iOS. Service-owned Claude stream-json sessions must support text turns, public streaming/tool output, explicit allow/deny approvals, interruption and persisted native session resume. Retain command fencing, ACL, durable replay and unknown-delivery semantics. No permission bypass, private thinking projection, imported-history takeover or automatic user-input retry. Test deterministic Claude fixtures and record installed-CLI handshake separately from model-backed smoke.

## Approved extension — same conversation Agent switching (2026-11-22)
The user now explicitly requests Codex/Claude switching inside one conversation, using t3code as reference. Preserve project/device/Thread identity and history; hand off public context to fresh provider-native sessions while idle. See agent-switch-design.md.

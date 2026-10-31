# 设计：iOS iroh 传输层

## 边界

- 改动范围：`agent-bridge/crates/agent-bridge-client/`（新代码）、
  `agent-bridge/ios/AgentBridge/`（新增少量调用点）、
  `agent-bridge/scripts/ios-build-client.sh`（如需要新增构建产物路径）。
- 不改 `agent-bridge/crates/agentd/`、`agent-bridge/crates/abp-protocol/`：现有
  `Frame`/`STREAM_*`/`RpcRequest`/`IoFrame` 已经覆盖本任务需要的全部字段，Mac 侧服务端逻辑
  （`network.rs`）已经实现并被 `abp-test-harness` 验证过。如设计过程中发现协议缺口（见
  “已知缺口”），记录但不在本任务内修改 `agentd`。
- 不改 `AppModel.swift` 现有的 mock 数据结构（`ProjectItem`/`SessionItem`/`ApprovalItem`）
  和既有流程（`send`/`resolve`/`createSession` 保持纯本地，直到有专门任务接语义协议）。
  新增内容只追加字段/方法，不删除已有行为。

## 现状复用

`agent-bridge/crates/abp-test-harness/src/lib.rs` 的 `Peer`/`Stream` 是本任务 Rust 实现的
参照模板——它已经验证过与 `agentd::network` 的 Hello/Open/Request-Response 和 IO 帧交互
是正确的。新代码在协议细节上向它对齐，但要加上 UniFFI 导出、回调推送和生命周期管理。

## 新增类型（`agent-bridge-client/src/lib.rs` 或拆分的子模块）

```rust
#[derive(uniffi::Enum, Clone)]
pub enum ConnectionState {
    Idle,
    Connecting,
    Connected,
    Disconnected,
    Failed { code: String, message: String },
}

#[derive(uniffi::Error, thiserror::Error, Debug)]
pub enum BridgeError {
    #[error("{message}")]
    Network { code: String, message: String },
}
// 所有新 RPC 方法返回 Result<T, BridgeError>（UniFFI 生成 Swift `throws`），
// 与旧的 PairOutcome 手动 ok/error 字段风格不同——这是一个有意的不一致：
// pair_over_iroh 保持原样（已验证，不碰），新代码用更地道的 UniFFI 错误模式。

#[derive(uniffi::Record)] pub struct AgentInfo { pub id: String, pub name: String, pub version: String, pub status: String }
#[derive(uniffi::Record)] pub struct ProcessInfo { pub process_id: String, pub generation: String, pub agent_id: String, pub status: String, pub exit_code: Option<i32> }
#[derive(uniffi::Record)] pub struct SystemInfo { pub host_name: String, pub os_version: String }

#[derive(uniffi::Object)]
pub struct BridgeConnection {
    endpoint: tokio::sync::Mutex<Option<Endpoint>>,
    connection: tokio::sync::Mutex<Option<Connection>>,
    key_path: String,
    endpoint_id: tokio::sync::Mutex<String>, // Mac's endpoint id, settable after pairing
    state: tokio::sync::Mutex<ConnectionState>,
}

#[uniffi::export(async_runtime = "tokio")]
impl BridgeConnection {
    #[uniffi::constructor]
    pub fn new(key_path: String, endpoint_id: String) -> Arc<Self>;

    pub async fn connect(&self) -> ConnectionState;   // binds Endpoint if needed, then connect()
    pub async fn reconnect(&self) -> ConnectionState; // drop old Connection, connect() again on same Endpoint
    pub async fn disconnect(&self);                   // close Connection + Endpoint, set Disconnected
    pub fn state(&self) -> ConnectionState;

    pub async fn ping(&self) -> Result<(), BridgeError>;
    pub async fn get_system_info(&self) -> Result<SystemInfo, BridgeError>;
    pub async fn list_agents(&self) -> Result<Vec<AgentInfo>, BridgeError>;
    pub async fn list_processes(&self) -> Result<Vec<ProcessInfo>, BridgeError>;
    pub async fn start_process(&self, operation_id: String, agent_id: String, cwd: String) -> Result<ProcessInfo, BridgeError>;
    pub async fn stop_process(&self, operation_id: String, process_id: String, generation: String) -> Result<ProcessInfo, BridgeError>;
    pub async fn get_process_status(&self, process_id: String, generation: String) -> Result<ProcessInfo, BridgeError>;

    pub async fn attach_io(
        &self,
        process_id: String,
        generation: String,
        callback: Box<dyn AgentIoCallback>,
    ) -> Result<Arc<IoHandle>, BridgeError>;
}

#[uniffi::export(callback_interface)]
pub trait AgentIoCallback: Send + Sync {
    fn on_stdout(&self, data: Vec<u8>, cursor: u64, offset: u64);
    fn on_stderr(&self, data: Vec<u8>, cursor: u64, offset: u64);
    fn on_gap(&self, affected_channel: i32, offset: u64, lost_bytes: u64);
    fn on_exit(&self, exit_code: Option<i32>);
    fn on_error(&self, code: String, message: String);
}

#[derive(uniffi::Object)]
pub struct IoHandle { send: tokio::sync::Mutex<SendStream>, reader: tokio::sync::Mutex<Option<JoinHandle<()>>> }

#[uniffi::export(async_runtime = "tokio")]
impl IoHandle {
    pub async fn write_stdin(&self, data: Vec<u8>) -> Result<(), BridgeError>;
    pub fn close(&self); // aborts reader task, best-effort finish() on send
}
```

（字段名/粒度在实现阶段可微调；关键是 `ConnectionState`/`BridgeError`/回调接口形状。）

## 数据流

### 连接与重连

```
Swift: BridgeConnection(keyPath, savedEndpointId)
Swift: await connection.connect()
Rust:  load_or_create_key(keyPath)  // 复用配对用的同一份身份
       Endpoint::builder(...).secret_key(key).bind()  // 一次，缓存在 self.endpoint
       endpoint.connect(EndpointId, ALPN)              // 得到 Connection，缓存在 self.connection
       state = Connected
```

重连只替换 `self.connection`，不重新 `bind()`——节点身份由密钥决定，和是否重新 bind 无关，
重新 bind 还要多付一次建连成本。`disconnect()` 才会关 `Endpoint`。

### Control RPC（每次调用独立双向流，对齐 `abp-test-harness::Peer::rpc`）

```
1. connection.open_bi()
2. 写 Hello → 读对端 Hello → negotiate() 得到 max
3. 写 Open{kind: STREAM_CONTROL} → 读 Response（Mac 侧回"" + "null"）
4. 写 Request{rpc_id, method, body_json, timeout_ms}
5. 读 Response；error_code 非空则映射为 BridgeError；否则 serde_json 解析 body_json 到对应 Record
6. send.finish()
```

每次重新握手有固定开销（一次 RTT），但避免了在一条长连接 STREAM_CONTROL 流上做请求/响应
乱序匹配的复杂度，和现有验证过的测试桩行为完全一致，首版优先正确性。若后续发现调用频率
高到需要优化，可以在不改变外部签名的前提下换成单流 pipeline（`rpc_id` 已经天然支持）。

### AgentIO（单条长连接流，贯穿进程生命周期）

```
attach_io(process_id, generation, callback):
  1. open_bi + Hello/Open{kind: STREAM_AGENT_IO, process_id, generation}
  2. 读 Response 确认 Mac 侧已 attach_io 成功
  3. spawn 一个读任务：循环 read_frame
       Io{channel=STDOUT,...} → callback.on_stdout(data, cursor, offset)
       Io{channel=STDERR,...} → callback.on_stderr(...)
       Io{channel=GAP,...}    → callback.on_gap(...)
       Io{channel=EXIT,...}   → callback.on_exit(exit_code); 任务结束
       Error{...}             → callback.on_error(code, message); 任务结束
  4. 返回 IoHandle{send 半边 + 读任务 JoinHandle}
write_stdin(data):
  按 wire::MAX_IO_BYTES 分片，每片包成 Io{channel: CHANNEL_STDIN, data}，写入 send 半边
close():
  abort 读任务；忽略 send.finish() 的错误（Drop 时同样处理，模式对齐
  `agentd::network::AbortTask`/`ConnectionGuard` 的现有写法）
```

## 生命周期与并发

- `Connection`（iroh）本身是可 `Clone` 的轻量 handle（`agentd::network` 里同一个
  `Connection` 被 clone 进多个 spawn 的 task，这是已验证的用法），因此 `BridgeConnection`
  内部只需要一把 `tokio::sync::Mutex` 保护“当前是哪个 Connection”，而不需要把所有操作都
  串行化——拿到 clone 后各 RPC/IO 任务并发跑是安全的。
- `BridgeConnection`/`IoHandle` 是 `uniffi::Object`（Swift 侧是引用类型，`deinit` 时触发
  Rust `Drop`）。`Drop` 里不能 `await`，照抄 `agentd` 里已有的做法：`Drop` 只做
  `task.abort()`/同步关闭，不等待；需要优雅关闭的地方提供显式 `async fn close()` 给 Swift
  主动调用。
- 没有 Rust 内部自动重试循环（PRD R1 的约束）：`reconnect()` 由 Swift 在
  `ScenePhase == .active` 时主动调用一次；多次失败的节奏（退避、提示用户）由 Swift 决定，
  Rust 只负责单次重连的确定性结果。

## Swift 侧改动（最小面）

- `AppModel.swift`：
  - `finishPair` 增加保存 Mac `endpoint_id`（新增 `Snapshot` 字段，`decodeIfPresent` 兼容
    旧 `state.json`，参照现有 `createdAt` 的兼容写法）。
  - 新增一个 `BridgeConnection` 实例（配对成功或 App 启动时若已持久化 endpoint_id 则创建），
    暴露 `connectionState`、`macAgents` 等 `@Observable` 字段，替换掉 `online`/`hostName`
    当前“配对成功=一直在线”的假设来源。
  - 新增一个演示用的真实终端通路：在现有 `Route.terminal` 页面里，如果该会话绑定了一个
    真实 `process_id`（新字段，仅用于验证，不强求纳入现有 mock 会话模型），用
    `attach_io` 的回调把字节流 append 到现成的终端展示状态。
  - `ScenePhase` 监听：进前台时若 `connectionState != .connected` 调一次 `reconnect()`。
- 不新增 SwiftUI 页面；复用现有导航和终端视图的展示骨架。

## 已知协议缺口（记录，不在本任务修复）

- `agentd::network::rpc` 目前没有审批相关方法（如 `RespondApproval`），也没有“发送一条
  聊天消息给某个已知协议的 Agent”这种高层方法——`StartProcess`/`STREAM_AGENT_IO` 给的是
  裸进程和裸字节流。这与 `doc/agent-bridge-ios-client.md` 的产品定位一致（Mac 只做发现和
  I/O 中继，语义解析在手机侧），但意味着本任务验证的“终端页实时输出”只能是原始字节，不会
  有结构化审批卡片——这是预期内的边界，不是 bug。
- `StartProcess`/`StopProcess` 需要 `operation_id`（用于去重），Swift 侧需要生成并保留
  这个 ID（例如 `UUID().uuidString`），本任务只要求能正确传递，不要求实现断线后的去重恢复
  UI（那是 doc §06 “操作去重”表的范围，留给后续任务）。

## 测试策略

- 纯逻辑单元测试（不需要网络）：帧编解码边界、`write_stdin` 分片大小计算、
  `ConnectionState`/`BridgeError` 的错误分类映射。
- Loopback 集成测试（`#[tokio::test]`，两个本地 iroh `Endpoint` 互连，不依赖 `agentd`）：
  写一个最小的“假 Mac 服务端”任务，按 `abp-protocol` 的 Hello/Open/Request-Response 和
  Io 帧格式应答，验证 `BridgeConnection` 对 `Ping`/`ListAgents`/`attach_io` 的处理路径，
  对齐 `abp-protocol::tests` 和 `abp-test-harness` 现有的测试风格。
- 真机/模拟器端到端验证（手动，记录在 `implement.md` 的验收步骤里）：真实启动一次
  `agentd`（例如通过桌面 Tauri app 或 `abp-test-harness` 的对端），模拟器扫码配对后跑
  一遍 R4 的最小通路。

## 构建影响

`third_party/netdev`/`netwatch` 的 `[patch.crates-io]` 和 `scripts/ios-build-client.sh`
保持不变——新代码只是在同一个 crate 里加函数/类型，不引入新依赖，交叉编译目标
（`aarch64-apple-ios`、`aarch64-apple-ios-sim`）不变。构建脚本本身不需要改，除非新增的
`callback_interface` 生成了额外的生成文件需要同步进 `Bridging-Header.h`（UniFFI 通常会
把所有导出合并进同一个 `agent_bridge_clientFFI.h`，预期不需要手工改脚本，实现阶段跑一次
确认即可）。

## 回滚点

- 新代码是纯新增（新类型/新函数），不改 `pair_over_iroh`/`PairOutcome`，回滚只需要在
  `AppModel.swift` 撤掉新增的 `BridgeConnection` 调用点和 `Snapshot` 新字段
  （`decodeIfPresent` 保证旧字段缺失时不炸），Rust 侧撤掉新增模块即可，不影响已验证的
  配对路径。

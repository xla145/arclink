# 执行计划：iOS iroh 传输层

## 顺序检查清单

1. **准备**：读 `agentd/src/network.rs`、`abp-test-harness/src/lib.rs`、
   `abp-protocol/src/lib.rs`（已在 design.md 引用过的部分），确认字段/常量名没有漂移。
   确认 `agent-bridge-client/Cargo.toml` 当前依赖（`iroh`、`tokio`、`uniffi`、`serde_json`、
   `hex`）是否够用，新代码不新增第三方依赖。

2. **类型骨架**：在 `agent-bridge-client/src` 新增模块（如 `connection.rs`、`io.rs`，
   `lib.rs` 内 `mod` 引入），定义 `ConnectionState`、`BridgeError`、`AgentInfo`、
   `ProcessInfo`、`SystemInfo` 等 `uniffi::Record`/`Enum`/`Error`。先让它们编译通过
   （`cargo check -p agent-bridge-client`），不急着接协议逻辑。

3. **BridgeConnection：connect/reconnect/disconnect/state**：
   实现 `Endpoint` 懒绑定 + `Connection` 建立，复用 `load_or_create_key`（如需要可以把
   `lib.rs` 里现成的 `load_or_create_key` 提升为 `pub(crate)` 共享）。
   - 验证：新增单测覆盖“密钥文件复用后两次 bind 得到同一 NodeId”（可以直接照搬现有
     `key_file_roundtrip` 测试思路）。

4. **Control RPC**：实现 `ping`/`get_system_info`/`list_agents`/`list_processes`/
   `start_process`/`stop_process`/`get_process_status`，按 design.md 的“每次调用独立双向流”
   流程，错误路径（超时/协议不兼容/Mac 侧 error_code）统一映射到 `BridgeError`。
   - 验证：写一个本地 loopback 集成测试（两个 iroh `Endpoint` 直连，一个充当最小假
     `agentd`），覆盖至少 `ping` 成功、`list_agents` 返回体解析、一次 Mac 侧 `error_code`
     非空的失败路径。

5. **AgentIO**：实现 `attach_io`/`IoHandle::write_stdin`/`close`，回调接口
   `AgentIoCallback`，覆盖 stdout/stderr/gap/exit/error 分支。
   - 验证：loopback 测试里让假服务端发送一段 stdout + 一个 gap + 一个 exit，断言回调
     按顺序收到；再测一次 `write_stdin` 分片大小正确（对照 `wire::MAX_IO_BYTES`）。

6. **构建产物**：跑一次 `agent-bridge/scripts/ios-build-client.sh`，确认新函数/类型被
   UniFFI 正确生成进 `ios/AgentBridge/Generated/agent_bridge_client.swift` 和
   `AgentBridgeClient.xcframework`（设备 + 模拟器两个 slice），记录构建日志路径。

7. **Swift 最小打通（R4）**：
   - `AppModel.swift`：`finishPair` 保存 Mac `endpoint_id`；新增
     `BridgeConnection`/`connectionState`/`macAgents` 等字段；`ScenePhase` 回前台触发
     `reconnect()`。
   - 复用现有终端 `Route.terminal` 页面展示一次真实 `attach_io` 的 stdout/stderr。
   - 模拟器 Debug 构建：
     ```sh
     cd agent-bridge/ios
     xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
       -destination 'platform=iOS Simulator,name=iPhone 17' \
       -configuration Debug build CODE_SIGNING_ALLOWED=NO
     ```

8. **端到端手动验证**：启动一次真实 `agentd`（桌面 Tauri app 或 `abp-test-harness` 对端
   均可），模拟器扫码配对 → 观察首页/设置展示真实在线状态和 Agent 列表 → `StartProcess`
   启动一个真实进程 → 终端页看到真实 stdout → `StopProcess` → 断网/杀 `agentd` 再恢复，
   确认 `connectionState` 如实变化，手动 `reconnect()` 能恢复。记录结果（哪些步骤实测
   通过、哪些受限于环境无法验证）。

9. **质量检查**（对应 Phase 2.2 / trellis-check）：
   - `cargo fmt --check` / `cargo clippy -p agent-bridge-client --all-targets`
   - `cargo test -p agent-bridge-client`
   - 模拟器构建通过（见步骤 7）
   - 对照 `prd.md` 的 Acceptance Criteria 逐条过一遍

10. **收尾**：更新 `agent-bridge/ios/README.md`（“还没有的”那一节，去掉已经做到的部分，
    补充新的边界说明），如发现协议缺口写进 `.trellis/spec/` 或留在 design.md 的“已知协议
    缺口”供下一个任务参考。commit 按用户指示进行（Phase 3.4），本任务不擅自提交
    `third_party/`、`Frameworks/` 等大体量二进制/生成产物前先确认用户是否要纳入 git。

## 回滚点

- 步骤 2-6（Rust 新代码）出问题：直接删掉新模块/新 `mod` 引用，`pair_over_iroh` 不受影响，
  `cargo test -p agent-bridge-client` 应回到当前基线状态。
- 步骤 7（Swift）出问题：撤掉 `AppModel.swift` 里新增的字段和调用点，`Snapshot` 的新字段
  用 `decodeIfPresent` 已保证旧数据兼容，无需数据迁移。
- 步骤 8 若真机/Mac 环境不可用：明确降级为“模拟器 + 本机 `agentd`/`abp-test-harness`”验证，
  在报告里写清楚哪些场景没有真实验证过，不要含糊带过。

## 验证命令汇总

```sh
cd agent-bridge
cargo fmt --check
cargo clippy -p agent-bridge-client --all-targets
cargo test -p agent-bridge-client
./scripts/ios-build-client.sh
cd ios
xcodebuild -project AgentBridge.xcodeproj -scheme AgentBridge \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -configuration Debug build CODE_SIGNING_ALLOWED=NO
```

## 验收记录（真机实测，2026-10-31）

真机：iPhone 16 Pro（"xu"），账号 `xuliandream@gmail.com`（Team `B59HNJ54M5`）签名安装，桌面端
`agent-bridge-desktop`（含内嵌 `agentd`）在本机 `cargo tauri dev` 下运行。

- [x] `cargo test -p agent-bridge-client` 通过，含帧编解码、分片、断线错误分类的单测/loopback 集成测试。
- [x] `scripts/ios-build-client.sh` 重新生成 xcframework + Swift 绑定；iOS 模拟器与真机 Debug 构建均成功
      （真机构建额外需要显式打开 `CODE_SIGNING_ALLOWED`/`CODE_SIGN_STYLE=Automatic` 并补上
      `SystemConfiguration.framework` 显式链接，否则链接期缺符号）。
- [x] 真实扫码配对成功后，"我的 Mac"详情页展示真实连接状态（`connectionState` 驱动）和
      `ListAgents` 查到的真实 Agent 列表（现场验证：Codex CLI 显示为已安装/可用）。
- [x] 杀掉网络/恢复后 `connectionState` 能如实反映——验证路径是一次真实环境问题：本机开着
      系统级代理（Fake-IP/TUN 模式，所有域名解析到 `198.18.0.0/15`），导致 iroh 直连和中继
      两条路径都走不通，关闭代理后配对/连接立即成功，确认是环境问题而非代码缺陷。
- [ ] **未做**：对一个真实 Mac 进程发起 `StartProcess`，终端页实时显示 stdout/stderr，
      `StopProcess` 能停止它——Rust/UniFFI 层已实现并有 loopback 测试覆盖，但 Swift 侧
      没有任何调用点（`trellis-check` 已标记为真实缺口，非环境限制）。
      这一块连同"解析 Codex `app-server --stdio` 协议、还原项目/会话列表"一起，移交给
      新任务 `.trellis/tasks/<待创建>-codex-app-server-protocol/` 规划实现。
- [ ] 真机进后台超过一段时间再回前台的 `reconnectIfNeeded()` 路径：代码已实现
      （`ScenePhase == .active` 触发），但本次真机验证会话里没有专门测试这个场景，不计入
      已验证项。

## 收尾说明

- `agent-bridge/ios/README.md` 已更新（见该文件"现在能做什么"/"还没有的"）。
- 本任务不包含 Claude Code/Codex 语义协议解析、项目列表、SQLite、图片附件——这些是下一个
  任务的范围。
- 尚未提交 Git；`third_party/`、`Frameworks/` 等大体量二进制/生成产物是否纳入版本控制，
  commit 前需要用户确认。

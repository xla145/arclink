# ArcLink

ArcLink（弧连）是应用展示名称；工程、协议、bundle ID 和数据目录继续使用 Agent Bridge 标识，以保持兼容。

轻量 Agent 宿主。桌面端采用 Tauri 2、Rust、React 和 TypeScript，负责 Agent 发现、设备授权、进程生命周期和字节中继。`ios/` 是 SwiftUI 客户端壳，目前只在手机本机记录会话和审批，尚未连接 daemon。

## 工程

| 目录 | 职责 |
| --- | --- |
| `crates/abp-protocol` | ABP 帧、Protobuf 消息与错误 |
| `crates/agent-adapters` | Agent 探测、版本策略和进程启动配置 |
| `crates/agentd` | 内嵌 daemon、SQLite、配对、进程与 iroh 网络 |
| `crates/abp-test-harness` | 独立测试端和传输集成测试 |
| `desktop` | React 面板及 Tauri 原生壳 |
| `ios` | SwiftUI 客户端壳，说明见 `ios/README.md` |
| `fixtures` | 脱敏后的兼容性验证证据 |

## 本地开发

需要 Rust、Node.js、Corepack，以及当前平台的 Tauri 2 编译依赖。macOS 需要 Xcode Command Line Tools。Node 包管理器版本由 `desktop/package.json` 固定。

```sh
cd agent-bridge/desktop
corepack pnpm install --frozen-lockfile
corepack pnpm tauri dev
```

只启动网页开发服务器：

```sh
corepack pnpm dev
```

普通浏览器不具备原生能力，会显示桥接不可用。网页渲染验证不能代替托盘、Keychain、登录启动和进程清理的原生验证。

## 检查与构建

```sh
cd agent-bridge
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo test --workspace --locked
cd desktop
corepack pnpm test --run
corepack pnpm build
corepack pnpm tauri build --bundles app,dmg
```

Cargo workspace 共用根目录的 `Cargo.lock`。macOS 打包产物位于 `target/release/bundle/`；本地构建不等于 Developer ID 签名或公证。Corepack 必须在 `desktop` 目录执行，才能读取该项目固定的包管理器版本。

## 运行边界

- 设备必须扫码并获得桌面端明确授权才能控制进程。二维码令牌短时有效且只能使用一次。
- 原始 AgentIO 无法判断一条消息是任务还是审批，因此双向访问需要同时授予 `task` 和 `approval`；这不是按消息内容实施的语义权限过滤。
- 关闭面板保留 daemon；手机断线保留 Agent 进程；撤销设备使连接和输入权限失效，不能撤回已经送入 Agent 的操作。
- 退出应用清理应用拥有的进程。daemon 或主机重启不承诺恢复执行现场。
- 工作目录不是安全沙箱。已授权设备控制的是当前用户权限下的 Agent。
- 未验证的 Agent/版本保持“未验证”，不因为发现可执行文件就开放控制。`fixtures/codex-0.165.0-transport.json` 仅证明指定版本的 stdio 初始化和只读 RPC，未证明模型任务、审批、取消或恢复能力。
- 不自动开启登录启动、不安装到 `/Applications`，也不发布应用。Windows/Linux、手机扫码互通和公网 Relay 需要分别记录验证证据。

实际完成的检查与限制将在 `VERIFICATION.md` 中记录。

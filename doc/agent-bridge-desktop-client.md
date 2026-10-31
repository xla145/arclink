# Agent Bridge 桌面客户端 — 技术实现文档

基于 agent-bridge-plan.md 架构设计，结合 client-design 和 client-development 技能规范。

2026-10-31 · v0.1 · 状态：待实现

## 01 产品定位与技术选型

### 定位

桌面客户端是 Agent Bridge 的**轻量宿主**，不是 Agent 交互工作台。它的全部职责：

1. **Agent 发现** — 扫描本机已安装的 Agent（Claude Code、Codex、Herdr 等），检测版本和可用性。
2. **设备配对** — 展示二维码，管理已配对手机列表，处理授权与撤销。
3. **进程与 I/O 中继** — 按手机指令启动/停止 Agent 进程，透传 stdin/stdout/stderr。
4. **状态面板** — 展示 daemon 运行状态、已连接设备、活跃 Agent 进程和网络连通性。

桌面端**不做**：会话管理、任务调度、审批协调、事件解析或状态持久化。这些全部由手机侧 Rust 层完成。

### 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| 应用框架 | **Tauri 2** | 跨平台桌面壳；托盘/菜单栏弹窗为主要交互形态 |
| 前端 | **React + TypeScript + Vite** | 托盘面板 UI |
| 后端 | **Rust** | daemon 核心（agentd）、Agent 适配器、iroh 网络 |
| 通信 | Tauri commands + 事件 | React ↔ Rust 桥接 |
| 网络 | **iroh** | P2P 连接、NAT 穿透、Relay |
| 序列化 | **prost (Protobuf)** | ABP 协议消息 |
| 存储 | **SQLite** | 轻量：配对记录、Agent 发现缓存、进程去重 |
| 安全存储 | 平台原生 | macOS Keychain / Windows Credential Manager / Linux Secret Service |

不引入全局状态库或路由系统。面板是单页紧凑视图，不是多页面后台。

## 02 应用形态与窗口策略

### 主要形态：托盘/菜单栏弹窗

桌面客户端以系统托盘图标（Windows/Linux）或菜单栏图标（macOS）为入口，点击打开弹窗面板。

```
┌─────────────────────────────────┐
│  Agent Bridge          [⚙] [×] │
├─────────────────────────────────┤
│  ● 运行中 · 直连 192.168.1.5   │
│                                 │
│  已连接设备                     │
│  ┌─────────────────────────┐   │
│  │ 📱 iPhone · 在线 · 3分前 │   │
│  │    [撤销]               │   │
│  └─────────────────────────┘   │
│                                 │
│  Agent 状态                     │
│  ┌─────────────────────────┐   │
│  │ ✓ Claude Code 2.1.314   │   │
│  │   运行中 · PID 4521     │   │
│  │ ✓ Codex CLI 0.165.0     │   │
│  │   就绪                  │   │
│  │ ○ Herdr                 │   │
│  │   未安装                │   │
│  └─────────────────────────┘   │
│                                 │
│  [配对新设备]    [查看日志]     │
└─────────────────────────────────┘
```

### 窗口行为

| 行为 | 规则 |
|---|---|
| 打开面板 | 点击托盘图标；按当前屏幕可用区域定位，处理缩放和屏幕边缘 |
| 关闭面板 | 点击面板外区域或按 Esc；关闭面板不停止 daemon |
| 退出应用 | 菜单中的"退出"或系统级退出；提示正在运行的 Agent 进程将被停止 |
| 配对窗口 | 独立窗口展示二维码和配对进度，配对完成或超时后自动关闭 |
| 双击启动 | 只允许一个实例；重复启动聚焦已有实例 |
| 深色/浅色 | 跟随系统主题 |

macOS 特有：

- 激活策略设为 `accessory`（不在 Dock 显示主窗口）。
- 托盘使用模板图标，适配深浅色菜单栏。
- 登录启动使用 `tauri-plugin-autostart` 或 LaunchAgent，由用户在设置中手动开启。

Windows/Linux 特有：

- 系统托盘图标，右键菜单包含"打开面板""设置""退出"。
- 登录启动使用各平台注册表/autostart 机制。

## 03 Rust 侧架构

### 与现有 crate 的关系

```text
agent-bridge/
├── crates/
│   ├── abp-protocol/          # 消息 schema（Tauri 项目依赖）
│   ├── agentd/                # daemon 核心逻辑（Tauri 项目依赖）
│   ├── agent-adapters/        # Agent 探测和进程管理（agentd 依赖）
│   └── ...
├── desktop/                   # ← 新增：Tauri 2 桌面客户端
│   ├── src-tauri/
│   │   ├── Cargo.toml         # 依赖 agentd、abp-protocol
│   │   ├── src/
│   │   │   ├── main.rs        # Tauri 入口，启动 daemon 和 UI
│   │   │   ├── commands/      # Tauri commands：Agent 查询、配对、设置
│   │   │   ├── tray.rs        # 托盘图标和菜单
│   │   │   ├── state.rs       # Tauri 管理的共享状态
│   │   │   └── platform.rs    # 平台特定逻辑
│   │   ├── capabilities/      # Tauri 2 权限声明
│   │   ├── icons/
│   │   └── tauri.conf.json
│   ├── src/                   # React 前端
│   │   ├── App.tsx
│   │   ├── components/
│   │   ├── hooks/
│   │   ├── bridge.ts          # 统一 Tauri command 调用层
│   │   └── types.ts           # 与 Rust DTO 对齐的类型
│   ├── index.html
│   ├── package.json
│   ├── vite.config.ts
│   └── tsconfig.json
```

Tauri 应用内嵌 daemon 逻辑（通过依赖 `agentd` crate），不额外启动独立进程。若后续需要 daemon 独立于 GUI 运行（如无头服务器），可提取为独立二进制。

### Tauri Commands

所有 UI 操作通过具名、参数受限的 Tauri command 暴露给前端：

```rust
// commands/agents.rs
#[tauri::command]
async fn list_agents(state: State<'_, AppState>) -> Result<Vec<AgentInfo>, BridgeError> { ... }

#[tauri::command]
async fn get_agent_detail(
    state: State<'_, AppState>,
    agent_id: String,
) -> Result<AgentDetail, BridgeError> { ... }

// commands/pairing.rs
#[tauri::command]
async fn start_pairing(
    state: State<'_, AppState>,
    config: PairConfig,
) -> Result<PairSession, BridgeError> { ... }

#[tauri::command]
async fn cancel_pairing(
    state: State<'_, AppState>,
    session_id: String,
) -> Result<(), BridgeError> { ... }

#[tauri::command]
async fn list_paired_devices(state: State<'_, AppState>) -> Result<Vec<PairedDevice>, BridgeError> { ... }

#[tauri::command]
async fn revoke_device(
    state: State<'_, AppState>,
    device_id: String,
) -> Result<(), BridgeError> { ... }

// commands/status.rs
#[tauri::command]
async fn get_daemon_status(state: State<'_, AppState>) -> Result<DaemonStatus, BridgeError> { ... }

#[tauri::command]
async fn get_process_list(state: State<'_, AppState>) -> Result<Vec<ProcessInfo>, BridgeError> { ... }

// commands/settings.rs
#[tauri::command]
async fn get_settings(state: State<'_, AppState>) -> Result<AppSettings, BridgeError> { ... }

#[tauri::command]
async fn update_settings(
    state: State<'_, AppState>,
    settings: AppSettings,
) -> Result<(), BridgeError> { ... }

#[tauri::command]
async fn set_autostart(
    state: State<'_, AppState>,
    enabled: bool,
) -> Result<AutostartStatus, BridgeError> { ... }
```

#### DTO 设计

Rust 使用 serde DTO，前端在统一桥接模块调用。类型由 `ts-rs` 或契约测试维护对齐。

```rust
#[derive(Serialize, Deserialize, Type)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub status: AgentStatus,          // Installed / Available / Running / NotFound / VersionMismatch
    pub capabilities: Vec<String>,
    pub adapter_version: String,
    pub validation: ValidationStatus, // Verified / Unverified / Failed
}

#[derive(Serialize, Deserialize, Type)]
pub struct PairedDevice {
    pub device_id: String,
    pub name: String,
    pub paired_at: String,            // ISO 8601；u64 时间戳超出 JS 安全范围，传字符串
    pub last_seen: Option<String>,
    pub connection: ConnectionState,  // Online / Reconnecting / Offline
    pub permissions: Vec<Permission>,
}

#[derive(Serialize, Deserialize, Type)]
pub struct DaemonStatus {
    pub running: bool,
    pub uptime_secs: u32,
    pub iroh_endpoint_id: Option<String>,
    pub network: NetworkInfo,
    pub active_processes: u32,
    pub connected_devices: u32,
}

#[derive(Serialize, Deserialize, Type)]
pub struct BridgeError {
    pub code: ErrorCode,    // Unauthorized / AgentNotFound / ProcessFailed / NetworkError / ...
    pub message: String,    // 用户可读，不含令牌或内部堆栈
}
```

`u64` 类型（时间戳、大序列号）传为字符串，避免 JavaScript 精度丢失。区分 `null`（字段不存在/未知）和空列表。

### Tauri Events（Rust → React）

daemon 状态变化通过 Tauri 事件推送给前端，前端不轮询：

```rust
// Rust 侧发射
app.emit("agent-status-changed", &agent_status_payload)?;
app.emit("device-connected", &device_payload)?;
app.emit("device-disconnected", &device_id)?;
app.emit("process-started", &process_info)?;
app.emit("process-exited", &process_exit)?;
app.emit("pairing-progress", &pair_progress)?;
app.emit("network-changed", &network_info)?;
```

```typescript
// React 侧监听
import { listen } from '@tauri-apps/api/event';

useEffect(() => {
  const unlisten = listen<AgentStatus>('agent-status-changed', (event) => {
    updateAgentStatus(event.payload);
  });
  return () => { unlisten.then(fn => fn()); };
}, []);
```

事件携带足够的进程代次标识，避免把已结束进程的事件写入当前状态。组件卸载时取消订阅。

### Tauri Capabilities

`capabilities/` 按功能最小化声明：

```json
{
  "identifier": "agent-bridge-main",
  "description": "Agent Bridge desktop client",
  "windows": ["main", "pairing"],
  "permissions": [
    "core:default",
    "core:window:allow-close",
    "core:window:allow-set-size",
    "core:tray:default",
    "autostart:allow-enable",
    "autostart:allow-disable",
    "autostart:allow-is-enabled",
    "shell:allow-open"
  ]
}
```

不暴露任意 shell 执行、不受限文件路径访问或不受限 RPC 转发给 WebView。外部链接通过 `shell:open` 打开系统浏览器。

## 04 React 前端架构

### 目录结构

```text
src/
├── App.tsx                    # 根组件，面板布局
├── bridge.ts                  # 统一 Tauri command 调用，错误标准化
├── types.ts                   # 与 Rust DTO 对齐的 TypeScript 类型
├── components/
│   ├── StatusBar.tsx          # 顶部：daemon 状态、网络指示
│   ├── DeviceList.tsx         # 已配对设备列表
│   ├── DeviceCard.tsx         # 单个设备卡片：名称、状态、操作
│   ├── AgentList.tsx          # Agent 发现结果列表
│   ├── AgentCard.tsx          # 单个 Agent：名称、版本、状态
│   ├── ProcessList.tsx        # 活跃进程列表（只读）
│   ├── PairingPanel.tsx       # 配对流程：二维码 + 进度
│   ├── SettingsPanel.tsx      # 设置：登录启动、网络、日志
│   ├── EmptyState.tsx         # 空状态引导
│   ├── ErrorBanner.tsx        # 错误/降级提示条
│   └── common/
│       ├── StatusDot.tsx      # 状态指示点（颜色 + 标签，不仅依赖颜色）
│       ├── ActionButton.tsx   # 带 loading/disabled 状态的操作按钮
│       └── ConfirmDialog.tsx  # 有副作用操作的确认弹窗
├── hooks/
│   ├── useDaemonStatus.ts     # 订阅 daemon 状态事件
│   ├── useAgents.ts           # Agent 列表查询 + 事件更新
│   ├── useDevices.ts          # 设备列表查询 + 连接事件
│   ├── useProcesses.ts        # 活跃进程列表
│   └── usePairing.ts          # 配对流程状态机
└── styles/
    ├── tokens.css             # 设计变量：颜色、字号、间距
    └── panel.css              # 面板布局样式
```

### 桥接层 (`bridge.ts`)

所有 Tauri command 调用集中在桥接模块，前端组件不直接调用 `invoke`：

```typescript
import { invoke } from '@tauri-apps/api/core';

export interface BridgeError {
  code: string;
  message: string;
}

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    // 标准化错误格式
    throw normalizeBridgeError(err);
  }
}

export const bridge = {
  listAgents: () => call<AgentInfo[]>('list_agents'),
  getDaemonStatus: () => call<DaemonStatus>('get_daemon_status'),
  listPairedDevices: () => call<PairedDevice[]>('list_paired_devices'),
  revokeDevice: (deviceId: string) => call<void>('revoke_device', { deviceId }),
  startPairing: (config: PairConfig) => call<PairSession>('start_pairing', { config }),
  cancelPairing: (sessionId: string) => call<void>('cancel_pairing', { sessionId }),
  getProcessList: () => call<ProcessInfo[]>('get_process_list'),
  getSettings: () => call<AppSettings>('get_settings'),
  updateSettings: (settings: AppSettings) => call<void>('update_settings', { settings }),
  setAutostart: (enabled: boolean) => call<AutostartStatus>('set_autostart', { enabled }),
};
```

### 状态管理

不引入全局状态库。面板视图单一、组件少，用 React 自带状态 + 自定义 hook 即可：

- 每个 hook 内部 `useState` + Tauri 事件监听，返回当前数据和 loading/error 状态。
- 刷新失败时保留上次已知数据并展示过期提示，不清空面板。
- 操作进行中（配对、撤销）禁用对应按钮，不依赖 UI 禁用作为唯一防重复手段——Rust 侧也检查。

### 关键交互状态

#### 首次启动 / 无设备

```
┌─────────────────────────────────┐
│  Agent Bridge          [⚙]     │
├─────────────────────────────────┤
│                                 │
│  🔗 尚未配对任何设备            │
│                                 │
│  在手机上安装 Agent Bridge，    │
│  然后扫描下方二维码配对。       │
│                                 │
│  [配对新设备]                   │
│                                 │
│  ─────────────────────────────  │
│  Agent 状态                     │
│  ✓ Claude Code 2.1.314 · 就绪  │
│  ✓ Codex CLI 0.165.0 · 就绪    │
│                                 │
└─────────────────────────────────┘
```

#### 配对流程

```
┌── 配对新设备 ──────────────────┐
│                                │
│  ┌──────────────┐              │
│  │              │              │
│  │   QR Code    │  有效期 120s │
│  │              │              │
│  └──────────────┘              │
│                                │
│  使用手机 Agent Bridge 扫描    │
│                                │
│  ● 等待扫描...                 │
│  ─ 或 ─                       │
│  ● 设备 "iPhone" 请求配对      │
│    授予权限：查看、任务、审批   │
│    [确认配对]  [拒绝]          │
│                                │
│  [取消]                        │
└────────────────────────────────┘
```

#### 撤销设备（有副作用）

```
┌── 撤销设备 ────────────────────┐
│                                │
│  确定撤销 "iPhone" 的访问？    │
│                                │
│  • 将断开当前连接               │
│  • 正在运行的 Agent 进程不会    │
│    自动停止，但该设备无法       │
│    继续控制                     │
│  • 手机需要重新配对才能连接     │
│                                │
│  [撤销]  [取消]                │
└────────────────────────────────┘
```

#### daemon 不可用 / 网络异常

错误提示包含可执行的下一步：

```
┌─ ErrorBanner ──────────────────────────┐
│ ⚠ iroh 端点初始化失败                  │
│   检查网络连接或查看日志排查           │
│   [查看日志]  [重试]                   │
└────────────────────────────────────────┘
```

### 设计变量

```css
/* tokens.css */
:root {
  /* 语义色 */
  --color-bg-primary: #ffffff;
  --color-bg-secondary: #f5f5f5;
  --color-text-primary: #1a1a1a;
  --color-text-secondary: #666666;
  --color-border: #e0e0e0;
  --color-accent: #0066cc;
  --color-success: #22863a;
  --color-warning: #b08800;
  --color-error: #cb2431;
  --color-status-online: #22863a;
  --color-status-offline: #959da5;
  --color-status-connecting: #b08800;

  /* 文字层级 */
  --font-size-sm: 12px;
  --font-size-base: 13px;
  --font-size-lg: 15px;
  --font-size-title: 16px;

  /* 间距 */
  --space-xs: 4px;
  --space-sm: 8px;
  --space-md: 12px;
  --space-lg: 16px;
  --space-xl: 24px;

  /* 面板 */
  --panel-width: 320px;
  --panel-max-height: 480px;
  --panel-radius: 10px;
}

@media (prefers-color-scheme: dark) {
  :root {
    --color-bg-primary: #1e1e1e;
    --color-bg-secondary: #2d2d2d;
    --color-text-primary: #e0e0e0;
    --color-text-secondary: #999999;
    --color-border: #404040;
    --color-accent: #4da6ff;
    --color-success: #3fb950;
    --color-warning: #d29922;
    --color-error: #f85149;
  }
}
```

面板宽度固定 320px，最大高度 480px，超出滚动。长设备名和 Agent 名截断（`text-overflow: ellipsis`）。状态不只靠颜色表达——每个 `StatusDot` 同时携带文本标签。

## 05 进程管理与 I/O 中继

### 进程所有权

Tauri 应用的 Rust 侧拥有所有 Agent 子进程句柄。当手机请求启动 Agent 时：

1. Rust 侧分配唯一 `process_id` 和代次标识（generation）。
2. 通过 `agent-adapters` 的 `start()` 启动子进程，获取 stdin/stdout/stderr 管道。
3. 设置进程代次为 `starting`，首次 I/O 就绪后变为 `running`。
4. 将 stdout/stderr 数据通过 iroh AgentIO 流转发给手机。
5. 将手机通过 AgentIO 发来的数据写入 stdin。

进程退出时：

- 记录退出码和时间。
- 关闭对应的 AgentIO 流。
- 旧代次的回调和事件不写入新进程状态。

### 子进程安全

遵循 `tauri-react-contracts.md` 的子进程规范：

- 根据 Tauri 实际打包位置解析 Agent 可执行文件路径，不依赖开发时绝对路径。
- 使用显式程序路径和参数数组，不经过 shell 拼接。
- stdout 机器协议与 stderr 日志分离读取。
- 对 JSONL/二进制帧先限定长度，增量处理，再解码。
- EOF/异常退出时立即通知手机侧所有 pending 操作。
- 日志不记录令牌、密钥和完整命令输出。

### I/O 中继缓冲

```text
Agent stdout ──→ [BoundedQueue 64KB] ──→ iroh AgentIO 流 ──→ 手机
手机 ──→ iroh AgentIO 流 ──→ [SerializedWriter] ──→ Agent stdin
```

- 出方向：有界队列 64 KiB。队列满时丢弃最旧数据并标记 gap，不阻塞 Agent 进程输出。
- 入方向：串行化写入 stdin，避免大于 PIPE_BUF 的并发消息互相穿插。
- PTY 模式单独处理 resize 信号。

## 06 Agent 发现

### 探测流程

daemon 启动时和收到手机 `ListAgents` 请求时执行探测：

```text
对每个已注册的 Agent 类型：
  1. 查找可执行文件（$PATH 搜索 + 已知安装路径）
  2. 执行版本命令（如 `claude --version`、`codex --version`）
  3. 比对适配器兼容性记录中的锁定版本
  4. 返回 AgentInfo { status, version, capabilities, validation }
```

探测结果缓存到本地 SQLite，带 TTL（默认 5 分钟）。手机发起 `ListAgents` 时如缓存有效直接返回，过期则重新探测。

### 状态定义

| 状态 | 含义 |
|---|---|
| `Installed` | 找到可执行文件，版本已确认 |
| `Available` | Installed + 适配器版本匹配，可以启动 |
| `Running` | 存在由 daemon 管理的活跃进程 |
| `NotFound` | 未找到可执行文件 |
| `VersionMismatch` | 可执行文件存在但版本不在已验证范围 |
| `ProbeFailed` | 探测过程出错（权限、超时等） |

`VersionMismatch` 和 `ProbeFailed` 在 UI 中展示具体原因和可能的修复步骤。

## 07 设备配对与授权

### 配对流程

沿用 plan §06 的扫码配对设计，桌面端负责：

1. **生成配对会话** — daemon 生成一次性高熵令牌、Endpoint ID、有效期，编码为二维码。
2. **展示二维码** — Tauri 独立窗口展示，使用 `qrcode` 库在前端渲染（纯 JS，无外部请求）。
3. **等待扫描** — 通过 iroh Pair 通道接收连接请求。
4. **确认授权** — 弹窗展示请求方设备信息和拟授予的权限，用户确认后完成绑定。
5. **持久化** — 配对记录存入 SQLite，包含设备 ID、公钥指纹、权限和有效期。

### 权限模型

| 权限 | 说明 | 默认 |
|---|---|---|
| `view` | 查看 Agent 列表和进程状态 | ✓ |
| `session` | 请求启动/停止 Agent 进程 | ✓ |
| `task` | 通过 AgentIO 发送任务和消息 | ✓ |
| `approval` | 通过 AgentIO 响应审批请求 | ✓ |
| `terminal` | 附着 PTY 终端并输入 | ✓ |
| `file_preview` | 受限文件读取和 diff 查看 | 后续 |

每次操作和每条新 iroh 流都校验权限，不仅在连接时检查一次。

### 撤销

撤销设备时：
- 关闭该设备的所有连接、AgentIO 流和终端租约。
- 拒绝后续来自该设备的操作。
- 已通过 AgentIO 发给 Agent 的命令无法保证撤回——UI 展示实际状态。
- 手机删除本地配对记录 ≠ 桌面端撤销授权，两侧独立管理。

## 08 平台抽象层

daemon 的 `platform` 模块封装各操作系统差异：

| 能力 | macOS | Windows | Linux |
|---|---|---|---|
| 服务注册 | LaunchAgent plist | 服务/计划任务 | systemd user unit |
| 登录启动 | LaunchAgent / `tauri-plugin-autostart` | 注册表 Run 键 | XDG autostart / systemd |
| 安全存储 | Keychain (`security-framework`) | Credential Manager (`windows-credentials`) | Secret Service (`secret-service-rs`) |
| 进程组 | `nix` crate, `killpg` | Job Objects | `nix` crate, `killpg` |
| PTY | `nix` / 专用 PTY 库 | `winpty` / ConPTY | `nix` / 专用 PTY 库 |
| 休眠检测 | IOKit 通知 | `WM_POWERBROADCAST` | systemd inhibitor / UPower |
| 托盘图标 | 模板图标（`setTemplate(true)`） | 标准图标 | 标准图标 |
| Dock 行为 | `ActivationPolicy::Accessory` | N/A | N/A |

通过 trait 抽象，编译时按 `cfg(target_os)` 选择实现。在原生环境验证，不用网页模拟替代托盘、进程组和登录启动行为。

## 09 构建与打包

### 开发

```bash
cd desktop
pnpm install
pnpm tauri dev          # 启动开发模式（Vite HMR + Rust 热重载）
```

### 类型检查与质量

```bash
pnpm tsc --noEmit              # 前端类型检查
pnpm vite build                # 前端生产构建
cd src-tauri
cargo fmt -- --check           # Rust 格式
cargo clippy -- -D warnings    # Rust lint
cargo test                     # Rust 单元测试
```

### 生产构建

```bash
pnpm tauri build               # 各平台产物
```

| 平台 | 产物 |
|---|---|
| macOS | `.app` bundle + `.dmg` |
| Windows | `.exe` installer (NSIS/WiX) |
| Linux | `.deb` / `.AppImage` |

构建后核对：前端资源打入 bundle、Agent 适配器可执行路径正确、图标和应用标识正确。本地开发签名 ≠ 公证或商店可分发。

### Cargo workspace 集成

`desktop/src-tauri/` 加入根 `Cargo.toml` 的 workspace members：

```toml
[workspace]
members = [
    "crates/*",
    "desktop/src-tauri",
]
```

共享 `Cargo.lock`，避免依赖版本分裂。

## 10 验证清单

按变更选择，不逐条全跑：

### 核心功能

- [ ] 托盘图标可点击打开/隐藏面板；关闭面板不停止 daemon。
- [ ] `ListAgents` 返回正确的已安装 Agent 列表、版本和状态。
- [ ] 配对流程：二维码展示 → 手机扫描 → 桌面确认 → 配对成功。
- [ ] 撤销设备后立即断开连接，后续请求被拒绝。
- [ ] 手机请求 `StartProcess` → daemon 启动 Agent → AgentIO 中继正常。
- [ ] 手机请求 `StopProcess` → Agent 进程正常终止。
- [ ] Agent 进程异常退出 → 手机侧收到退出事件。

### 健壮性

- [ ] 双击启动只产生一个实例。
- [ ] 重启 daemon 后旧回调不影响新状态。
- [ ] 进程 EOF/异常退出时 pending 的 AgentIO 数据得到处理。
- [ ] stdin 写入串行化，大消息不互相穿插。
- [ ] I/O 队列满时丢弃旧数据并标记缺口，不阻塞 Agent。
- [ ] 请求超时不重复触发副作用。

### 平台

- [ ] macOS：模板图标、Dock 不显示、登录启动可开关。
- [ ] Windows：系统托盘、右键菜单、登录启动。
- [ ] Linux：系统托盘、登录启动。
- [ ] 各平台安全存储可读写 iroh 设备密钥。
- [ ] 各平台进程组停止能清理子进程。

### UI

- [ ] 空设备列表展示配对引导，不展示虚构设备。
- [ ] 长设备名、深色模式和窄面板仍可读。
- [ ] 操作进行中按钮禁用，完成后恢复。
- [ ] 有副作用的操作（撤销、退出）有确认弹窗且说明影响。
- [ ] 错误提示包含可执行的下一步。
- [ ] 打包后 React 资源和图标正确加载。

### 安全

- [ ] WebView 不暴露任意 shell 执行。
- [ ] 文件预览路径校验，拒绝越界和符号链接穿透。
- [ ] 令牌和密钥不出现在日志或前端状态。
- [ ] 配对令牌一次性消费，不可重放。
- [ ] 外部链接通过系统浏览器打开，不在 WebView 内导航。

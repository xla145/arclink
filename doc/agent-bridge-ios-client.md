# Agent Bridge iOS 客户端 — 技术实现文档

基于 agent-bridge-plan.md 架构设计与 agent-bridge-mobile.html 交互原型。

2026-10-31 · v0.1 · 状态：待实现

## 01 产品定位与技术选型

### 定位

iOS 客户端是 Agent Bridge 的**交互核心**。桌面 daemon 仅负责 Agent 发现和 I/O 中继，所有会话管理、任务调度、审批协调、事件解析和状态持久化均在手机侧完成。

核心能力：

1. **项目管理** — 为每个 Agent 配置项目（工作目录），管理项目下的多个会话实例。
2. **对话式交互** — 聊天界面发送任务、上传图片、接收 Agent 回复和事件。
3. **审批控制** — 解析 Agent 权限请求，展示 diff/命令详情，批准或拒绝。
4. **终端查看** — 实时展示 Agent 进程输出，支持内联图片和代码高亮。
5. **设备管理** — 配对/管理桌面主机，配置权限和通知。

### 技术栈

| 层 | 选型 | 说明 |
|---|---|---|
| UI 框架 | **SwiftUI** | iOS 原生，支持深浅色主题、手势、安全区域 |
| 核心逻辑 | **Rust** | 网络、协议解析、Agent 通信、状态机 |
| 绑定 | **UniFFI** | Rust → Swift FFI，锁定版本 |
| 网络 | **iroh** (Rust) | P2P 连接、NAT 穿透、Relay |
| 本地存储 | **SQLite** (Rust) | 会话、任务、审批、事件、操作去重 |
| 安全存储 | **iOS Keychain** | iroh 设备密钥、配对令牌 |
| 推送 | **APNs**（后续） | 审批通知、任务完成通知 |

### 首版约束

- 一对一：一部手机配对一台桌面主机。多主机支持预留数据结构但首版 UI 不开放切换。
- iOS 优先，Android 后续扩展。
- 手机需通过 iroh P2P 连接到桌面 daemon，不经过中心服务器。

## 02 应用架构

### 层次结构

```text
┌─────────────────────────────────────────────┐
│                SwiftUI Views                │
│  HomeView · ProjectView · SessionView       │
│  ApprovalView · TerminalView · SettingsView │
├─────────────────────────────────────────────┤
│              Swift ViewModels               │
│  @Observable state · formatted data ·       │
│  UI actions → Rust calls                    │
├─────────────────────────────────────────────┤
│           UniFFI Bridge (generated)         │
│  Swift ↔ Rust async callbacks, DTO types    │
├─────────────────────────────────────────────┤
│              Rust Core Library              │
│  connection · agent_protocol · session ·    │
│  approval · store · sync                    │
├─────────────────────────────────────────────┤
│           iroh · SQLite · Keychain          │
└─────────────────────────────────────────────┘
```

### 项目结构

```text
agent-bridge/
├── crates/
│   ├── abp-protocol/              # 消息 schema、帧格式
│   ├── agent-bridge-client/       # ← 核心：协议解析、状态机、存储、UniFFI 导出
│   └── ...
├── ios/
│   ├── AgentBridge.xcodeproj
│   ├── AgentBridge/
│   │   ├── App.swift              # @main 入口
│   │   ├── Models/
│   │   │   ├── AppState.swift     # 全局状态容器
│   │   │   ├── Project.swift      # 项目模型
│   │   │   ├── Session.swift      # 会话模型
│   │   │   ├── Approval.swift     # 审批模型
│   │   │   └── Device.swift       # 设备模型
│   │   ├── ViewModels/
│   │   │   ├── HomeViewModel.swift
│   │   │   ├── ProjectViewModel.swift
│   │   │   ├── SessionViewModel.swift
│   │   │   ├── ApprovalViewModel.swift
│   │   │   ├── TerminalViewModel.swift
│   │   │   └── SettingsViewModel.swift
│   │   ├── Views/
│   │   │   ├── Home/
│   │   │   │   ├── HomeView.swift
│   │   │   │   ├── AgentTabBar.swift
│   │   │   │   ├── ProjectCard.swift
│   │   │   │   └── ApprovalBanner.swift
│   │   │   ├── Project/
│   │   │   │   ├── ProjectDetailView.swift
│   │   │   │   ├── SessionRow.swift
│   │   │   │   └── AddProjectView.swift
│   │   │   ├── Session/
│   │   │   │   ├── ChatView.swift
│   │   │   │   ├── MessageBubble.swift
│   │   │   │   ├── ChatEventPill.swift
│   │   │   │   ├── ComposerBar.swift
│   │   │   │   ├── AttachmentStrip.swift
│   │   │   │   └── EmptyChatHint.swift
│   │   │   ├── Approval/
│   │   │   │   ├── ApprovalListView.swift
│   │   │   │   ├── ApprovalCard.swift
│   │   │   │   ├── ApprovalDetailView.swift
│   │   │   │   └── DiffPreview.swift
│   │   │   ├── Terminal/
│   │   │   │   ├── TerminalView.swift
│   │   │   │   ├── TermBlock.swift
│   │   │   │   ├── InlineImage.swift
│   │   │   │   └── TermApprovalCard.swift
│   │   │   ├── Settings/
│   │   │   │   ├── SettingsView.swift
│   │   │   │   ├── DeviceListView.swift
│   │   │   │   ├── DeviceDetailView.swift
│   │   │   │   └── NotificationSettings.swift
│   │   │   └── Common/
│   │   │       ├── StatusPill.swift
│   │   │       ├── SearchBar.swift
│   │   │       ├── ActionSheet+.swift
│   │   │       └── Toast.swift
│   │   ├── Bridge/
│   │   │   ├── RustBridge.swift   # UniFFI 调用封装
│   │   │   └── EventBus.swift     # Rust 事件 → Swift 分发
│   │   ├── Resources/
│   │   │   ├── Assets.xcassets
│   │   │   └── Localizable.xcstrings
│   │   └── Utilities/
│   │       ├── DateFormatters.swift
│   │       └── ImagePicker.swift
│   └── AgentBridgeTests/
├── scripts/
│   └── build-xcframework.sh       # Rust → XCFramework 打包
└── Cargo.toml
```

## 03 导航结构

### 页面层级

```text
首页 (HomeView)
├── 审批列表 (ApprovalListView)
│   └── 审批详情 (ApprovalDetailView)
├── 项目详情 (ProjectDetailView)
│   ├── 会话/对话 (ChatView)
│   │   └── 终端 (TerminalView)
│   └── 项目设置 (AddProjectView, edit mode)
├── 添加项目 (AddProjectView, create mode)
└── 设置 (SettingsView)
    └── 我的 Mac (DeviceListView)
        └── Mac 详情 (DeviceDetailView)
```

### NavigationStack 实现

```swift
enum AppRoute: Hashable {
    case approvals
    case approvalDetail(id: String)
    case project(id: String)
    case session(projectId: String, sessionId: String?)  // nil = new
    case terminal(sessionId: String)
    case addProject(editingId: String?)  // nil = create
    case settings
    case deviceList
    case deviceDetail(id: String)
}

struct ContentView: View {
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: AppRoute.self) { route in
                    switch route {
                    case .approvals:
                        ApprovalListView(path: $path)
                    case .approvalDetail(let id):
                        ApprovalDetailView(approvalId: id, path: $path)
                    case .project(let id):
                        ProjectDetailView(projectId: id, path: $path)
                    case .session(let pid, let sid):
                        ChatView(projectId: pid, sessionId: sid, path: $path)
                    case .terminal(let id):
                        TerminalView(sessionId: id)
                    case .addProject(let editId):
                        AddProjectView(editingProjectId: editId, path: $path)
                    case .settings:
                        SettingsView(path: $path)
                    case .deviceList:
                        DeviceListView(path: $path)
                    case .deviceDetail(let id):
                        DeviceDetailView(deviceId: id, path: $path)
                    }
                }
        }
    }
}
```

## 04 核心页面实现

### 4.1 首页 (HomeView)

```text
MacBook Pro ●                    ⋯
在线 · 直连
─────────────────────────────
⚠ 2 个待审批              1:48 >
🔍 [搜索项目…                  ]
[Claude Code] [Codex] [Herdr]  ⊕
┌──────────────────────────────┐
│ 📁 my-app       2 个会话 待审>│
│ 📁 backend      无活跃会话   >│
└──────────────────────────────┘
```

数据流：

```swift
@Observable
class HomeViewModel {
    var connectionState: ConnectionState = .connecting
    var hostName: String = ""
    var agents: [AgentInfo] = []           // 来自 daemon ListAgents
    var selectedAgent: String = ""
    var projects: [ProjectSummary] = []    // 本地 SQLite
    var pendingApprovals: Int = 0          // 本地状态
    var searchQuery: String = ""

    var filteredProjects: [ProjectSummary] {
        guard !searchQuery.isEmpty else { return projects }
        return projects.filter {
            $0.name.localizedCaseInsensitiveContains(searchQuery) ||
            $0.path.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    func load() async {
        // 1. 查询 daemon 连接状态和 Agent 列表
        // 2. 从本地 SQLite 读取项目和会话摘要
        // 3. 统计待审批数
    }
}
```

### 4.2 会话/对话页 (ChatView)

这是**最核心的页面**——聊天式界面与 Agent 交互。

#### 消息模型

```swift
enum ChatItem: Identifiable {
    case message(ChatMessage)
    case event(ChatEvent)

    var id: String { ... }
}

struct ChatMessage: Identifiable {
    let id: String
    let sender: Sender          // .user | .agent
    let text: String
    let images: [ImageAttachment]
    let timestamp: Date

    enum Sender { case user, agent }
}

struct ChatEvent: Identifiable {
    let id: String
    let kind: EventKind         // .tool, .result, .approval, .info, .error
    let label: String
    let detail: String?
    let isActionable: Bool      // 如 approval 可点击
    let timestamp: Date
}

struct ImageAttachment: Identifiable {
    let id: String
    let thumbnail: UIImage?     // 本地预览
    let fullURL: URL?           // 本地文件路径
    let size: String?           // "1280×720 · 284 KB"
}
```

#### ViewModel

```swift
@Observable
class SessionViewModel {
    let projectId: String
    var sessionId: String?            // nil = 新会话
    var title: String = "新会话"
    var items: [ChatItem] = []
    var composerText: String = ""
    var pendingImages: [PendingImage] = []
    var isSending: Bool = false
    var agentTyping: Bool = false

    var canSend: Bool {
        !composerText.trimmingCharacters(in: .whitespaces).isEmpty
        || !pendingImages.isEmpty
    }

    // 新建会话
    func send() async {
        guard canSend else { return }
        isSending = true

        let text = composerText
        let images = pendingImages
        composerText = ""
        pendingImages = []

        // 1. 首条消息时创建会话
        if sessionId == nil {
            sessionId = try await bridge.createSession(
                projectId: projectId,
                agentId: project.agentId
            )
            items.append(.event(ChatEvent(kind: .info, label: "会话已创建")))
            title = String(text.prefix(20))
        }

        // 2. 添加用户消息到列表
        let msg = ChatMessage(sender: .user, text: text, images: ...)
        items.append(.message(msg))

        // 3. 通过 AgentIO 发送
        try await bridge.submitTask(sessionId: sessionId!, message: text, attachments: images)

        isSending = false
        agentTyping = true  // 等待 Agent 回复
    }

    // 监听 Agent 事件流
    func subscribe() async {
        guard let sid = sessionId else { return }
        for await event in bridge.events(sessionId: sid) {
            switch event {
            case .agentText(let text):
                agentTyping = false
                items.append(.message(ChatMessage(sender: .agent, text: text, ...)))
            case .toolCall(let tool, let args):
                items.append(.event(ChatEvent(kind: .tool, label: "工具 · \(tool)")))
            case .toolResult(let result):
                items.append(.event(ChatEvent(kind: .result, label: result.summary)))
            case .approvalRequest(let req):
                items.append(.event(ChatEvent(kind: .approval, label: "⏳ 待审批 · \(req.type)", isActionable: true)))
            case .image(let img):
                items.append(.message(ChatMessage(sender: .agent, images: [img], ...)))
            case .error(let err):
                items.append(.event(ChatEvent(kind: .error, label: err.message)))
            case .completed:
                items.append(.event(ChatEvent(kind: .info, label: "任务完成")))
            }
        }
    }
}
```

#### 图片上传

```swift
struct ComposerBar: View {
    @Bindable var vm: SessionViewModel
    @State private var showImagePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // 附件预览条
            if !vm.pendingImages.isEmpty {
                AttachmentStrip(images: $vm.pendingImages)
            }
            // 输入栏
            HStack(alignment: .bottom, spacing: 8) {
                Button { showImagePicker = true } label: {
                    Image(systemName: "photo")
                        .frame(width: 36, height: 36)
                        .background(Color(.systemGray5))
                        .clipShape(Circle())
                }
                TextEditor(text: $vm.composerText)
                    .frame(minHeight: 36, maxHeight: 100)
                    .padding(.horizontal, 12)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                Button { Task { await vm.send() } } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(!vm.canSend)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .photosPicker(isPresented: $showImagePicker, selection: ..., matching: .images)
    }
}
```

### 4.3 审批详情 (ApprovalDetailView)

```text
←审批         审批详情

  Claude Code · 会话 #a3f8

  工具调用 · 写入文件
  写入 src/components/Dashboard.tsx
  +42 行，-18 行

  变更预览
  @@ -15,8 +15,12 @@
  - import { fetchData } from '../api';
  + import { useQuery } from '../hooks/useQuery';
  + import { DashboardGrid } from './DashboardGrid';

  审批 ID    apv_8f3a
  有效期     1:48
────────────────────────────
  [拒绝]          [批准写入]
```

关键实现：

```swift
struct ApprovalDetailView: View {
    let approvalId: String
    @State private var approval: ApprovalDetail?
    @State private var isSubmitting = false

    var body: some View {
        ScrollView { ... }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 10) {
                Button("拒绝") { respond(.reject) }
                    .buttonStyle(.secondary)
                Button("批准写入") { respond(.approve) }
                    .buttonStyle(.primary)
                    .disabled(isSubmitting || approval?.isExpired == true)
            }
            .padding()
        }
    }

    func respond(_ decision: ApprovalDecision) {
        isSubmitting = true
        Task {
            let result = try await bridge.respondApproval(
                approvalId: approvalId,
                decision: decision,
                operationId: UUID().uuidString
            )
            showToast(decision == .approve ? "已批准写入" : "已拒绝")
            path.removeLast()
        }
    }
}
```

### 4.4 终端视图 (TerminalView)

暗色主题、结构化输出块、内联图片支持。

```swift
struct TerminalView: View {
    @State var vm: TerminalViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(vm.blocks) { block in
                        switch block {
                        case .prompt(let cmd):
                            TermPromptLine(command: cmd)
                        case .agentText(let text):
                            TermTextBlock(label: "Agent 输出", text: text)
                        case .toolCall(let tool, let code):
                            TermCodeBlock(label: "工具 · \(tool)", code: code)
                        case .image(let img):
                            TermInlineImage(image: img, onTap: { vm.expandedImage = img })
                        case .approval(let req):
                            TermApprovalCard(request: req, onApprove: ..., onReject: ...)
                        case .result(let summary, let code):
                            TermCodeBlock(label: summary, code: code, style: .result)
                        }
                    }
                    if vm.isLive { TermCursor() }
                }
                .padding(12)
            }
            .background(Color(hex: "0d1117"))
        }
        .toolbar {
            ToolbarItem(placement: .principal) { Text("终端").foregroundColor(.white) }
            ToolbarItem(placement: .topBarTrailing) {
                StatusPill(text: "● LIVE", color: .green)
            }
        }
        .fullScreenCover(item: $vm.expandedImage) { img in
            ImageViewer(image: img)
        }
    }
}
```

### 4.5 设置 (SettingsView)

iOS 分组列表风格，参考 Remmo 的布局。

```swift
struct SettingsView: View {
    var body: some View {
        List {
            Section("Mac") {
                NavigationLink(value: AppRoute.deviceList) {
                    HStack {
                        Label("Mac", systemImage: "desktopcomputer")
                        Spacer()
                        Circle().fill(.green).frame(width: 7)
                        Text("mac 的 MacBook Pro")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Section("智能体") {
                Picker("权限", selection: $permission) {
                    Text("完全访问").tag(Permission.full)
                    Text("查看和审批").tag(Permission.viewApprove)
                    Text("仅查看").tag(Permission.viewOnly)
                }
            }
            Section("通知") {
                Toggle("需要批准", isOn: $notifyApproval)
                Toggle("已完成", isOn: $notifyCompleted)
                Toggle("在 Mac 上完成", isOn: $notifyOnMac)
                Toggle("执行失败", isOn: $notifyFailed)
            }
            Section("Agent Bridge") {
                Picker("外观", selection: $theme) { ... }
                Picker("会话保留", selection: $retention) { ... }
                Picker("语言", selection: $language) { ... }
                Button("清除会话历史", role: .destructive) { ... }
            }
            Section("关于") {
                Link("发送反馈", destination: feedbackURL)
                Link("隐私政策", destination: privacyURL)
                LabeledContent("版本", value: appVersion)
            }
        }
        .navigationTitle("设置")
    }
}
```

## 05 Rust 核心层 (agent-bridge-client)

### 模块划分

```text
agent-bridge-client/
├── src/
│   ├── lib.rs                 # UniFFI 导出入口
│   ├── connection/
│   │   ├── mod.rs
│   │   ├── endpoint.rs        # iroh 连接管理
│   │   ├── pairing.rs         # 扫码配对流程
│   │   └── heartbeat.rs       # 心跳与重连
│   ├── protocol/
│   │   ├── mod.rs
│   │   ├── control.rs         # ABP Control RPC
│   │   ├── agent_io.rs        # AgentIO 流透传
│   │   └── framing.rs         # 帧解析
│   ├── agent/
│   │   ├── mod.rs
│   │   ├── claude_code.rs     # Claude Code 协议解析
│   │   ├── codex.rs           # Codex 协议解析
│   │   └── generic.rs         # Generic PTY 解析
│   ├── session/
│   │   ├── mod.rs
│   │   ├── state_machine.rs   # 会话状态机
│   │   ├── task.rs            # 任务状态跟踪
│   │   └── events.rs          # 事件流解析
│   ├── approval/
│   │   ├── mod.rs
│   │   ├── state_machine.rs   # 审批状态机
│   │   ├── dedup.rs           # operation_id 去重
│   │   └── timeout.rs         # 到期管理
│   ├── store/
│   │   ├── mod.rs
│   │   ├── db.rs              # SQLite 封装
│   │   ├── migrations.rs      # Schema 迁移
│   │   ├── sessions.rs        # 会话 CRUD
│   │   ├── approvals.rs       # 审批 CRUD
│   │   ├── events.rs          # 事件日志
│   │   └── projects.rs        # 项目配置
│   └── sync/
│       ├── mod.rs
│       └── reconnect.rs       # 断线重连与状态恢复
├── uniffi.toml
└── Cargo.toml
```

### UniFFI 导出接口

```rust
// lib.rs — UniFFI 导出的核心接口

#[uniffi::export]
pub struct BridgeClient { ... }

#[uniffi::export]
impl BridgeClient {
    // ── 连接 ──
    pub async fn connect(&self, endpoint_id: String) -> Result<ConnectionInfo, BridgeError>;
    pub async fn disconnect(&self) -> Result<(), BridgeError>;
    pub fn connection_state(&self) -> ConnectionState;

    // ── Agent 发现 ──
    pub async fn list_agents(&self) -> Result<Vec<AgentInfo>, BridgeError>;

    // ── 项目 ──
    pub async fn list_projects(&self, agent_id: String) -> Result<Vec<ProjectSummary>, BridgeError>;
    pub async fn add_project(&self, config: ProjectConfig) -> Result<String, BridgeError>;
    pub async fn update_project(&self, id: String, config: ProjectConfig) -> Result<(), BridgeError>;
    pub async fn delete_project(&self, id: String) -> Result<(), BridgeError>;

    // ── 会话 ──
    pub async fn create_session(&self, project_id: String) -> Result<String, BridgeError>;
    pub async fn list_sessions(&self, project_id: String) -> Result<Vec<SessionSummary>, BridgeError>;
    pub async fn submit_task(&self, session_id: String, message: String, attachments: Vec<Attachment>) -> Result<String, BridgeError>;
    pub async fn cancel_task(&self, session_id: String, task_id: String) -> Result<(), BridgeError>;
    pub async fn stop_session(&self, session_id: String) -> Result<(), BridgeError>;
    pub async fn delete_session(&self, session_id: String) -> Result<(), BridgeError>;

    // ── 事件流 ──
    pub fn subscribe_events(&self, session_id: String, callback: Box<dyn EventCallback>);

    // ── 审批 ──
    pub async fn list_approvals(&self) -> Result<Vec<ApprovalSummary>, BridgeError>;
    pub async fn get_approval(&self, id: String) -> Result<ApprovalDetail, BridgeError>;
    pub async fn respond_approval(&self, id: String, decision: ApprovalDecision, operation_id: String) -> Result<ApprovalResult, BridgeError>;

    // ── 设备 ──
    pub async fn list_devices(&self) -> Result<Vec<PairedDevice>, BridgeError>;
    pub async fn start_pairing(&self) -> Result<PairSession, BridgeError>;
    pub async fn revoke_device(&self, device_id: String) -> Result<(), BridgeError>;

    // ── 设置 ──
    pub async fn get_settings(&self) -> Result<AppSettings, BridgeError>;
    pub async fn update_settings(&self, settings: AppSettings) -> Result<(), BridgeError>;
}

#[uniffi::export(callback_interface)]
pub trait EventCallback: Send + Sync {
    fn on_event(&self, event: SessionEvent);
    fn on_error(&self, error: BridgeError);
    fn on_completed(&self);
}
```

### 关键 DTO

```rust
#[derive(uniffi::Record)]
pub struct AgentInfo {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    pub status: AgentStatus,           // Installed / Available / NotFound
    pub capabilities: Vec<String>,
    pub color: String,                 // 用于 UI 的 Agent 主题色
}

#[derive(uniffi::Record)]
pub struct ProjectConfig {
    pub name: String,
    pub path: String,                  // 工作目录
    pub agent_id: String,
    pub env_vars: HashMap<String, String>,
    pub launch_args: Vec<String>,
    pub auto_start: bool,
}

#[derive(uniffi::Record)]
pub struct SessionSummary {
    pub id: String,
    pub title: String,
    pub status: SessionStatus,         // Running / WaitingApproval / Completed / Cancelled / Failed
    pub pending_approvals: u32,
    pub created_at: String,            // ISO 8601
    pub duration_secs: Option<u32>,
}

#[derive(uniffi::Enum)]
pub enum SessionEvent {
    AgentText { text: String },
    ToolCall { tool: String, args: String },
    ToolResult { summary: String, code: Option<String> },
    ApprovalRequest { id: String, kind: String, target: String, detail: Option<String> },
    Image { url: String, width: u32, height: u32, size_bytes: u64, caption: String },
    Error { message: String },
    Completed,
}

#[derive(uniffi::Record)]
pub struct Attachment {
    pub data: Vec<u8>,
    pub mime_type: String,
    pub filename: String,
}

#[derive(uniffi::Record)]
pub struct ApprovalDetail {
    pub id: String,
    pub session_id: String,
    pub session_title: String,
    pub agent_name: String,
    pub kind: String,                  // "写入文件" / "执行命令" / ...
    pub target: String,                // 文件路径或命令
    pub diff: Option<DiffContent>,
    pub decisions: Vec<String>,        // ["approve", "reject"]
    pub expires_at: String,
    pub is_expired: bool,
    pub status: ApprovalStatus,
}
```

## 06 本地存储 (SQLite)

### Schema

```sql
-- 项目
CREATE TABLE projects (
    id          TEXT PRIMARY KEY,
    agent_id    TEXT NOT NULL,
    name        TEXT NOT NULL,
    path        TEXT NOT NULL,
    env_vars    TEXT,               -- JSON
    launch_args TEXT,               -- JSON
    auto_start  INTEGER DEFAULT 0,
    created_at  TEXT NOT NULL,
    updated_at  TEXT NOT NULL
);

-- 会话
CREATE TABLE sessions (
    id            TEXT PRIMARY KEY,
    project_id    TEXT NOT NULL REFERENCES projects(id),
    title         TEXT NOT NULL,
    status        TEXT NOT NULL,    -- running / waiting_approval / completed / cancelled / failed
    process_id    TEXT,             -- daemon 侧进程 ID
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

-- 消息（聊天记录）
CREATE TABLE messages (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(id),
    sender      TEXT NOT NULL,     -- user / agent
    text        TEXT,
    timestamp   TEXT NOT NULL,
    event_seq   INTEGER
);

-- 消息附件（图片）
CREATE TABLE attachments (
    id          TEXT PRIMARY KEY,
    message_id  TEXT NOT NULL REFERENCES messages(id),
    mime_type   TEXT NOT NULL,
    filename    TEXT NOT NULL,
    file_path   TEXT NOT NULL,      -- 本地文件路径
    width       INTEGER,
    height      INTEGER,
    size_bytes  INTEGER
);

-- 事件（内联在聊天中的工具调用等）
CREATE TABLE events (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL REFERENCES sessions(id),
    event_seq   INTEGER NOT NULL,
    kind        TEXT NOT NULL,      -- tool / result / approval / info / error / image
    label       TEXT NOT NULL,
    detail      TEXT,
    timestamp   TEXT NOT NULL,
    UNIQUE(session_id, event_seq)
);

-- 审批
CREATE TABLE approvals (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES sessions(id),
    kind          TEXT NOT NULL,
    target        TEXT NOT NULL,
    diff_json     TEXT,
    decisions     TEXT NOT NULL,    -- JSON array
    status        TEXT NOT NULL,    -- pending / resolving / resolved / cancelled / expired / unknown
    expires_at    TEXT,
    created_at    TEXT NOT NULL,
    resolved_at   TEXT,
    decision      TEXT,
    operation_id  TEXT UNIQUE
);

-- 操作去重
CREATE TABLE operations (
    operation_id  TEXT PRIMARY KEY,
    method        TEXT NOT NULL,
    status        TEXT NOT NULL,    -- sent / confirmed / unknown
    created_at    TEXT NOT NULL,
    expires_at    TEXT NOT NULL
);

-- 配对设备
CREATE TABLE devices (
    id             TEXT PRIMARY KEY,
    name           TEXT NOT NULL,
    endpoint_id    TEXT NOT NULL,
    paired_at      TEXT NOT NULL,
    last_seen      TEXT,
    is_active      INTEGER DEFAULT 1
);
```

### 数据保留策略

| 数据 | 保留规则 |
|---|---|
| 项目配置 | 永久，用户手动删除 |
| 会话与消息 | 按用户设置（默认 7 天），可选 3/7/30/永久 |
| 事件日志 | 跟随会话保留期 |
| 审批记录 | 权威状态永久；历史记录跟随会话 |
| 操作去重 | 7 天后清理 |
| 图片附件 | 跟随消息；清理时删除本地文件 |

## 07 网络与状态同步

### 连接生命周期

```text
App 启动
  ↓
检查已保存设备 → 无设备 → 显示空状态（扫码引导）
  ↓ 有设备
尝试 iroh 连接
  ↓ 成功
Hello 握手 → 状态同步
  ↓
正常运行（心跳 15s）
  ↓ 连接中断
指数退避重连（1s → 60s，带抖动）
  ↓ 重连成功
重新握手 → 查询 daemon 进程状态 → 恢复 AgentIO 订阅
```

### 断线处理

| 场景 | 行为 |
|---|---|
| 手机进后台 | 允许连接中断；回前台重连并同步 |
| Wi-Fi ↔ 蜂窝切换 | 检测网络变化，尽快重连 |
| daemon 重启 | 进程丢失，会话标记 RecoveryRequired |
| 主机睡眠 | UI 显示"不可达"，唤醒后重连 |
| 消息丢失 | AgentIO 缺口明确标记，不静默拼接 |

### 回前台同步流程

```swift
// ScenePhase 监听
.onChange(of: scenePhase) { _, phase in
    if phase == .active {
        Task {
            // 1. 重新验证连接
            await bridge.reconnectIfNeeded()
            // 2. 查询 daemon 进程状态
            let status = try await bridge.getProcessStatuses()
            // 3. 刷新审批列表（可能有新审批或过期）
            await approvalVM.refresh()
            // 4. 恢复活跃会话的事件订阅
            for session in activeSessions {
                await session.resubscribe()
            }
        }
    }
}
```

## 08 图片处理

### 上传流程

```text
选择图片 (PhotosPicker / 相机)
  ↓
本地压缩 (max 1280px, JPEG 80%)
  ↓
生成缩略图 → 显示预览条
  ↓
用户发送
  ↓
消息入库 → 图片存本地沙盒
  ↓
通过 AgentIO 发送 (Base64 或分块)
```

### 接收图片（Agent 截图等）

```text
AgentIO 事件 → Image 类型
  ↓
下载到本地沙盒（或从 AgentIO 流接收字节）
  ↓
生成缩略图
  ↓
聊天中内联展示（限高 240px）
  ↓
点击 → 全屏查看（缩放、平移）
```

### 本地存储

```text
Documents/
└── attachments/
    └── {session_id}/
        ├── {id}_thumb.jpg     # 缩略图 (200px)
        └── {id}_full.jpg      # 原图
```

- 图片不存入 SQLite，只存路径引用
- 清理会话时同步删除目录

## 09 XCFramework 构建

### 构建脚本

```bash
#!/bin/bash
# scripts/build-xcframework.sh

set -e

TARGETS=(
    "aarch64-apple-ios"            # 真机
    "aarch64-apple-ios-sim"        # 模拟器 (Apple Silicon)
)

for target in "${TARGETS[@]}"; do
    cargo build --release --target "$target" -p agent-bridge-client
done

# 生成 UniFFI Swift 绑定
cargo run -p agent-bridge-client --bin uniffi-bindgen generate \
    --library target/aarch64-apple-ios/release/libagent_bridge_client.dylib \
    --language swift \
    --out-dir ios/Generated

# 打包 XCFramework
xcodebuild -create-xcframework \
    -library target/aarch64-apple-ios/release/libagent_bridge_client.a \
    -headers ios/Generated/ \
    -library target/aarch64-apple-ios-sim/release/libagent_bridge_client.a \
    -headers ios/Generated/ \
    -output ios/AgentBridgeClient.xcframework
```

### Xcode 集成

1. 将 `AgentBridgeClient.xcframework` 拖入项目
2. 将生成的 `agent_bridge_client.swift` 加入编译
3. 在 `Build Settings` 中添加 `Other Linker Flags: -lresolv`（iroh 需要）
4. 确保 `Framework Search Paths` 包含 XCFramework 位置

## 10 验证清单

### 核心交互

- [ ] 首页显示 Mac 连接状态、Agent 列表、项目列表
- [ ] 搜索项目可按名称和路径过滤
- [ ] Agent tab 切换正确过滤项目
- [ ] 点击项目进入会话列表
- [ ] ⊕ 新建会话 → 空聊天 → 发送首条消息创建会话
- [ ] 点击已有会话 → 显示标题和历史对话
- [ ] 发送文本消息，Agent 回复正确显示
- [ ] 上传图片：选择 → 预览 → 发送 → 气泡内展示
- [ ] Agent 返回图片（截图）→ 内联展示 → 点击放大
- [ ] 审批通知在首页显示条数和倒计时
- [ ] 审批详情显示 diff 预览
- [ ] 批准/拒绝后 toast 反馈
- [ ] 终端视图实时输出、内联代码和图片
- [ ] 会话更多菜单：取消任务、停止会话、删除记录

### 项目管理

- [ ] 添加项目：选 Agent、填路径、高级配置
- [ ] 编辑项目：标题变为"项目设置"、按钮变为"保存"、显示删除
- [ ] 删除项目有确认弹窗

### 设置

- [ ] Mac 管理：查看详情、断开配对
- [ ] 添加新 Mac（预留）
- [ ] 权限 picker 可选
- [ ] 通知 toggle 可切换
- [ ] 外观/语言/保留期 picker 可选
- [ ] 清除历史有确认

### 网络与健壮性

- [ ] 回前台重连并同步状态
- [ ] Wi-Fi/蜂窝切换不丢消息
- [ ] daemon 重启后会话标记 RecoveryRequired
- [ ] 操作去重：相同 operation_id 不重复发送
- [ ] 审批过期后卡片不可提交

### 平台

- [ ] 深浅色主题完整
- [ ] 安全区域适配（刘海、底部横条）
- [ ] 键盘弹出不遮挡输入框
- [ ] 长文本截断/换行正确
- [ ] 图片选择器权限处理

import SwiftUI

enum AgentKind: String, CaseIterable, Identifiable, Hashable, Codable {
    case claude = "Claude Code"
    case codex = "Codex"
    case herdr = "Herdr"

    var id: String { rawValue }

    var tint: Color {
        switch self {
        case .claude: Color(red: 0.69, green: 0.32, blue: 0.87)
        case .codex: Color(red: 0.20, green: 0.78, blue: 0.35)
        case .herdr: Color(red: 0.35, green: 0.78, blue: 0.98)
        }
    }

    var shortName: String { self == .claude ? "Claude" : rawValue }
    var symbolName: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .herdr: "circle.hexagongrid.fill"
        }
    }

    var installed: Bool { self != .herdr }

    /// The id string `agentd`/`agent-adapters::discover_specs()` actually
    /// uses on the wire — distinct from `rawValue`, which is display text.
    var agentId: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .herdr: "herdr"
        }
    }
}

enum SessionStatus: String, Codable {
    case waiting = "待审批"
    case running = "运行中"
    case done = "已完成"
    case cancelled = "已取消"

    var tint: Color {
        switch self {
        case .waiting: .orange
        case .running: .blue
        case .done: .green
        case .cancelled: .secondary
        }
    }
}

struct ProjectItem: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    var path: String
    var agent: AgentKind
    /// Default so plain memberwise construction keeps working everywhere
    /// it's already called; `decodeIfPresent` so old saved JSON missing
    /// this key still decodes instead of throwing.
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, name, path, agent, createdAt
    }

    init(id: String, name: String, path: String, agent: AgentKind, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.agent = agent
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        agent = try container.decode(AgentKind.self, forKey: .agent)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

enum SessionSource: String, Codable, CaseIterable {
    case cli = "CLI"
    case desktop = "桌面"
    case unknown = "未知"

    init(remoteValue: String?) {
        switch remoteValue {
        case "cli": self = .cli
        case "desktop": self = .desktop
        default: self = .unknown
        }
    }

    var symbolName: String {
        switch self {
        case .cli: "terminal"
        case .desktop: "desktopcomputer"
        case .unknown: "questionmark.circle"
        }
    }
}

enum SessionExecutionPolicy: String, CaseIterable, Codable, Identifiable {
    case readOnly = "只读"
    case workspace = "项目内读写"
    case fullAccess = "完全访问"
    var id: String { rawValue }
    var sandbox: String {
        switch self { case .readOnly: "read-only"; case .workspace: "workspace-write"; case .fullAccess: "danger-full-access" }
    }
    var approvalPolicy: String { self == .workspace ? "on-request" : "never" }
}

struct ChatSessionOptions: Codable, Hashable {
    var model: String? = nil
    var executionPolicy: SessionExecutionPolicy = .workspace
}

struct SessionItem: Identifiable, Hashable, Codable {
    let id: String
    var projectId: String
    var title: String
    var status: SessionStatus
    var detail: String
    var createdAt: Date = Date()
    /// Native process identity, independent of the durable Codex thread.
    /// Raw terminal uses the phone row ID as its start operation; structured
    /// chat starts one fresh app-server per driver lifetime and resumes the
    /// persisted thread rather than reinitializing an existing process.
    var realProcessId: String?
    var realGeneration: String?
    /// Native Codex thread identity; independent of the phone row and process.
    var codexThreadId: String?
    var chatOptions: ChatSessionOptions?
    var source: SessionSource
    var isReadOnly: Bool { source == .desktop || ["Codex 对话", "Claude 对话"].contains(detail) }

    enum CodingKeys: String, CodingKey {
        case id, projectId, title, status, detail, createdAt, realProcessId, realGeneration, codexThreadId, chatOptions, source
    }

    init(
        id: String, projectId: String, title: String, status: SessionStatus, detail: String,
        createdAt: Date = Date(), realProcessId: String? = nil, realGeneration: String? = nil, source: SessionSource? = nil, codexThreadId: String? = nil, chatOptions: ChatSessionOptions? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.status = status
        self.detail = detail
        self.createdAt = createdAt
        self.realProcessId = realProcessId
        self.realGeneration = realGeneration
        self.codexThreadId = codexThreadId
        self.chatOptions = chatOptions
        self.source = source ?? Self.legacySource(detail)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(SessionStatus.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        realProcessId = try container.decodeIfPresent(String.self, forKey: .realProcessId)
        realGeneration = try container.decodeIfPresent(String.self, forKey: .realGeneration)
        codexThreadId = try container.decodeIfPresent(String.self, forKey: .codexThreadId)
        chatOptions = try container.decodeIfPresent(ChatSessionOptions.self, forKey: .chatOptions)
        source = try container.decodeIfPresent(SessionSource.self, forKey: .source) ?? Self.legacySource(detail)
    }

    private static func legacySource(_ detail: String) -> SessionSource {
        ["Codex 对话", "Claude 对话"].contains(detail) ? .desktop : .cli
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: String
    var sessionId: String
    var isUser: Bool
    var text: String
    var imageData: Data?
    var time: String
    // Optional for compatibility with saved single-image messages.
    var imageAttachments: [Data]? = nil
    var thinkingSummary: String? = nil
    var toolOutput: String? = nil
    var turnMetrics: ChatTurnMetrics? = nil
    var assistantPhase: String? = nil
    var executionStep: ChatExecutionStep? = nil

    var images: [Data] { imageAttachments ?? imageData.map { [$0] } ?? [] }
}

struct ApprovalItem: Identifiable, Hashable, Codable {
    let id: String
    var sessionId: String
    var title: String
    var kind: String
    var target: String
    var detail: String
    var pending: Bool
    var approved: Bool?
}

enum Route: Hashable {
    case approvals
    case approval(String)
    case project(String)
    case session(projectId: String, sessionId: String?)
    case terminal(String)
    case addProject(editing: String?)
    case settings
    case devices
}

@MainActor
@Observable
final class AppStore {
    private(set) var devices: [PairedMac] = []
    private(set) var selectedDeviceID: String?
    private var runtimes: [String: DeviceRuntime] = [:]
    private var networkFailures: [String: String] = [:]
    private var orphanedWorkspace = DeviceWorkspace()
    private let storage: DeviceStorage
    private let connectionFactory: ((String) -> any DeviceTransport)?
    private let credentials: any RelayCredentialStore
    private let pairingOperation: ((String, String, String, String, String) async -> PairOutcome)?
    private let networkPairingOperation: ((String, String, String, String, String, PeerNetworkConfig) async -> PairOutcome)?
    private var storageWritable = true
    private var foreground = true
    private var healthTask: Task<Void, Never>?
    private var pairingGeneration = UUID()
    private(set) var pairingSuccessID: UUID?
    private let catalogNow: () -> Date
    private struct CatalogKey: Hashable {
        var deviceID: String
        var agentID: String
    }
    private struct CatalogLoad {
        var id: UUID
        var generation: UUID
        var task: Task<Bool, Never>
    }
    private var catalogLoads: [CatalogKey: CatalogLoad] = [:]
    private struct ChatKey: Hashable { var deviceID: String; var sessionID: String }
    @MainActor @Observable fileprivate final class ChatRuntime {
        let driver: any CodexChatDriving
        var busy = false
        var blocked = false
        var error: String?
        var started = false
        var starting = false
        var bridge: BridgeConnection?
        var recoveryNeeded = false
        var recovering = false
        var recoveryExhausted = false
        var recoveryAttempt = 0
        var recoveryGeneration = UUID()
        var recoveryTask: Task<Void, Never>?
        var approvalRequests: [String: String] = [:]
        var pendingMetricSteps: [String: [ChatExecutionStep]] = [:]
        var deciding: Set<String> = []
        init(driver: any CodexChatDriving, bridge: BridgeConnection?) { self.driver = driver; self.bridge = bridge }
        func close() {
            recoveryGeneration = UUID()
            recoveryTask?.cancel()
            recoveryTask = nil
            driver.onEvent = nil
            driver.close()
        }
    }
    private var chats: [ChatKey: ChatRuntime] = [:]
    private var chatPersistenceTask: Task<Void, Never>?
    private struct ChatConnectionRecovery {
        var id: UUID
        var task: Task<Bool, Never>
    }
    private var chatConnectionRecoveries: [String: ChatConnectionRecovery] = [:]
    /// Injectable binding for state tests; production always uses the selected
    /// device runtime's existing authenticated connection.
    private let chatFactory: ((String) -> (any CodexChatDriving, BridgeConnection))?

    var toast: String?
    var storageError: String?
    var notifyApproval = true
    var notifyDone = true
    var notifyOnMac = false
    var notifyFailed = true

    var paired: Bool { selectedDeviceID != nil }
    var hostName: String { devices.first { $0.id == selectedDeviceID }?.displayName ?? "" }
    var online: Bool { connectionState == .connected }
    var connectionState: ConnectionState? { selectedDeviceID.flatMap { runtimes[$0]?.state } }
    var macAgents: [AgentInfo] { selectedDeviceID.flatMap { runtimes[$0]?.agents } ?? [] }
    var macBridge: BridgeConnection? {
        selectedDeviceID.flatMap { runtimes[$0]?.transport as? BridgeConnection }
    }

    private var workspace: DeviceWorkspace {
        get { devices.first { $0.id == selectedDeviceID }?.workspace ?? orphanedWorkspace }
        set {
            if let index = devices.firstIndex(where: { $0.id == selectedDeviceID }) {
                devices[index].workspace = newValue
            } else { orphanedWorkspace = newValue }
        }
    }
    var selectedAgent: AgentKind {
        get { workspace.selectedAgent }
        set { workspace.selectedAgent = newValue; persist() }
    }
    var currentProjectID: String? { currentProject(for: selectedAgent)?.id }

    func currentProject(for agent: AgentKind) -> ProjectItem? {
        let saved = workspace.selectedProjectIDs?[agent.rawValue]
        return projects.first { $0.agent == agent && $0.id == saved }
            ?? projects.filter { $0.agent == agent }.sorted { $0.createdAt > $1.createdAt }.first
    }

    func selectProject(_ id: String) {
        guard let item = project(id) else { return }
        var selections = workspace.selectedProjectIDs ?? [:]
        selections[item.agent.rawValue] = id
        workspace.selectedProjectIDs = selections
        selectedAgent = item.agent
    }
    var projects: [ProjectItem] { get { workspace.projects } set { workspace.projects = newValue } }
    var sessions: [SessionItem] { get { workspace.sessions } set { workspace.sessions = newValue } }
    var messages: [ChatMessage] { get { workspace.messages } set { workspace.messages = newValue } }
    var approvals: [ApprovalItem] { get { workspace.approvals } set { workspace.approvals = newValue } }
    var permission: String { get { workspace.permission } set { workspace.permission = newValue } }

    var connectionStateLabel: String { selectedDeviceID.map { connectionLabel(for: $0) } ?? "未配对" }
    var connectionSummary: String { paired ? "已配对 · \(connectionStateLabel)" : "未配对" }

    func connectionLabel(for id: String) -> String {
        guard devices.first(where: { $0.id == id })?.endpointID != nil else { return "请重新扫码连接" }
        if let failure = networkFailures[id] { return failure }
        switch runtimes[id]?.state {
        case .connected:
            switch runtimes[id]?.pathKind {
            case "direct": return "在线 · 直连"
            case "relay": return "在线 · 中继"
            default: return "在线"
            }
        case .connecting: return "连接中…"
        case .disconnected: return "离线"
        case .failed(let code, let message): return Self.localizedPairError(code: code, message: message)
        case .idle, nil: return "等待连接"
        }
    }
    func isOnline(_ id: String) -> Bool { runtimes[id]?.state == .connected }

    init(
        storage: DeviceStorage = DeviceStorage(),
        autoConnect: Bool = true,
        connectionFactory: ((String) -> any DeviceTransport)? = nil,
        pairingOperation: ((String, String, String, String, String) async -> PairOutcome)? = nil,
        credentials: (any RelayCredentialStore)? = nil,
        catalogNow: @escaping () -> Date = Date.init,
        chatFactory: ((String) -> (any CodexChatDriving, BridgeConnection))? = nil,
        networkPairingOperation: ((String, String, String, String, String, PeerNetworkConfig) async -> PairOutcome)? = nil
    ) {
        self.storage = storage
        self.catalogNow = catalogNow
        self.chatFactory = chatFactory
        self.connectionFactory = connectionFactory
        self.pairingOperation = pairingOperation
        self.credentials = credentials ?? KeychainRelayCredentials()
        self.networkPairingOperation = networkPairingOperation
        foreground = autoConnect
        do {
            let saved = try storage.load()
            devices = saved.devices
            selectedDeviceID = saved.selectedDeviceID
            orphanedWorkspace = saved.orphanedWorkspace ?? DeviceWorkspace()
            notifyApproval = saved.notifyApproval
            notifyDone = saved.notifyDone
            notifyOnMac = saved.notifyOnMac
            notifyFailed = saved.notifyFailed
        } catch {
            storageWritable = false
            storageError = "无法读取设备记录，原文件已保留。请先备份并检查数据后重试。"
        }
        if autoConnect { reconnectIfNeeded() }
    }

    func selectDevice(_ id: String) {
        guard devices.contains(where: { $0.id == id }), id != selectedDeviceID else { return }
        let previous = selectedDeviceID
        selectedDeviceID = id
        if !persist() { selectedDeviceID = previous }
        // Selection never replaces or disconnects another device's transport.
    }

    func refreshMacStatus() async {
        await withTaskGroup(of: Void.self) { group in
            for device in devices where device.endpointID != nil {
                group.addTask { @MainActor [weak self] in await self?.refreshDevice(device.id) }
            }
        }
    }

    private func refreshDevice(_ id: String) async {
        guard let device = devices.first(where: { $0.id == id }), let endpoint = device.endpointID else { return }
        let runtime: DeviceRuntime
        if let existing = runtimes[id] { runtime = existing }
        else {
            do {
                let transport: any DeviceTransport
                if let connectionFactory { transport = connectionFactory(endpoint) }
                else if let network = try networkConfig(for: device) {
                    transport = try BridgeConnection.withNetwork(keyPath: Self.irohKeyPath, endpointId: endpoint, network: network)
                } else { transport = BridgeConnection(keyPath: Self.irohKeyPath, endpointId: endpoint) }
                runtime = DeviceRuntime(transport: transport)
            } catch {
                networkFailures[id] = "中继配置或密钥不可用，请重新扫码"
                show("无法读取中继配置或密钥，请重新扫码更新此设备。")
                return
            }
            networkFailures[id] = nil
            runtimes[id] = runtime
        }
        guard !runtime.refreshing else { return }
        runtime.refreshing = true
        let generation = runtime.generation
        defer { if runtimes[id] === runtime && runtime.generation == generation { runtime.refreshing = false } }
        func isCurrent() -> Bool {
            !Task.isCancelled && runtimes[id] === runtime && runtime.generation == generation
        }
        let previouslyConnected = runtime.state == .connected
        let hadRpcFailures = runtime.rpcFailures > 0
        // Keep the actionable failure visible while automatic health checks
        // retry; repeatedly replacing it made an unreachable host look stuck.
        if runtime.state == .idle || runtime.state == .disconnected { runtime.state = .connecting }
        let state = await runtime.transport.connect()
        guard isCurrent() else { return }
        runtime.state = state
        guard state == .connected else { runtime.agents = []; return }
        do {
            try await runtime.transport.ping()
            guard isCurrent() else { return }
            runtime.rpcFailures = 0
            let path = await runtime.transport.pathKind()
            guard isCurrent() else { return }
            runtime.pathKind = path
            let agents = try await runtime.transport.listAgents()
            guard isCurrent() else { return }
            runtime.agents = agents
            resumeChats(deviceID: id, resetBudget: !previouslyConnected || hadRpcFailures)
            // Catalog I/O must not delay publishing the host's health or the next health check.
            Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime, self.runtimes[id] === runtime,
                      runtime.generation == generation else { return }
                await self.autoImportMacProjects(deviceID: id, runtime: runtime, agents: agents)
            }
        } catch {
            guard isCurrent() else { return }
            // A single slow ping on a relay path is not a dead link. Tearing
            // the iroh connection down here is what made devices look like
            // they drop every few seconds. Redial only after a second miss,
            // and keep the last agent list until that redial fails.
            runtime.rpcFailures += 1
            guard runtime.rpcFailures >= 2 else { return }
            runtime.rpcFailures = 0
            let redialed = await runtime.transport.reconnect()
            guard isCurrent() else { return }
            runtime.state = redialed
            if redialed == .connected {
                let path = await runtime.transport.pathKind()
                guard isCurrent() else { return }
                runtime.pathKind = path
                resumeChats(deviceID: id, resetBudget: true)
            }
            if redialed != .connected { runtime.agents = [] }
        }
    }

    func reconnectIfNeeded() {
        let enteredForeground = !foreground
        foreground = true
        resumeChats(resetBudget: enteredForeground)
        guard healthTask == nil else { return }
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.foreground else { return }
                await self.refreshMacStatus()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }

    func suspendHealthChecks() {
        if chatPersistenceTask != nil {
            chatPersistenceTask?.cancel()
            chatPersistenceTask = nil
            persist()
        }
        foreground = false
        for entry in chats.values {
            entry.recoveryGeneration = UUID()
            entry.recoveryTask?.cancel()
            entry.recoveryTask = nil
            if entry.recovering { entry.recoveryNeeded = true }
            entry.recovering = false
        }
        for recovery in chatConnectionRecoveries.values { recovery.task.cancel() }
        chatConnectionRecoveries.removeAll()
        healthTask?.cancel()
        healthTask = nil
        // Drop a refresh that is still in flight so its late result cannot
        // mark a device online after we left the foreground. Do not change
        // the visible state: `.inactive` also fires for the notification
        // shade, and forcing `.idle` there looked like a disconnect.
        for runtime in runtimes.values {
            runtime.generation = UUID()
            runtime.refreshing = false
        }
    }

    var canSend: Bool { permission == "完全访问" }
    var canApprove: Bool { permission != "仅查看" }

    func prune(retention: String) {
        let days: Int? = switch retention {
        case "3 天": 3
        case "7 天": 7
        case "30 天": 30
        default: nil
        }
        guard let days else { return }
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let stale = Set(sessions.filter { $0.createdAt < cutoff }.map(\.id))
        guard !stale.isEmpty else { return }
        for key in chats.keys.filter({ $0.deviceID == selectedDeviceID && stale.contains($0.sessionID) }) {
            chats.removeValue(forKey: key)?.close()
        }
        sessions.removeAll { stale.contains($0.id) }
        messages.removeAll { stale.contains($0.sessionId) }
        approvals.removeAll { stale.contains($0.sessionId) }
        persist()
    }

    func cancelPending(sessionId: String) {
        if isRemoteChatSession(sessionId: sessionId) { stopSession(id: sessionId); return }
        let pending = approvals.filter { $0.sessionId == sessionId && $0.pending }
        guard !pending.isEmpty else {
            show("没有待处理的任务")
            return
        }
        for item in pending {
            resolve(item.id, approved: false)
        }
        show("已取消当前任务")
    }

    func stopSession(id: String) {
        if isRemoteChatSession(sessionId: id), let deviceID = selectedDeviceID {
            let key = ChatKey(deviceID: deviceID, sessionID: id)
            guard let entry = chats[key], entry.started, entry.busy || entry.driver.isTurnBusy else {
                show("当前没有可中断的远程任务。")
                return
            }
            Task {
                do {
                    try await entry.driver.interrupt()
                    guard self.chats[key] === entry else { return }
                    self.updateChat(key) { workspace, index in workspace.sessions[index].detail = "已请求 Codex 停止，等待确认…" }
                } catch {
                    let unknown: Bool
                    if case CodexChatError.deliveryUnknown = error { unknown = true }
                    else { unknown = entry.driver.isDeliveryUncertain }
                    self.failChat(error, key: key, entry: entry, unknown: unknown)
                }
            }
            return
        }
        guard let index = sessions.firstIndex(where: { $0.id == id }), !sessions[index].isReadOnly else { return }
        for offset in approvals.indices where approvals[offset].sessionId == id && approvals[offset].pending {
            approvals[offset].pending = false
            approvals[offset].approved = false
        }
        sessions[index].status = .cancelled
        sessions[index].detail = "已停止"
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: id, isUser: false, text: "会话已停止。未批准的操作不会执行。", imageData: nil, time: Self.clock.string(from: Date())))
        persist()
        show("已停止会话")
    }

    func deleteSession(id: String) {
        if let deviceID = selectedDeviceID {
            chats.removeValue(forKey: ChatKey(deviceID: deviceID, sessionID: id))?.close()
        }
        sessions.removeAll { $0.id == id }
        messages.removeAll { $0.sessionId == id }
        approvals.removeAll { $0.sessionId == id }
        persist()
        show("已删除会话记录")
    }

    func unpair() {
        guard let id = selectedDeviceID else { return }
        removeDevice(id)
    }

    func removeDevice(_ id: String) {
        guard devices.contains(where: { $0.id == id }) else { return }
        let previousDevices = devices
        let previousSelection = selectedDeviceID
        devices.removeAll { $0.id == id }
        if selectedDeviceID == id { selectedDeviceID = devices.first?.id }
        guard persist() else {
            devices = previousDevices
            selectedDeviceID = previousSelection
            return
        }
        removeUnusedCredentials(from: previousDevices)
        chatConnectionRecoveries.removeValue(forKey: id)?.task.cancel()
        for key in chats.keys.filter({ $0.deviceID == id }) {
            chats.removeValue(forKey: key)?.close()
        }
        if let runtime = runtimes.removeValue(forKey: id) {
            runtime.generation = UUID()
            Task { await runtime.transport.disconnect() }
        }
        show("已移除设备，其他连接不受影响")
    }

    func save() { persist() }

    var pendingCount: Int { approvals.filter(\.pending).count }

    func projects(for agent: AgentKind, query: String) -> [ProjectItem] {
        projects.filter { item in
            item.agent == agent &&
            (query.isEmpty || item.name.localizedCaseInsensitiveContains(query) || item.path.localizedCaseInsensitiveContains(query))
        }
    }

    func sessions(for projectId: String) -> [SessionItem] {
        sessions.filter { $0.projectId == projectId }
    }

    func pendingCount(projectId: String) -> Int {
        let ids = Set(sessions(for: projectId).map(\.id))
        return approvals.filter { ids.contains($0.sessionId) && $0.pending }.count
    }

    func clearHistory() {
        for key in chats.keys.filter({ $0.deviceID == selectedDeviceID }) {
            chats.removeValue(forKey: key)?.close()
        }
        messages.removeAll()
        sessions.removeAll()
        approvals.removeAll()
        persist()
        show("已清除会话历史")
    }

    func project(_ id: String) -> ProjectItem? { projects.first { $0.id == id } }

    func send(sessionId: String, text: String, image: Data?) {
        send(sessionId: sessionId, text: text, images: image.map { [$0] } ?? [])
    }

    func send(sessionId: String, text: String, images: [Data]) {
        if usesRemoteChat {
            let deviceID = selectedDeviceID
            Task { await sendMessage(sessionId: sessionId, text: text, images: images, deviceID: deviceID) }
            return
        }
        sendMock(sessionId: sessionId, text: text, images: images)
    }

    private func sendMock(sessionId: String, text: String, images: [Data]) {
        guard canSend, let row = sessions.first(where: { $0.id == sessionId }),
              !row.isReadOnly, project(row.projectId) != nil,
              images.count <= ChatAttachment.maximumCount,
              images.allSatisfy({ ChatAttachment.isValid($0) }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return }
        let stamp = Self.clock.string(from: Date())
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: true, text: text, imageData: images.first, time: stamp, imageAttachments: images))
        let workspace = sessions.first { $0.id == sessionId }.flatMap { self.project($0.projectId) }
        let directory = workspace?.path ?? "当前项目"
        let request = text.isEmpty ? "请查看附图" : text
        let reply = "已在本机记录：\(request)。\n\n当前聊天发送为本地模拟，文字和图片尚未传给 Mac。你可以在终端页单独启动项目的真实 Agent 进程。"
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: false, text: reply, imageData: nil, time: stamp))
        let runsCommand = text.contains("运行") || text.contains("命令") || text.localizedCaseInsensitiveContains("test")
        approvals.append(ApprovalItem(
            id: UUID().uuidString,
            sessionId: sessionId,
            title: runsCommand ? "运行命令" : "写入 \(directory)",
            kind: runsCommand ? "工具调用 · 执行命令" : "工具调用 · 写入文件",
            target: runsCommand ? text : directory,
            detail: runsCommand ? "批准后才会把这条命令记为可执行。当前没有连上桌面进程，不会真的在 Mac 上运行。" : "批准后才会把这次修改记为允许。当前没有连上桌面进程，不会真的改 Mac 上的文件。",
            pending: true,
            approved: nil
        ))
        if let index = sessions.firstIndex(where: { $0.id == sessionId }) {
            let waiting = approvals.filter { $0.sessionId == sessionId && $0.pending }.count
            sessions[index].status = .waiting
            sessions[index].detail = "进行中 · \(waiting) 个待审批"
        }
        persist()
    }

    var usesRemoteChat: Bool {
        devices.first(where: { $0.id == selectedDeviceID })?.endpointID != nil
    }

    func isRemoteChatSession(sessionId: String) -> Bool {
        usesRemoteChat && sessions.contains { row in
            row.id == sessionId && !row.isReadOnly && project(row.projectId)?.agent == .codex
        }
    }

    func isChatBusy(sessionId: String) -> Bool {
        guard let deviceID = selectedDeviceID else { return false }
        guard let entry = chats[ChatKey(deviceID: deviceID, sessionID: sessionId)] else { return false }
        return entry.busy || entry.recoveryNeeded || entry.recovering
    }

    func isChatSendBlocked(sessionId: String) -> Bool {
        guard let deviceID = selectedDeviceID,
              let entry = chats[ChatKey(deviceID: deviceID, sessionID: sessionId)] else { return false }
        // A failed initializer permits deliberate retry. A submitted turn
        // with uncertain outcome stays fenced until native evidence settles it.
        return entry.started && entry.blocked
    }

    func chatError(sessionId: String) -> String? {
        guard let deviceID = selectedDeviceID else { return nil }
        return chats[ChatKey(deviceID: deviceID, sessionID: sessionId)]?.error
    }

    func chatRecoveryLabel(sessionId: String) -> String? {
        guard let deviceID = selectedDeviceID,
              let entry = chats[ChatKey(deviceID: deviceID, sessionID: sessionId)] else { return nil }
        if entry.recovering { return "正在恢复 Mac 连接（第 \(max(1, entry.recoveryAttempt)) 次）…" }
        if entry.recoveryNeeded { return entry.recoveryExhausted ? "自动重连已暂停，可以手动重试。" : "连接中断，等待恢复…" }
        return nil
    }

    func isChatRecovering(sessionId: String) -> Bool {
        guard let deviceID = selectedDeviceID else { return false }
        return chats[ChatKey(deviceID: deviceID, sessionID: sessionId)]?.recovering == true
    }

    func retryChatConnection(sessionId: String) {
        guard let deviceID = selectedDeviceID,
              let entry = chats[ChatKey(deviceID: deviceID, sessionID: sessionId)] else { return }
        startChatRecovery(key: ChatKey(deviceID: deviceID, sessionID: sessionId), entry: entry, manual: true)
    }

    private func resumeChats(deviceID: String? = nil, resetBudget: Bool = false) {
        guard foreground else { return }
        for (key, entry) in chats where deviceID == nil || key.deviceID == deviceID {
            if entry.driver.recoveryState == .recoveryNeeded { entry.recoveryNeeded = true }
            if resetBudget, entry.recoveryNeeded, entry.driver.recoveryState != .blocked {
                entry.recoveryExhausted = false
                entry.recoveryAttempt = 0
            }
            if entry.recoveryNeeded { startChatRecovery(key: key, entry: entry) }
        }
    }

    private func startChatRecovery(key: ChatKey, entry: ChatRuntime, manual: Bool = false) {
        guard foreground, chats[key] === entry, (entry.started || entry.starting), entry.recoveryNeeded,
              !entry.recovering, entry.recoveryTask == nil, manual || !entry.recoveryExhausted else { return }
        if manual { entry.recoveryExhausted = false; entry.recoveryAttempt = 0 }
        let generation = UUID()
        entry.recoveryGeneration = generation
        entry.recovering = true
        entry.blocked = true
        entry.recoveryTask = Task { @MainActor [weak self, weak entry] in
            guard let self, let entry else { return }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.foreground && self.chats[key] === entry && entry.recoveryGeneration == generation
            }
            defer {
                if entry.recoveryGeneration == generation { entry.recovering = false; entry.recoveryTask = nil }
            }
            for attempt in 0..<4 {
                guard isCurrent() else { return }
                entry.recoveryAttempt = attempt + 1
                if attempt > 0 {
                    do { try await Task.sleep(for: .seconds(Double(1 << (attempt - 1)))) } catch { return }
                }
                guard isCurrent(), let bridge = entry.bridge else { return }
                do {
                    if self.chatFactory == nil, !(await self.ensureChatHost(deviceID: key.deviceID)) {
                        throw CodexChatError.unavailable("暂时无法连接 Mac，请检查两端网络。")
                    }
                    guard isCurrent() else { return }
                    if entry.driver.recoveryState != .connected || entry.driver.isDeliveryUncertain {
                        try await entry.driver.recover(bridge: bridge)
                    }
                    guard isCurrent() else { return }
                    guard entry.driver.recoveryState == .connected else {
                        throw CodexChatError.unavailable("恢复连接时再次断开，请稍候重试。")
                    }
                    self.finishChatRecovery(key: key, entry: entry)
                    return
                } catch {
                    guard isCurrent() else { return }
                    if entry.driver.recoveryState == .blocked {
                        entry.recoveryNeeded = false
                        self.failChat(error, key: key, entry: entry, unknown: entry.driver.isDeliveryUncertain)
                        entry.blocked = true
                        return
                    }
                    entry.error = "重连暂未成功，正在等待下一次尝试。"
                    self.updateChat(key) { workspace, index in workspace.sessions[index].detail = entry.error! }
                }
            }
            guard isCurrent() else { return }
            entry.recoveryExhausted = true
            entry.error = "暂时无法恢复 Mac 连接。请检查网络后点「重试连接」；不会重复发送任务。"
            self.updateChat(key) { workspace, index in workspace.sessions[index].detail = entry.error! }
        }
    }

    /// Coalesce host redial across several chats on the same Mac. Reattaching
    /// chat A must not repeatedly tear down a connection chat B just recovered.
    private func ensureChatHost(deviceID: String) async -> Bool {
        if let existing = chatConnectionRecoveries[deviceID] { return await existing.task.value }
        guard let runtime = runtimes[deviceID] else { return false }
        let generation = runtime.generation
        let id = UUID()
        let task = Task { @MainActor [weak self, weak runtime] in
            guard let self, let runtime else { return false }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && self.foreground && self.runtimes[deviceID] === runtime && runtime.generation == generation
            }
            let connected = await runtime.transport.connect()
            guard isCurrent() else { return false }
            if connected == .connected {
                do { try await runtime.transport.ping(); if isCurrent() { runtime.state = .connected; return true } }
                catch { /* A stale connection needs one shared redial. */ }
            }
            guard isCurrent() else { return false }
            let redialed = await runtime.transport.reconnect()
            guard isCurrent() else { return false }
            runtime.state = redialed
            guard redialed == .connected else { return false }
            do { try await runtime.transport.ping(); return isCurrent() }
            catch { return false }
        }
        chatConnectionRecoveries[deviceID] = ChatConnectionRecovery(id: id, task: task)
        let result = await task.value
        if chatConnectionRecoveries[deviceID]?.id == id { chatConnectionRecoveries[deviceID] = nil }
        return result
    }

    private func finishChatRecovery(key: ChatKey, entry: ChatRuntime) {
        guard foreground, chats[key] === entry, entry.driver.recoveryState == .connected else { return }
        entry.recoveryNeeded = false
        entry.recovering = false
        entry.recoveryExhausted = false
        entry.busy = entry.starting || entry.driver.isTurnBusy
        entry.blocked = entry.driver.isDeliveryUncertain
        entry.error = entry.blocked ? "已恢复连接，先前发送结果仍待确认；请勿重复发送。" : nil
        updateChat(key) { workspace, index in
            let pending = workspace.approvals.contains { $0.sessionId == key.sessionID && $0.pending }
            workspace.sessions[index].status = pending ? .waiting : (entry.busy ? .running : .done)
            workspace.sessions[index].detail = entry.error ?? (pending ? "Codex 正在等待你的审批" : (entry.busy ? "已恢复连接，Codex 正在回复…" : "Mac 连接已恢复"))
        }
    }

    /// A true result clears the composer: either acknowledged, or delivery is
    /// explicitly unknown and retained in history. Unknown turns are never replayed.
    @discardableResult
    func sendMessage(sessionId: String, text: String, images: [Data], deviceID: String? = nil) async -> Bool {
        guard let deviceID = deviceID ?? selectedDeviceID,
              let device = devices.first(where: { $0.id == deviceID }) else { return false }
        if device.endpointID == nil {
            guard selectedDeviceID == deviceID else { return false }
            let before = messages.count
            sendMock(sessionId: sessionId, text: text, images: images)
            return messages.count > before
        }
        guard storageWritable, device.workspace.permission == "完全访问",
              let row = device.workspace.sessions.first(where: { $0.id == sessionId }), !row.isReadOnly,
              let project = device.workspace.projects.first(where: { $0.id == row.projectId }) else { return false }
        guard project.agent == .codex else {
            show("远程聊天目前支持 Codex，请切换到 Codex 项目。")
            return false
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty else { return false }
        guard text.utf8.count <= 128 * 1024 else {
            show("消息为空或过长，请缩短后重试。")
            return false
        }
        let key = ChatKey(deviceID: deviceID, sessionID: sessionId)
        // Initialization never submits a turn. A deliberate next tap may
        // replace that failed connection after login/path/network is corrected.
        // Retain entries that sent a turn: their unknown delivery stays fenced.
        if let existing = chats[key], !existing.started, !existing.busy, existing.error != nil {
            existing.close()
            chats.removeValue(forKey: key)
        }
        if let existing = chats[key], existing.busy || existing.blocked || existing.recoveryNeeded || existing.recovering {
            show(existing.blocked ? "连接状态不确定，请先检查 Mac 上的对话，避免重复发送。" : "请等待当前回复完成，或先停止任务。")
            return false
        }
        let entry: ChatRuntime
        var bridge: BridgeConnection?
        if let existing = chats[key] {
            entry = existing
        } else {
            let driver: any CodexChatDriving
            if let chatFactory {
                let binding = chatFactory(deviceID)
                driver = binding.0
                bridge = binding.1
            } else {
                guard let runtime = runtimes[deviceID], runtime.state == .connected,
                      let connection = runtime.transport as? BridgeConnection else {
                    show("Mac 当前离线，请连接后重试。")
                    return false
                }
                driver = CodexChatSession()
                bridge = connection
            }
            driver.configure(options: row.chatOptions ?? ChatSessionOptions())
            entry = ChatRuntime(driver: driver, bridge: bridge)
            chats[key] = entry
            driver.onEvent = { [weak self, weak entry] event in
                guard let self, let entry, self.chats[key] === entry else { return }
                self.receiveChatEvent(event, key: key, entry: entry)
            }
        }
        entry.busy = true
        entry.error = nil
        updateChat(key) { workspace, index in
            workspace.sessions[index].status = .running
            workspace.sessions[index].detail = entry.started ? "正在发送到 Mac…" : "正在启动 Mac 上的 Codex…"
        }
        let preparedImages: [Data]
        do {
            if !images.isEmpty {
                updateChat(key) { workspace, index in workspace.sessions[index].detail = "正在准备发送图片…" }
            }
            preparedImages = try await Task.detached(priority: .userInitiated) { try RemoteChatImage.prepare(images) }.value
            guard chats[key] === entry, !Task.isCancelled else { return false }
        } catch {
            failChat(CodexChatError.rejected(error.localizedDescription), key: key, entry: entry, unknown: false)
            return false
        }
        do {
            if !entry.started {
                guard let bridge else { throw CodexChatError.unavailable("Mac 连接已失效，请重新连接。") }
                // App termination loses in-memory byte/lease checkpoints. Do
                // not create a second app-server while the former one may
                // still execute this thread on the Mac.
                if let oldProcess = row.realProcessId, let oldGeneration = row.realGeneration {
                    do {
                        let previous = try await bridge.getProcessStatus(processId: oldProcess, generation: oldGeneration)
                        guard chats[key] === entry, !Task.isCancelled else { return false }
                        if ["running", "starting", "stopping"].contains(previous.state) {
                            throw CodexChatError.rejected("Mac 上的原 Codex 进程仍在运行。请先在 Mac 确认并停止，再重试，避免重复执行。")
                        }
                        guard ["exited", "stopped", "lost", "failed"].contains(previous.state) else {
                            throw CodexChatError.unavailable("无法确认 Mac 上原进程的状态，请先检查 Mac 后重试。")
                        }
                    } catch let error as BridgeError {
                        if case .Failed(let code, _) = error, code == "process_gone" { /* Host confirms the old identity is gone. */ }
                        else { throw error }
                    }
                }
                entry.starting = true
                defer { entry.starting = false }
                let info = try await entry.driver.start(bridge: bridge, operationId: UUID().uuidString,
                                                        cwd: project.path, threadId: row.codexThreadId)
                guard chats[key] === entry, devices.contains(where: { $0.id == deviceID }) else { entry.driver.close(); return false }
                entry.started = true
                setRealProcess(deviceID: deviceID, sessionId: sessionId, processId: info.processId, generation: info.generation)
            }
        } catch {
            failChat(error, key: key, entry: entry, unknown: false)
            entry.blocked = true
            return false
        }
        guard chats[key] === entry else { return false }
        if entry.driver.isTurnBusy || entry.driver.isDeliveryUncertain {
            entry.busy = entry.driver.isTurnBusy
            entry.blocked = entry.driver.isDeliveryUncertain
            updateChat(key) { workspace, index in
                workspace.sessions[index].status = .running
                workspace.sessions[index].detail = "已恢复 Mac 上的进行中任务，请等待完成后再发送。"
            }
            if selectedDeviceID == deviceID { show("Mac 上的这条对话仍有任务进行中，已恢复接收回复。") }
            return false
        }
        let userMessageID = UUID().uuidString
        entry.pendingMetricSteps.removeAll()
        updateChat(key) { workspace, _ in
            workspace.messages.append(ChatMessage(id: userMessageID, sessionId: sessionId, isUser: true,
                                                 text: text, imageData: preparedImages.first, time: Self.clock.string(from: Date()), imageAttachments: preparedImages))
        }
        do {
            try await entry.driver.send(text: text, images: preparedImages)
            guard chats[key] === entry else { return true }
            // A fast completion may arrive before the turn/start response.
            if entry.busy {
                updateChat(key) { workspace, index in workspace.sessions[index].detail = "Mac 上的 Codex 正在回复…" }
            }
            return true
        } catch {
            let unknown: Bool
            if case CodexChatError.deliveryUnknown = error { unknown = true } else { unknown = false }
            if !unknown {
                updateChat(key) { workspace, _ in workspace.messages.removeAll { $0.id == userMessageID } }
            }
            failChat(error, key: key, entry: entry, unknown: unknown)
            return unknown
        }
    }

    private func updateChat(_ key: ChatKey, persistNow: Bool = true, _ mutate: (inout DeviceWorkspace, Int) -> Void) {
        guard let deviceIndex = devices.firstIndex(where: { $0.id == key.deviceID }),
              let sessionIndex = devices[deviceIndex].workspace.sessions.firstIndex(where: { $0.id == key.sessionID }) else { return }
        mutate(&devices[deviceIndex].workspace, sessionIndex)
        if persistNow { persist() }
        else if chatPersistenceTask == nil {
            // Keep live text observable without rewriting all device histories
            // for every token; completion and foreground suspension flush now.
            chatPersistenceTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.chatPersistenceTask = nil
                self.persist()
            }
        }
    }

    private func failChat(_ error: Error, key: ChatKey, entry: ChatRuntime, unknown: Bool) {
        guard chats[key] === entry else { return }
        let recoverable = entry.driver.recoveryState == .recoveryNeeded || entry.driver.recoveryState == .recovering
        if !recoverable { entry.busy = false }
        entry.blocked = entry.blocked || unknown || recoverable
        let message: String
        if let codexError = error as? CodexChatError { message = codexError.localizedDescription }
        else if case let BridgeError.Failed(code, diagnostic) = error {
            message = Self.localizedPairError(code: code, message: diagnostic)
        } else { message = "远程 Codex 调用失败，请检查 Mac 的连接和登录状态。" }
        entry.error = message
        if recoverable {
            entry.recoveryNeeded = true
            updateChat(key) { workspace, index in workspace.sessions[index].detail = message }
            startChatRecovery(key: key, entry: entry)
        } else {
            updateChat(key) { workspace, index in
                workspace.sessions[index].status = .cancelled
                workspace.sessions[index].detail = message
                if let user = workspace.messages.lastIndex(where: { $0.sessionId == key.sessionID && $0.isUser }) {
                    workspace.messages[user].turnMetrics?.finished = true
                }
            }
        }
        if selectedDeviceID == key.deviceID { show(message) }
    }

    private func receiveChatEvent(_ event: CodexChatEvent, key: ChatKey, entry: ChatRuntime) {
        switch event {
        case .thread(let id):
            updateChat(key) { workspace, index in workspace.sessions[index].codexThreadId = id }
        case .turnStarted:
            entry.busy = true
        case .turnObserved(let id, let completed):
            updateTurnMetrics(key: key, turnID: id, allowBinding: true) { metrics in
                if completed {
                    metrics.finished = true
                    if metrics.completedAt == nil { metrics.completedAt = Date() }
                } else if metrics.startedAt == nil && metrics.completedAt == nil { metrics.startedAt = Date() }
                for step in entry.pendingMetricSteps[id] ?? [] { metrics.record(step) }
            }
            for step in entry.pendingMetricSteps[id] ?? [] { appendChatExecution(key: key, turnID: id, step: step) }
            entry.pendingMetricSteps.removeAll()
        case .turnAssociated(let id):
            updateTurnMetrics(key: key, turnID: id, allowBinding: true) { _ in }
        case .turnReconciled(let id):
            updateTurnMetrics(key: key, turnID: id) { $0.finished = true }
        case .executionStep(let turnID, let step):
            if updateTurnMetrics(key: key, turnID: turnID, update: { $0.record(step) }) {
                appendChatExecution(key: key, turnID: turnID, step: step)
            } else {
                entry.pendingMetricSteps[turnID, default: []].append(step)
            }
        case .assistantPhase(let itemId, let phase):
            updateAssistantMetadata(key: key, itemID: itemId, phase: phase)
        case .publicSummary(let itemId, let text):
            updateAssistantMetadata(key: key, itemID: "summary-" + itemId, summary: text)
        case .assistantDelta(let itemId, let text):
            appendChatText(key: key, itemID: itemId, text: text, completed: false)
        case .assistantCompleted(let itemId, let text):
            appendChatText(key: key, itemID: itemId, text: text, completed: true)
        case .turnCompleted(let status, let error):
            entry.busy = false
            entry.blocked = entry.driver.isDeliveryUncertain || entry.recoveryNeeded
            entry.error = error
            updateChat(key) { workspace, index in
                workspace.sessions[index].status = status == "completed" ? .done : .cancelled
                workspace.sessions[index].detail = error ?? (status == "completed" ? "Codex 回复完成" : "Codex 任务已停止")
                for i in workspace.approvals.indices where workspace.approvals[i].sessionId == key.sessionID && workspace.approvals[i].pending {
                    workspace.approvals[i].pending = false
                    workspace.approvals[i].approved = false
                }
            }
        case .approval(let request):
            guard !entry.approvalRequests.values.contains(request.requestId) else { return }
            let id = UUID().uuidString
            entry.approvalRequests[id] = request.requestId
            updateChat(key) { workspace, index in
                workspace.approvals.append(ApprovalItem(id: id, sessionId: key.sessionID, title: request.title,
                                                       kind: request.kind, target: request.target, detail: request.detail,
                                                       pending: true, approved: nil))
                workspace.sessions[index].status = .waiting
                workspace.sessions[index].detail = "Codex 正在等待你的审批"
            }
        case .approvalResolved(let requestId):
            guard let id = entry.approvalRequests.first(where: { $0.value == requestId })?.key else { return }
            updateChat(key) { workspace, _ in
                if let index = workspace.approvals.firstIndex(where: { $0.id == id }) { workspace.approvals[index].pending = false }
            }
        case .recoveryNeeded(let message):
            entry.recoveryNeeded = true
            entry.blocked = true
            entry.error = message
            updateChat(key) { workspace, index in workspace.sessions[index].detail = message }
            startChatRecovery(key: key, entry: entry)
        case .recovered:
            if foreground { finishChatRecovery(key: key, entry: entry) }
            else { entry.recoveryNeeded = true }
        case .failure(let error):
            let unknown: Bool
            if case .deliveryUnknown = error { unknown = true } else { unknown = false }
            failChat(error, key: key, entry: entry, unknown: unknown)
        }
    }

    private func updateAssistantMetadata(key: ChatKey, itemID: String, phase: String? = nil, summary: String? = nil) {
        let id = "codex-\(key.sessionID)-\(itemID)"
        updateChat(key) { workspace, _ in
            if !workspace.messages.contains(where: { $0.id == id }) {
                workspace.messages.append(ChatMessage(id: id, sessionId: key.sessionID, isUser: false,
                    text: "", imageData: nil, time: Self.clock.string(from: Date())))
            }
            guard let index = workspace.messages.firstIndex(where: { $0.id == id }) else { return }
            if let phase { workspace.messages[index].assistantPhase = phase }
            if let summary { workspace.messages[index].thinkingSummary = summary }
        }
    }

    private func appendChatExecution(key: ChatKey, turnID: String, step: ChatExecutionStep) {
        let id = "codex-\(key.sessionID)-tool-\(step.id)"
        updateChat(key) { workspace, _ in
            if let index = workspace.messages.firstIndex(where: { $0.id == id }) {
                let previous = workspace.messages[index].executionStep
                guard previous?.completed != true else { return }
                var updated = step
                updated.input = step.input ?? previous?.input
                updated.output = step.output ?? previous?.output
                workspace.messages[index].executionStep = updated
            } else {
                guard let user = workspace.messages.lastIndex(where: { $0.sessionId == key.sessionID && $0.isUser && $0.turnMetrics?.turnID == turnID }) else { return }
                let nextUser = workspace.messages.indices.first { $0 > user && workspace.messages[$0].sessionId == key.sessionID && workspace.messages[$0].isUser }
                var message = ChatMessage(id: id, sessionId: key.sessionID, isUser: false,
                    text: "", imageData: nil, time: Self.clock.string(from: Date()))
                message.executionStep = step
                workspace.messages.insert(message, at: nextUser ?? workspace.messages.endIndex)
            }
        }
    }

    @discardableResult
    private func updateTurnMetrics(key: ChatKey, turnID: String, allowBinding: Bool = false, update: (inout ChatTurnMetrics) -> Void) -> Bool {
        var recorded = false
        updateChat(key) { workspace, _ in
            let existing = workspace.messages.lastIndex { $0.sessionId == key.sessionID && $0.isUser && $0.turnMetrics?.turnID == turnID }
            let pending = workspace.messages.lastIndex { $0.sessionId == key.sessionID && $0.isUser }
            guard let index = existing ?? (allowBinding ? pending : nil),
                  workspace.messages[index].turnMetrics == nil || workspace.messages[index].turnMetrics?.turnID == turnID else { return }
            var metrics = workspace.messages[index].turnMetrics ?? ChatTurnMetrics(turnID: turnID)
            update(&metrics)
            workspace.messages[index].turnMetrics = metrics
            recorded = true
        }
        return recorded
    }

    private func appendChatText(key: ChatKey, itemID: String, text: String, completed: Bool) {
        let id = "codex-\(key.sessionID)-\(itemID)"
        updateChat(key, persistNow: completed) { workspace, _ in
            if let index = workspace.messages.firstIndex(where: { $0.id == id }) {
                if completed { workspace.messages[index].text = text }
                else { workspace.messages[index].text += text }
            } else {
                workspace.messages.append(ChatMessage(id: id, sessionId: key.sessionID, isUser: false,
                                                     text: text, imageData: nil, time: Self.clock.string(from: Date())))
            }
        }
    }

    func canConfigureUnsentSession(_ id: String) -> Bool {
        guard let row = sessions.first(where: { $0.id == id }), !row.isReadOnly,
              row.realProcessId == nil, row.codexThreadId == nil,
              !messages.contains(where: { $0.sessionId == id }) else { return false }
        if let deviceID = selectedDeviceID, let entry = chats[ChatKey(deviceID: deviceID, sessionID: id)] {
            return !entry.started && !entry.busy && !entry.driver.isDeliveryUncertain
                && !entry.recovering && !entry.recoveryNeeded
        }
        return true
    }

    func configureUnsentSession(_ id: String, projectID: String, options: ChatSessionOptions) -> Bool {
        guard canConfigureUnsentSession(id), canSend, project(projectID) != nil,
              let index = sessions.firstIndex(where: { $0.id == id }) else { return false }
        let previous = sessions[index]
        sessions[index].projectId = projectID
        sessions[index].chatOptions = options
        guard persist() else { sessions[index] = previous; return false }
        if let deviceID = selectedDeviceID {
            let key = ChatKey(deviceID: deviceID, sessionID: id)
            chats[key]?.close()
            chats.removeValue(forKey: key)
        }
        return true
    }

    func createSession(projectId: String, title: String, options: ChatSessionOptions? = nil) -> String {
        guard let project = project(projectId), project.agent.installed, canSend else { return "" }
        selectProject(projectId)
        let id = UUID().uuidString
        sessions.insert(SessionItem(id: id, projectId: projectId, title: title, status: .running, detail: usesRemoteChat ? "等待连接 Mac 上的 Codex" : "本地模拟 · 刚刚创建", source: .cli, chatOptions: options), at: 0)
        guard persist() else {
            sessions.removeAll { $0.id == id }
            return ""
        }
        return id
    }

    /// Records that a session now drives a real Mac process — called once
    /// after `TerminalSession.start(...)` succeeds.
    func setRealProcess(deviceID: String, sessionId: String, processId: String, generation: String) {
        guard let deviceIndex = devices.firstIndex(where: { $0.id == deviceID }),
              let index = devices[deviceIndex].workspace.sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        devices[deviceIndex].workspace.sessions[index].realProcessId = processId
        devices[deviceIndex].workspace.sessions[index].realGeneration = generation
        persist()
    }

    /// Read without network access so views can render persisted data immediately.
    func cachedMacProjects(deviceID: String, agent: AgentKind) -> [MacProject]? {
        devices.first { $0.id == deviceID }?.workspace.projectCatalogs?[agent.agentId]?.values
    }

    /// The single catalog boundary: fresh cache, coalesced refresh, and stale-on-error.
    @discardableResult
    func loadMacProjects(deviceID: String, agent: AgentKind, force: Bool = false) async -> [MacProject]? {
        guard let device = devices.first(where: { $0.id == deviceID }) else { return nil }
        if !force, let cache = device.workspace.projectCatalogs?[agent.agentId], cache.isFresh(at: catalogNow()) {
            return cache.values
        }
        guard let runtime = runtimes[deviceID], runtime.state == .connected else {
            if force { show("Mac 当前离线，已保留本地对话列表。") }
            return cachedMacProjects(deviceID: deviceID, agent: agent)
        }
        let key = CatalogKey(deviceID: deviceID, agentID: agent.agentId)
        let generation = runtime.generation
        let load: CatalogLoad
        if let existing = catalogLoads[key], existing.generation == generation {
            load = existing
        } else {
            let id = UUID()
            let task = Task { @MainActor [weak self, weak runtime] in
                guard let self, let runtime, self.runtimes[deviceID] === runtime,
                      runtime.generation == generation else { return false }
                do {
                    let projects = try await runtime.transport.listAgentProjects(agentId: agent.agentId)
                    guard !Task.isCancelled, self.runtimes[deviceID] === runtime,
                          runtime.generation == generation,
                          let index = self.devices.firstIndex(where: { $0.id == deviceID }) else { return false }
                    let previous = self.devices[index].workspace
                    let previousPaths = Set(previous.projectCatalogs?[agent.agentId]?.projects.map(\.path) ?? [])
                    self.applyMacProjects(projects, agent: agent, deviceIndex: index, previousPaths: previousPaths)
                    var catalogs = self.devices[index].workspace.projectCatalogs ?? [:]
                    catalogs[agent.agentId] = ProjectCatalogCache(fetchedAt: self.catalogNow(), projects: projects)
                    self.devices[index].workspace.projectCatalogs = catalogs
                    guard self.persist() else {
                        self.devices[index].workspace = previous
                        return false
                    }
                    return true
                } catch { return false }
            }
            load = CatalogLoad(id: id, generation: generation, task: task)
            catalogLoads[key] = load
        }
        let succeeded = await load.task.value
        if catalogLoads[key]?.id == load.id { catalogLoads[key] = nil }
        if !succeeded, force, !Task.isCancelled, selectedDeviceID == deviceID,
           runtimes[deviceID] === runtime, runtime.generation == generation {
            show("刷新失败，已保留本地对话列表，请稍后重试。")
        }
        return cachedMacProjects(deviceID: deviceID, agent: agent)
    }

    func refreshConversationList(agent: AgentKind, force: Bool = true) async {
        guard let deviceID = selectedDeviceID else { return }
        await loadMacProjects(deviceID: deviceID, agent: agent, force: force)
    }

    private func autoImportMacProjects(deviceID: String, runtime: DeviceRuntime, agents: [AgentInfo]) async {
        let generation = runtime.generation
        for kind in AgentKind.allCases {
            guard runtimes[deviceID] === runtime, runtime.generation == generation else { return }
            guard let agent = agents.first(where: { $0.id == kind.agentId }), agent.status != "not_found" else { continue }
            await loadMacProjects(deviceID: deviceID, agent: kind)
        }
    }

    /// Called only after a successful, generation-checked response. The caller persists
    /// this projection and the source catalog together, or rolls the workspace back.
    private func applyMacProjects(_ projects: [MacProject], agent kind: AgentKind, deviceIndex index: Int, previousPaths: Set<String>) {
        let incoming = Set(projects.map(\.path))

        // Drop rows this phone invented from the previous source (trusted
        // directories / session cwd), which are not Codex projects. Only
        // rows we auto-imported and that never grew a real process.
        let stale = devices[index].workspace.projects.filter { item in
            item.agent == kind && !incoming.contains(item.path)
                && (previousPaths.contains(item.path) || devices[index].workspace.sessions.contains { $0.projectId == item.id })
                && devices[index].workspace.sessions.filter { $0.projectId == item.id }.allSatisfy {
                    $0.realProcessId == nil && (
                        $0.detail == "从 Mac 导入" || $0.detail == "Codex 对话" || $0.detail == "Claude 对话"
                    )
                }
        }
        if !stale.isEmpty {
            let ids = Set(stale.map(\.id))
            let sessionIds = Set(devices[index].workspace.sessions.filter { ids.contains($0.projectId) }.map(\.id))
            devices[index].workspace.projects.removeAll { ids.contains($0.id) }
            devices[index].workspace.sessions.removeAll { ids.contains($0.projectId) }
            devices[index].workspace.messages.removeAll { sessionIds.contains($0.sessionId) }
            devices[index].workspace.approvals.removeAll { sessionIds.contains($0.sessionId) }
        }
        let marker = kind == .codex ? "Codex 对话" : "Claude 对话"
        for project in projects {
            let createdAt = project.lastSeen.flatMap { Self.parseRFC3339($0) } ?? Date()
            let title = Self.projectTitle(project)
            let projectId: String
            if let existing = devices[index].workspace.projects.firstIndex(where: {
                $0.path == project.path && $0.agent == kind
            }) {
                if project.lastSeen != nil, devices[index].workspace.projects[existing].createdAt != createdAt {
                    devices[index].workspace.projects[existing].createdAt = createdAt
                }
                if devices[index].workspace.projects[existing].name != title {
                    devices[index].workspace.projects[existing].name = title
                }
                projectId = devices[index].workspace.projects[existing].id
            } else {
                let item = ProjectItem(
                    id: UUID().uuidString, name: title, path: project.path, agent: kind, createdAt: createdAt
                )
                devices[index].workspace.projects.append(item)
                projectId = item.id
            }
            _ = syncThreads(project.threads, projectId: projectId, deviceIndex: index, marker: marker)
        }

        let projectIds = Set(devices[index].workspace.projects.filter { $0.agent == kind }.map(\.id))
        let fake = devices[index].workspace.sessions.filter {
            projectIds.contains($0.projectId) && $0.title == "默认会话" && $0.detail == "从 Mac 导入" && $0.realProcessId == nil
        }
        if !fake.isEmpty {
            let ids = Set(fake.map(\.id))
            devices[index].workspace.sessions.removeAll { ids.contains($0.id) }
        }
    }

    /// Keeps a project's conversation rows aligned with the Agent's own
    /// thread list. Ids are the Agent's thread ids, so a later refresh
    /// updates titles instead of inserting duplicates. Rows the user created
    /// in this app use a different `detail` and are left alone.
    private func syncThreads(_ threads: [MacThread], projectId: String, deviceIndex: Int, marker: String) -> Bool {
        var changed = false
        let incoming = Set(threads.map(\.id))
        let before = devices[deviceIndex].workspace.sessions.count
        devices[deviceIndex].workspace.sessions.removeAll {
            $0.projectId == projectId && $0.detail == marker && !incoming.contains($0.id)
        }
        if devices[deviceIndex].workspace.sessions.count != before { changed = true }
        for thread in threads {
            // Phone-created remote conversations already have a durable local
            // row. Catalog refresh must not add a second, read-only copy.
            if devices[deviceIndex].workspace.sessions.contains(where: {
                !$0.isReadOnly && $0.codexThreadId == thread.id
            }) { continue }
            let created = thread.updatedAt.flatMap { Self.parseRFC3339($0) } ?? Date()
            let source = SessionSource(remoteValue: thread.source)
            if let existing = devices[deviceIndex].workspace.sessions.firstIndex(where: { $0.id == thread.id }) {
                var row = devices[deviceIndex].workspace.sessions[existing]
                if row.title != thread.title || row.createdAt != created || row.projectId != projectId || row.detail != marker || row.source != source {
                    row.title = thread.title
                    row.createdAt = created
                    row.projectId = projectId
                    row.detail = marker
                    row.source = source
                    devices[deviceIndex].workspace.sessions[existing] = row
                    changed = true
                }
            } else {
                devices[deviceIndex].workspace.sessions.append(SessionItem(
                    id: thread.id, projectId: projectId, title: thread.title,
                    status: .done, detail: marker, createdAt: created, source: source
                ))
                changed = true
            }
        }
        return changed
    }

    func isApprovalSubmitting(_ id: String, sessionId: String) -> Bool {
        guard let deviceID = selectedDeviceID else { return false }
        return chats[ChatKey(deviceID: deviceID, sessionID: sessionId)]?.deciding.contains(id) == true
    }

    func resolve(_ id: String, approved: Bool) {
        if usesRemoteChat {
            guard canApprove, let deviceID = selectedDeviceID,
                  let approval = approvals.first(where: { $0.id == id && $0.pending }),
                  !sessions.contains(where: { $0.id == approval.sessionId && $0.isReadOnly }) else { return }
            let key = ChatKey(deviceID: deviceID, sessionID: approval.sessionId)
            guard let entry = chats[key], let requestID = entry.approvalRequests[id], !entry.deciding.contains(id) else {
                show("这条审批已失去连接，请在 Mac 上检查当前任务。")
                return
            }
            entry.deciding.insert(id)
            Task {
                defer { entry.deciding.remove(id) }
                do {
                    try await entry.driver.resolveApproval(requestId: requestID, approved: approved)
                    guard self.chats[key] === entry else { return }
                    self.updateChat(key) { workspace, sessionIndex in
                        if let i = workspace.approvals.firstIndex(where: { $0.id == id }) {
                            workspace.approvals[i].pending = false
                            workspace.approvals[i].approved = approved
                        }
                        let remaining = workspace.approvals.contains { $0.sessionId == key.sessionID && $0.pending }
                        if entry.busy {
                            workspace.sessions[sessionIndex].status = remaining ? .waiting : .running
                            workspace.sessions[sessionIndex].detail = approved ? "已批准，等待 Codex 继续…" : "已拒绝，等待 Codex 确认…"
                        }
                    }
                    if self.selectedDeviceID == deviceID { self.show(approved ? "已发送批准决定" : "已发送拒绝决定") }
                } catch {
                    let unknown: Bool
                    if case CodexChatError.deliveryUnknown = error { unknown = true }
                    else { unknown = entry.driver.isDeliveryUncertain }
                    self.failChat(error, key: key, entry: entry, unknown: unknown)
                }
            }
            return
        }
        guard let index = approvals.firstIndex(where: { $0.id == id }), approvals[index].pending,
              !sessions.contains(where: { $0.id == approvals[index].sessionId && $0.isReadOnly }) else { return }
        approvals[index].pending = false
        approvals[index].approved = approved
        let sessionId = approvals[index].sessionId
        let target = approvals[index].target
        let stamp = Self.clock.string(from: Date())
        let outcome = approved
            ? "已批准「\(target)」。决定已记在这台手机上。桌面 Agent 还没接上，所以 Mac 上的文件和进程没有变化。"
            : "已拒绝「\(target)」。不会执行。"
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: false, text: outcome, imageData: nil, time: stamp))
        if let sessionIndex = sessions.firstIndex(where: { $0.id == sessionId }) {
            let remaining = approvals.filter { $0.sessionId == sessionId && $0.pending }.count
            let rejected = approvals.contains { $0.sessionId == sessionId && $0.approved == false }
            sessions[sessionIndex].status = rejected ? .cancelled : (remaining > 0 ? .waiting : .done)
            sessions[sessionIndex].detail = rejected ? "请求已拒绝 · 已停止" : (remaining > 0 ? "进行中 · \(remaining) 个待审批" : "审批已完成")
        }
        persist()
        show(approved ? "已批准" : "已拒绝")
    }

    private func networkConfig(for device: PairedMac) throws -> PeerNetworkConfig? {
        guard let network = device.network else { return nil }
        let key = try network.credentialReference.flatMap { try credentials.read($0) }
        if network.credentialReference != nil && key == nil { throw RelayStorageError.missingCredential }
        return try validatePeerNetwork(network: PeerNetworkConfig(relayUrl: network.relayURL,
            relayAccessKey: key, directAddresses: network.directAddresses))
    }

    /// Delete superseded secrets only after their replacement record is durable.
    private func removeUnusedCredentials(from previousDevices: [PairedMac]) {
        let retained = Set(devices.compactMap { $0.network?.credentialReference })
        let previous = Set(previousDevices.compactMap { $0.network?.credentialReference })
        for reference in previous.subtracting(retained) {
            try? credentials.remove(reference)
        }
    }

    private func checkCredentialConflict(_ network: PeerNetworkConfig, replacingEndpointID: String? = nil) throws {
        guard let origin = network.relayUrl else { return }
        for device in devices where device.network?.relayURL == origin {
            let existing: PeerNetworkConfig?
            do {
                existing = try networkConfig(for: device)
            } catch RelayStorageError.missingCredential {
                // Re-scan can restore this target; pairing authenticates before persistence.
                // Other saved hosts and existing, different credentials still conflict.
                guard let replacingEndpointID, device.endpointID == replacingEndpointID else { throw RelayStorageError.conflict }
                continue
            }
            guard existing?.relayAccessKey == network.relayAccessKey else { throw RelayStorageError.conflict }
        }
    }

    func updateNetwork(deviceID: String, relayURL: String, accessKey: String) async -> Bool {
        guard storageWritable, pairingPhase == nil, let device = devices.first(where: { $0.id == deviceID }),
              let endpoint = device.endpointID else { return false }
        let generation = UUID()
        pairingGeneration = generation
        pairingPhase = "正在验证连接配置…"
        defer { if pairingGeneration == generation { pairingPhase = nil } }
        do {
            let old = try networkConfig(for: device)
            let hints = try validatePeerNetwork(network: PeerNetworkConfig(
                relayUrl: relayURL.isEmpty ? nil : relayURL, relayAccessKey: nil,
                directAddresses: old?.directAddresses ?? []))
            let retainedKey = hints.relayUrl == old?.relayUrl ? old?.relayAccessKey : nil
            let network = try validatePeerNetwork(network: PeerNetworkConfig(
                relayUrl: hints.relayUrl,
                relayAccessKey: hints.relayUrl == nil ? nil : (accessKey.isEmpty ? retainedKey : accessKey),
                directAddresses: hints.directAddresses))
            try checkCredentialConflict(network)
            // Verify candidate without replacing this or another host's runtime.
            let candidate = try BridgeConnection.withNetwork(keyPath: Self.irohKeyPath, endpointId: endpoint, network: network)
            guard await candidate.connect() == .connected else {
                await candidate.disconnect()
                show("无法连接，请检查网络后重新扫码。")
                return false
            }
            await candidate.disconnect()
            guard !Task.isCancelled, pairingGeneration == generation, devices.contains(where: { $0.id == deviceID }) else { return false }
            return finishPair(name: device.name, endpointId: endpoint, repairingDeviceID: deviceID, network: network)
        } catch RelayStorageError.conflict {
            show("连接配置与其他设备冲突，请联系中继管理员更新后重新扫码。")
        } catch {
            show("连接配置不可用，请在 Mac 上重新生成二维码并扫描。")
        }
        return false
    }

    func cancelPairing() {
        pairingGeneration = UUID()
        pairingPhase = nil
    }

    func pair(from payload: String, repairingDeviceID: String? = nil) async -> Bool {
        guard storageWritable else { show(storageError ?? "无法保存设备记录"); return false }
        guard pairingPhase == nil else { return false }
        let invitation: PairInvitation
        let network: PeerNetworkConfig?
        do {
            invitation = try PairInvitation.decode(payload)
            network = try invitation.network?.validated()
            if let network { try checkCredentialConflict(network, replacingEndpointID: invitation.endpointID) }
        } catch RelayStorageError.conflict {
            show("连接配置与其他设备冲突，请联系中继管理员更新后重新扫码。")
            return false
        } catch {
            show("配对码或中继信息无效，请在 Mac 上重新生成。")
            return false
        }
        let token = invitation.token
        let sessionId = invitation.sessionID ?? ""
        let endpointId = invitation.endpointID ?? ""
        let name = invitation.deviceName.flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        if let repairingDeviceID {
            guard devices.contains(where: { $0.id == repairingDeviceID && ($0.endpointID == nil || $0.endpointID == endpointId) }), !endpointId.isEmpty else {
                show("请扫描这台 Mac 的新版配对码")
                return false
            }
            guard !devices.contains(where: { $0.endpointID == endpointId && $0.id != repairingDeviceID }) else {
                show("这台 Mac 已在设备列表中，请扫描要恢复的电脑")
                return false
            }
        }
        let generation = UUID()
        pairingGeneration = generation
        pairingPhase = "正在连接 Mac，尝试直连或中继…"
        defer { if pairingGeneration == generation { pairingPhase = nil } }
        func stillPairing() -> Bool { pairingGeneration == generation && !Task.isCancelled }
        if !endpointId.isEmpty {
            let outcome: PairOutcome
            if let network, let networkPairingOperation {
                outcome = await networkPairingOperation(endpointId, sessionId, token, UIDevice.current.name, Self.irohKeyPath, network)
            } else if network == nil, let pairingOperation {
                outcome = await pairingOperation(endpointId, sessionId, token, UIDevice.current.name, Self.irohKeyPath)
            } else {
                let (stages, continuation) = AsyncStream<PairingStage>.makeStream()
                let observer = PairingProgressObserver(continuation: continuation)
                let updates = Task { @MainActor [weak self] in
                    for await stage in stages {
                        guard let self, self.pairingGeneration == generation, self.pairingPhase != nil,
                              !Task.isCancelled else { return }
                        self.pairingPhase = Self.pairingStageLabel(stage)
                    }
                }
                defer { continuation.finish(); updates.cancel() }
                outcome = await pairOverIrohWithProgress(endpointId: endpointId, sessionId: sessionId,
                    token: token, deviceName: UIDevice.current.name, keyPath: Self.irohKeyPath,
                    network: network ?? PeerNetworkConfig(relayUrl: nil, relayAccessKey: nil, directAddresses: []),
                    progress: observer)
            }
            guard stillPairing() else { return false }
            if outcome.ok && !outcome.pending { return finishPair(name: name, endpointId: endpointId, repairingDeviceID: repairingDeviceID, network: network) }
            show(Self.localizedPairError(code: outcome.errorCode, message: outcome.errorMessage))
            return false
        }
        show("这张配对码版本过旧，请更新 Mac 端并重新生成二维码。")
        return false
    }

    /// `pair_over_iroh`'s `errorMessage` is the Rust layer's English
    /// diagnostic text (e.g. "Could not reach the Mac. Check both
    /// networks."), never meant for display as-is in this Chinese UI.
    /// Map the stable `errorCode` to a Chinese message; fall back to a
    /// generic one (with the raw code, not the English message) for any
    /// code this hasn't been taught yet.
    /// Shared Rust-error-code → Chinese-string table. `internal` (not
    /// `private`) so `TerminalSession` can reuse it for `BridgeError` too —
    /// one table, not a second copy that drifts.
    static func pairingStageLabel(_ stage: PairingStage) -> String {
        switch stage {
        case .connecting: "正在连接 Mac，尝试直连或中继…"
        case .handshaking: "已连接 Mac，正在提交配对请求…"
        case .awaitingApproval: "Mac 已收到配对请求，请在 Mac 上确认。"
        }
    }

    static func localizedPairError(code: String, message: String) -> String {
        switch code {
        case "unreachable":
            return "连接不到这台 Mac，请检查两边网络是否正常，并确认 Mac 没有休眠。"
        case "connect_timeout":
            return "尚未连通 Mac，配对请求未确认送达。请确认 Mac 在线并检查两端网络后重新扫码。"
        case "approval_timeout":
            return "等待 Mac 确认超时，请在 Mac 重新打开配对窗口后扫码。"
        case "timeout":
            return "连接 Mac 超时，请检查网络后重试。"
        case "network_error":
            return "网络异常，手机暂时无法建立连接。"
        case "identity_error":
            return "读取手机身份信息失败，请重新打开 App 后再试。"
        case "relay_conflict":
            return "连接配置与其他设备冲突，请联系中继管理员更新后重新扫码。"
        case "invalid_network", "invalid_relay", "relay_config":
            return "中继配置无效，请在 Mac 更新后重新扫码。"
        case "invalid_params":
            return "二维码信息无效，请在 Mac 上重新生成并扫描。"
        case "incompatible":
            return "手机和 Mac 的版本不兼容，请把两边都更新到最新版本。"
        case "protocol_error":
            return "通信出现异常，请重新扫描二维码。"
        case "pairing_state", "unauthorized":
            return "配对邀请已失效或被取消，请在 Mac 上重新生成二维码。"
        default:
            return message.isEmpty ? "配对失败，请重试。" : "配对失败（\(code)），请重试。"
        }
    }

    @discardableResult
    private func finishPair(name: String, endpointId: String, repairingDeviceID: String?, network: PeerNetworkConfig?) -> Bool {
        var stagedReference: String?
        var savedNetwork: SavedPeerNetwork?
        do {
            if let network {
                if let key = network.relayAccessKey {
                    let reference = UUID().uuidString
                    try credentials.write(key, reference: reference)
                    stagedReference = reference
                }
                savedNetwork = SavedPeerNetwork(relayURL: network.relayUrl,
                    credentialReference: stagedReference, directAddresses: network.directAddresses)
            }
        } catch {
            show("无法安全保存中继密钥，请解锁手机后重试。")
            return false
        }
        var committed = false
        defer {
            if !committed, let stagedReference { try? credentials.remove(stagedReference) }
        }
        let before = devices
        let previous = selectedDeviceID
        let endpoint = endpointId.isEmpty ? nil : endpointId
        if let repairingDeviceID {
            guard let index = devices.firstIndex(where: { $0.id == repairingDeviceID && ($0.endpointID == nil || $0.endpointID == endpoint) }),
                  !devices.contains(where: { $0.endpointID == endpoint && $0.id != repairingDeviceID }) else { return false }
            devices[index].name = name
            devices[index].endpointID = endpoint
            selectedDeviceID = repairingDeviceID
        } else if let index = devices.firstIndex(where: { endpoint != nil && $0.endpointID == endpoint }) {
            devices[index].name = name
            selectedDeviceID = devices[index].id
        } else {
            let device = PairedMac(id: UUID().uuidString, name: name, endpointID: endpoint)
            devices.append(device)
            selectedDeviceID = device.id
        }
        if let savedNetwork, let index = devices.firstIndex(where: { $0.id == selectedDeviceID }) {
            devices[index].network = savedNetwork
        }
        guard persist() else {
            devices = before
            selectedDeviceID = previous
            return false
        }
        committed = true
        removeUnusedCredentials(from: before)
        if savedNetwork != nil, let id = selectedDeviceID, let old = runtimes.removeValue(forKey: id) {
            old.generation = UUID()
            Task { await old.transport.disconnect() }
        }
        if foreground { Task { @MainActor [weak self] in await self?.refreshMacStatus() } }
        pairingSuccessID = UUID()
        show("已配对 \(name)")
        return true
    }

    var pairingPhase: String?

    nonisolated private static var irohKeyPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let folder = base?.appendingPathComponent("AgentBridge", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("iroh-key").path
        }
        return NSTemporaryDirectory() + "iroh-key"
    }

    func addProject(name: String, path: String, agent: AgentKind) {
        let item = ProjectItem(id: UUID().uuidString, name: name, path: path, agent: agent)
        projects.append(item)
        selectProject(item.id)
        persist()
        show("已添加项目")
    }

    /// Import a project without inventing a conversation; its real histories
    /// arrive through syncThreads, local conversations begin with first send.
    @discardableResult
    func importMacProject(name: String, path: String, agent: AgentKind, createdAt: Date? = nil) -> String {
        let project = ProjectItem(
            id: UUID().uuidString, name: name, path: path, agent: agent, createdAt: createdAt ?? Date()
        )
        projects.append(project)
        selectProject(project.id)
        persist()
        show("已导入「\(name)」")
        return project.id
    }

    func updateProject(id: String, name: String, path: String, agent: AgentKind) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        projects[index].path = path
        projects[index].agent = agent
        selectedAgent = agent
        persist()
        show("已保存")
    }

    func deleteProject(id: String) {
        let sessionIds = Set(sessions.filter { $0.projectId == id }.map(\.id))
        for key in chats.keys.filter({ $0.deviceID == selectedDeviceID && sessionIds.contains($0.sessionID) }) {
            chats.removeValue(forKey: key)?.close()
        }
        projects.removeAll { $0.id == id }
        sessions.removeAll { $0.projectId == id }
        messages.removeAll { sessionIds.contains($0.sessionId) }
        approvals.removeAll { sessionIds.contains($0.sessionId) }
        persist()
        show("已删除项目")
    }

    func show(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if toast == text { toast = nil }
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard storageWritable else { return false }
        do {
            try storage.save(DeviceSnapshot(
                devices: devices, selectedDeviceID: selectedDeviceID,
                orphanedWorkspace: orphanedWorkspace,
                notifyApproval: notifyApproval, notifyDone: notifyDone,
                notifyOnMac: notifyOnMac, notifyFailed: notifyFailed
            ))
            return true
        } catch {
            show("设备记录保存失败，请检查可用空间后重试。")
            return false
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// RFC3339 from the daemon: chrono emits fractional seconds only when
    /// they're non-zero, so try both forms.
    static func parseRFC3339(_ string: String) -> Date? {
        iso8601Fractional.date(from: string) ?? iso8601Plain.date(from: string)
    }

    static func projectTitle(_ project: MacProject) -> String {
        if let name = project.name, !name.isEmpty { return name }
        return (project.path as NSString).lastPathComponent
    }

    private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Rust callbacks can arrive off-main; preserve stage order through one async stream.
private final class PairingProgressObserver: PairingProgressCallback {
    let continuation: AsyncStream<PairingStage>.Continuation
    init(continuation: AsyncStream<PairingStage>.Continuation) { self.continuation = continuation }
    func onStage(stage: PairingStage) { continuation.yield(stage) }
}

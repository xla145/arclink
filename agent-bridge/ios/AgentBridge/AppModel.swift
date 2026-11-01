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
}

struct SessionItem: Identifiable, Hashable, Codable {
    let id: String
    var projectId: String
    var title: String
    var status: SessionStatus
    var detail: String
    var createdAt: Date = Date()
    /// Set once `StartProcess` succeeds for this session; `operation_id` for
    /// that call is this session's own `id`, so re-sending it (app restart,
    /// repeated tap) is idempotent on the Mac rather than spawning a second
    /// process. `nil` means this session has never driven a real process —
    /// the terminal page falls back to its local mock replay.
    var realProcessId: String?
    var realGeneration: String?
    var source: SessionSource
    var isReadOnly: Bool { source == .desktop }

    enum CodingKeys: String, CodingKey {
        case id, projectId, title, status, detail, createdAt, realProcessId, realGeneration, source
    }

    init(
        id: String, projectId: String, title: String, status: SessionStatus, detail: String,
        createdAt: Date = Date(), realProcessId: String? = nil, realGeneration: String? = nil, source: SessionSource? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.status = status
        self.detail = detail
        self.createdAt = createdAt
        self.realProcessId = realProcessId
        self.realGeneration = realGeneration
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
    private var orphanedWorkspace = DeviceWorkspace()
    private let storage: DeviceStorage
    private let connectionFactory: (String) -> any DeviceTransport
    private let pairingOperation: (String, String, String, String, String) async -> PairOutcome
    private var storageWritable = true
    private var foreground = true
    private var healthTask: Task<Void, Never>?
    private var pairingGeneration = UUID()
    var toast: String?
    var storageError: String?
    var notifyApproval = true
    var notifyDone = true
    var notifyOnMac = false
    var notifyFailed = true

    var paired: Bool { selectedDeviceID != nil }
    var hostName: String { devices.first { $0.id == selectedDeviceID }?.name ?? "" }
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
        switch runtimes[id]?.state {
        case .connected: return "在线"
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
        connectionFactory: @escaping (String) -> any DeviceTransport = {
            BridgeConnection(keyPath: AppStore.irohKeyPath, endpointId: $0)
        },
        pairingOperation: @escaping (String, String, String, String, String) async -> PairOutcome = {
            await pairOverIroh(endpointId: $0, sessionId: $1, token: $2, deviceName: $3, keyPath: $4)
        }
    ) {
        self.storage = storage
        self.connectionFactory = connectionFactory
        self.pairingOperation = pairingOperation
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
            runtime = DeviceRuntime(transport: connectionFactory(endpoint))
            runtimes[id] = runtime
        }
        guard !runtime.refreshing else { return }
        runtime.refreshing = true
        let generation = runtime.generation
        defer { if runtimes[id] === runtime && runtime.generation == generation { runtime.refreshing = false } }
        func isCurrent() -> Bool {
            !Task.isCancelled && runtimes[id] === runtime && runtime.generation == generation
        }
        if runtime.state != .connected { runtime.state = .connecting }
        let state = await runtime.transport.connect()
        guard isCurrent() else { return }
        runtime.state = state
        guard state == .connected else { runtime.agents = []; return }
        do {
            try await runtime.transport.ping()
            guard isCurrent() else { return }
            runtime.rpcFailures = 0
            let agents = try await runtime.transport.listAgents()
            guard isCurrent() else { return }
            runtime.agents = agents
            await autoImportMacProjects(deviceID: id, runtime: runtime, agents: agents)
            guard isCurrent() else { return }
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
            if redialed != .connected { runtime.agents = [] }
        }
    }

    func reconnectIfNeeded() {
        foreground = true
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
        foreground = false
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
        sessions.removeAll { stale.contains($0.id) }
        messages.removeAll { stale.contains($0.sessionId) }
        approvals.removeAll { stale.contains($0.sessionId) }
        persist()
    }

    func cancelPending(sessionId: String) {
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
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
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

    func createSession(projectId: String, title: String) -> String {
        guard let project = project(projectId), project.agent.installed, canSend else { return "" }
        selectProject(projectId)
        let id = UUID().uuidString
        sessions.insert(SessionItem(id: id, projectId: projectId, title: title, status: .running, detail: "本地模拟 · 刚刚创建", source: .cli), at: 0)
        persist()
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

    /// Runs after every successful `listAgents` refresh: for each verified
    /// Agent, pulls its real on-disk project paths (`ListAgentProjects`)
    /// and creates a `ProjectItem` + default session for any not already
    /// present (matched by path+agent) — so the Home list reflects what's
    /// really on the Mac without a manual "导入" trip, and a repeat refresh
    /// never re-creates or duplicates what's already there.
    ///
    /// Writes `devices[deviceID]` directly rather than through the
    /// `workspace` computed property, which is keyed to `selectedDeviceID`
    /// — this runs for every device's own background refresh, not only the
    /// one currently on screen.
    private func autoImportMacProjects(deviceID: String, runtime: DeviceRuntime, agents: [AgentInfo]) async {
        for kind in AgentKind.allCases {
            guard let agent = agents.first(where: { $0.id == kind.agentId }),
                  agent.status != "not_found" else {
                print("[AutoImport] \(kind.agentId): skipped (not found in agents)")
                continue
            }
            guard !runtime.importedAgentIDs.contains(kind.agentId) else {
                print("[AutoImport] \(kind.agentId): skipped (already imported this session)")
                continue
            }
            runtime.importedAgentIDs.insert(kind.agentId)
            guard let projects = try? await runtime.transport.listAgentProjects(agentId: kind.agentId), !projects.isEmpty else {
                print("[AutoImport] \(kind.agentId): RPC returned empty or failed")
                continue
            }
            print("[AutoImport] \(kind.agentId): received \(projects.count) projects, total threads: \(projects.map(\.threads.count).reduce(0,+))")
            guard let index = devices.firstIndex(where: { $0.id == deviceID }) else { return }
            let incoming = Set(projects.map(\.path))
            var changed = 0
            // Drop rows this phone invented from the previous source (trusted
            // directories / session cwd), which are not Codex projects. Only
            // rows we auto-imported and that never grew a real process.
            let stale = devices[index].workspace.projects.filter { item in
                item.agent == kind && !incoming.contains(item.path)
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
                changed += stale.count
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
                        changed += 1
                    }
                    if devices[index].workspace.projects[existing].name != title {
                        devices[index].workspace.projects[existing].name = title
                        changed += 1
                    }
                    projectId = devices[index].workspace.projects[existing].id
                } else {
                    let item = ProjectItem(
                        id: UUID().uuidString, name: title, path: project.path, agent: kind, createdAt: createdAt
                    )
                    devices[index].workspace.projects.append(item)
                    projectId = item.id
                    changed += 1
                }
                if syncThreads(project.threads, projectId: projectId, deviceIndex: index, marker: marker) {
                    changed += 1
                }
            }
            if changed > 0 { persist() }
            let projectIds = Set(devices[index].workspace.projects.filter { $0.agent == kind }.map(\.id))
            let fake = devices[index].workspace.sessions.filter {
                projectIds.contains($0.projectId) && $0.title == "默认会话" && $0.detail == "从 Mac 导入" && $0.realProcessId == nil
            }
            if !fake.isEmpty {
                let ids = Set(fake.map(\.id))
                devices[index].workspace.sessions.removeAll { ids.contains($0.id) }
                persist()
            }
        }
    }

    /// Keeps a project's conversation rows aligned with the Agent's own
    /// thread list. Ids are the Agent's thread ids, so a later refresh
    /// updates titles instead of inserting duplicates. Rows the user created
    /// in this app use a different `detail` and are left alone.
    private func syncThreads(_ threads: [MacThread], projectId: String, deviceIndex: Int, marker: String) -> Bool {
        print("[SyncThreads] projectId=\(projectId) incoming=\(threads.count) marker=\(marker)")
        var changed = false
        let incoming = Set(threads.map(\.id))
        let before = devices[deviceIndex].workspace.sessions.count
        devices[deviceIndex].workspace.sessions.removeAll {
            $0.projectId == projectId && $0.detail == marker && !incoming.contains($0.id)
        }
        if devices[deviceIndex].workspace.sessions.count != before { changed = true }
        for thread in threads {
            let created = thread.updatedAt.flatMap { Self.parseRFC3339($0) } ?? Date()
            if let existing = devices[deviceIndex].workspace.sessions.firstIndex(where: { $0.id == thread.id }) {
                var row = devices[deviceIndex].workspace.sessions[existing]
                if row.title != thread.title || row.createdAt != created || row.projectId != projectId || row.detail != marker {
                    row.title = thread.title
                    row.createdAt = created
                    row.projectId = projectId
                    row.detail = marker
                    row.source = .desktop
                    devices[deviceIndex].workspace.sessions[existing] = row
                    changed = true
                }
            } else {
                devices[deviceIndex].workspace.sessions.append(SessionItem(
                    id: thread.id, projectId: projectId, title: thread.title,
                    status: .done, detail: marker, createdAt: created
                ))
                changed = true
            }
        }
        return changed
    }

    func resolve(_ id: String, approved: Bool) {
        guard let index = approvals.firstIndex(where: { $0.id == id }), approvals[index].pending else { return }
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

    func cancelPairing() {
        pairingGeneration = UUID()
        pairingPhase = nil
    }

    func pair(from payload: String, repairingDeviceID: String? = nil) async -> Bool {
        guard storageWritable else { show(storageError ?? "无法保存设备记录"); return false }
        guard pairingPhase == nil else { return false }
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else {
            show("扫到的不是 Mac 配对码")
            return false
        }
        let sessionId = object["session_id"] as? String ?? ""
        let endpointId = object["endpoint_id"] as? String ?? ""
        let name = (object["device_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Mac"
        if let repairingDeviceID {
            guard devices.contains(where: { $0.id == repairingDeviceID && $0.endpointID == nil }), !endpointId.isEmpty else {
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
        pairingPhase = "正在连接 Mac，需要你在 Mac 上点确认…"
        defer { if pairingGeneration == generation { pairingPhase = nil } }
        func stillPairing() -> Bool { pairingGeneration == generation && !Task.isCancelled }
        if !endpointId.isEmpty {
            let outcome = await pairingOperation(endpointId, sessionId, token, UIDevice.current.name, Self.irohKeyPath)
            guard stillPairing() else { return false }
            if outcome.ok { return finishPair(name: name, endpointId: endpointId, repairingDeviceID: repairingDeviceID) }
            let lanOK = await tryLANPair(object: object, token: token)
            guard stillPairing() else { return false }
            if lanOK { return finishPair(name: name, endpointId: endpointId, repairingDeviceID: repairingDeviceID) }
            show(Self.localizedPairError(code: outcome.errorCode, message: outcome.errorMessage))
            return false
        }
        let lanOK = await tryLANPair(object: object, token: token)
        guard stillPairing() else { return false }
        if lanOK { return finishPair(name: name, endpointId: endpointId, repairingDeviceID: repairingDeviceID) }
        show("这张码不能连上 Mac。请关掉桌面配对窗口后重新打开。")
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
    static func localizedPairError(code: String, message: String) -> String {
        switch code {
        case "unreachable":
            return "连接不到这台 Mac，请检查两边网络是否正常，并确认 Mac 没有休眠。"
        case "timeout":
            return "连接 Mac 超时，请检查网络后重试。"
        case "network_error":
            return "网络异常，手机暂时无法建立连接。"
        case "identity_error":
            return "读取手机身份信息失败，请重新打开 App 后再试。"
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
    private func finishPair(name: String, endpointId: String, repairingDeviceID: String?) -> Bool {
        let before = devices
        let previous = selectedDeviceID
        let endpoint = endpointId.isEmpty ? nil : endpointId
        if let repairingDeviceID {
            guard let index = devices.firstIndex(where: { $0.id == repairingDeviceID && $0.endpointID == nil }),
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
        guard persist() else {
            devices = before
            selectedDeviceID = previous
            return false
        }
        if foreground { Task { @MainActor [weak self] in await self?.refreshMacStatus() } }
        show("已配对 \(name)")
        return true
    }

    private func tryLANPair(object: [String: Any], token: String) async -> Bool {
        let urls = object["pair_urls"] as? [String] ?? []
        let body: [String: String] = [
            "token": token,
            "name": UIDevice.current.name,
            "device_id": phoneId,
        ]
        guard let encoded = try? JSONSerialization.data(withJSONObject: body) else { return false }
        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = encoded
            request.timeoutInterval = 4
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
        }
        return false
    }

    var pairingPhase: String?

    private var phoneId: String {
        let key = "agentbridge.phoneId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

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

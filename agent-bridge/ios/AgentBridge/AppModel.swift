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

    var installed: Bool { self != .herdr }
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
}

struct SessionItem: Identifiable, Hashable, Codable {
    let id: String
    var projectId: String
    var title: String
    var status: SessionStatus
    var detail: String
    var createdAt: Date = Date()

    enum CodingKeys: String, CodingKey {
        case id, projectId, title, status, detail, createdAt
    }

    init(id: String, projectId: String, title: String, status: SessionStatus, detail: String, createdAt: Date = Date()) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.status = status
        self.detail = detail
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectId = try container.decode(String.self, forKey: .projectId)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(SessionStatus.self, forKey: .status)
        detail = try container.decode(String.self, forKey: .detail)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

struct ChatMessage: Identifiable, Hashable, Codable {
    let id: String
    var sessionId: String
    var isUser: Bool
    var text: String
    var imageData: Data?
    var time: String
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
    var paired = false
    var hostName = ""
    var online = false
    var selectedAgent: AgentKind = .claude
    var projects: [ProjectItem] = []
    var sessions: [SessionItem] = []
    var messages: [ChatMessage] = []
    var approvals: [ApprovalItem] = []
    var toast: String?
    var permission = "完全访问"
    var notifyApproval = true
    var notifyDone = true
    var notifyOnMac = false
    var notifyFailed = true

    var pairToken = UUID().uuidString

    init() {
        if let saved = Self.load() {
            paired = saved.paired
            hostName = saved.hostName
            online = saved.online
            selectedAgent = saved.selectedAgent
            projects = saved.projects
            sessions = saved.sessions
            messages = saved.messages
            approvals = saved.approvals
            permission = saved.permission
            notifyApproval = saved.notifyApproval
            notifyDone = saved.notifyDone
            notifyOnMac = saved.notifyOnMac
            notifyFailed = saved.notifyFailed
        }
        removeStaleDemoData()
    }

    /// 0.1 shipped demo rows pre-seeded on first launch. Drop them once so pairing starts clean.
    private func removeStaleDemoData() {
        let demoProjects: Set<String> = ["p1", "p2", "p3"]
        let demoSessions: Set<String> = ["s1", "s2", "s3", "s4"]
        let demoMessages: Set<String> = ["m1", "m2", "m3"]
        let demoApprovals: Set<String> = ["a1", "a2"]
        let flagged = UserDefaults.standard.bool(forKey: "agentbridge.demoDataRemoved")
        guard !flagged else { return }
        UserDefaults.standard.set(true, forKey: "agentbridge.demoDataRemoved")
        let touchedProjects = !projects.filter { demoProjects.contains($0.id) }.isEmpty
        let touchedSessions = !sessions.filter { demoSessions.contains($0.id) }.isEmpty
        let touchedMessages = !messages.filter { demoMessages.contains($0.id) }.isEmpty
        let touchedApprovals = !approvals.filter { demoApprovals.contains($0.id) }.isEmpty
        guard touchedProjects || touchedSessions || touchedMessages || touchedApprovals else { return }
        projects.removeAll { demoProjects.contains($0.id) }
        sessions.removeAll { demoSessions.contains($0.id) }
        messages.removeAll { demoMessages.contains($0.id) }
        approvals.removeAll { demoApprovals.contains($0.id) }
        persist()
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
        paired = false
        online = false
        pairToken = UUID().uuidString
        persist()
        show("已断开配对")
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
        let stamp = Self.clock.string(from: Date())
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: true, text: text, imageData: image, time: stamp))
        let workspace = sessions.first { $0.id == sessionId }.flatMap { self.project($0.projectId) }
        let directory = workspace?.path ?? "当前项目"
        let reply = image == nil
            ? "已记下这个任务：\(text)。我会在 \(directory) 里先读相关文件。要改文件或跑命令之前，需要你批准。"
            : "已收到截图，并记下：\(text)。对照 \(directory) 处理前，需要你批准具体操作。"
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
        let id = UUID().uuidString
        sessions.insert(SessionItem(id: id, projectId: projectId, title: title, status: .running, detail: "刚刚创建"), at: 0)
        persist()
        return id
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

    func pair(from payload: String) async -> Bool {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["token"] as? String, !token.isEmpty else {
            show("扫到的不是 Mac 配对码")
            return false
        }
        let sessionId = object["session_id"] as? String ?? ""
        let endpointId = object["endpoint_id"] as? String ?? ""
        if let name = object["device_name"] as? String, !name.isEmpty {
            hostName = name
        }
        // Preferred path: iroh P2P. Works across the internet; the QR carries
        // the Mac's endpoint id, no LAN address involved.
        if !endpointId.isEmpty {
            pairingPhase = "正在连接 Mac，需要你在 Mac 上点确认…"
            let outcome = await pairOverIroh(
                endpointId: endpointId,
                sessionId: sessionId,
                token: token,
                deviceName: UIDevice.current.name,
                keyPath: Self.irohKeyPath
            )
            pairingPhase = nil
            if outcome.ok {
                finishPair(token: token)
                return true
            }
            // LAN fallback keeps same-network pairing working when iroh
            // cannot establish a path (e.g. relay unreachable).
            if !(await tryLANPair(object: object, token: token)) {
                show(outcome.errorMessage.isEmpty ? "配对失败" : outcome.errorMessage)
                return false
            }
            finishPair(token: token)
            return true
        }
        if await tryLANPair(object: object, token: token) {
            finishPair(token: token)
            return true
        }
        show("这张码不能连上 Mac。请关掉桌面配对窗口后重新打开。")
        return false
    }

    private func finishPair(token: String) {
        pairToken = token
        paired = true
        online = true
        persist()
        show("已配对 \(hostName)")
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

    private static var irohKeyPath: String {
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
        selectedAgent = agent
        persist()
        show("已添加项目")
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

    private struct Snapshot: Codable {
        var paired: Bool
        var hostName: String
        var online: Bool
        var selectedAgent: AgentKind
        var projects: [ProjectItem]
        var sessions: [SessionItem]
        var messages: [ChatMessage]
        var approvals: [ApprovalItem]
        var permission: String
        var notifyApproval: Bool
        var notifyDone: Bool
        var notifyOnMac: Bool
        var notifyFailed: Bool
    }

    private func persist() {
        let snapshot = Snapshot(
            paired: paired, hostName: hostName, online: online, selectedAgent: selectedAgent,
            projects: projects, sessions: sessions, messages: messages, approvals: approvals,
            permission: permission, notifyApproval: notifyApproval, notifyDone: notifyDone,
            notifyOnMac: notifyOnMac, notifyFailed: notifyFailed
        )
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func load() -> Snapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private static var fileURL: URL? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let folder = base?.appendingPathComponent("AgentBridge", isDirectory: true)
        if let folder {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent("state.json")
        }
        return nil
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

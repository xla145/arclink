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
    var paired = true
    var hostName = "MacBook Pro"
    var online = true
    var selectedAgent: AgentKind = .claude
    var projects: [ProjectItem] = [
        ProjectItem(id: "p1", name: "my-app", path: "~/projects/my-app", agent: .claude),
        ProjectItem(id: "p2", name: "backend", path: "~/work/backend", agent: .claude),
        ProjectItem(id: "p3", name: "api-server", path: "~/projects/api-server", agent: .codex),
    ]
    var sessions: [SessionItem] = [
        SessionItem(id: "s1", projectId: "p1", title: "重构 Dashboard 组件", status: .waiting, detail: "进行中 · 12 分钟 · 2 个待审批"),
        SessionItem(id: "s2", projectId: "p1", title: "修复登录页 CSS", status: .done, detail: "已完成 · 3 分钟前"),
        SessionItem(id: "s3", projectId: "p1", title: "添加用户设置页", status: .cancelled, detail: "已取消 · 昨天"),
        SessionItem(id: "s4", projectId: "p3", title: "生成 API 文档", status: .running, detail: "运行中 · 5 分钟"),
    ]
    var messages: [ChatMessage] = [
        ChatMessage(id: "m1", sessionId: "s1", isUser: true, text: "重构 Dashboard 组件，使用 useQuery 替换手动 fetch", imageData: nil, time: "14:22"),
        ChatMessage(id: "m2", sessionId: "s1", isUser: false, text: "我来帮你重构 Dashboard 组件。先读取当前实现。", imageData: nil, time: "14:22"),
        ChatMessage(id: "m3", sessionId: "s1", isUser: false, text: "写入 Dashboard.tsx 的变更等待你的批准（+42 / −18）。", imageData: nil, time: "14:23"),
    ]
    var approvals: [ApprovalItem] = [
        ApprovalItem(id: "a1", sessionId: "s1", title: "写入 src/components/Dashboard.tsx", kind: "工具调用 · 写入文件", target: "src/components/Dashboard.tsx", detail: "+42 行 / −18 行", pending: true, approved: nil),
        ApprovalItem(id: "a2", sessionId: "s1", title: "运行 npm test", kind: "工具调用 · 执行命令", target: "npm test --coverage --watchAll=false", detail: "无文件变更", pending: true, approved: nil),
    ]
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

    func confirmPair() {
        paired = true
        online = true
        persist()
        show("已在本机记下配对。桌面 daemon 仍未连接。")
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

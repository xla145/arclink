import SwiftUI

enum AgentKind: String, CaseIterable, Identifiable, Hashable {
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

enum SessionStatus: String {
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

struct ProjectItem: Identifiable, Hashable {
    let id: String
    var name: String
    var path: String
    var agent: AgentKind
    var sessionCount: Int
    var pendingApprovals: Int
}

struct SessionItem: Identifiable, Hashable {
    let id: String
    var projectId: String
    var title: String
    var status: SessionStatus
    var detail: String
}

struct ChatMessage: Identifiable, Hashable {
    let id: String
    var sessionId: String
    var isUser: Bool
    var text: String
    var imageData: Data?
    var time: String
}

struct ApprovalItem: Identifiable, Hashable {
    let id: String
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
    case terminal
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
        ProjectItem(id: "p1", name: "my-app", path: "~/projects/my-app", agent: .claude, sessionCount: 2, pendingApprovals: 1),
        ProjectItem(id: "p2", name: "backend", path: "~/work/backend", agent: .claude, sessionCount: 0, pendingApprovals: 0),
        ProjectItem(id: "p3", name: "api-server", path: "~/projects/api-server", agent: .codex, sessionCount: 1, pendingApprovals: 0),
    ]
    var sessions: [SessionItem] = [
        SessionItem(id: "s1", projectId: "p1", title: "重构 Dashboard 组件", status: .waiting, detail: "进行中 · 12 分钟 · 1 个待审批"),
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
        ApprovalItem(id: "a1", title: "写入 src/components/Dashboard.tsx", kind: "工具调用 · 写入文件", target: "src/components/Dashboard.tsx", detail: "+42 行 / −18 行", pending: true, approved: nil),
        ApprovalItem(id: "a2", title: "运行 npm test", kind: "工具调用 · 执行命令", target: "npm test --coverage", detail: "无文件变更", pending: true, approved: nil),
    ]
    var toast: String?
    var showPairQR = false
    var permission = "完全访问"
    var notifyApproval = true
    var notifyDone = true
    var notifyOnMac = false
    var notifyFailed = true

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

    func project(_ id: String) -> ProjectItem? { projects.first { $0.id == id } }

    func send(sessionId: String, text: String, image: Data?) {
        let stamp = Self.clock.string(from: Date())
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: true, text: text, imageData: image, time: stamp))
        let reply = image == nil ? "收到。我先查看相关文件，然后开始处理。" : "收到截图，我来分析一下界面结构。"
        messages.append(ChatMessage(id: UUID().uuidString, sessionId: sessionId, isUser: false, text: reply, imageData: nil, time: stamp))
    }

    func createSession(projectId: String, title: String) -> String {
        let id = UUID().uuidString
        sessions.insert(SessionItem(id: id, projectId: projectId, title: title, status: .running, detail: "刚刚创建"), at: 0)
        if let index = projects.firstIndex(where: { $0.id == projectId }) {
            projects[index].sessionCount += 1
        }
        return id
    }

    func resolve(_ id: String, approved: Bool) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        approvals[index].pending = false
        approvals[index].approved = approved
        show(approved ? "已批准" : "已拒绝")
    }

    func addProject(name: String, path: String, agent: AgentKind) {
        let item = ProjectItem(id: UUID().uuidString, name: name, path: path, agent: agent, sessionCount: 0, pendingApprovals: 0)
        projects.append(item)
        selectedAgent = agent
        show("已添加项目")
    }

    func show(_ text: String) {
        toast = text
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1600))
            if toast == text { toast = nil }
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

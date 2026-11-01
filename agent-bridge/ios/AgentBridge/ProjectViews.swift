import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    var projectId: String
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var source: SourceFilter = .all

    private enum SourceFilter: String, CaseIterable {
        case all = "全部"
        case cli = "CLI"
        case desktop = "桌面"
        case unknown = "未知"
    }

    private var project: ProjectItem? { store.project(projectId) }
    private var allRows: [SessionItem] {
        store.sessions(for: projectId).sorted { $0.createdAt > $1.createdAt }
    }
    private var rows: [SessionItem] {
        allRows.filter { session in
            let sourceMatches = source == .all || session.source.rawValue == source.rawValue
            let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
            return sourceMatches && (search.isEmpty || session.title.localizedCaseInsensitiveContains(search)
                || store.messages.contains { $0.sessionId == session.id && $0.text.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let project {
                    HStack(spacing: 8) {
                        Image(systemName: project.agent.symbolName).foregroundStyle(project.agent.tint)
                        Text(project.agent.rawValue).fontWeight(.medium)
                        Spacer()
                        Text("\(allRows.count) 个对话").foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Text(project.path)
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    Picker("对话来源", selection: $source) {
                        ForEach(SourceFilter.allCases, id: \.self) { filter in
                            Text("\(filter.rawValue) \(count(filter))").tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("conversation-source-filter")
                    searchField
                    sessionList
                    Text("按最近更新时间排序 · 导入历史仅供查看")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(.top, 2)
                } else {
                    ContentUnavailableView("项目不存在", systemImage: "folder.badge.questionmark", description: Text("这个项目可能已被移除，请返回首页选择其他项目。"))
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project?.name ?? "项目对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    store.selectProject(projectId)
                    path.append(Route.session(projectId: projectId, sessionId: nil))
                } label: { Image(systemName: "plus.bubble") }
                    .accessibilityLabel("新建 CLI 对话")
                    .disabled(project == nil || !store.canSend)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(Route.addProject(editing: projectId)) } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("项目设置")
                    .disabled(project == nil)
            }
        }
        .onAppear { store.selectProject(projectId) }
        .task(id: projectId) {
            if let project { await store.refreshConversationList(agent: project.agent, force: false) }
        }
        .refreshable {
            if let project { await store.refreshConversationList(agent: project.agent) }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索对话", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("conversation-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("清除对话搜索")
            }
        }
        .font(.subheadline).padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sessionList: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right").font(.title2)
                    Text(query.isEmpty ? "还没有\(source == .all ? "" : source.rawValue)对话" : "没有匹配的对话")
                        .font(.subheadline.weight(.medium))
                    Text(query.isEmpty ? "可以点击右上角开始新的 CLI 对话。" : "试试其他关键词或切换来源筛选。")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 36).padding(.horizontal, 12)
            }
            ForEach(rows) { session in
                Button { path.append(Route.session(projectId: projectId, sessionId: session.id)) } label: {
                    sessionRow(session)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session-\(session.id)")
                if session.id != rows.last?.id { Divider().padding(.leading, 54) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func sessionRow(_ session: SessionItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: session.source.symbolName)
                .font(.subheadline).foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title).font(.subheadline.weight(.medium)).lineLimit(2).foregroundStyle(.primary)
                    Spacer(minLength: 0)
                    Text(session.createdAt, style: .date).font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(snippet(session)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                HStack(spacing: 8) {
                    Text(session.source.rawValue)
                        .font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.secondary)
                    if session.isReadOnly {
                        Label("只读历史", systemImage: "lock").font(.system(size: 9)).foregroundStyle(.secondary)
                    } else {
                        Text(session.status.rawValue).font(.system(size: 9)).foregroundStyle(session.status.tint)
                    }
                    let pending = store.approvals.filter { $0.sessionId == session.id && $0.pending }.count
                    if pending > 0 { Text("\(pending) 待审批").font(.system(size: 9)).foregroundStyle(.orange) }
                }
            }
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).padding(.top, 7)
        }
        .padding(12)
        .contentShape(Rectangle())
    }

    private func count(_ filter: SourceFilter) -> Int {
        allRows.filter { filter == .all || $0.source.rawValue == filter.rawValue }.count
    }

    private func snippet(_ session: SessionItem) -> String {
        if let message = store.messages.last(where: { $0.sessionId == session.id }) {
            return message.text.isEmpty ? "图片消息" : MessageMarkdown.snippet(message.text)
        }
        return session.isReadOnly ? "来自 Mac 的历史记录，点击查看内容" : session.detail
    }
}

struct AddProjectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var editingId: String?

    @State private var agent: AgentKind = .claude
    @State private var pathText = "~/projects/my-app"
    @State private var name = "my-app"
    @State private var confirmDelete = false
    /// Real, on-disk paths the Agent itself already tracked on the Mac
    /// (`ListAgentProjects`) — nil while unknown/loading, `[]` once loaded
    /// with nothing found, so the section can tell "haven't checked yet"
    /// from "checked, there's nothing".
    @State private var macProjects: [MacProject]?

    private var editing: Bool { editingId != nil }

    var body: some View {
        Form {
            Section("选择 Agent") {
                ForEach(AgentKind.allCases) { kind in
                    Button {
                        if kind.installed { agent = kind }
                    } label: {
                        HStack {
                            Text(kind.rawValue)
                            if !kind.installed {
                                Text("未安装").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if agent == kind && kind.installed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!kind.installed)
                }
            }
            if !editing, let macProjects, !macProjects.isEmpty {
                Section {
                    ForEach(macProjects, id: \.path) { project in
                        Button {
                            importOne(project)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(AppStore.projectTitle(project)).foregroundStyle(.primary)
                                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    Button("全部导入（\(macProjects.count) 个）") { importAll(macProjects) }
                        .font(.subheadline.weight(.medium))
                } header: {
                    Text("从 \(store.hostName) 导入")
                } footer: {
                    Text("\(agent.rawValue) 在这台 Mac 上已经记录过的项目路径。点一下导入项目；发送第一条消息时才创建对话。")
                }
            }
            Section("项目地址") {
                TextField("路径", text: $pathText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("项目名称") {
                TextField("名称", text: $name)
            }
            Section {
                Button(editing ? "保存修改" : "添加项目") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if !editing {
                        store.addProject(name: trimmed, path: pathText, agent: agent)
                    } else if let editingId {
                        store.updateProject(id: editingId, name: trimmed, path: pathText, agent: agent)
                    }
                    dismiss()
                }
            }
            if editing {
                Section {
                    Button("删除项目", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(editing ? "项目设置" : "添加项目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let editingId, let project = store.project(editingId) {
                agent = project.agent
                pathText = project.path
                name = project.name
            } else {
                agent = store.selectedAgent.installed ? store.selectedAgent : .claude
            }
        }
        .task(id: "\(store.selectedDeviceID ?? "")/\(agent.agentId)") { await loadMacProjects() }
        .refreshable { await loadMacProjects(force: true) }
        .confirmationDialog("删除这个项目？会话记录会一起去掉。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除项目", role: .destructive) {
                if let editingId {
                    store.deleteProject(id: editingId)
                }
                dismiss()
            }
        }
    }

    /// Quiet on any failure (not connected, Mac doesn't know this Agent,
    /// protocol error): the import section just stays hidden, matching the
    /// existing empty-state convention rather than interrupting someone
    /// mid-form with an error they didn't ask for.
    private func loadMacProjects(force: Bool = false) async {
        guard !editing, let deviceID = store.selectedDeviceID else { macProjects = nil; return }
        let requestedAgent = agent
        macProjects = store.cachedMacProjects(deviceID: deviceID, agent: requestedAgent)
        let result = await store.loadMacProjects(deviceID: deviceID, agent: requestedAgent, force: force)
        guard !Task.isCancelled, store.selectedDeviceID == deviceID, agent == requestedAgent else { return }
        macProjects = result
    }

    private func importOne(_ project: MacProject) {
        store.importMacProject(
            name: AppStore.projectTitle(project), path: project.path, agent: agent,
            createdAt: project.lastSeen.flatMap { AppStore.parseRFC3339($0) }
        )
        dismiss()
    }

    private func importAll(_ projects: [MacProject]) {
        for project in projects {
            store.importMacProject(
                name: (project.path as NSString).lastPathComponent, path: project.path, agent: agent,
                createdAt: project.lastSeen.flatMap { AppStore.parseRFC3339($0) }
            )
        }
        dismiss()
    }
}

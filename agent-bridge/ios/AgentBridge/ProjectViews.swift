import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    var projectId: String
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var source: SourceFilter = .all
    @State private var confirmDelete = false
    @FocusState private var searchFocused: Bool

    private enum SourceFilter: String, CaseIterable {
        case all = "全部"
        case cli = "CLI"
        case desktop = "桌面"
        case unknown = "未知"

        /// What the chip says; `rawValue` stays the stored `SessionSource` value.
        var title: String {
            switch self {
            case .all: "全部"
            case .cli: "ArcLink"
            case .desktop: "桌面导入"
            case .unknown: "其他"
            }
        }
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
            VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
                if let project {
                    header(project)
                    sourceChips
                    searchField
                    sessionList
                    Text("桌面端导入的历史仅供查看，可在 Mac 上继续")
                        .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                        .frame(maxWidth: .infinity).multilineTextAlignment(.center)
                } else {
                    ContentUnavailableView("项目不存在", systemImage: "folder.badge.questionmark", description: Text("这个项目可能已被移除，请返回首页选择其他项目。"))
                }
            }
            .padding(.horizontal, ArcTheme.Space.s4)
            .padding(.top, ArcTheme.Space.s2)
            .padding(.bottom, ArcTheme.Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ArcTheme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Hidden while typing so it never floats over results above the keyboard.
            if project != nil && !searchFocused {
                Button {
                    store.selectProject(projectId)
                    path.append(Route.session(projectId: projectId, sessionId: nil))
                } label: { Label("在此项目新对话", systemImage: "plus") }
                    .buttonStyle(.arc(pill: true))
                    .disabled(!store.canSend)
                    .accessibilityIdentifier("project-new-chat")
                    .padding(.bottom, ArcTheme.Space.s4)
            }
        }
        .navigationTitle(project?.name ?? "项目对话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { path.append(Route.addProject(editing: projectId)) } label: {
                        Label("项目设置", systemImage: "pencil")
                    }
                    if let project {
                        Button { UIPasteboard.general.string = project.path; store.show("已复制路径") } label: {
                            Label("复制路径", systemImage: "doc.on.doc")
                        }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("移除项目", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("项目操作")
                    .disabled(project == nil)
            }
        }
        .confirmationDialog("移除这个项目？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除项目", role: .destructive) {
                store.deleteProject(id: projectId)
                if !path.isEmpty { path.removeLast() }
            }
        } message: { Text("只从 ArcLink 中移除，会话记录会一起去掉，不会删除 Mac 上的文件。") }
        .onAppear { store.selectProject(projectId) }
        .task(id: projectId) {
            if let project { await store.refreshConversationList(agent: project.agent, force: false) }
        }
        .refreshable {
            if let project { await store.refreshConversationList(agent: project.agent) }
        }
    }

    private func header(_ project: ProjectItem) -> some View {
        ArcCard(padding: ArcTheme.Space.s3) {
            HStack(spacing: ArcTheme.Space.s3) {
                IconTile(symbol: "folder", accent: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.path)
                        .font(.footnote.monospaced()).foregroundStyle(ArcTheme.ink)
                        .textSelection(.enabled)
                        .lineLimit(2).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Image(systemName: project.agent.symbolName).foregroundStyle(project.agent.tint)
                        Text("\(project.agent.rawValue) · \(store.hostName) · \(allRows.count) 个对话")
                    }
                    .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                }
            }
        }
    }

    private var sourceChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: ArcTheme.Space.s2) {
                ForEach(SourceFilter.allCases, id: \.self) { filter in
                    let n = count(filter)
                    if filter == .all || filter != .unknown || n > 0 {
                        let selected = source == filter
                        Button { source = filter } label: {
                            HStack(spacing: 6) {
                                Text(filter.title)
                                Text("\(n)").opacity(0.75)
                            }
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(selected ? ArcTheme.bg : ArcTheme.inkMuted)
                            .padding(.horizontal, ArcTheme.Space.s3)
                            .frame(minHeight: 32)
                            .background(selected ? ArcTheme.ink : ArcTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(selected ? ArcTheme.ink : ArcTheme.line))
                            .frame(minHeight: ArcTheme.tapMin)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(filter.title) \(n)")
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                        .accessibilityIdentifier("source-\(filter)")
                    }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: ArcTheme.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(ArcTheme.inkMuted)
            TextField("搜索对话", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($searchFocused)
                .accessibilityIdentifier("conversation-search")
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ArcTheme.inkMuted) }
                    .accessibilityLabel("清除对话搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, ArcTheme.Space.s3)
        .frame(minHeight: 40)
        .arcBackground(ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
    }

    @ViewBuilder
    private var sessionList: some View {
        if rows.isEmpty {
            VStack(spacing: ArcTheme.Space.s2) {
                Image(systemName: "bubble.left.and.bubble.right").font(.title2)
                Text(query.isEmpty ? "还没有\(source == .all ? "" : source.title)对话" : "没有匹配的对话")
                    .font(.headline).foregroundStyle(ArcTheme.ink)
                Text(query.isEmpty ? "在这个项目里开一个新对话吧。" : "试试其他关键词或切换来源筛选。")
                    .font(.subheadline)
            }
            .foregroundStyle(ArcTheme.inkMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, ArcTheme.Space.s8)
        } else {
            ArcListGroup(rows) { session in
                let pending = store.approvals.filter { $0.sessionId == session.id && $0.pending }.count
                Button { path.append(Route.session(projectId: projectId, sessionId: session.id)) } label: {
                    ArcListRow(title: session.title, subtitle: snippet(session),
                               trailing: Self.relativeFormatter.localizedString(for: session.createdAt, relativeTo: Date())) {
                        IconTile(symbol: session.isReadOnly ? "lock" : session.source.symbolName)
                    } tags: {
                        if session.isReadOnly {
                            StatusTag(kind: .neutral, text: "只读历史")
                        } else if pending == 0 || session.status != .waiting {
                            StatusTag(session.status)
                        }
                        // The count already says "waiting", so it replaces the status tag.
                        if pending > 0 { StatusTag(kind: .waiting, text: "\(pending) 待审批") }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("session-\(session.id)")
            }
        }
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

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct AddProjectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var editingId: String?

    @State private var agent: AgentKind = .claude
    @State private var pathText = ""
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var selectedPaths: Set<String> = []
    @State private var browsingFolders = false
    /// Real, on-disk paths the Agent itself already tracked on the Mac
    /// (`ListAgentProjects`) — nil while unknown/loading, `[]` once loaded
    /// with nothing found, so the section can tell "haven't checked yet"
    /// from "checked, there's nothing".
    @State private var macProjects: [MacProject]?

    private var editing: Bool { editingId != nil }
    private var manualPath: String { pathText.trimmingCharacters(in: .whitespaces) }
    private var canSave: Bool { editing ? !manualPath.isEmpty : (!selectedPaths.isEmpty || !manualPath.isEmpty) }

    var body: some View {
        Form {
            Section {
                Picker("Agent", selection: $agent) {
                    ForEach(AgentKind.allCases.filter(\.installed)) { kind in
                        Text(kind.shortName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            if !editing {
                Section {
                    if let macProjects {
                        if macProjects.isEmpty {
                            Text("没有可导入的项目").foregroundStyle(ArcTheme.inkMuted)
                        }
                        ForEach(macProjects, id: \.path) { project in
                            let selected = selectedPaths.contains(project.path)
                            Button {
                                if selected { selectedPaths.remove(project.path) } else { selectedPaths.insert(project.path) }
                            } label: {
                                HStack(spacing: ArcTheme.Space.s3) {
                                    IconTile(symbol: "folder")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(AppStore.projectTitle(project)).font(.callout.weight(.medium)).foregroundStyle(ArcTheme.ink)
                                        Text(project.path).font(.footnote.monospaced()).foregroundStyle(ArcTheme.inkMuted)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(selected ? ArcTheme.primary : ArcTheme.inkFaint)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                        if macProjects.count > 1 {
                            Button(selectedPaths.count == macProjects.count ? "取消全选" : "全选（\(macProjects.count) 个）") {
                                selectedPaths = selectedPaths.count == macProjects.count ? [] : Set(macProjects.map(\.path))
                            }
                            .font(.subheadline.weight(.medium))
                        }
                    } else {
                        HStack { ProgressView(); Text("正在读取 \(store.hostName) 上的项目…").foregroundStyle(ArcTheme.inkMuted) }
                    }
                } header: {
                    Text("\(store.hostName) 上已有的 \(agent.shortName) 项目")
                } footer: {
                    Text("导入只是登记路径，发送第一条消息时才会在 Mac 上创建对话。")
                }
            }
            Section(editing ? "项目地址" : "或选择 Mac 上的文件夹") {
                Button { browsingFolders = true } label: {
                    Label("浏览 Mac 上的文件夹", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("browse-mac-folders")
                TextField("~/path/to/project", text: $pathText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(editing ? "名称" : "名称（可选，默认取文件夹名）", text: $name)
            }
            if editing {
                Section {
                    Button("移除项目", role: .destructive) { confirmDelete = true }
                } footer: {
                    Text("只从 ArcLink 中移除，不会删除 Mac 上的文件。")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(ArcTheme.bg)
        .navigationTitle(editing ? "项目设置" : "添加项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(editing ? "保存" : "添加", action: save)
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                    .accessibilityIdentifier("save-project")
            }
        }
        .onAppear {
            if let editingId, let project = store.project(editingId) {
                agent = project.agent
                pathText = project.path
                name = project.name
            } else {
                agent = store.selectedAgent.installed ? store.selectedAgent : .claude
            }
        }
        .onChange(of: agent) { _, _ in selectedPaths = [] }
        .sheet(isPresented: $browsingFolders) {
            MacFolderPicker { chosen in
                pathText = chosen
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = (chosen as NSString).lastPathComponent
                }
            }
        }
        .task(id: "\(store.selectedDeviceID ?? "")/\(agent.agentId)") { await loadMacProjects() }
        .refreshable { await loadMacProjects(force: true) }
        .confirmationDialog("移除这个项目？会话记录会一起去掉。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除项目", role: .destructive) {
                if let editingId {
                    store.deleteProject(id: editingId)
                }
                dismiss()
            }
        }
    }

    private func save() {
        let manualName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName = (manualPath as NSString).lastPathComponent
        if let editingId {
            store.updateProject(id: editingId, name: manualName.isEmpty ? fallbackName : manualName, path: manualPath, agent: agent)
            dismiss()
            return
        }
        for project in macProjects ?? [] where selectedPaths.contains(project.path) {
            store.importMacProject(
                name: AppStore.projectTitle(project), path: project.path, agent: agent,
                createdAt: project.lastSeen.flatMap { AppStore.parseRFC3339($0) }
            )
        }
        if !manualPath.isEmpty {
            store.addProject(name: manualName.isEmpty ? fallbackName : manualName, path: manualPath, agent: agent)
        }
        dismiss()
    }

    /// Quiet on any failure (not connected, Mac doesn't know this Agent,
    /// protocol error): the list just shows nothing to import, rather than
    /// interrupting someone mid-form with an error they didn't ask for.
    private func loadMacProjects(force: Bool = false) async {
        guard !editing, let deviceID = store.selectedDeviceID else { macProjects = nil; return }
        let requestedAgent = agent
        macProjects = store.cachedMacProjects(deviceID: deviceID, agent: requestedAgent)
        let result = await store.loadMacProjects(deviceID: deviceID, agent: requestedAgent, force: force)
        guard !Task.isCancelled, store.selectedDeviceID == deviceID, agent == requestedAgent else { return }
        macProjects = result ?? []
    }
}

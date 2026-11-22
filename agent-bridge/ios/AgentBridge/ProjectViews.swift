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

    private struct DiscoveredProject: Identifiable {
        var id: String { path }
        var path: String
        var name: String
        var agents: [AgentKind]
        var threadCount: Int
        var lastSeen: Date?
    }

    @State private var agent: AgentKind = .claude
    @State private var selectedPath = ""
    @State private var name = ""
    @State private var confirmDelete = false
    @State private var selectedPaths: Set<String> = []
    @State private var browsingFolders = false
    @State private var discovered: [DiscoveredProject]?
    @State private var saving = false

    private var editing: Bool { editingId != nil }
    private var canSave: Bool { !saving && (editing ? !selectedPath.isEmpty : (!selectedPaths.isEmpty || !selectedPath.isEmpty)) }

    private var existingPaths: Set<String> {
        Set(store.unifiedProjects().map(\.path))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                // 1. Manual Mac folder picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("从 Mac 选择文件夹")
                        .font(.footnote)
                        .foregroundStyle(ArcTheme.inkMuted)
                        .padding(.horizontal, 14)

                    VStack(spacing: 0) {
                        Button { browsingFolders = true } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "folder")
                                    .font(.system(size: 17, weight: .regular))
                                    .foregroundStyle(ArcTheme.ink)
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(selectedPath.isEmpty ? "浏览 Mac 文件夹" : (selectedPath as NSString).lastPathComponent)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(ArcTheme.ink)
                                        .lineLimit(1)
                                    Text(selectedPath.isEmpty ? "选择或新建目录，自动关联该路径下的对话" : Self.shortPath(selectedPath))
                                        .font(.caption)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ArcTheme.inkFaint)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("browse-mac-folders")

                        if !selectedPath.isEmpty || editing {
                            Rectangle()
                                .fill(ArcTheme.line.opacity(0.7))
                                .frame(height: 0.5)
                                .padding(.leading, 16)
                            TextField("项目名称（默认使用文件夹名）", text: $name)
                                .font(.body)
                                .foregroundStyle(ArcTheme.ink)
                                .padding(.horizontal, 16)
                                .frame(minHeight: 46)
                                .accessibilityLabel("项目名称")
                        }
                    }
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                // 2. Unified Codex + Claude discovered projects
                if !editing {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Codex 与 Claude 已有项目")
                                .font(.footnote)
                                .foregroundStyle(ArcTheme.inkMuted)
                            Spacer()
                            if !selectedPaths.isEmpty {
                                Text("已选 \(selectedPaths.count) 个")
                                    .font(.footnote)
                                    .foregroundStyle(ArcTheme.ink)
                            }
                        }
                        .padding(.horizontal, 14)

                        VStack(spacing: 0) {
                            if let discovered {
                                let available = discovered.filter { !existingPaths.contains($0.path) }
                                if available.isEmpty {
                                    Text(discovered.isEmpty ? "未在 Mac 上发现 Codex 或 Claude 项目" : "发现的项目均已添加到首页")
                                        .font(.subheadline)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 16)
                                } else {
                                    ForEach(available) { item in
                                        if item.id != available.first?.id {
                                            Rectangle()
                                                .fill(ArcTheme.line.opacity(0.7))
                                                .frame(height: 0.5)
                                                .padding(.leading, 16)
                                        }
                                        let selected = selectedPaths.contains(item.path)
                                        Button {
                                            if selected { selectedPaths.remove(item.path) } else { selectedPaths.insert(item.path) }
                                        } label: {
                                            HStack(spacing: 12) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    HStack(spacing: 6) {
                                                        Text(item.name)
                                                            .font(.body.weight(.medium))
                                                            .foregroundStyle(ArcTheme.ink)
                                                            .lineLimit(1)
                                                        ForEach(item.agents) { kind in
                                                            AgentIcon(agent: kind, size: 12, tint: ArcTheme.inkMuted)
                                                        }
                                                    }
                                                    HStack(spacing: 6) {
                                                        Text(Self.shortPath(item.path))
                                                            .font(.caption.monospaced())
                                                            .foregroundStyle(ArcTheme.inkMuted)
                                                            .lineLimit(1)
                                                            .truncationMode(.middle)
                                                        if item.threadCount > 0 {
                                                            Text("· \(item.threadCount) 条对话")
                                                                .font(.caption)
                                                                .foregroundStyle(ArcTheme.inkFaint)
                                                        }
                                                    }
                                                }
                                                Spacer(minLength: 8)
                                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                                    .font(.system(size: 20))
                                                    .foregroundStyle(selected ? ArcTheme.ink : ArcTheme.inkFaint)
                                            }
                                            .padding(.horizontal, 16)
                                            .padding(.vertical, 12)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                                    }
                                }
                            } else {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("正在读取 \(store.hostName) 上的 Codex 与 Claude 项目…")
                                        .font(.subheadline)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 16)
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityIdentifier("project-import-options")

                        Text("添加后将自动读取该项目路径下 Codex 与 Claude 的历史对话。")
                            .font(.caption)
                            .foregroundStyle(ArcTheme.inkFaint)
                            .padding(.horizontal, 14)
                            .padding(.top, 2)
                    }
                }

                if editing {
                    VStack(alignment: .leading, spacing: 6) {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            HStack {
                                Text("移除项目")
                                    .font(.body)
                                    .foregroundStyle(ArcTheme.danger)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                            .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        Text("只从 ArcLink 中移除，不会删除 Mac 上的文件。")
                            .font(.caption)
                            .foregroundStyle(ArcTheme.inkFaint)
                            .padding(.horizontal, 14)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(ArcTheme.bg.ignoresSafeArea())
        .navigationTitle(editing ? "项目设置" : "添加项目")
        .navigationBarTitleDisplayMode(.inline)
        .arcBackButton("首页")
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button {
                Task { await save() }
            } label: {
                if saving {
                    ProgressView().tint(ArcTheme.surface)
                } else {
                    Text(editing ? "保存修改" : (selectedPaths.count > 1 ? "添加 \(selectedPaths.count) 个项目" : "添加项目"))
                }
            }
            .buttonStyle(.arc(block: true))
            .disabled(!canSave)
            .accessibilityIdentifier("save-project")
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(ArcTheme.bg)
        }
        .onAppear {
            if let editingId, let project = store.project(editingId) {
                agent = project.agent
                selectedPath = project.path
                name = project.name
            }
        }
        .sheet(isPresented: $browsingFolders) {
            MacFolderPicker { chosen in
                selectedPath = chosen
                if name.trimmingCharacters(in: .whitespaces).isEmpty {
                    name = (chosen as NSString).lastPathComponent
                }
            }
        }
        .task(id: store.selectedDeviceID ?? "") { await loadAllMacProjects() }
        .refreshable { await loadAllMacProjects(force: true) }
        .confirmationDialog("移除这个项目？会话记录会一起去掉。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除项目", role: .destructive) {
                if let editingId {
                    store.deleteProject(id: editingId)
                }
                dismiss()
            }
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let manualName = name.trimmingCharacters(in: .whitespaces)
        let fallbackName = (selectedPath as NSString).lastPathComponent
        if let editingId {
            store.updateProject(id: editingId, name: manualName.isEmpty ? fallbackName : manualName, path: selectedPath, agent: agent)
            dismiss()
            return
        }

        var pathsToRegister: [(name: String, path: String, createdAt: Date?)] = []
        for item in discovered ?? [] where selectedPaths.contains(item.path) {
            pathsToRegister.append((item.name, item.path, item.lastSeen))
        }
        if !selectedPath.isEmpty && !selectedPaths.contains(selectedPath) {
            pathsToRegister.append((manualName.isEmpty ? fallbackName : manualName, selectedPath, Date()))
        }

        let deviceID = store.selectedDeviceID
        let bridge = deviceID.flatMap { store.bridge(for: $0) }
        for entry in pathsToRegister {
            // Register as a managed project on Mac if online, and register local Codex + Claude
            // records so existing histories under this path sync immediately.
            if let bridge {
                _ = try? await bridge.createManagedProject(
                    commandId: UUID().uuidString,
                    path: entry.path,
                    name: entry.name
                )
            }
            for kind in AgentKind.allCases where kind.installed {
                store.importMacProject(name: entry.name, path: entry.path, agent: kind, createdAt: entry.createdAt)
            }
        }
        if let deviceID {
            await store.refreshManagedCatalog(deviceID: deviceID)
            for kind in AgentKind.allCases where kind.installed {
                await store.refreshConversationList(agent: kind, force: true)
            }
        }
        dismiss()
    }

    private func loadAllMacProjects(force: Bool = false) async {
        guard !editing, let deviceID = store.selectedDeviceID else { discovered = nil; return }
        // Show cached projects immediately, then refresh both Codex and Claude in parallel.
        let cachedCodex = store.cachedMacProjects(deviceID: deviceID, agent: .codex) ?? []
        let cachedClaude = store.cachedMacProjects(deviceID: deviceID, agent: .claude) ?? []
        if !cachedCodex.isEmpty || !cachedClaude.isEmpty {
            discovered = Self.mergeDiscovered(codex: cachedCodex, claude: cachedClaude)
        }
        async let codexTask = store.loadMacProjects(deviceID: deviceID, agent: .codex, force: force)
        async let claudeTask = store.loadMacProjects(deviceID: deviceID, agent: .claude, force: force)
        let (codex, claude) = await (codexTask ?? [], claudeTask ?? [])
        guard !Task.isCancelled, store.selectedDeviceID == deviceID else { return }
        discovered = Self.mergeDiscovered(codex: codex, claude: claude)
    }

    private static func mergeDiscovered(codex: [MacProject], claude: [MacProject]) -> [DiscoveredProject] {
        var map: [String: DiscoveredProject] = [:]
        func ingest(_ list: [MacProject], kind: AgentKind) {
            for item in list {
                let seen = item.lastSeen.flatMap { AppStore.parseRFC3339($0) }
                if var existing = map[item.path] {
                    if !existing.agents.contains(kind) { existing.agents.append(kind) }
                    existing.threadCount += item.threads.count
                    if let seen, (existing.lastSeen == nil || seen > existing.lastSeen!) { existing.lastSeen = seen }
                    map[item.path] = existing
                } else {
                    map[item.path] = DiscoveredProject(
                        path: item.path,
                        name: AppStore.projectTitle(item),
                        agents: [kind],
                        threadCount: item.threads.count,
                        lastSeen: seen
                    )
                }
            }
        }
        ingest(codex, kind: .codex)
        ingest(claude, kind: .claude)
        return map.values.sorted {
            let l = $0.lastSeen ?? .distantPast, r = $1.lastSeen ?? .distantPast
            return l == r ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : l > r
        }
    }

    private static func shortPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        if components.count >= 2 && components[0] == "Users" {
            let rest = components.dropFirst(2).joined(separator: "/")
            return rest.isEmpty ? "~" : "~/\(rest)"
        }
        return path
    }
}

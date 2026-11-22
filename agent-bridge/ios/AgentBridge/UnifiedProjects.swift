import SwiftUI

/// A presentation group, never a migration of provider-native identities.
struct UnifiedProjectItem: Identifiable {
    var id: String { path }
    var name: String
    var path: String
    var legacyIDs: Set<String>
    var managedID: String?
    var lastActivity: Date?
}

enum UnifiedConversationItem: Identifiable {
    case legacy(SessionItem)
    case managed(ManagedThread)

    var id: String {
        switch self {
        case .legacy(let session): return "legacy:\(session.projectId):\(session.id)"
        case .managed(let thread): return "managed:\(thread.id)"
        }
    }
    var title: String {
        switch self { case .legacy(let session): return session.title; case .managed(let thread): return thread.title }
    }
    @MainActor var updatedAt: Date {
        switch self {
        case .legacy(let session): return session.createdAt
        case .managed(let thread): return AppStore.parseRFC3339(thread.updatedAt) ?? AppStore.parseRFC3339(thread.createdAt) ?? .distantPast
        }
    }
    var isRunning: Bool {
        switch self {
        case .legacy(let session): return !session.isReadOnly && session.status == .running
        case .managed(let thread): return ["active", "queued", "starting", "running", "waiting_approval"].contains(thread.status)
        }
    }
}

@MainActor
extension AppStore {
    func unifiedProjects(query: String = "") -> [UnifiedProjectItem] {
        let deviceThreads = selectedDeviceID.flatMap { managedThreads[$0] } ?? [:]
        return Self.groupProjects(legacy: projects, managed: selectedDeviceID.flatMap { managedProjects[$0] } ?? [], sessions: sessions, threads: deviceThreads)
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    static func groupProjects(legacy: [ProjectItem], managed: [ManagedProject], sessions: [SessionItem] = [], threads: [String: [ManagedThread]] = [:]) -> [UnifiedProjectItem] {
        var rows: [String: UnifiedProjectItem] = [:]
        for item in legacy {
            if rows[item.path] != nil { rows[item.path]?.legacyIDs.insert(item.id) }
            else { rows[item.path] = UnifiedProjectItem(name: item.name, path: item.path, legacyIDs: [item.id], managedID: nil) }
        }
        for item in managed {
            if rows[item.canonicalRoot] != nil { rows[item.canonicalRoot]?.managedID = item.id }
            else { rows[item.canonicalRoot] = UnifiedProjectItem(name: item.name, path: item.canonicalRoot, legacyIDs: [], managedID: item.id) }
        }
        let values = rows.values.map { project in
            var row = project
            let conversationActivity = Self.groupConversations(project: row, sessions: sessions, threads: row.managedID.flatMap { threads[$0] } ?? []).first?.updatedAt
            let legacyActivity = legacy.filter { row.legacyIDs.contains($0.id) }.map(\.createdAt).max()
            let managedActivity = managed.first { $0.id == row.managedID }.flatMap { AppStore.parseRFC3339($0.updatedAt) ?? AppStore.parseRFC3339($0.createdAt) }
            row.lastActivity = [conversationActivity, legacyActivity, managedActivity].compactMap { $0 }.max()
            return row
        }
        return values.sorted {
            let left = $0.lastActivity ?? .distantPast, right = $1.lastActivity ?? .distantPast
            if left != right { return left > right }
            let nameOrder = $0.name.localizedStandardCompare($1.name)
            return nameOrder == .orderedSame ? $0.path < $1.path : nameOrder == .orderedAscending
        }
    }

    func unifiedConversations(project: UnifiedProjectItem, query: String = "") -> [UnifiedConversationItem] {
        let threads = selectedDeviceID.flatMap { managedThreads[$0] } ?? [:]
        return Self.groupConversations(project: project, sessions: sessions, threads: project.managedID.flatMap { threads[$0] } ?? [], query: query)
    }

    static func groupConversations(project: UnifiedProjectItem, sessions: [SessionItem], threads: [ManagedThread], query: String = "") -> [UnifiedConversationItem] {
        let legacy = sessions.filter { project.legacyIDs.contains($0.projectId) }.map(UnifiedConversationItem.legacy)
        let managed = threads.filter { $0.projectId == project.managedID }.map(UnifiedConversationItem.managed)
        return (legacy + managed).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt
        }
    }
}

struct UnifiedProjectDetailView: View {
    @Environment(AppStore.self) private var store
    let projectPath: String
    @Binding var path: NavigationPath
    @State private var creating = false
    @State private var query = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var confirmDelete = false

    private var project: UnifiedProjectItem? { store.unifiedProjects().first { $0.path == projectPath } }
    private var allConversations: [UnifiedConversationItem] {
        guard let project else { return [] }
        return store.unifiedConversations(project: project, query: "")
    }
    private var conversations: [UnifiedConversationItem] {
        guard let project else { return [] }
        return store.unifiedConversations(project: project, query: query)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // Compact tappable path strip (tap to copy)
                Button {
                    UIPasteboard.general.string = projectPath
                    store.show("已复制路径")
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(ArcTheme.primary)
                        Text(projectPath)
                            .font(.caption.monospaced())
                            .foregroundStyle(ArcTheme.inkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(ArcTheme.inkFaint)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)

                if let error = store.selectedDeviceID.flatMap({ store.managedCatalogError[$0] }) {
                    ArcBanner(text: error)
                }

                // Conversations header + on-demand search toggle (matches HomeView)
                HStack(spacing: 8) {
                    Text("对话")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ArcTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !allConversations.isEmpty {
                        Text("\(allConversations.count)")
                            .font(.caption.weight(.semibold))
                            .monospacedDigit()
                            .foregroundStyle(ArcTheme.inkMuted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(ArcTheme.surfaceSunken, in: Capsule())
                    }
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if showSearch {
                                query = ""
                                searchFocused = false
                                showSearch = false
                            } else {
                                showSearch = true
                                searchFocused = true
                            }
                        }
                    } label: {
                        Image(systemName: showSearch ? "xmark" : "magnifyingglass")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(ArcTheme.ink)
                            .frame(width: 36, height: 36)
                            .background(ArcTheme.surface, in: Circle())
                            .overlay(Circle().stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showSearch ? "关闭搜索" : "搜索对话")
                }
                .padding(.leading, 2)
                .padding(.top, 2)

                if showSearch || !query.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(ArcTheme.inkFaint)
                        TextField("搜索对话", text: $query)
                            .font(.subheadline)
                            .foregroundStyle(ArcTheme.ink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($searchFocused)
                            .submitLabel(.search)
                            .onSubmit { searchFocused = false }
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(ArcTheme.inkFaint)
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(ArcTheme.line, lineWidth: 0.75))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Conversations list
                if conversations.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.title2)
                            .foregroundStyle(ArcTheme.inkFaint)
                        Text(query.isEmpty ? "还没有对话" : "没有匹配的对话")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ArcTheme.ink)
                        if !query.isEmpty {
                            Button("清除搜索") { query = "" }
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ArcTheme.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(ArcTheme.line.opacity(0.7), lineWidth: 0.75))
                } else {
                    ArcListGroup(conversations, dividerInset: 62) { conversation in
                        conversationRow(conversation)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(ArcTheme.bg)
        .navigationTitle(project?.name ?? "项目")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ArcTheme.ink)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(project?.name ?? "项目")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ArcTheme.ink)
                        .lineLimit(1)
                    if !store.hostName.isEmpty {
                        Text(store.hostName)
                            .font(.caption2)
                            .foregroundStyle(ArcTheme.inkMuted)
                            .lineLimit(1)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let legacyID = project?.legacyIDs.sorted().first {
                        Button { path.append(Route.addProject(editing: legacyID)) } label: {
                            Label("项目设置", systemImage: "pencil")
                        }
                    }
                    Button {
                        UIPasteboard.general.string = projectPath
                        store.show("已复制路径")
                    } label: { Label("复制路径", systemImage: "doc.on.doc") }
                    if !(project?.legacyIDs.isEmpty ?? true) {
                        Button(role: .destructive) { confirmDelete = true } label: {
                            Label("移除本地项目记录", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(ArcTheme.ink)
                }
                .accessibilityLabel("项目操作")
            }
        }
        .confirmationDialog("移除这个项目？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("移除本地项目记录", role: .destructive) {
                for id in project?.legacyIDs ?? [] { store.deleteProject(id: id) }
                if project?.managedID == nil, !path.isEmpty { path.removeLast() }
            }
        } message: {
            Text(project?.managedID == nil
                ? "会话记录会一起移除，但不会删除 Mac 上的文件。"
                : "只移除 ArcLink 中的旧项目记录；共享项目和托管对话不会删除。")
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    searchFocused = false
                    if store.devices.first(where: { $0.id == store.selectedDeviceID })?.endpointID == nil,
                       let legacyID = project?.legacyIDs.sorted().first {
                        store.selectProject(legacyID)
                    }
                    creating = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .bold))
                        Text("新对话")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(ArcTheme.onPrimary)
                    .padding(.horizontal, 26)
                    .frame(height: 50)
                    .background(ArcTheme.primary, in: Capsule())
                    .shadow(color: ArcTheme.primary.opacity(0.28), radius: 14, y: 6)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-new-chat")
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .sheet(isPresented: $creating) {
            if store.devices.first(where: { $0.id == store.selectedDeviceID })?.endpointID != nil {
                NewManagedTaskSheet(initialDeviceID: store.selectedDeviceID, initialProjectPath: projectPath) { device, thread in
                    creating = false
                    path.append(Route.deviceThread(deviceID: device, threadID: thread))
                }
            } else {
                NewConversationSheet(projectID: project?.legacyIDs.sorted().first ?? "") { projectID, sessionID in
                    creating = false
                    path.append(Route.session(projectId: projectID, sessionId: sessionID))
                }
            }
        }
        .task { if let device = store.selectedDeviceID { await store.refreshManagedCatalog(deviceID: device) } }
        .refreshable {
            for agent in AgentKind.allCases where agent.installed { await store.refreshConversationList(agent: agent) }
            if let device = store.selectedDeviceID { await store.refreshManagedCatalog(deviceID: device) }
        }
    }

    private func conversationRow(_ conversation: UnifiedConversationItem) -> some View {
        let agent: AgentKind = switch conversation {
        case .managed(let thread): thread.providerId == "claude" ? .claude : .codex
        case .legacy(let session): store.project(session.projectId)?.agent ?? .codex
        }
        let isRunning: Bool = switch conversation {
        case .managed(let thread): ["active", "running"].contains(thread.status)
        case .legacy(let session): session.status == .running
        }
        let subtitle: String = switch conversation {
        case .managed(let thread): "\(managedProvider(thread.providerId)) · \(managedStatus(thread.status))"
        case .legacy(let session): "\(agent.shortName) · \(session.isReadOnly ? "只读历史" : session.status.rawValue)"
        }
        let unavailable: Bool = if case .legacy(let session) = conversation { session.sourceUnavailable } else { false }

        return Button {
            switch conversation {
            case .managed(let thread):
                if let device = store.selectedDeviceID { path.append(Route.deviceThread(deviceID: device, threadID: thread.id)) }
            case .legacy(let session):
                path.append(Route.session(projectId: session.projectId, sessionId: session.id))
            }
        } label: {
            HStack(spacing: 12) {
                AgentIcon(agent: agent, size: 17)
                    .frame(width: 36, height: 36)
                    .background(agent.tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(conversation.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(ArcTheme.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if isRunning {
                            Circle()
                                .fill(ArcTheme.live)
                                .frame(width: 6, height: 6)
                        }
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isRunning ? ArcTheme.live : ArcTheme.inkMuted)
                            .lineLimit(1)
                    }
                    if unavailable {
                        Text("原始记录暂不可用")
                            .font(.caption2)
                            .foregroundStyle(ArcTheme.warning)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcTheme.inkFaint)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

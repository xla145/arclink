import SwiftUI

/// The Workspace: what needs you (approvals), what is running, then all
/// projects ordered by recent activity. Agent selection happens per new task.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool
    @State private var choosingConversation = false
    @State private var choosingDevice = false
    @State private var chosenProjectID = ""

    private var pendingApprovals: [ApprovalItem] { store.approvals.filter(\.pending) }
    private var headerState: WorkspaceHeader.State {
        switch store.connectionState {
        case .connected: .online(store.connectionStateLabel)
        case .connecting: .connecting
        default: store.connectionStateLabel == "请重新扫码连接" ? .offline("需重新扫码") : .offline("离线")
        }
    }
    private var runningSessions: [SessionItem] {
        store.sessions.filter { $0.status == .running && store.project($0.projectId) != nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: ArcTheme.Space.s4) {
                if !store.online { offlineBar }
                if !pendingApprovals.isEmpty {
                    if pendingApprovals.count == 1 {
                        ArcSectionHeader("待你批准")
                        approvalCard(pendingApprovals[0])
                    } else {
                        // Multiple approvals: compact banner, tap to see all
                        Button { path.append(Route.approvals) } label: {
                            HStack(spacing: ArcTheme.Space.s3) {
                                Image(systemName: "clock").font(.subheadline.weight(.semibold))
                                    .foregroundStyle(ArcTheme.warning)
                                Text("\(pendingApprovals.count) 项待审批")
                                    .font(.callout.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                                Spacer(minLength: 4)
                                Text("查看全部").font(.footnote.weight(.medium)).foregroundStyle(ArcTheme.primary)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ArcTheme.primary)
                            }
                            .padding(ArcTheme.Space.s4)
                            .arcBackground(ArcTheme.warningSoft, radius: ArcTheme.Radius.lg)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("home-approval-banner")
                    }
                }
                if !runningSessions.isEmpty {
                    ArcSectionHeader("进行中").padding(.top, ArcTheme.Space.s2)
                    ForEach(runningSessions) { runningCard($0) }
                }
                projectsHeader
                if showSearch || !query.isEmpty {
                    searchField
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                projectList
            }
            .padding(.horizontal, ArcTheme.Space.s4)
            .padding(.top, ArcTheme.Space.s3)
            .padding(.bottom, ArcTheme.Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            for agent in AgentKind.allCases where agent.installed {
                await store.refreshConversationList(agent: agent)
            }
            if let device = store.selectedDeviceID { await store.refreshManagedCatalog(deviceID: device) }
        }
        .task(id: store.selectedDeviceID) {
            for agent in AgentKind.allCases where agent.installed {
                await store.refreshConversationList(agent: agent, force: false)
            }
            if let device = store.selectedDeviceID { await store.refreshManagedCatalog(deviceID: device) }
        }
        .onAppear {
            // Returning to Home should refresh stale catalogs even when the
            // selected device did not change; the cache keeps this inexpensive.
            Task {
                for agent in AgentKind.allCases where agent.installed {
                    await store.refreshConversationList(agent: agent, force: false)
                }
                if let device = store.selectedDeviceID { await store.refreshManagedCatalog(deviceID: device) }
            }
        }
        .background(ArcTheme.bg)
        // An inset (not an overlay) so it sits above whichever tab bar is showing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                Button {
                    searchFocused = false
                    chosenProjectID = store.allProjects(query: "").first?.id ?? ""
                    choosingConversation = true
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
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("chat-fab")
                Spacer(minLength: 0)
            }
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        // The header is drawn in the page so it looks the same on every iOS version;
        // the hidden title still names the page for VoiceOver, back buttons and tests.
        .navigationTitle("工作台")
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            WorkspaceHeader(
                name: store.hostName,
                state: headerState,
                fullState: store.connectionStateLabel,
                pending: store.pendingCount,
                agents: store.macAgents,
                onDevice: { choosingDevice = true },
                onApprovals: { path.append(Route.approvals) },
                onSettings: { path.append(Route.settings) }
            )
        }
        .sheet(isPresented: $choosingConversation) {
            if store.devices.contains(where: { $0.endpointID != nil }) {
                NewManagedTaskSheet(initialDeviceID: store.selectedDeviceID) { device, thread in
                    choosingConversation = false
                    path.append(Route.deviceThread(deviceID: device, threadID: thread))
                }
            } else {
                NewConversationSheet(projectID: chosenProjectID) { projectID, sessionID in
                    choosingConversation = false
                    path.append(Route.session(projectId: projectID, sessionId: sessionID))
                }
            }
        }
        .sheet(isPresented: $choosingDevice) { DevicePickerSheet() }
        .onChange(of: store.selectedDeviceID) { _, _ in
            choosingConversation = false
            choosingDevice = false
        }
    }

    private var offlineBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(ArcTheme.warning)
                .frame(width: 34, height: 34)
                .background(ArcTheme.warningSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(store.hostName) \(store.connectionStateLabel)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ArcTheme.ink)
                    .lineLimit(1)
                Text("当前显示的是上次同步的内容")
                    .font(.caption)
                    .foregroundStyle(ArcTheme.inkMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { store.reconnectIfNeeded() } label: {
                Text("重连")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArcTheme.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(ArcTheme.primarySoft, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(ArcTheme.line.opacity(0.8), lineWidth: 0.75)
        )
        .accessibilityIdentifier("offline-bar")
    }

    /// The whole request, decided in place. A decided request is no longer
    /// pending, so it leaves this list; history stays in Approvals.
    private func approvalCard(_ item: ApprovalItem) -> some View {
        let session = store.sessions.first { $0.id == item.sessionId }
        let project = session.flatMap { store.project($0.projectId) }
        let submitting = store.isApprovalSubmitting(item.id, sessionId: item.sessionId)
        return VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
            Button { path.append(Route.approval(item.id)) } label: {
                VStack(alignment: .leading, spacing: ArcTheme.Space.s2) {
                    HStack(spacing: ArcTheme.Space.s2) {
                        Image(systemName: project?.agent.symbolName ?? "clock")
                            .foregroundStyle(project?.agent.tint ?? ArcTheme.warning)
                        Text([project?.name, session?.title].compactMap { $0 }.joined(separator: " · "))
                            .font(.footnote).foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ArcTheme.warning)
                    }
                    Text(item.title).font(.callout.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                    Text(item.kind.contains("写入") ? item.target : "$ \(item.target)")
                        .font(.footnote.monospaced()).foregroundStyle(ArcTheme.ink)
                        .lineLimit(3)
                        .padding(.horizontal, 10).padding(.vertical, ArcTheme.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看完整请求")
            if store.canApprove {
                HStack(spacing: ArcTheme.Space.s2) {
                    Button("拒绝") { decide(item, approved: false) }.buttonStyle(.arc(.secondary, block: true))
                    Button("允许") { decide(item, approved: true) }.buttonStyle(.arc(block: true))
                }
                .disabled(submitting || store.isChatSendBlocked(sessionId: item.sessionId))
                if submitting { ProgressView("正在提交决定…").font(.caption) }
            }
        }
        .padding(ArcTheme.Space.s4)
        .arcBackground(ArcTheme.warningSoft, radius: ArcTheme.Radius.lg)
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home-approval-\(item.id)")
    }

    private func decide(_ item: ApprovalItem, approved: Bool) {
        withAnimation(.easeOut(duration: 0.25)) { store.resolve(item.id, approved: approved) }
    }

    private func runningCard(_ session: SessionItem) -> some View {
        let project = store.project(session.projectId)
        return Button {
            store.selectProject(session.projectId)
            path.append(Route.session(projectId: session.projectId, sessionId: session.id))
        } label: {
            ArcCard {
                VStack(alignment: .leading, spacing: ArcTheme.Space.s2) {
                    HStack(spacing: ArcTheme.Space.s2) {
                        if let agent = project?.agent {
                            Image(systemName: agent.symbolName).font(.subheadline).foregroundStyle(agent.tint)
                        }
                        Text(session.title).font(.callout.weight(.semibold)).foregroundStyle(ArcTheme.ink).lineLimit(1)
                        Spacer(minLength: 4)
                        StatusTag(.running)
                    }
                    if !session.detail.isEmpty {
                        Text(session.detail).font(.footnote.monospaced()).foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
                    }
                    Text(project?.name ?? "").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("running-\(session.id)")
    }

    private var projectsHeader: some View {
        let total = store.unifiedProjects().count
        return HStack(spacing: 8) {
            Text("项目")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ArcTheme.ink)
                .accessibilityAddTraits(.isHeader)
            if total > 0 {
                Text("\(total)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ArcTheme.inkMuted)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(ArcTheme.surfaceSunken, in: Capsule())
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
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
                .accessibilityLabel(showSearch ? "关闭搜索" : "搜索项目")

                Button { path.append(Route.addProject(editing: nil)) } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ArcTheme.ink)
                        .frame(width: 36, height: 36)
                        .background(ArcTheme.surface, in: Circle())
                        .overlay(Circle().stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加项目")
            }
        }
        .padding(.leading, 2)
        .padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(ArcTheme.inkFaint)
            TextField("搜索项目", text: $query)
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
                .accessibilityLabel("清除项目搜索")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ArcTheme.line, lineWidth: 0.75)
        )
    }

    @ViewBuilder
    private var projectList: some View {
        let items = sortedProjects()
        if items.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder").font(.title2)
                Text(query.isEmpty ? "还没有项目" : "没有匹配的项目").font(.headline).foregroundStyle(ArcTheme.ink)
                if query.isEmpty {
                    Text("从 Mac 上已有的记录导入，或手动添加路径。").font(.subheadline)
                    Button("添加项目") { path.append(Route.addProject(editing: nil)) }.buttonStyle(.arc())
                } else {
                    Button("清除搜索") { query = "" }.buttonStyle(.arc(.secondary))
                }
            }
            .foregroundStyle(ArcTheme.inkMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, ArcTheme.Space.s8)
        } else {
            ArcListGroup(items, dividerInset: 64) { project in
                let sessions = store.sessions.filter { project.legacyIDs.contains($0.projectId) }
                let sessionIDs = Set(sessions.map(\.id))
                let pending = store.approvals.filter { sessionIDs.contains($0.sessionId) && $0.pending }.count
                let conversations = store.unifiedConversations(project: project)
                let running = conversations.contains { $0.isRunning }
                let totalCount = conversations.count
                Button { openProject(project) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(running ? ArcTheme.live : ArcTheme.primary)
                            .frame(width: 38, height: 38)
                            .background(running ? ArcTheme.liveSoft : ArcTheme.primarySoft.opacity(0.75),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(project.name)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(ArcTheme.ink)
                                .lineLimit(1)
                            Text(project.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(ArcTheme.inkMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        HStack(spacing: 6) {
                            if running {
                                Circle()
                                    .fill(ArcTheme.live)
                                    .frame(width: 7, height: 7)
                            }
                            if pending > 0 {
                                Text("\(pending) 待审批")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(ArcTheme.warning)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(ArcTheme.warningSoft, in: Capsule())
                            }
                            if totalCount > 0 {
                                Text("\(totalCount)")
                                    .font(.footnote.weight(.medium))
                                    .monospacedDigit()
                                    .foregroundStyle(ArcTheme.inkMuted)
                            }
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ArcTheme.inkFaint)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .frame(minHeight: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-\(project.id)")
            }
        }
    }

    @ViewBuilder
    private func projectMetadata(count: Int, pending: Int, running: Bool) -> some View {
        Text("\(count) 个对话").font(.caption).foregroundStyle(ArcTheme.inkMuted)
        if pending > 0 { StatusTag(kind: .waiting, text: "\(pending) 待审批") }
        if running { StatusTag(.running) }
    }

    private func openProject(_ project: UnifiedProjectItem) {
        path.append(Route.unifiedProject(project.path))
    }

    private func sortedProjects() -> [UnifiedProjectItem] {
        store.unifiedProjects(query: query)
    }

}

/// Compact workspace header: Mac name + status in one tight row.
private struct WorkspaceHeader: View {
    enum State: Equatable {
        case online(String), connecting, offline(String)

        var label: String {
            switch self {
            case .online(let text): text
            case .connecting: "连接中…"
            case .offline(let text): text
            }
        }

        var shortLabel: String {
            switch self {
            case .online: "在线"
            case .connecting: "连接中"
            case .offline(let text): text
            }
        }

        var color: Color {
            switch self {
            case .online: ArcTheme.live
            case .connecting: ArcTheme.primary
            case .offline: ArcTheme.inkFaint
            }
        }
    }

    var name: String
    var state: State
    /// The store's full wording, read by VoiceOver; the visible label is shortened.
    var fullState: String
    var pending: Int
    var agents: [AgentInfo]
    var onDevice: () -> Void
    var onApprovals: () -> Void
    var onSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Confident device switcher + crisp circular action buttons
            HStack(spacing: 10) {
                Button(action: onDevice) {
                    HStack(spacing: 8) {
                        statusDot
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Text(name.isEmpty ? "未命名 Mac" : name)
                                    .font(.headline)
                                    .foregroundStyle(ArcTheme.ink)
                                    .lineLimit(1)
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(ArcTheme.inkMuted)
                            }
                            Text(state.shortLabel)
                                .font(.caption)
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                    }
                    .frame(minHeight: ArcTheme.tapMin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(name) · \(fullState)")
                .accessibilityHint("切换设备")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("device-switcher")

                Spacer(minLength: ArcTheme.Space.s2)

                HStack(spacing: 8) {
                    CircleIconButton(symbol: pending > 0 ? "bell.badge" : "bell", badge: pending, action: onApprovals)
                        .accessibilityLabel(pending > 0 ? "审批，\(pending) 项待处理" : "审批")
                        .accessibilityIdentifier("approval-entry")
                    CircleIconButton(symbol: "gearshape", action: onSettings)
                        .accessibilityLabel("设置")
                        .accessibilityIdentifier("settings-entry")
                }
            }
        }
        .padding(.horizontal, ArcTheme.Space.s4)
        .padding(.top, ArcTheme.Space.s2)
        .padding(.bottom, ArcTheme.Space.s2)
        .background(ArcTheme.bg)
    }

    @ViewBuilder private var statusDot: some View {
        let dot = Circle().fill(state.color).frame(width: 8, height: 8)
        if case .online = state, !reduceMotion {
            dot.background {
                PhaseAnimator([false, true]) { expanded in
                    Circle().fill(state.color.opacity(expanded ? 0 : 0.45))
                        .scaleEffect(expanded ? 2.4 : 1)
                } animation: { expanded in expanded ? .easeOut(duration: 1.4) : .linear(duration: 0.01) }
            }
        } else {
            dot
        }
    }
}

/// 40pt round action in the header, with an optional count badge.
private struct CircleIconButton: View {
    var symbol: String
    var badge = 0
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .symbolRenderingMode(badge > 0 ? .palette : .monochrome)
                .foregroundStyle(badge > 0 ? ArcTheme.warning : ArcTheme.ink, ArcTheme.ink)
                .font(.system(size: 17, weight: .medium))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(ArcTheme.surface)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(ArcTheme.warning, in: Capsule())
                            .overlay(Capsule().stroke(ArcTheme.bg, lineWidth: 2))
                            .offset(x: 6, y: -6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 40, height: 40)
                .background(ArcTheme.surface, in: Circle())
                .overlay(Circle().stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                .frame(minWidth: 40, minHeight: ArcTheme.tapMin)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

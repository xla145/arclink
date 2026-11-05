import SwiftUI

/// The Workspace tab: what needs you (approvals), what is running, then the
/// selected agent's projects ordered by recent activity.
struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var showingSearch = false
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
            VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
                if !store.online { offlineBar }
                if !pendingApprovals.isEmpty {
                    ArcSectionHeader("待你批准 · \(pendingApprovals.count)")
                    ForEach(pendingApprovals) { approvalCard($0) }
                }
                if !runningSessions.isEmpty {
                    ArcSectionHeader("进行中").padding(.top, ArcTheme.Space.s2)
                    ForEach(runningSessions) { runningCard($0) }
                }
                ArcSectionHeader(title: "项目") {
                    Button {
                        showingSearch.toggle()
                        if !showingSearch { query = "" }
                    } label: { Image(systemName: "magnifyingglass").frame(width: 36, height: ArcTheme.tapMin) }
                        .accessibilityLabel("搜索项目")
                    Button { path.append(Route.addProject(editing: nil)) } label: {
                        Image(systemName: "plus").frame(width: 36, height: ArcTheme.tapMin)
                    }
                    .accessibilityLabel("添加项目")
                }
                .padding(.top, ArcTheme.Space.s2)
                AgentSwitcher(selection: $store.selectedAgent)
                if showingSearch { searchField }
                if store.selectedAgent.installed {
                    projectList
                } else {
                    ContentUnavailableView("未安装 \(store.selectedAgent.rawValue)", systemImage: store.selectedAgent.symbolName,
                                           description: Text("在 \(store.hostName) 上安装后即可使用，也可以切换到其他 Agent。"))
                        .padding(.top, ArcTheme.Space.s6)
                }
            }
            .padding(.horizontal, ArcTheme.Space.s4)
            .padding(.top, ArcTheme.Space.s2)
            .padding(.bottom, ArcTheme.Space.s4)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable { await store.refreshConversationList(agent: store.selectedAgent) }
        .task(id: "\(store.selectedDeviceID ?? "")/\(store.selectedAgent.agentId)") {
            await store.refreshConversationList(agent: store.selectedAgent, force: false)
        }
        .onAppear {
            // `.task(id:)` above only re-fires when the device/agent selection
            // changes, so returning to Home from a pushed view (same device,
            // same agent) would otherwise never pick up new Mac-side activity
            // once the project catalog's 5-minute cache goes stale. This is a
            // cheap no-op whenever that cache is still fresh.
            Task { await store.refreshConversationList(agent: store.selectedAgent, force: false) }
        }
        .background(ArcTheme.bg)
        // An inset (not an overlay) so it sits above whichever tab bar is showing.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if store.selectedAgent.installed {
                Button {
                    chosenProjectID = store.currentProject(for: store.selectedAgent)?.id ?? ""
                    choosingConversation = true
                } label: {
                    Label("新对话", systemImage: "plus")
                }
                .buttonStyle(.arc(pill: true))
                .accessibilityLabel("新对话")
                .accessibilityIdentifier("chat-fab")
                .padding(.bottom, ArcTheme.Space.s4)
            }
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
                onDevice: { choosingDevice = true },
                onApprovals: { path.append(Route.approvals) },
                onSettings: { path.append(Route.settings) }
            )
        }
        .sheet(isPresented: $choosingConversation) {
            NewConversationSheet(projectID: chosenProjectID) { projectID, sessionID in
                choosingConversation = false
                path.append(Route.session(projectId: projectID, sessionId: sessionID))
            }
        }
        .sheet(isPresented: $choosingDevice) { DevicePickerSheet() }
        .onChange(of: store.selectedAgent) { _, _ in
            query = ""
            choosingConversation = false
        }
        .onChange(of: store.selectedDeviceID) { _, _ in
            choosingConversation = false
            choosingDevice = false
        }
    }

    private var offlineBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
            Text("\(store.hostName) \(store.connectionStateLabel)，显示的是上次同步的内容")
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("重连") { store.reconnectIfNeeded() }
                .buttonStyle(.arc(.secondary))
                .controlSize(.small)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(ArcTheme.inkMuted)
        .padding(.leading, ArcTheme.Space.s3).padding(.vertical, ArcTheme.Space.s1)
        .arcBackground(ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
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

    private var searchField: some View {
        HStack(spacing: ArcTheme.Space.s2) {
            Image(systemName: "magnifyingglass").foregroundStyle(ArcTheme.inkMuted)
            TextField("搜索项目", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(ArcTheme.inkMuted) }
                    .accessibilityLabel("清除项目搜索")
            }
        }
        .font(.body)
        .padding(.horizontal, ArcTheme.Space.s3)
        .frame(minHeight: 40)
        .arcBackground(ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
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
                }
            }
            .foregroundStyle(ArcTheme.inkMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).padding(.vertical, ArcTheme.Space.s8)
        } else {
            ArcListGroup(items) { project in
                let sessions = store.sessions(for: project.id)
                let pending = store.pendingCount(projectId: project.id)
                let running = sessions.contains { $0.status == .running }
                Button { openProject(project) } label: {
                    ArcListRow(title: project.name, subtitle: "\(sessions.count) 个对话 · \(project.path)",
                               trailing: Self.relativeFormatter.localizedString(for: lastActivity(project), relativeTo: Date())) {
                        IconTile(symbol: "folder")
                    } tags: {
                        if pending > 0 { StatusTag(kind: .waiting, text: "\(pending) 待审批") }
                        if running { StatusTag(.running) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-\(project.id)")
            }
        }
    }

    private func openProject(_ project: ProjectItem) {
        store.selectProject(project.id)
        path.append(Route.project(project.id))
    }

    private func lastActivity(_ project: ProjectItem) -> Date {
        store.sessions(for: project.id).map(\.createdAt).max() ?? project.createdAt
    }

    private func sortedProjects() -> [ProjectItem] {
        store.projects(for: store.selectedAgent, query: query).sorted { lastActivity($0) > lastActivity($1) }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Workspace header: the current Mac with a live status dot, then approvals and settings.
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
    var onDevice: () -> Void
    var onApprovals: () -> Void
    var onSettings: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: ArcTheme.Space.s3) {
            Button(action: onDevice) {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(ArcTheme.primary)
                        .frame(width: 40, height: 40)
                        .arcBackground(ArcTheme.primarySoft, radius: ArcTheme.Radius.md)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(name.isEmpty ? "未命名 Mac" : name)
                                .font(.headline).foregroundStyle(ArcTheme.ink).lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold)).foregroundStyle(ArcTheme.inkMuted)
                        }
                        HStack(spacing: 6) {
                            statusDot
                            Text(state.label).font(.caption.weight(.medium)).foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
                        }
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

            CircleIconButton(symbol: pending > 0 ? "bell.badge" : "bell", badge: pending, action: onApprovals)
                .accessibilityLabel(pending > 0 ? "审批，\(pending) 项待处理" : "审批")
                .accessibilityIdentifier("approval-entry")
            CircleIconButton(symbol: "gearshape", action: onSettings)
                .accessibilityLabel("设置")
                .accessibilityIdentifier("settings-entry")
        }
        .padding(.horizontal, ArcTheme.Space.s4)
        .padding(.top, ArcTheme.Space.s1)
        .padding(.bottom, ArcTheme.Space.s2)
        .background(ArcTheme.bg)
    }

    @ViewBuilder private var statusDot: some View {
        let dot = Circle().fill(state.color).frame(width: 8, height: 8)
        if case .online = state, !reduceMotion {
            // A soft ring that breathes outward while the Mac is reachable.
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
                .frame(width: 40, height: 40)
                .background(ArcTheme.surface, in: Circle())
                .overlay(Circle().stroke(ArcTheme.line, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text(badge > 99 ? "99+" : "\(badge)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(ArcTheme.surface)
                            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                            .background(ArcTheme.warning, in: Capsule())
                            .overlay(Capsule().stroke(ArcTheme.bg, lineWidth: 2))
                            .offset(x: 6, y: -4)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: ArcTheme.tapMin, height: ArcTheme.tapMin)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

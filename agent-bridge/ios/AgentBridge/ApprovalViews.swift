import SwiftUI

struct ApprovalListView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var showingHistory = false

    private var pending: [ApprovalItem] { store.approvals.filter(\.pending) }
    private var history: [ApprovalItem] { store.approvals.filter { !$0.pending } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
                Picker("审批范围", selection: $showingHistory) {
                    Text("待处理 \(pending.count)").tag(false)
                    Text("历史").tag(true)
                }
                .pickerStyle(.segmented)
                let items = showingHistory ? history : pending
                if items.isEmpty {
                    VStack(spacing: ArcTheme.Space.s2) {
                        Image(systemName: "checkmark.circle").font(.title2)
                        Text(showingHistory ? "还没有审批记录" : "没有待处理的审批").font(.headline).foregroundStyle(ArcTheme.ink)
                        if !showingHistory {
                            Text("Agent 需要执行命令或写入文件时，会在这里请求你的批准。").font(.subheadline)
                        }
                    }
                    .foregroundStyle(ArcTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity).padding(.vertical, ArcTheme.Space.s8)
                } else {
                    ArcListGroup(items) { item in row(item) }
                    if !showingHistory {
                        Text("“项目内读写”权限下，越界的命令和写入需要你批准；“完全访问”不会请求审批。")
                            .font(.footnote).foregroundStyle(ArcTheme.inkMuted).padding(.horizontal, ArcTheme.Space.s1)
                    }
                }
            }
            .padding(.horizontal, ArcTheme.Space.s4)
            .padding(.bottom, ArcTheme.Space.s6)
        }
        .background(ArcTheme.bg)
        .navigationTitle("审批")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: ApprovalItem) -> some View {
        let project = store.sessions.first { $0.id == item.sessionId }.flatMap { store.project($0.projectId) }
        let session = store.sessions.first { $0.id == item.sessionId }
        return Button { path.append(Route.approval(item.id)) } label: {
            ArcListRow(title: item.title,
                       subtitle: [project.map { "\($0.agent.shortName) · \($0.name)" } ?? "项目已移除", session?.title]
                           .compactMap { $0 }.joined(separator: " · ")) {
                IconTile(symbol: project?.agent.symbolName ?? "folder", tint: project?.agent.tint)
            } tags: {
                if item.pending {
                    StatusTag(kind: .waiting, text: "待审批")
                } else if item.approved == true {
                    StatusTag(kind: .done, text: "已允许")
                } else {
                    StatusTag(kind: .failed, text: "已拒绝")
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("approval-\(item.id)")
    }
}

struct ApprovalDetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var id: String

    private var item: ApprovalItem? { store.approvals.first { $0.id == id } }
    private var session: SessionItem? { item.flatMap { request in store.sessions.first { $0.id == request.sessionId } } }
    private var project: ProjectItem? { session.flatMap { store.project($0.projectId) } }

    var body: some View {
        ScrollView {
            if let item {
                let writes = item.kind.contains("写入")
                VStack(alignment: .leading, spacing: ArcTheme.Space.s4) {
                    ArcCard(padding: ArcTheme.Space.s3) {
                        HStack(spacing: ArcTheme.Space.s3) {
                            IconTile(symbol: project?.agent.symbolName ?? "folder", tint: project?.agent.tint)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session?.title ?? "对话已移除").font(.callout.weight(.medium)).foregroundStyle(ArcTheme.ink)
                                Text("\(project?.agent.rawValue ?? "项目已移除") · \(project?.name ?? "未知项目")")
                                    .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: ArcTheme.Space.s2) {
                        if item.pending {
                            StatusTag(kind: .waiting, text: "等待你批准 · \(item.kind)")
                        } else {
                            StatusTag(kind: item.approved == true ? .done : .failed, text: item.approved == true ? "已允许" : "已拒绝")
                        }
                        Text(writes ? "允许写入这个文件？" : "允许执行这条命令？")
                            .font(.title2.bold()).foregroundStyle(ArcTheme.ink)
                            .accessibilityAddTraits(.isHeader)
                        Text(item.title).font(.subheadline).foregroundStyle(ArcTheme.inkMuted)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text(writes ? item.target : "命令")
                            Spacer()
                            Button("复制") {
                                UIPasteboard.general.string = writes ? item.detail : item.target
                                store.show("已复制")
                            }
                        }
                        .font(.caption.weight(.medium)).foregroundStyle(ArcTheme.codeMuted)
                        .padding(.horizontal, ArcTheme.Space.s3).frame(minHeight: 36)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
                        Text(writes ? item.detail : "$ \(item.target)")
                            .font(.footnote.monospaced()).foregroundStyle(ArcTheme.codeInk)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(ArcTheme.Space.s3)
                    }
                    .arcBackground(ArcTheme.codeBg, radius: ArcTheme.Radius.md)
                    if !writes && !item.detail.isEmpty {
                        Text(item.detail).font(.subheadline).foregroundStyle(ArcTheme.inkMuted)
                    }
                    VStack(spacing: 0) {
                        if let project {
                            infoRow("工作目录", value: project.path, mono: true)
                            ArcDivider(inset: ArcTheme.Space.s4)
                        }
                        infoRow("审批 ID", value: item.id, mono: true)
                    }
                    .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.lg)
                    Text(store.isRemoteChatSession(sessionId: item.sessionId) ? "决定将发送给 Mac 上的 Codex。" : "本地模拟审批 · 决定仅保存在手机，不会执行 Mac 操作。")
                        .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                }
                .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, ArcTheme.Space.s3)
            }
        }
        .background(ArcTheme.bg)
        .navigationTitle("审批")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let item {
                if item.pending && store.canApprove {
                    HStack(spacing: ArcTheme.Space.s2) {
                        Button("拒绝") { resolve(false) }.buttonStyle(.arc(.secondary, block: true))
                        Button("允许") { resolve(true) }.buttonStyle(.arc(block: true))
                    }
                    .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, 10)
                    .background(ArcTheme.bg)
                    .overlay(alignment: .top) { Rectangle().fill(ArcTheme.line).frame(height: 0.5) }
                } else if !item.pending {
                    Text(item.approved == true ? "你已允许这次操作" : "你已拒绝这次操作")
                        .font(.subheadline.weight(.medium)).foregroundStyle(ArcTheme.inkMuted)
                        .frame(maxWidth: .infinity).padding(.vertical, ArcTheme.Space.s4)
                        .background(ArcTheme.bg)
                        .overlay(alignment: .top) { Rectangle().fill(ArcTheme.line).frame(height: 0.5) }
                }
            }
        }
    }

    private func infoRow(_ title: String, value: String, mono: Bool) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.body).foregroundStyle(ArcTheme.ink)
            Spacer(minLength: ArcTheme.Space.s3)
            Text(value).font(mono ? .footnote.monospaced() : .subheadline).foregroundStyle(ArcTheme.inkMuted)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, ArcTheme.Space.s4).frame(minHeight: 48)
    }

    private func resolve(_ approved: Bool) {
        store.resolve(id, approved: approved)
        dismiss()
    }
}

struct TerminalView: View {
    @Environment(AppStore.self) private var store
    var sessionId: String
    @State private var terminal = TerminalSession()

    private var session: SessionItem? { store.sessions.first { $0.id == sessionId } }
    private var project: ProjectItem? { session.flatMap { store.project($0.projectId) } }

    /// Starting a real process needs an actually-connected Mac and an
    /// Agent version it has verified transport support for — matching the
    /// same gate `agentd::start_process` itself enforces server-side.
    private var canRunReal: Bool {
        guard !store.isRemoteChatSession(sessionId: sessionId),
              store.connectionState == .connected, let project else { return false }
        return store.macAgents.first { $0.id == project.agent.agentId }?.validation == "verified"
    }

    private var lines: [String] {
        var output: [String] = []
        if let session, let project {
            output.append("$ cd \(project.path)")
            output.append("# \(project.agent.rawValue) · \(session.title) · \(session.status.rawValue)")
        }
        for message in store.messages where message.sessionId == sessionId {
            let who = message.isUser ? "you" : "agent"
            output.append("[\(message.time)] \(who): \(message.text)")
            if message.imageData != nil {
                output.append("[\(message.time)] \(who): [image]")
            }
        }
        for approval in store.approvals where approval.sessionId == sessionId {
            let state = approval.pending ? "pending" : (approval.approved == true ? "approved" : "rejected")
            output.append("# approval \(state): \(approval.kind) · \(approval.target)")
        }
        if output.count <= 1 {
            output.append("# 这个会话还没有输出。")
        }
        return output
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if session?.realProcessId != nil && !store.isRemoteChatSession(sessionId: sessionId) {
                    if case .failed(let message) = terminal.runState {
                        Text("# \(message)").foregroundStyle(ArcTheme.codeDanger)
                    }
                    if terminal.liveLines.isEmpty {
                        Text("# 正在连接真实进程的输出…")
                    }
                    ForEach(Array(terminal.liveLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .foregroundStyle(line.hasPrefix("!") ? ArcTheme.codeDanger : (line.hasPrefix("#") ? ArcTheme.codeMuted : ArcTheme.codeInk))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .foregroundStyle(line.hasPrefix("#") ? ArcTheme.codeMuted : ArcTheme.codeInk)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(ArcTheme.codeBg)
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ArcTheme.codeBg, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !store.isRemoteChatSession(sessionId: sessionId) && (canRunReal || session?.realProcessId != nil) {
                ToolbarItem(placement: .topBarTrailing) {
                    runControlButton
                }
            }
        }
        .task { await attachIfNeeded() }
        .onDisappear { terminal.detach() }
    }

    @ViewBuilder private var runControlButton: some View {
        switch terminal.runState {
        case .running, .attaching:
            Button("停止") { Task { await stopReal() } }.foregroundStyle(ArcTheme.codeDanger)
        case .starting, .stopping:
            ProgressView()
        default:
            if canRunReal {
                Button("启动") { Task { await startReal() } }
            }
        }
    }

    private func attachIfNeeded() async {
        guard !store.isRemoteChatSession(sessionId: sessionId) else { return }
        guard let bridge = store.macBridge, let session,
              let processId = session.realProcessId, let generation = session.realGeneration
        else { return }
        await terminal.attach(bridge: bridge, processId: processId, generation: generation)
    }

    private func startReal() async {
        guard !store.isRemoteChatSession(sessionId: sessionId) else { return }
        guard let deviceID = store.selectedDeviceID, let bridge = store.macBridge, let session, let project else { return }
        guard let info = await terminal.start(
            bridge: bridge, sessionId: session.id, agentId: project.agent.agentId, cwd: project.path
        ) else { return }
        store.setRealProcess(deviceID: deviceID, sessionId: session.id, processId: info.processId, generation: info.generation)
        guard store.selectedDeviceID == deviceID, !Task.isCancelled else { return }
        if info.state == "running" || info.state == "starting" {
            await terminal.attach(bridge: bridge, processId: info.processId, generation: info.generation)
        } else {
            terminal.runState = .stopped(exitCode: info.exitCode)
        }
    }

    private func stopReal() async {
        guard !store.isRemoteChatSession(sessionId: sessionId) else { return }
        guard let bridge = store.macBridge, let session,
              let processId = session.realProcessId, let generation = session.realGeneration
        else { return }
        await terminal.stop(bridge: bridge, processId: processId, generation: generation)
        terminal.detach()
    }
}

import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var projectId: String
    var sessionId: String?
    @Binding var path: NavigationPath
    /// Set when this new conversation forks a read-only desktop conversation.
    var forkSourceId: String? = nil

    @State private var liveId: String?
    @State private var draft = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var attachments: [DraftImage] = []
    @State private var attachmentEpoch = UUID()
    @State private var loadingImages = false
    @State private var expandedImage: ChatImagePreview?
    @State private var macMessages: [MacMessage] = []
    @State private var loadingMac = false
    @State private var macError: String?
    @State private var historyContinuation: ImportedHistoryContinuation?
    @State private var more = false
    @State private var submitting = false
    @FocusState private var composing: Bool
    @State private var scrollTracker = ChatScrollTracker()
    @State private var followsLatest = true
    @State private var scrollRequest = 0
    // Options for a conversation that has not been created yet; sent with the first message.
    @State private var newModel = ""
    @State private var newPolicy: SessionExecutionPolicy = .workspace
    @State private var models: [MacModel] = []
    /// All agents' models, keyed by agent kind, for cross-agent model switching.
    @State private var allAgentModels: [AgentKind: [MacModel]] = [:]
    @State private var showModelPicker = false
    @State private var selectedModelAgent: AgentKind? = nil

    private var resolvedId: String? { liveId ?? sessionId }
    private var sessionRow: SessionItem? { store.sessions.first { $0.id == resolvedId && $0.projectId == projectId } }
    private var isMacThread: Bool { sessionRow?.isReadOnly == true }
    private var project: ProjectItem? { store.project(projectId) }
    private var forkSource: SessionItem? { forkSourceId.flatMap { id in store.sessions.first { $0.id == id } } }
    /// Forking needs the agent's own native fork; only Codex conversations have one today.
    private var canFork: Bool { project?.agent == .codex && store.canSend }
    private var thread: [ChatMessage] { store.messages.filter { $0.sessionId == resolvedId } }
    private var requests: [ApprovalItem] { store.approvals.filter { $0.sessionId == resolvedId } }
    private var remoteChat: Bool { store.usesRemoteChat }
    private var busy: Bool { submitting || resolvedId.map { store.isChatBusy(sessionId: $0) } == true }
    private var canCompose: Bool { !isMacThread && store.canSend && project != nil && (resolvedId == nil || sessionRow != nil) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    if typeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(sessionRow?.title ?? "新对话").font(.title2.bold())
                            contextHeader
                        }.accessibilityAddTraits(.isHeader)
                    }
                    if isMacThread {
                        history
                    } else if thread.isEmpty {
                        newConversationIntro
                    }
                    if !isMacThread {
                        ForEach(ConversationTurn.live(thread)) { message in
                            messageRow(isUser: message.isUser, text: message.text, time: message.time,
                                       images: message.images, steps: message.steps, summary: message.summary)
                        }
                        ForEach(requests) { request in
                            approvalCard(request)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, ArcTheme.Space.s4)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ChatBottomPreference.self,
                        value: ChatScrollPosition(top: geometry.frame(in: .named("chat-scroll")).minY,
                                                          bottom: geometry.frame(in: .named("chat-scroll")).maxY))
                })
            }
            .coordinateSpace(name: "chat-scroll")
            .background(ArcTheme.chatBg)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { scrollTracker.viewportHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in scrollTracker.viewportHeight = height }
            })
            .onPreferenceChange(ChatBottomPreference.self) { bottom in
                guard let bottom else { return }
                scrollTracker.bottomPosition = bottom.bottom
                scrollTracker.state.observe(bottom, viewport: scrollTracker.viewportHeight)
                let next = scrollTracker.state.followsLatest
                if next != followsLatest { followsLatest = next }
            }
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if value.translation.height > 5 {
                    scrollTracker.state.followsLatest = false
                    if followsLatest { followsLatest = false }
                }
            }.onEnded { _ in
                let next = scrollTracker.bottomPosition <= scrollTracker.viewportHeight + 32
                scrollTracker.state.followsLatest = next
                if next != followsLatest { followsLatest = next }
            })
            .scrollDismissesKeyboard(.interactively)
            .task(id: "\(store.online)") { await loadModels() }
            .task(id: sessionId) {
                await loadMacMessages()
                if !Task.isCancelled { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            #if DEBUG
            .task(id: sessionId) { await applyLiveUpdateFixture() }
            #endif
            .onChange(of: thread) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: requests) { _, _ in
                if followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: scrollRequest) { _, _ in
                scrollTracker.state.followsLatest = true
                if !followsLatest { followsLatest = true }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: composing) { _, active in
                if active && followsLatest {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        if composing && followsLatest { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !followsLatest {
                    Button { scrollRequest += 1 } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(ArcTheme.ink)
                            .frame(width: 38, height: 38)
                            .background(ArcTheme.surface, in: Circle())
                            .overlay(Circle().stroke(ArcTheme.line.opacity(0.8), lineWidth: 0.75))
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("回到最新")
                    .accessibilityIdentifier("chat-latest")
                    .padding(.bottom, 12)
                }
            }
            }
            composer
        }
        .navigationTitle("对话")
        .navigationBarTitleDisplayMode(.inline)
        .arcBackButton("项目")
        .tint(ArcTheme.ink)
        .toolbarBackground(ArcTheme.chatBg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if typeSize.isAccessibilitySize {
                    Text("对话").font(.headline)
                } else {
                    VStack(spacing: 1) {
                        Text(sessionRow?.title ?? "新对话")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ArcTheme.ink)
                            .lineLimit(1)
                        contextHeader
                    }
                }
            }
            if !isMacThread {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { more = true } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(ArcTheme.ink)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("会话操作").disabled(resolvedId == nil)
                }
            }
        }
        .confirmationDialog("会话", isPresented: $more, titleVisibility: .hidden) {
            if let id = resolvedId, !isMacThread {
                Button("终端") { path.append(Route.terminal(id)) }
                    .disabled(store.isRemoteChatSession(sessionId: id))
                Button("取消当前任务") { store.cancelPending(sessionId: id) }
                Button("停止会话") { store.stopSession(id: id) }
                Button("删除会话记录", role: .destructive) { store.deleteSession(id: id); path.removeLast() }
            }
        }
        .sheet(item: $expandedImage) { preview in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: preview.image).resizable().scaledToFit()
                        .frame(width: min(preview.image.size.width, UIScreen.main.bounds.width - 32)).padding()
                }
                .navigationTitle("图片预览").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { expandedImage = nil } }
            }
        }
        .sheet(item: $historyContinuation) { history in
            NewManagedTaskSheet(initialDeviceID: history.deviceID, initialProjectPath: history.projectPath, historyContinuation: history) { device, thread in
                historyContinuation = nil
                guard store.selectedDeviceID == device else { return }
                path.append(Route.deviceThread(deviceID: device, threadID: thread))
            }
        }
        .sheet(isPresented: $showModelPicker) {
            let currentModel = sessionRow?.chatOptions?.model ?? newModel
            let currentAgent = selectedModelAgent ?? project?.agent ?? .codex
            let policyBinding = Binding<SessionExecutionPolicy>(
                get: { sessionRow?.chatOptions?.executionPolicy ?? newPolicy },
                set: { updated in
                    newPolicy = updated
                    if let id = resolvedId, let index = store.sessions.firstIndex(where: { $0.id == id }) {
                        var opts = store.sessions[index].chatOptions ?? ChatSessionOptions()
                        opts.executionPolicy = updated
                        store.sessions[index].chatOptions = opts
                        store.save()
                    }
                }
            )
            AgentModelPickerSheet(
                activeAgent: currentAgent,
                selectedModel: currentModel,
                policy: policyBinding,
                allAgentModels: allAgentModels,
                loadingModels: false,
                online: store.online
            ) { agent, modelId in
                selectedModelAgent = agent
                if resolvedId != nil {
                    updateModel(modelId)
                } else {
                    newModel = modelId
                }
                showModelPicker = false
            }
        }
        .onDisappear { attachmentEpoch = UUID(); loadingImages = false }
    }

    // MARK: New conversation

    /// A new CLI conversation inside a project only needs a model and a permission;
    /// the project and Mac are already in the navigation bar.
    private var newConversationIntro: some View {
        VStack(alignment: .leading, spacing: ArcTheme.Space.s2) {
            ArcSectionHeader(forkSource.map { "分叉自「\($0.title)」" } ?? "新对话设置")
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: ArcTheme.Space.s3) {
                    Text("项目").foregroundStyle(ArcTheme.ink)
                    Spacer(minLength: ArcTheme.Space.s2)
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(project?.name ?? "项目不存在").foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
                        if let project {
                            Text(project.path).font(.caption.monospaced()).foregroundStyle(ArcTheme.inkMuted)
                                .lineLimit(1).truncationMode(.head)
                        }
                    }
                }
                .padding(.horizontal, ArcTheme.Space.s4).frame(minHeight: 56)
                .accessibilityElement(children: .combine)
                ArcDivider(inset: ArcTheme.Space.s4)
                settingRow("模型") {
                    Picker("模型", selection: $newModel) {
                        Text("跟随 Mac 设置").tag("")
                        ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("chat-new-model")
                }
                ArcDivider(inset: ArcTheme.Space.s4)
                settingRow("权限") {
                    Picker("权限", selection: $newPolicy) {
                        ForEach(SessionExecutionPolicy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("chat-new-permission")
                }
            }
            .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.lg)
            .disabled(!canCompose)
        }
        .padding(.top, ArcTheme.Space.s2)
    }

    private func settingRow(_ title: String, @ViewBuilder picker: () -> some View) -> some View {
        HStack {
            Text(title).foregroundStyle(ArcTheme.ink)
            Spacer()
            picker().pickerStyle(.menu).tint(ArcTheme.ink)
        }
        .padding(.leading, ArcTheme.Space.s4).padding(.trailing, ArcTheme.Space.s2).frame(minHeight: 52)
    }


    /// The model this conversation was created with — searches across all agents.
    private var currentModelName: String {
        let id = sessionRow?.chatOptions?.model ?? ""
        if id.isEmpty { return "跟随 Mac" }
        // Search across all agents' model lists
        for (_, agentModels) in allAgentModels {
            if let match = agentModels.first(where: { $0.id == id }) { return match.name }
        }
        return models.first { $0.id == id }?.name ?? id
    }

    private var currentPolicy: SessionExecutionPolicy { sessionRow?.chatOptions?.executionPolicy ?? .workspace }

    /// Read-only reminders of what this conversation runs with; chosen before the first message.
    /// When idle and not read-only, the model chip becomes an interactive picker showing all agents' models.
    private var modelChip: some View {
        let canSwitch = resolvedId != nil && !isMacThread && !busy
        let currentModel = sessionRow?.chatOptions?.model ?? ""
        let hasAnyModels = !allAgentModels.isEmpty || !models.isEmpty
        return Group {
            if canSwitch {
                Menu {
                    Button { updateModel("") } label: {
                        HStack {
                            Text("跟随 Mac 设置")
                            if currentModel.isEmpty { Image(systemName: "checkmark") }
                        }
                    }
                    // Show models grouped by agent
                    ForEach(AgentKind.allCases.filter { $0.installed && !(allAgentModels[$0] ?? []).isEmpty }, id: \.self) { agent in
                        Section(agent.shortName) {
                            ForEach(allAgentModels[agent] ?? [], id: \.id) { model in
                                Button { updateModel(model.id) } label: {
                                    HStack {
                                        Text(model.name)
                                        if currentModel == model.id { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        }
                    }
                    // Fallback: show flat models list if allAgentModels is empty but models loaded
                    if allAgentModels.isEmpty && !models.isEmpty {
                        ForEach(models, id: \.id) { model in
                            Button { updateModel(model.id) } label: {
                                HStack {
                                    Text(model.name)
                                    if currentModel == model.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    modelChipContent(interactive: true)
                }
                .accessibilityLabel("切换模型，当前 \(currentModelName)")
            } else {
                modelChipContent(interactive: false)
                    .accessibilityLabel("模型，\(currentModelName)")
            }
        }
    }

    /// The visual chip showing current agent icon + model name.
    private func modelChipContent(interactive: Bool) -> some View {
        let currentModel = sessionRow?.chatOptions?.model ?? ""
        // Find which agent this model belongs to
        let modelAgent: AgentKind? = {
            if currentModel.isEmpty { return project?.agent }
            for (agent, models) in allAgentModels {
                if models.contains(where: { $0.id == currentModel }) { return agent }
            }
            return project?.agent
        }()
        return chipLabel(currentModelName,
                         symbol: modelAgent?.symbolName ?? project?.agent.symbolName ?? "sparkle",
                         tint: modelAgent?.tint ?? project?.agent.tint,
                         interactive: interactive)
    }

    private func updateModel(_ modelId: String) {
        guard let id = resolvedId else { return }
        let newModel = modelId.isEmpty ? nil : modelId
        // For unsent sessions, use the full configure path
        if store.canConfigureUnsentSession(id) {
            let options = ChatSessionOptions(model: newModel,
                                             executionPolicy: sessionRow?.chatOptions?.executionPolicy ?? .workspace,
                                             forkFromThreadId: sessionRow?.chatOptions?.forkFromThreadId)
            _ = store.configureUnsentSession(id, projectID: projectId, options: options)
        } else {
            // For active sessions, just update the stored model preference
            if let index = store.sessions.firstIndex(where: { $0.id == id }) {
                var opts = store.sessions[index].chatOptions ?? ChatSessionOptions()
                opts.model = newModel
                store.sessions[index].chatOptions = opts
                store.save()
                newModel.map { _ in store.show("模型已切换，下次发送生效") } ?? store.show("已恢复跟随 Mac 设置")
            }
        }
    }

    private var policyChip: some View {
        let short = switch currentPolicy { case .readOnly: "只读"; case .workspace: "读写"; case .fullAccess: "完全" }
        return chipLabel(short, symbol: currentPolicy == .fullAccess ? "exclamationmark.shield" : "shield", tint: nil)
            .accessibilityLabel("权限，\(currentPolicy.rawValue)")
    }

    private func chipLabel(_ text: String, symbol: String, tint: Color?, interactive: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint ?? ArcTheme.inkMuted)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(interactive ? ArcTheme.ink : ArcTheme.inkMuted)
                .lineLimit(1)
            if interactive {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(ArcTheme.inkFaint)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(ArcTheme.surfaceSunken, in: Capsule())
        .accessibilityElement(children: .ignore)
    }

    private func loadModels() async {
        guard let bridge = store.macBridge else { return }
        let device = store.selectedDeviceID
        // Load models for all installed agents
        for agent in AgentKind.allCases where agent.installed {
            guard let result = try? await bridge.listAgentModels(agentId: agent.agentId),
                  !Task.isCancelled, device == store.selectedDeviceID else { continue }
            allAgentModels[agent] = result
            // Keep backward compat: `models` is the current project's agent models
            if agent == project?.agent { models = result }
        }
    }

    private var contextHeader: some View {
        HStack(spacing: 4) {
            if store.online {
                Circle()
                    .fill(ArcTheme.live)
                    .frame(width: 5, height: 5)
            }
            Text("\(project?.name ?? "项目不存在") · \(store.hostName.isEmpty ? "本地" : store.hostName)\(isMacThread ? " · 只读" : "")")
                .font(.caption2)
                .foregroundStyle(ArcTheme.inkMuted)
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chat-context")
    }

    private func approvalCard(_ request: ApprovalItem) -> some View {
        let pending = request.pending
        let approved = request.approved == true
        let submitting = store.isApprovalSubmitting(request.id, sessionId: request.sessionId)
        return VStack(alignment: .leading, spacing: 10) {
            // Header row: icon + title + status badge
            HStack(spacing: 8) {
                Image(systemName: pending ? "shield.lefthalf.filled" : (approved ? "checkmark.circle.fill" : "xmark.circle.fill"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(pending ? ArcTheme.warning : (approved ? ArcTheme.success : ArcTheme.inkMuted))
                    .frame(width: 24, height: 24)
                    .background((pending ? ArcTheme.warningSoft : (approved ? ArcTheme.successSoft : ArcTheme.surfaceSunken)),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(request.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArcTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(pending ? "待确认" : (approved ? "已允许" : "已拒绝"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(pending ? ArcTheme.warning : (approved ? ArcTheme.success : ArcTheme.inkMuted))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(pending ? ArcTheme.warningSoft : (approved ? ArcTheme.successSoft : ArcTheme.surfaceSunken),
                                in: Capsule())
            }

            // Target file or command pill
            Text(request.kind.contains("写入") ? request.target : "$ \(request.target)")
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(ArcTheme.ink)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            // Action row when pending
            if pending && store.canApprove {
                if submitting {
                    HStack {
                        Spacer()
                        ProgressView().controlSize(.small)
                        Spacer()
                    }
                    .frame(height: 36)
                } else {
                    HStack(spacing: 8) {
                        Button { store.resolve(request.id, approved: false) } label: {
                            Text("拒绝")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ArcTheme.ink)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isChatSendBlocked(sessionId: request.sessionId))

                        Button { store.resolve(request.id, approved: true) } label: {
                            Text("允许")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(ArcTheme.onPrimary)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(ArcTheme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.isChatSendBlocked(sessionId: request.sessionId))
                    }
                }
            }
        }
        .padding(12)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(pending ? ArcTheme.warning.opacity(0.35) : ArcTheme.line, lineWidth: 1)
        )
        .shadow(color: pending ? .black.opacity(0.05) : .clear, radius: 8, y: 3)
        .accessibilityIdentifier("approval-event-\(request.id)")
    }

    @ViewBuilder private var history: some View {
        if loadingMac {
            ProgressView("正在读取 Mac 对话…").frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let macError {
            ContentUnavailableView("无法读取对话", systemImage: "wifi.exclamationmark", description: Text(macError))
            Button("重试") { Task { await loadMacMessages() } }
                .buttonStyle(.arc(.secondary)).frame(maxWidth: .infinity)
        } else if macMessages.isEmpty {
            ContentUnavailableView("暂无消息", systemImage: "bubble.left.and.bubble.right", description: Text("Mac 上的这条对话还没有可显示的消息。"))
        } else {
            ForEach(macTurns) { turn in
                messageRow(isUser: turn.isUser, text: turn.text, time: turn.time, steps: turn.steps, summary: turn.summary)
            }
        }
    }

    private var macTurns: [ConversationTurn] {
        ConversationTurn.history(macMessages) { timestamp in
            timestamp.flatMap(AppStore.parseRFC3339).map { Self.chatClock.string(from: $0) } ?? ""
        }
    }

    @ViewBuilder
    private func messageRow(isUser: Bool, text: String, time: String, images: [Data] = [], steps: [MessageStep] = [], summary: ConversationSummary) -> some View {
        if isUser {
            // User bubble: right-aligned, crisp neutral pill
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    if !text.isEmpty {
                        UserMessageBody(text: text)
                            .font(.subheadline)
                            .lineSpacing(3)
                    }
                    ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                        if let image = UIImage(data: data) {
                            Button { expandedImage = ChatImagePreview(image: image) } label: {
                                Image(uiImage: image).resizable().scaledToFit()
                                    .frame(maxHeight: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                            }
                            .buttonStyle(.plain).accessibilityLabel("查看图片 \(index + 1)")
                        }
                    }
                }
                .foregroundStyle(ArcTheme.ink)
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ArcTheme.userBubble, in: UnevenRoundedRectangle(
                    topLeadingRadius: 18, bottomLeadingRadius: 18,
                    bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous))
                if !time.isEmpty {
                    Text(time)
                        .font(.caption2)
                        .foregroundStyle(ArcTheme.inkFaint)
                        .monospacedDigit()
                        .padding(.trailing, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, typeSize.isAccessibilitySize ? 16 : 48)
        } else {
            // Agent message: T3 Code editorial layout — clean steps + prose without boxed header chrome
            VStack(alignment: .leading, spacing: 12) {
                if !steps.isEmpty {
                    InlineStepsGroup(steps: steps)
                }
                if !text.isEmpty {
                    MacMessageText(text: text).textSelection(.enabled)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Button { expandedImage = ChatImagePreview(image: image) } label: {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                        }
                        .buttonStyle(.plain).accessibilityLabel("查看图片 \(index + 1)")
                    }
                }
                ConversationSummaryView(summary: summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contextMenu {
                if !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        store.show("已复制回复的 Markdown")
                    } label: { Label("复制", systemImage: "doc.on.doc") }
                }
            }
        }
    }

    @ViewBuilder private var composer: some View {
        if isMacThread {
            desktopSessionBar
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(attachments) { item in
                                if let image = UIImage(data: item.data) {
                                    ZStack(alignment: .topTrailing) {
                                        Button { expandedImage = ChatImagePreview(image: image) } label: {
                                            Image(uiImage: image).resizable().scaledToFill().frame(width: 68, height: 68)
                                                .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.sm, style: .continuous))
                                        }.buttonStyle(.plain).accessibilityLabel("预览待发送图片")
                                        Button {
                                            attachments.removeAll { $0.id == item.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                                .foregroundStyle(ArcTheme.bg, ArcTheme.ink).frame(width: 28, height: 28)
                                        }.accessibilityLabel("移除图片")
                                    }
                                }
                            }
                        }
                    }
                }
                if let id = resolvedId, let label = store.chatRecoveryLabel(sessionId: id) {
                    HStack(spacing: ArcTheme.Space.s2) {
                        if store.isChatRecovering(sessionId: id) { ProgressView() } else {
                            Image(systemName: "wifi.exclamationmark").accessibilityHidden(true)
                        }
                        Text(label).frame(maxWidth: .infinity, alignment: .leading)
                        Button("重试连接") { store.retryChatConnection(sessionId: id) }
                            .font(.footnote.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                            .padding(.horizontal, 10).frame(minHeight: 32)
                            .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.sm)
                            .disabled(store.isChatRecovering(sessionId: id))
                    }
                    .font(.footnote.weight(.medium)).foregroundStyle(ArcTheme.inkMuted)
                    .padding(.leading, ArcTheme.Space.s3).padding(.trailing, ArcTheme.Space.s2).padding(.vertical, ArcTheme.Space.s2)
                    .arcBackground(ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
                    .accessibilityIdentifier("chat-recovery")
                }
                if let id = resolvedId, let error = store.chatError(sessionId: id) {
                    ArcBanner(text: error).accessibilityIdentifier("remote-chat-error")
                }
                if busy && resolvedId.flatMap({ store.chatRecoveryLabel(sessionId: $0) }) == nil {
                    AgentThinkingIndicator(agent: selectedModelAgent ?? project?.agent ?? .codex, label: "正在思考")
                }
                if !store.canSend {
                    Text("当前权限仅可查看\(store.canApprove ? "和审批" : "")，不能发送新任务。")
                        .font(.footnote).foregroundStyle(ArcTheme.warning)
                }
                // Signature T3 Code floating capsule composer
                HStack(alignment: .bottom, spacing: 8) {
                    PhotosPicker(selection: $picked, maxSelectionCount: max(1, ChatAttachment.maximumCount - attachments.count), matching: .images) {
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(ArcTheme.ink)
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel("从相册添加图片")
                    .disabled(!canCompose || loadingImages || attachments.count >= ChatAttachment.maximumCount)
                    .onChange(of: picked) { _, items in loadImages(items) }

                    TextField("描述你的任务…", text: $draft, axis: .vertical)
                        .font(.body)
                        .foregroundStyle(ArcTheme.ink)
                        .focused($composing)
                        .lineLimit(1...5)
                        .padding(.vertical, 8)
                        .accessibilityIdentifier("composer")
                        .disabled(!canCompose)

                    if loadingImages {
                        ProgressView().controlSize(.small).frame(width: 24, height: 36)
                    }

                    // Official Agent icon + chevron -> opens spacious AgentModelPickerSheet
                    Button {
                        composing = false
                        showModelPicker = true
                    } label: {
                        let activeAgent = selectedModelAgent ?? project?.agent ?? .codex
                        HStack(spacing: 4) {
                            AgentIcon(agent: activeAgent, size: 18, tint: ArcTheme.ink)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                        .padding(.horizontal, 6)
                        .frame(minHeight: 36)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(busy || isMacThread)
                    .accessibilityLabel("切换 Agent 与模型，当前 \(currentModelName)")

                    Button {
                        if busy, let id = resolvedId { store.stopSession(id: id) }
                        else { send() }
                    } label: {
                        let active = busy || canSubmit
                        Image(systemName: busy ? "stop.fill" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(active ? ArcTheme.onPrimary : ArcTheme.inkFaint)
                            .frame(width: 34, height: 34)
                            .background(busy ? ArcTheme.ink : (canSubmit ? ArcTheme.primary : ArcTheme.line), in: Circle())
                            .frame(width: 36, height: 36)
                            .contentShape(Circle())
                    }
                    .accessibilityLabel(busy ? "停止" : "发送")
                    .disabled(submitting || (busy ? resolvedId == nil : !canSubmit))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ArcTheme.line.opacity(0.6), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 2)

            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 8).background(ArcTheme.chatBg)

        }
    }

    /// A desktop-app conversation can only be read here; continuing means forking it
    /// into a new managed conversation using explicitly selected public context.
    /// Compressed to a single compact row.
    private var desktopSessionBar: some View {
        HStack(spacing: ArcTheme.Space.s3) {
            Image(systemName: "lock")
                .font(.footnote.weight(.semibold)).foregroundStyle(ArcTheme.inkMuted)
                .accessibilityHidden(true)
            Text("只读").font(.footnote.weight(.medium)).foregroundStyle(ArcTheme.inkMuted)
            Spacer(minLength: 0)
            Group {
                if let device = store.selectedDeviceID,
                   store.devices.first(where: { $0.id == device })?.endpointID != nil {
                    Button("基于历史继续") {
                        guard let project, let id = resolvedId else { return }
                        historyContinuation = ImportedHistoryContinuation(deviceID: device, projectPath: project.path, provider: project.agent.agentId, threadID: id, title: sessionRow?.title ?? "历史对话", messages: macMessages)
                        if historyContinuation == nil { store.show("没有可引用的公开文字历史，请先读取对话。") }
                    }
                    .disabled(!store.canSend || loadingMac || macError != nil || macMessages.isEmpty)
                    .accessibilityIdentifier("history-continue")
                } else if canFork, let id = resolvedId {
                    Button("创建分叉继续") { path.append(Route.fork(projectId: projectId, sourceId: id)) }
                        .accessibilityIdentifier("fork-session")
                } else {
                    Button("新建对话") { path.append(Route.session(projectId: projectId, sessionId: nil)) }
                        .disabled(!store.canSend)
                        .accessibilityIdentifier("readonly-new-chat")
                }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(ArcTheme.ink)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(ArcTheme.chatBg)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("readonly-composer")
    }

    private var canSubmit: Bool {
        canCompose && !busy && resolvedId.map({ !store.isChatSendBlocked(sessionId: $0) }) != false && !loadingImages && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    private func loadImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty, canCompose else { return }
        let epoch = attachmentEpoch
        loadingImages = true
        Task { @MainActor in
            defer {
                if epoch == attachmentEpoch { loadingImages = false; picked = [] }
            }
            for item in items {
                guard epoch == attachmentEpoch, !Task.isCancelled else { return }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    guard epoch == attachmentEpoch, canCompose else { return }
                    appendImage(data)
                } else { store.show("无法读取图片，请重新选择") }
            }
        }
    }

    private func appendImage(_ data: Data) {
        guard attachments.count < ChatAttachment.maximumCount else { store.show("最多添加 4 张图片"); return }
        guard let prepared = ChatAttachment.prepare(data) else {
            store.show("图片无法读取或超过 10 MB，请选择较小的图片")
            return
        }
        attachments.append(DraftImage(data: prepared))
    }

    private func send() {
        guard canSubmit, !busy else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = forkSource.map { "分叉 · \($0.title)" } ?? (text.isEmpty ? "图片对话" : String(text.prefix(24)))
        let id = resolvedId ?? store.createSession(projectId: projectId, title: String(title.prefix(32)),
                                                   options: ChatSessionOptions(model: newModel.isEmpty ? nil : newModel, executionPolicy: newPolicy,
                                                                               forkFromThreadId: forkSourceId))
        guard !id.isEmpty else { return }
        liveId = id
        let deviceID = store.selectedDeviceID
        let images = attachments.map(\.data)
        let originalDraft = draft
        submitting = true
        scrollTracker.state.followsLatest = true
        if !followsLatest { followsLatest = true }
        scrollRequest += 1
        Task { @MainActor in
            let accepted = await store.sendMessage(sessionId: id, text: text, images: images, deviceID: deviceID)
            submitting = false
            guard accepted, store.selectedDeviceID == deviceID, resolvedId == id else { return }
            // Preserve edits made while the request was in flight.
            if draft == originalDraft {
                attachmentEpoch = UUID()
                draft = ""; attachments = []; picked = []; composing = false
            }
        }
    }

    #if DEBUG
    private func applyLiveUpdateFixture() async {
        let environment = Foundation.ProcessInfo.processInfo.environment
        guard let testID = environment["ARCLINK_UI_TEST_ID"], UUID(uuidString: testID) != nil,
              !store.usesRemoteChat,
              let json = environment["ARCLINK_UI_TEST_LIVE_UPDATE"], let data = json.data(using: .utf8),
              let update = try? JSONDecoder().decode(ChatMessage.self, from: data),
              update.sessionId == resolvedId else { return }
        let device = store.selectedDeviceID
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        guard !Task.isCancelled, device == store.selectedDeviceID, update.sessionId == resolvedId,
              let index = store.messages.firstIndex(where: { $0.id == update.id && $0.sessionId == update.sessionId }) else { return }
        store.messages[index] = update
    }
    #endif

    private func loadMacMessages() async {
        guard isMacThread, let id = resolvedId, let project else { return }
        let device = store.selectedDeviceID
        macMessages = []; macError = nil
        #if DEBUG
        // Same isolated launch contract as DeviceStorage's UI fixtures. Exercise
        // the imported-history renderer without a live paired Mac in UI tests.
        let environment = Foundation.ProcessInfo.processInfo.environment
        if let testID = environment["ARCLINK_UI_TEST_ID"], UUID(uuidString: testID) != nil,
           let json = environment["ARCLINK_UI_TEST_MAC_MESSAGES"],
           let data = json.data(using: .utf8),
           let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] {
            macMessages = rows.compactMap { row in
                guard let role = row["role"], let text = row["text"] else { return nil }
                return MacMessage(role: role, text: text, timestamp: row["timestamp"], toolCallId: row["toolCallId"], toolName: row["toolName"], toolPhase: row["toolPhase"], toolFailed: row["toolFailed"].flatMap(Bool.init), assistantPhase: row["assistantPhase"])
            }
            return
        }
        #endif
        guard let bridge = store.macBridge else {
            macError = "请先在「我的设备」中连接 Mac，再点重试。"
            return
        }
        loadingMac = true
        defer { if device == store.selectedDeviceID { loadingMac = false } }
        do {
            let result = try await bridge.getThreadMessages(agentId: project.agent.agentId, threadId: id)
            guard !Task.isCancelled, device == store.selectedDeviceID, id == resolvedId else { return }
            macMessages = result
        } catch {
            guard !Task.isCancelled, device == store.selectedDeviceID else { return }
            macError = "读取失败，请确认 Mac 在线后重试。"
        }
    }

    private static let chatClock: DateFormatter = {
        let formatter = DateFormatter(); formatter.dateFormat = "MM-dd HH:mm"; return formatter
    }()
}

private struct DraftImage: Identifiable {
    let id = UUID()
    let data: Data
}
private struct ChatImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

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
    @State private var more = false
    @State private var submitting = false
    @FocusState private var composing: Bool
    @State private var scrollState = ChatScrollFollowState()
    private var followsLatest: Bool { scrollState.followsLatest }
    @State private var bottomPosition: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var scrollRequest = 0
    // Options for a conversation that has not been created yet; sent with the first message.
    @State private var newModel = ""
    @State private var newPolicy: SessionExecutionPolicy = .workspace
    @State private var models: [MacModel] = []

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
                .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, ArcTheme.Space.s5)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ChatBottomPreference.self,
                        value: ChatScrollPosition(top: geometry.frame(in: .named("chat-scroll")).minY,
                                                          bottom: geometry.frame(in: .named("chat-scroll")).maxY))
                })
            }
            .coordinateSpace(name: "chat-scroll")
            .background(ArcTheme.bg)
            .background(GeometryReader { geometry in
                Color.clear.onAppear { viewportHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
            })
            .onPreferenceChange(ChatBottomPreference.self) { bottom in
                guard let bottom else { return }
                bottomPosition = bottom.bottom
                scrollState.observe(bottom, viewport: viewportHeight)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 5).onChanged { value in
                if value.translation.height > 5 { scrollState.followsLatest = false }
            }.onEnded { _ in
                scrollState.followsLatest = bottomPosition <= viewportHeight + 32
            })
            .scrollDismissesKeyboard(.interactively)
            .task(id: "\(store.online)") { if resolvedId == nil { await loadModels() } }
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
                scrollState.followsLatest = true
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
            .overlay(alignment: .bottomTrailing) {
                if !followsLatest {
                    Button { scrollRequest += 1 } label: {
                        Label("回到最新", systemImage: "arrow.down")
                            .font(.footnote.weight(.medium)).foregroundStyle(ArcTheme.ink)
                            .padding(.horizontal, 14)
                            .frame(minHeight: ArcTheme.tapMin)
                            .background(ArcTheme.surface, in: Capsule())
                            .overlay(Capsule().stroke(ArcTheme.line))
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("chat-latest")
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationTitle(sessionRow?.title ?? "新对话")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ArcTheme.primary)
        .toolbarBackground(ArcTheme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if typeSize.isAccessibilitySize {
                    Text("对话").font(.headline)
                } else {
                    VStack(spacing: 3) {
                        Text(sessionRow?.title ?? "新对话").font(.headline).lineLimit(1)
                        contextHeader
                    }
                }
            }
            if !isMacThread {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { more = true } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                        .accessibilityLabel("会话操作").disabled(resolvedId == nil)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { composing = false }
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
            picker().pickerStyle(.menu).tint(ArcTheme.primary)
        }
        .padding(.leading, ArcTheme.Space.s4).padding(.trailing, ArcTheme.Space.s2).frame(minHeight: 52)
    }


    /// The model this conversation was created with.
    private var currentModelName: String {
        let id = sessionRow?.chatOptions?.model ?? ""
        if id.isEmpty { return "跟随 Mac" }
        return models.first { $0.id == id }?.name ?? id
    }

    private var currentPolicy: SessionExecutionPolicy { sessionRow?.chatOptions?.executionPolicy ?? .workspace }

    /// Read-only reminders of what this conversation runs with; chosen before the first message.
    private var modelChip: some View {
        chipLabel(currentModelName, symbol: project?.agent.symbolName ?? "sparkle", tint: project?.agent.tint)
            .accessibilityLabel("模型，\(currentModelName)")
    }

    private var policyChip: some View {
        let short = switch currentPolicy { case .readOnly: "只读"; case .workspace: "读写"; case .fullAccess: "完全" }
        return chipLabel(short, symbol: currentPolicy == .fullAccess ? "exclamationmark.shield" : "shield", tint: nil)
            .accessibilityLabel("权限，\(currentPolicy.rawValue)")
    }

    private func chipLabel(_ text: String, symbol: String, tint: Color?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).foregroundStyle(tint ?? ArcTheme.inkMuted)
            Text(text).foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 10).frame(minHeight: 28)
        .background(ArcTheme.surfaceSunken, in: Capsule())
        .accessibilityElement(children: .ignore)
    }

    private func loadModels() async {
        guard let bridge = store.macBridge, let agent = project?.agent else { return }
        let device = store.selectedDeviceID
        guard let result = try? await bridge.listAgentModels(agentId: agent.agentId),
              !Task.isCancelled, device == store.selectedDeviceID else { return }
        models = result
    }

    private var contextHeader: some View {
        Text("\(project?.name ?? "项目不存在") · \(store.hostName.isEmpty ? "本地" : store.hostName)\(isMacThread ? " · 只读" : "")")
            .font(.caption).foregroundStyle(ArcTheme.inkMuted).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .accessibilityIdentifier("chat-context")
    }

    private func approvalCard(_ request: ApprovalItem) -> some View {
        let pending = request.pending
        let approved = request.approved == true
        return VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
            Button { composing = false; path.append(Route.approval(request.id)) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(pending ? "等待你批准" : (approved ? "你已允许" : "你已拒绝"),
                              systemImage: pending ? "clock" : (approved ? "checkmark" : "xmark"))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(pending ? ArcTheme.warning : ArcTheme.inkMuted)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(pending ? ArcTheme.warning : ArcTheme.inkFaint)
                    }
                    Text(request.title).font(.subheadline).foregroundStyle(ArcTheme.ink)
                    Text(request.target).font(.footnote.monospaced()).foregroundStyle(ArcTheme.ink).lineLimit(3)
                        .padding(.horizontal, 10).padding(.vertical, ArcTheme.Space.s2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .arcBackground(pending ? ArcTheme.surface : ArcTheme.surfaceSunken, radius: ArcTheme.Radius.sm)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("approval-event-\(request.id)")
            DisclosureGroup("操作详情") {
                Text(request.detail).font(.footnote.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
            if pending && store.canApprove {
                HStack(spacing: ArcTheme.Space.s2) {
                    Button("拒绝") { store.resolve(request.id, approved: false) }
                        .buttonStyle(ArcButtonStyle(kind: .secondary, block: true))
                    Button("允许") { store.resolve(request.id, approved: true) }
                        .buttonStyle(.arc(block: true))
                }
                .disabled(store.isApprovalSubmitting(request.id, sessionId: request.sessionId)
                          || store.isChatSendBlocked(sessionId: request.sessionId))
                if store.isApprovalSubmitting(request.id, sessionId: request.sessionId) {
                    ProgressView("正在提交决定…").font(.caption)
                }
            }
        }
        .padding(ArcTheme.Space.s4)
        .background(pending ? ArcTheme.warningSoft : ArcTheme.surface,
                    in: RoundedRectangle(cornerRadius: ArcTheme.Radius.lg, style: .continuous))
        .overlay {
            if !pending { RoundedRectangle(cornerRadius: ArcTheme.Radius.lg, style: .continuous).stroke(ArcTheme.line) }
        }
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
            // User bubble: right-aligned, compact width
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .leading, spacing: 8) {
                    if !text.isEmpty {
                        UserMessageBody(text: text)
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
                .background(ArcTheme.primarySoft, in: UnevenRoundedRectangle(
                    topLeadingRadius: ArcTheme.Radius.lg, bottomLeadingRadius: ArcTheme.Radius.lg,
                    bottomTrailingRadius: 6, topTrailingRadius: ArcTheme.Radius.lg, style: .continuous))
                Text(time).font(.caption).foregroundStyle(ArcTheme.inkMuted).monospacedDigit()
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, typeSize.isAccessibilitySize ? 16 : 44)
        } else {
            // Agent message: left-aligned
            VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: ArcTheme.Space.s2) {
                        Image(systemName: project?.agent.symbolName ?? "sparkle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(project?.agent.tint ?? ArcTheme.primary)
                            .frame(width: 24, height: 24)
                            .arcBackground(ArcTheme.surfaceSunken, radius: 7)
                            .accessibilityHidden(true)
                        Text(project?.agent.rawValue ?? "Agent").fontWeight(.medium)
                            .fixedSize(horizontal: false, vertical: true)
                        if !typeSize.isAccessibilitySize { Text("· \(time)").monospacedDigit() }
                        Spacer(minLength: 0)
                    }
                    if typeSize.isAccessibilitySize { Text(time).monospacedDigit() }
                }
                .font(.caption).foregroundStyle(ArcTheme.inkMuted)
                if !steps.isEmpty { AgentStepsDisclosure(steps: steps) }
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
                if !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        store.show("已复制回复的 Markdown")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc").font(.footnote)
                            .foregroundStyle(ArcTheme.inkMuted).frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("复制回复的 Markdown")
                }
                ConversationSummaryView(summary: summary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
                    HStack {
                        ProgressView()
                        Text("正在等待 Mac 上的 \(project?.agent.rawValue ?? "Agent")…").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                        Spacer()

                    }
                }
                if !store.canSend {
                    Text("当前权限仅可查看\(store.canApprove ? "和审批" : "")，不能发送新任务。")
                        .font(.footnote).foregroundStyle(ArcTheme.warning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("给 \(project?.agent.shortName ?? "Agent") 发消息…", text: $draft, axis: .vertical)
                        .focused($composing).lineLimit(2...5).padding(.horizontal, 6).padding(.top, 6)
                        .accessibilityIdentifier("composer").disabled(!canCompose)
                    HStack(spacing: 4) {
                        PhotosPicker(selection: $picked, maxSelectionCount: max(1, ChatAttachment.maximumCount - attachments.count), matching: .images) {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("从相册添加图片")
                        .disabled(!canCompose || loadingImages || attachments.count >= ChatAttachment.maximumCount)
                        .onChange(of: picked) { _, items in loadImages(items) }
                        if resolvedId != nil {
                            modelChip
                            policyChip
                        }
                        Spacer(minLength: 0)
                        if loadingImages { ProgressView().frame(width: 24, height: 44) }
                        Button {
                            if busy, let id = resolvedId { store.stopSession(id: id) }
                            else { send() }
                        } label: {
                            let active = busy || canSubmit
                            Image(systemName: busy ? "stop.fill" : "arrow.up")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(active ? ArcTheme.onPrimary : ArcTheme.inkFaint)
                                .frame(width: ArcTheme.sendButton, height: ArcTheme.sendButton)
                                .background(active ? ArcTheme.primary : ArcTheme.surfaceSunken, in: Circle())
                                .frame(width: ArcTheme.tapMin, height: ArcTheme.tapMin)
                                .contentShape(Circle())
                        }
                        .accessibilityLabel(busy ? "停止" : "发送")
                        .disabled(submitting || (busy ? resolvedId == nil : !canSubmit))
                    }
                }
                .padding(.leading, ArcTheme.Space.s2).padding(.trailing, 2).padding(.vertical, 4)
                .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.xl, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ArcTheme.Radius.xl, style: .continuous).stroke(ArcTheme.line))

            }
            .padding(.horizontal, ArcTheme.Space.s3).padding(.vertical, ArcTheme.Space.s2).background(ArcTheme.bg)

        }
    }

    /// A desktop-app conversation can only be read here; continuing means forking it
    /// into a new ArcLink conversation (Codex), or starting a fresh one (Claude for now).
    private var desktopSessionBar: some View {
        let compact = typeSize.isAccessibilitySize
        return HStack(spacing: ArcTheme.Space.s3) {
            Image(systemName: "lock")
                .font(.body.weight(.medium)).foregroundStyle(ArcTheme.inkMuted)
                .accessibilityHidden(true)
            // At accessibility sizes the bar keeps to one row so the conversation's
            // last rows can still scroll clear of it; the nav subtitle says 只读.
            if !compact {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已在 Mac 桌面端打开").font(.subheadline.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                    Text(canFork ? "这里只能查看，创建分叉后在手机上继续。" : "Claude 对话暂不支持分叉，可新建对话继续。")
                        .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                }
                Spacer(minLength: 0)
                Rectangle().fill(ArcTheme.line).frame(width: 0.5, height: 28)
            }
            Group {
                if canFork, let id = resolvedId {
                    Button("创建分叉") { path.append(Route.fork(projectId: projectId, sourceId: id)) }
                        .accessibilityIdentifier("fork-session")
                } else {
                    Button("新建对话") { path.append(Route.session(projectId: projectId, sessionId: nil)) }
                        .disabled(!store.canSend)
                        .accessibilityIdentifier("readonly-new-chat")
                }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(ArcTheme.primary)
            .frame(minHeight: compact ? nil : ArcTheme.tapMin)
            if compact { Spacer(minLength: 0) }
        }
        .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, compact ? ArcTheme.Space.s1 : 10)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ArcTheme.Radius.lg, style: .continuous).stroke(ArcTheme.line))
        .padding(.horizontal, ArcTheme.Space.s3).padding(.vertical, ArcTheme.Space.s1)
        .background(ArcTheme.bg)
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
        scrollState.followsLatest = true
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

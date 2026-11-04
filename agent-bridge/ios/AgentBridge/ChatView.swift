import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var projectId: String
    var sessionId: String?
    @Binding var path: NavigationPath

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

    private var resolvedId: String? { liveId ?? sessionId }
    private var sessionRow: SessionItem? { store.sessions.first { $0.id == resolvedId && $0.projectId == projectId } }
    private var isMacThread: Bool { sessionRow?.isReadOnly == true }
    private var project: ProjectItem? { store.project(projectId) }
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
                        ContentUnavailableView("开始新的对话", systemImage: "bubble.left.and.bubble.right", description: Text(remoteChat ? "描述你的需求，消息会发送到 Mac 上的 \(project?.agent.rawValue ?? "Agent")。\n第一条消息发送后才会创建对话。" : "描述你的需求，或添加图片。\n第一条消息发送后才会创建对话。"))
                        Button("查看项目结构") { draft = "查看项目结构"; composing = true }
                            .buttonStyle(.bordered).frame(maxWidth: .infinity)
                            .disabled(!canCompose)
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
                .padding(.horizontal, 20).padding(.vertical, 22)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ChatBottomPreference.self,
                        value: ChatScrollPosition(top: geometry.frame(in: .named("chat-scroll")).minY,
                                                          bottom: geometry.frame(in: .named("chat-scroll")).maxY))
                })
            }
            .coordinateSpace(name: "chat-scroll")
            .background(ChatStyle.background)
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
                            .font(.caption.weight(.medium)).padding(.horizontal, 14)
                            .frame(minHeight: 44)
                            .background(ChatStyle.surface, in: Capsule())
                            .overlay(Capsule().stroke(ChatStyle.border))
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("chat-latest")
                    .padding(16)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationTitle(sessionRow?.title ?? "新对话")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ChatStyle.accent)
        .toolbarBackground(ChatStyle.background, for: .navigationBar)
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

    private var contextHeader: some View {
        Text("\(project?.name ?? "项目不存在") · \(store.hostName.isEmpty ? "本地" : store.hostName)\(isMacThread ? " · 只读" : "")")
            .font(.caption2).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? nil : 1)
            .accessibilityIdentifier("chat-context")
    }

    private func approvalCard(_ request: ApprovalItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { composing = false; path.append(Route.approval(request.id)) } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label(request.pending ? "需要你的确认" : (request.approved == true ? "已批准" : "已拒绝"),
                              systemImage: request.pending ? "hand.raised" : (request.approved == true ? "checkmark.circle" : "xmark.circle"))
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    Text(request.title).font(.subheadline)
                    Text(request.target).font(.caption.monospaced()).lineLimit(3)
                    Text("查看完整请求").font(.caption).foregroundStyle(ChatStyle.accent)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("approval-event-\(request.id)")
            DisclosureGroup("操作详情") {
                Text(request.detail).font(.footnote.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }
            .font(.caption)
            if request.pending && store.canApprove {
                HStack(spacing: 10) {
                    Button("拒绝") { store.resolve(request.id, approved: false) }
                        .buttonStyle(.bordered)
                    Button("允许本次") { store.resolve(request.id, approved: true) }
                        .buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
                .disabled(store.isApprovalSubmitting(request.id, sessionId: request.sessionId)
                          || store.isChatSendBlocked(sessionId: request.sessionId))
                if store.isApprovalSubmitting(request.id, sessionId: request.sessionId) {
                    ProgressView("正在提交决定…").font(.caption)
                }
            }
        }
        .padding(16).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ChatStyle.border))
    }

    @ViewBuilder private var history: some View {
        if loadingMac {
            ProgressView("正在读取 Mac 对话…").frame(maxWidth: .infinity).padding(.vertical, 32)
        } else if let macError {
            ContentUnavailableView("无法读取对话", systemImage: "wifi.exclamationmark", description: Text(macError))
            Button("重试") { Task { await loadMacMessages() } }
                .buttonStyle(.bordered).frame(maxWidth: .infinity)
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
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain).accessibilityLabel("查看图片 \(index + 1)")
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(ChatStyle.user, in: RoundedRectangle(cornerRadius: 18))
                Text(time).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .padding(.trailing, 4)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, typeSize.isAccessibilitySize ? 16 : 44)
        } else {
            // Agent message: left-aligned
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: project?.agent.symbolName ?? "sparkle")
                            .font(.system(size: 14))
                            .foregroundStyle(project?.agent.tint ?? .accentColor)
                            .frame(width: 28, height: 28)
                            .background((project?.agent.tint ?? .accentColor).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityHidden(true)
                        Text(project?.agent.rawValue ?? "Agent").fontWeight(.semibold)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        if !typeSize.isAccessibilitySize { Text(time).font(.caption2).monospacedDigit() }
                    }
                    if typeSize.isAccessibilitySize { Text(time).font(.caption2).monospacedDigit() }
                }
                .font(.caption).foregroundStyle(.secondary)
                if !steps.isEmpty { AgentStepsDisclosure(steps: steps) }
                if !text.isEmpty {
                    MacMessageText(text: text).textSelection(.enabled)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        Button { expandedImage = ChatImagePreview(image: image) } label: {
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 300)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain).accessibilityLabel("查看图片 \(index + 1)")
                    }
                }
                if !text.isEmpty {
                    Button {
                        UIPasteboard.general.string = text
                        store.show("已复制回复的 Markdown")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc").font(.caption)
                            .foregroundStyle(.secondary).frame(minWidth: 44, minHeight: 44)
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
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                : AnyLayout(HStackLayout(spacing: 8))
            layout {
                Label("导入历史仅供查看", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("新建 CLI 对话") { path.append(Route.session(projectId: projectId, sessionId: nil)) }
                    .disabled(!store.canSend)
            }
            .font(.caption).padding(14).background(.bar)
            .accessibilityIdentifier("readonly-composer")
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
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                        }.buttonStyle(.plain).accessibilityLabel("预览待发送图片")
                                        Button {
                                            attachments.removeAll { $0.id == item.id }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                                .foregroundStyle(.white, .black.opacity(0.7)).frame(width: 28, height: 28)
                                        }.accessibilityLabel("移除图片")
                                    }
                                }
                            }
                        }
                    }
                }
                if let id = resolvedId, let label = store.chatRecoveryLabel(sessionId: id) {
                    HStack {
                        if store.isChatRecovering(sessionId: id) { ProgressView() }
                        Text(label).font(.caption)
                        Spacer()
                        Button("重试连接") { store.retryChatConnection(sessionId: id) }
                            .disabled(store.isChatRecovering(sessionId: id))
                    }
                    .accessibilityIdentifier("chat-recovery")
                }
                if let id = resolvedId, let error = store.chatError(sessionId: id) {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("remote-chat-error")
                }
                if busy && resolvedId.flatMap({ store.chatRecoveryLabel(sessionId: $0) }) == nil {
                    HStack {
                        ProgressView()
                        Text("正在等待 Mac 上的 \(project?.agent.rawValue ?? "Agent")…").font(.caption)
                        Spacer()

                    }
                }
                if !store.canSend {
                    Text("当前权限仅可查看\(store.canApprove ? "和审批" : "")，不能发送新任务。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    TextField("继续描述你的需求…", text: $draft, axis: .vertical)
                        .focused($composing).lineLimit(2...5).padding(.horizontal, 6).padding(.top, 6)
                        .accessibilityIdentifier("composer").disabled(!canCompose)
                    HStack(spacing: 4) {
                        PhotosPicker(selection: $picked, maxSelectionCount: max(1, ChatAttachment.maximumCount - attachments.count), matching: .images) {
                            Image(systemName: "plus").frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("从相册添加图片")
                        .disabled(!canCompose || loadingImages || attachments.count >= ChatAttachment.maximumCount)
                        .onChange(of: picked) { _, items in loadImages(items) }
                        imagePasteButton
                        Text(project?.agent.rawValue ?? "Agent").font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        if loadingImages { ProgressView().frame(width: 24, height: 44) }
                        Button {
                            if busy, let id = resolvedId { store.stopSession(id: id) }
                            else { send() }
                        } label: {
                            Image(systemName: busy ? "stop.fill" : "arrow.up")
                                .font(.body.weight(.semibold)).foregroundStyle(ChatStyle.onAccent)
                                .frame(width: 44, height: 44)
                                .background(ChatStyle.accent.opacity(busy || canSubmit ? 1 : 0.35), in: Circle())
                        }
                        .accessibilityLabel(busy ? "停止" : "发送")
                        .disabled(submitting || (busy ? resolvedId == nil : !canSubmit))
                    }
                }
                .padding(8).background(ChatStyle.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(ChatStyle.border))

                Text(remoteChat ? "文字和图片发送到 Mac · 最多 4 张，自动压缩" : "本地模拟 · 图片最多 4 张，每张不超过 10 MB")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(ChatStyle.background)

        }
    }

    private var imagePasteButton: some View {
        PasteButton(supportedContentTypes: [.image]) { providers in
            guard canCompose, !loadingImages else { return }
            let epoch = attachmentEpoch
            for provider in providers.prefix(max(0, ChatAttachment.maximumCount - attachments.count)) {
                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                    let data = (object as? UIImage)?.jpegData(compressionQuality: 0.85)
                    Task { @MainActor in
                        guard epoch == attachmentEpoch, let data, canCompose else { return }
                        appendImage(data)
                    }
                }
            }
        }
        .labelStyle(.iconOnly)
        .frame(width: 44, height: 44)
        .accessibilityLabel("粘贴图片")
        .disabled(!canCompose || loadingImages || attachments.count >= ChatAttachment.maximumCount)
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
        let id = resolvedId ?? store.createSession(projectId: projectId, title: text.isEmpty ? "图片对话" : String(text.prefix(24)))
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

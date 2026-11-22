import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ManagedDraftImage: Identifiable {
    let id = UUID()
    let data: Data
}

struct ManagedDraftFile: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}

private struct ManagedImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

@MainActor @Observable
final class ManagedThreadModel {
    var snapshot: ManagedThreadSnapshot?
    var draft = ""
    var imageAttachments: [ManagedDraftImage] = []
    var fileAttachments: [ManagedDraftFile] = []
    var busy = false
    var connected = false
    var error: String?
    var cacheError: String?
    var availableModels: [MacModel] = []
    var modelsSupported = false
    var loadingModels = false
    var modelError: String?
    private(set) var modelUncertain = false
    private(set) var providerUncertain = false
    private(set) var pendingProvider: ManagedThreadState.ProviderSwitch?
    var providerSupported = false
    var switchingProvider = false
    var providerError: String?
    private(set) var providerStorageBlocked = false
    private var modelLoadID = UUID()
    private var pendingModel: (command: String, model: String?, revision: String)?
    private(set) var uncertain = false
    private var bridge: BridgeConnection?
    private var deviceID = ""
    private var epoch = UUID()
    private var context = ""
    private var pending: (command: String, message: String, text: String, revision: String, images: [String])?
    var hasPendingApproval: Bool { snapshot?.approvals.contains { $0.state == "pending" } ?? false }
    var active: Bool { (snapshot?.runs.contains { ["queued", "starting", "running", "waiting_approval", "outcome_unknown"].contains($0.status) } ?? false) || hasPendingApproval }
    var isThinking: Bool {
        if hasPendingApproval { return false }
        if busy { return true }
        return snapshot?.runs.contains { ["queued", "starting", "running"].contains($0.status) } ?? false
    }
    var thinkingLabel: String {
        if busy { return "正在发送" }
        if let run = snapshot?.runs.last(where: { ["queued", "starting", "running"].contains($0.status) }) {
            return run.status == "running" ? "正在思考" : "正在准备"
        }
        return "正在思考"
    }
    var canInterrupt: Bool { snapshot?.runs.contains { ["queued", "starting", "running", "waiting_approval"].contains($0.status) } ?? false }
    var hasOutgoingContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !imageAttachments.isEmpty || !fileAttachments.isEmpty
    }
    var canSend: Bool { connected && !busy && !active && !uncertain && !modelUncertain && !providerUncertain && !providerStorageBlocked && !switchingProvider && hasOutgoingContent }
    func stop() {
        epoch = UUID(); modelLoadID = UUID(); connected = false; bridge = nil; busy = false
        // A cancelled view task does not cancel a mutation already delivered to the Mac.
        if pendingProvider != nil { providerUncertain = true; providerError = "Agent 切换结果待确认，发送已暂停。" }
        if pendingModel != nil { modelUncertain = true }
        if pending != nil { uncertain = true }
        switchingProvider = false; loadingModels = false; providerSupported = false; modelsSupported = false
    }
    func restoreProviderSwitch(device: String, thread: String) {
        pendingProvider = nil; providerUncertain = false; providerStorageBlocked = false; providerError = nil
        do {
            pendingProvider = try ManagedThreadState.loadProviderSwitch(device: device, thread: thread)
            providerUncertain = pendingProvider != nil
            if providerUncertain { providerError = "上次 Agent 切换结果待确认，请核对后继续。" }
        } catch { providerStorageBlocked = true; providerError = "无法读取待确认的 Agent 设置，为避免重复操作已暂停发送。" }
    }
    func sync(bridge: BridgeConnection, device: String, thread: String) async {
        stop(); let token = epoch; self.bridge = bridge; deviceID = device
        if context != "\(device)/\(thread)" {
            pending = nil; uncertain = false; pendingModel = nil; modelUncertain = false
            restoreProviderSwitch(device: device, thread: thread)
            draft = ""; imageAttachments = []; fileAttachments = []; snapshot = nil; context = "\(device)/\(thread)"
        }
        snapshot = ManagedThreadState.load(device: device, thread: thread)
        var needsSnapshot = true
        var consecutiveFailures = 0
        while !Task.isCancelled && token == epoch {
            do {
                if needsSnapshot {
                    let value = try await bridge.getManagedThreadSnapshot(threadId: thread)
                    guard !Task.isCancelled, token == epoch else { return }
                    publish(value); needsSnapshot = false
                    connected = true; error = nil; consecutiveFailures = 0
                }
                guard let value = snapshot else { return }
                connected = true
                let replay = try await bridge.waitManagedThread(environmentId: value.environmentId, threadId: thread, afterSequence: value.sequence)
                guard !Task.isCancelled, token == epoch, let latest = snapshot else { return }
                if let latestCursor = UInt64(latest.sequence), let replayCursor = UInt64(replay.sequence), replayCursor >= latestCursor { publish(try ManagedThreadState.apply(replay, to: latest)) }
                error = nil; consecutiveFailures = 0
                if let pending, snapshot?.messages.contains(where: { $0.clientMessageId == pending.message }) == true {
                    self.pending = nil; uncertain = false; draft = ""; imageAttachments = []; fileAttachments = []
                }
            } catch {
                guard !Task.isCancelled, token == epoch else { return }
                if case ManagedThreadState.Failure.unsupported = error {
                    connected = false
                    self.error = "请更新手机客户端以读取新的会话事件。"
                    return
                }
                consecutiveFailures += 1
                connected = false
                needsSnapshot = true
                // Only surface a visible error banner after repeated failures;
                // single transient QUIC/long-poll drops recover silently.
                if consecutiveFailures >= 3 {
                    self.error = "同步暂时中断：\(error.localizedDescription)"
                }
                let delay: Double = consecutiveFailures == 1 ? 0.4 : min(2.0, Double(consecutiveFailures))
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled, token == epoch else { return }
                // Actively heal a dropped QUIC connection instead of waiting for the 15s health loop.
                if consecutiveFailures == 1 {
                    _ = await bridge.connect()
                } else {
                    _ = await bridge.reconnect()
                }
            }
        }
    }
    private func publish(_ value: ManagedThreadSnapshot) {
        do { try ManagedThreadState.save(value, device: deviceID); cacheError = nil }
        catch { cacheError = "无法保存离线缓存，当前内容仍可在线查看。" }
        snapshot = value
    }
    /// Compresses attached images to stay well within the 700 KB durable turn / 768 KB sync batch budget.
    private static func prepareManagedImages(_ images: [Data]) throws -> [Data] {
        guard images.count <= RemoteChatImage.maximumCount else { throw RemoteChatImage.PreparationError.tooMany }
        let perImageLimit = images.count <= 1 ? 180 * 1024 : (420 * 1024 / images.count)
        let prepared: [Data] = try images.map { data in
            guard ChatAttachment.isValid(data),
                  let source = CGImageSourceCreateWithData(data as CFData, nil) else {
                throw RemoteChatImage.PreparationError.invalid
            }
            for dimension in [1536, 1280, 1024, 768, 512, 384, 256] {
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: dimension
                ] as CFDictionary) else { throw RemoteChatImage.PreparationError.invalid }
                for quality in [0.80, 0.65, 0.50, 0.35, 0.25] {
                    let encoded = NSMutableData()
                    guard let destination = CGImageDestinationCreateWithData(encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
                        throw RemoteChatImage.PreparationError.cannotCompress
                    }
                    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                    if CGImageDestinationFinalize(destination), encoded.length <= perImageLimit {
                        return encoded as Data
                    }
                }
            }
            throw RemoteChatImage.PreparationError.cannotCompress
        }
        guard prepared.reduce(0, { $0 + $1.count }) <= 450 * 1024 else {
            throw RemoteChatImage.PreparationError.cannotCompress
        }
        return prepared
    }

    private func composedOutgoingText() -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fileAttachments.isEmpty else { return draft }
        let fileBlocks = fileAttachments.map { file in
            "[附件: \(file.name)]\n```\n\(file.text)\n```"
        }.joined(separator: "\n\n")
        return trimmed.isEmpty ? fileBlocks : "\(fileBlocks)\n\n\(draft)"
    }
    func send(checkPending: Bool = false) async {
        guard let bridge, let snapshot, !busy, checkPending ? pending != nil : canSend else { return }
        let request: (command: String, message: String, text: String, revision: String, images: [String])
        if let existing = pending {
            request = existing
        } else {
            let encodedImages: [String]
            if imageAttachments.isEmpty {
                encodedImages = []
            } else {
                do {
                    encodedImages = try Self.prepareManagedImages(imageAttachments.map(\.data)).map { $0.base64EncodedString() }
                } catch {
                    self.error = error.localizedDescription
                    return
                }
            }
            request = (UUID().uuidString, UUID().uuidString, composedOutgoingText(), snapshot.thread.revision, encodedImages)
        }
        pending = request; let token = epoch; busy = true; error = nil
        defer { if token == epoch { busy = false } }
        do {
            _ = try await bridge.sendManagedThreadWithImages(
                commandId: request.0,
                threadId: snapshot.thread.id,
                clientMessageId: request.1,
                text: request.2,
                expectedRevision: request.3,
                images: request.4
            )
            guard token == epoch else { return }
            pending = nil; uncertain = false; draft = ""; imageAttachments = []; fileAttachments = []
            do {
                let value = try await bridge.getManagedThreadSnapshot(threadId: snapshot.thread.id)
                guard token == epoch else { return }; publish(value)
            } catch {
                if token == epoch { self.error = "消息已接受，正在恢复同步：\(error.localizedDescription)" }
            }
        } catch {
            guard token == epoch else { return }
            if self.snapshot?.messages.contains(where: { $0.clientMessageId == request.1 }) == true {
                pending = nil; uncertain = false; draft = ""; imageAttachments = []; fileAttachments = []; return
            }
            self.error = error.localizedDescription
            if case BridgeError.Failed(let code, _) = error, !["outcome_unknown", "network_error", "timeout", "disconnected"].contains(code) { pending = nil; uncertain = false }
            else { uncertain = true }
        }
    }
    func loadModels(bridge: BridgeConnection, provider: String) async {
        let requestID = UUID(); modelLoadID = requestID
        let token = epoch
        loadingModels = true; availableModels = []; modelError = nil
        defer { if modelLoadID == requestID { loadingModels = false } }
        do {
            let environment = try await bridge.describeEnvironment()
            guard !Task.isCancelled, token == epoch, requestID == modelLoadID, snapshot?.thread.providerId == provider else { return }
            modelsSupported = environment.capabilities.contains("managed_models_v1")
            providerSupported = environment.capabilities.contains("managed_provider_switch_v1")
            guard modelsSupported else { modelError = "更新 Mac 客户端后可切换模型。"; return }
            let values = try await bridge.listAgentModels(agentId: provider)
            guard !Task.isCancelled, token == epoch, requestID == modelLoadID, snapshot?.thread.providerId == provider else { return }
            availableModels = values
            modelError = values.isEmpty ? "模型目录为空，可使用客户端默认模型。" : nil
        } catch { if !Task.isCancelled, token == epoch, requestID == modelLoadID { modelError = "暂时无法读取模型目录。" } }
    }
    func selectProvider(_ provider: String, retry: Bool = false) async {
        guard ["claude", "codex"].contains(provider), let bridge, let snapshot, providerSupported, connected, !busy, !active, !uncertain, !modelUncertain, !providerStorageBlocked, retry || !providerUncertain, retry || provider != snapshot.thread.providerId, !retry || pendingProvider != nil else { return }
        let request = pendingProvider ?? ManagedThreadState.ProviderSwitch(command: UUID().uuidString, threadId: snapshot.thread.id, providerId: provider, model: nil, revision: snapshot.thread.revision)
        guard request.providerId == provider else { return }
        do { try ManagedThreadState.saveProviderSwitch(request, device: deviceID) }
        catch { providerError = "无法保存 Agent 切换请求，请稍后重试。"; return }
        pendingProvider = request
        let token = epoch; busy = true; switchingProvider = true; providerError = nil
        defer { if token == epoch { busy = false; switchingProvider = false } }
        do {
            let thread = try await bridge.setManagedThreadProvider(commandId: request.command, threadId: request.threadId, providerId: request.providerId, model: request.model, expectedRevision: request.revision)
            guard token == epoch else { return }
            if var latest = self.snapshot, (UInt64(thread.revision) ?? 0) >= (UInt64(latest.thread.revision) ?? 0) { latest.thread = thread; publish(latest) }
            try ManagedThreadState.clearProviderSwitch(device: deviceID, thread: request.threadId)
            pendingProvider = nil; providerUncertain = false
        } catch {
            guard token == epoch else { return }
            if case BridgeError.Failed(let code, _) = error, !["outcome_unknown", "network_error", "timeout", "disconnected"].contains(code) {
                do {
                    try ManagedThreadState.clearProviderSwitch(device: deviceID, thread: request.threadId)
                    pendingProvider = nil; providerUncertain = false
                    providerError = "Agent 切换未生效，请等待任务结束或刷新后重试。"
                } catch { providerUncertain = true; providerError = "无法保存核对结果，请再次核对 Agent 设置。" }
            } else { providerUncertain = true; providerError = "Agent 切换结果待确认，发送已暂停。" }
        }
    }
    func retryProviderSwitch() async { if let request = pendingProvider { await selectProvider(request.providerId, retry: true) } }

    func selectModel(_ value: String?, retry: Bool = false) async {
        guard let bridge, let snapshot, modelsSupported, connected, !busy, !active,
              !uncertain, !providerUncertain, !providerStorageBlocked, retry || !modelUncertain else { return }
        let request = pendingModel ?? (UUID().uuidString, value, snapshot.thread.revision)
        pendingModel = request
        let token = epoch; busy = true; modelError = nil
        defer { if token == epoch { busy = false } }
        do {
            let thread = try await bridge.setManagedThreadModel(commandId: request.command, threadId: snapshot.thread.id, model: request.model, expectedRevision: request.revision)
            guard token == epoch else { return }
            if var latest = self.snapshot, (UInt64(thread.revision) ?? 0) >= (UInt64(latest.thread.revision) ?? 0) {
                latest.thread = thread; publish(latest)
            }
            pendingModel = nil; modelUncertain = false
        } catch {
            guard token == epoch else { return }
            if case BridgeError.Failed(let code, _) = error, !["outcome_unknown", "network_error", "timeout", "disconnected"].contains(code) {
                pendingModel = nil; modelUncertain = false
                modelError = "模型修改未生效，请等待当前任务结束或刷新后重试。"
            } else {
                modelUncertain = true
                modelError = "模型修改结果待确认，发送已暂停。"
            }
        }
    }
    func interrupt() async {
        guard let bridge, let snapshot, !busy, connected, canInterrupt else { return }
        let token = epoch; busy = true; defer { if token == epoch { busy = false } }
        do { _ = try await bridge.interruptManagedThread(commandId: UUID().uuidString, threadId: snapshot.thread.id) }
        catch { if token == epoch { self.error = error.localizedDescription } }
    }
    func resolve(_ approval: ManagedApproval, approved: Bool) async {
        guard let bridge, let snapshot, !busy, connected else { return }
        let token = epoch; busy = true; defer { if token == epoch { busy = false } }
        do { _ = try await bridge.resolveManagedApproval(commandId: UUID().uuidString, threadId: snapshot.thread.id, approvalId: approval.id, approved: approved) }
        catch { if token == epoch { self.error = error.localizedDescription } }
    }
    func older() async {
        guard let bridge, let snapshot, !busy else { return }
        let token = epoch; busy = true; defer { if token == epoch { busy = false } }
        do {
            let history = try await bridge.managedThreadHistory(threadId: snapshot.thread.id, beforeId: snapshot.messages.first?.id)
            guard token == epoch, var latest = self.snapshot else { return }
            let ids = Set(latest.messages.map(\.id)); latest.messages = history.messages.filter { !ids.contains($0.id) } + latest.messages
            latest.hasOlderMessages = history.hasMore; publish(latest)
        } catch { if token == epoch { self.error = error.localizedDescription } }
    }
}

/// This page consumes durable public projections, never native AgentIO.
struct ManagedThreadView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    let threadId: String
    var owningDeviceID: String? = nil
    private var deviceID: String? { owningDeviceID ?? store.selectedDeviceID }
    @State private var model = ManagedThreadModel()
    @State private var showModelPicker = false
    @State private var expandedImage: ManagedImagePreview?

    private enum ThreadDisplayItem: Identifiable {
        case user(ManagedMessage)
        case assistant(ManagedMessage)
        case steps(id: String, steps: [MessageStep])
        case switchMarker(id: String, from: String, to: String)

        var id: String {
            switch self {
            case .user(let m): "u-\(m.id)"
            case .assistant(let m): "a-\(m.id)"
            case .steps(let id, _): "s-\(id)"
            case .switchMarker(let id, _, _): "sw-\(id)"
            }
        }
    }

    private func groupedItems(_ messages: [ManagedMessage]) -> [ThreadDisplayItem] {
        var result: [ThreadDisplayItem] = []
        var pendingSteps: [MessageStep] = []
        var pendingStepID: String?

        func flushSteps() {
            if !pendingSteps.isEmpty, let id = pendingStepID {
                result.append(.steps(id: id, steps: pendingSteps))
                pendingSteps = []
                pendingStepID = nil
            }
        }

        for message in messages {
            if let marker = ManagedThreadState.switchMarker(message) {
                flushSteps()
                result.append(.switchMarker(id: message.id, from: marker.from, to: marker.to))
            } else if message.role == "user" {
                flushSteps()
                result.append(.user(message))
            } else if message.role == "tool" || message.role == "summary" {
                let content = ManagedThreadState.content(message)
                let text = ManagedThreadState.text(message)
                let isSummary = message.role == "summary"
                let rawName = (content["tool_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let failed = content["failed"] as? Bool
                // Skip empty generic placeholder tool rows that carry no name, text, or error.
                if !isSummary && (rawName.isEmpty || rawName.lowercased() == "tool")
                    && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && failed != true {
                    continue
                }
                let title = isSummary ? "思考摘要" : ((rawName.isEmpty || rawName.lowercased() == "tool") ? "工具调用" : rawName)
                let step = MessageStep(
                    id: message.id,
                    title: title,
                    summary: MessageStep.preview(text),
                    input: nil,
                    output: text,
                    completed: content["completed"] as? Bool ?? true,
                    failed: failed ?? false,
                    isSummary: isSummary
                )
                if pendingStepID == nil { pendingStepID = message.id }
                pendingSteps.append(step)
            } else {
                flushSteps()
                result.append(.assistant(message))
            }
        }
        flushSteps()
        return result
    }

    var body: some View {
        Group {
            if let snapshot = model.snapshot {
                let activeAgent: AgentKind = snapshot.thread.providerId == "claude" ? .claude : .codex
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 18) {
                                if snapshot.hasOlderMessages {
                                    Button("加载更早消息") { Task { await model.older() } }
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(ArcTheme.inkMuted)
                                        .disabled(model.busy)
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }

                                ForEach(groupedItems(snapshot.messages)) { item in
                                    switch item {
                                    case .user(let message):
                                        userBubble(message)
                                    case .steps(_, let steps):
                                        InlineStepsGroup(steps: steps)
                                    case .assistant(let message):
                                        assistantText(message)
                                    case .switchMarker(_, let from, let to):
                                        switchMarkerRow(from: from, to: to, id: item.id)
                                    }
                                }

                                ForEach(snapshot.approvals.filter { $0.state == "pending" }, id: \.id) { approval in
                                    approvalCard(approval)
                                }

                                if model.isThinking {
                                    AgentThinkingIndicator(agent: activeAgent, label: model.thinkingLabel)
                                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                                }

                                Color.clear.frame(height: 1).id("managed-bottom")
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .background(ArcTheme.chatBg)
                        .onChange(of: snapshot.messages.count) { _, _ in
                            proxy.scrollTo("managed-bottom", anchor: .bottom)
                        }
                        .onChange(of: model.isThinking) { _, thinking in
                            if thinking {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    proxy.scrollTo("managed-bottom", anchor: .bottom)
                                }
                            }
                        }
                    }

                    ManagedThreadComposerBar(
                        model: model,
                        snapshot: snapshot,
                        activeAgent: activeAgent,
                        onOpenModelPicker: {
                            showModelPicker = true
                        },
                        onPreviewImage: { image in
                            expandedImage = ManagedImagePreview(image: image)
                        }
                    )
                }
                .sheet(isPresented: $showModelPicker) {
                    ManagedThreadModelPickerSheet(
                        snapshot: snapshot,
                        model: model
                    )
                }
                .sheet(item: $expandedImage) { preview in
                    NavigationStack {
                        ScrollView([.horizontal, .vertical]) {
                            Image(uiImage: preview.image)
                                .resizable()
                                .scaledToFit()
                                .padding()
                        }
                        .navigationTitle("图片预览")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { expandedImage = nil }
                            }
                        }
                    }
                }
            } else if let error = model.error {
                ContentUnavailableView("暂时无法同步", systemImage: "wifi.exclamationmark", description: Text(error))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ArcTheme.chatBg)
            } else {
                ProgressView("正在同步对话…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(ArcTheme.chatBg)
            }
        }
        .navigationTitle(model.snapshot?.thread.title ?? "对话")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ArcTheme.ink)
        .toolbarBackground(ArcTheme.chatBg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(model.snapshot?.thread.title ?? "对话")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ArcTheme.ink)
                        .lineLimit(1)
                    if let snapshot = model.snapshot {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(model.connected ? ArcTheme.live : ArcTheme.warning)
                                .frame(width: 5, height: 5)
                            Text(model.connected ? managedStatus(snapshot.thread.status) : "重新连接中")
                                .font(.caption2)
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                    }
                }
            }
        }
        .task(id: "\(deviceID ?? "")/\(threadId)/\(scenePhase == .active)") {
            guard scenePhase == .active, let device = deviceID, let bridge = store.bridge(for: device) else { model.stop(); return }
            await model.sync(bridge: bridge, device: device, thread: threadId)
        }
        .task(id: "\(deviceID ?? "")/\(model.snapshot?.thread.providerId ?? "")/\(model.connected)") {
            guard let device = deviceID, let bridge = store.bridge(for: device), let provider = model.snapshot?.thread.providerId else { return }
            await model.loadModels(bridge: bridge, provider: provider)
        }
        .onDisappear { model.stop() }
    }

    private func userBubble(_ message: ManagedMessage) -> some View {
        let text = ManagedThreadState.text(message)
        let content = ManagedThreadState.content(message)
        let images: [UIImage] = (content["images"] as? [String] ?? []).compactMap { encoded in
            Data(base64Encoded: encoded).flatMap(UIImage.init(data:))
        }
        return VStack(alignment: .trailing, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                if !text.isEmpty {
                    Text(text)
                        .font(.subheadline)
                        .lineSpacing(3)
                        .foregroundStyle(ArcTheme.ink)
                        .textSelection(.enabled)
                }
                ForEach(Array(images.enumerated()), id: \.offset) { index, image in
                    Button { expandedImage = ManagedImagePreview(image: image) } label: {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("查看图片 \(index + 1)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(ArcTheme.userBubble, in: UnevenRoundedRectangle(
                topLeadingRadius: 18, bottomLeadingRadius: 18,
                bottomTrailingRadius: 6, topTrailingRadius: 18, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }

    private func assistantText(_ message: ManagedMessage) -> some View {
        let text = ManagedThreadState.text(message)
        let content = ManagedThreadState.content(message)
        return VStack(alignment: .leading, spacing: 8) {
            if !text.isEmpty {
                MacMessageText(text: text).textSelection(.enabled)
            }
            if content["failed"] as? Bool == true {
                Label("执行失败", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(ArcTheme.danger)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func switchMarkerRow(from: String, to: String, id: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2)
            Text("\(managedProvider(from)) → \(managedProvider(to))")
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(ArcTheme.inkMuted)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(ArcTheme.surfaceSunken, in: Capsule())
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("provider-switch-\(id)")
    }

    private func approvalCard(_ approval: ManagedApproval) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ArcTheme.warning)
                    .frame(width: 24, height: 24)
                    .background(ArcTheme.warningSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(approval.kind)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArcTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("待确认")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(ArcTheme.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(ArcTheme.warningSoft, in: Capsule())
            }

            if !approval.target.isEmpty {
                Text(approval.target)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(ArcTheme.ink)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if !approval.detail.isEmpty {
                Text(approval.detail)
                    .font(.caption)
                    .foregroundStyle(ArcTheme.inkMuted)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                Button { Task { await model.resolve(approval, approved: false) } } label: {
                    Text("拒绝")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ArcTheme.ink)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { Task { await model.resolve(approval, approved: true) } } label: {
                    Text("允许")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(ArcTheme.onPrimary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(ArcTheme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .disabled(model.busy || !model.connected)
        }
        .padding(12)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ArcTheme.warning.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }
}

/// Isolated composer subview so typing in `model.draft` and keyboard focus do NOT
/// re-render the message ScrollView or re-run `groupedItems` on every keystroke.
private struct ManagedThreadComposerBar: View {
    @Bindable var model: ManagedThreadModel
    var snapshot: ManagedThreadSnapshot
    var activeAgent: AgentKind
    var onOpenModelPicker: () -> Void
    var onPreviewImage: (UIImage) -> Void
    @FocusState private var composing: Bool
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var loadingAttachments = false

    private var canAttach: Bool {
        model.connected && !model.busy && !model.active && !model.uncertain && !loadingAttachments
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.imageAttachments.isEmpty || !model.fileAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.imageAttachments) { item in
                            if let image = UIImage(data: item.data) {
                                ZStack(alignment: .topTrailing) {
                                    Button { onPreviewImage(image) } label: {
                                        Image(uiImage: image)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.sm, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("预览待发送图片")
                                    Button {
                                        model.imageAttachments.removeAll { $0.id == item.id }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .symbolRenderingMode(.palette)
                                            .foregroundStyle(ArcTheme.bg, ArcTheme.ink)
                                            .frame(width: 24, height: 24)
                                    }
                                    .accessibilityLabel("移除图片")
                                }
                            }
                        }
                        ForEach(model.fileAttachments) { file in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                    .font(.caption)
                                    .foregroundStyle(ArcTheme.inkMuted)
                                Text(file.name)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(ArcTheme.ink)
                                    .lineLimit(1)
                                    .frame(maxWidth: 140)
                                Button {
                                    model.fileAttachments.removeAll { $0.id == file.id }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(ArcTheme.inkFaint)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("移除文件 \(file.name)")
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            if let error = model.error {
                ArcBanner(text: error)
                    .padding(.horizontal, 14)
                    .accessibilityIdentifier("managed-error")
            }
            if let error = model.cacheError {
                Text(error).font(.caption).foregroundStyle(ArcTheme.warning).padding(.horizontal, 18)
            }
            if model.uncertain {
                HStack {
                    Text("发送结果尚未确认，不会自动重复发送。").font(.caption).foregroundStyle(ArcTheme.warning)
                    Spacer()
                    Button("检查结果") { Task { await model.send(checkPending: true) } }
                        .font(.caption.weight(.semibold))
                        .disabled(model.busy || !model.connected)
                }
                .padding(.horizontal, 18)
            }
            if model.switchingProvider {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("正在切换 Agent…").font(.caption).foregroundStyle(ArcTheme.inkMuted)
                }
                .padding(.horizontal, 18)
            }
            if let error = model.providerError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(ArcTheme.warning)
                    if model.providerUncertain {
                        Spacer()
                        Button("核对") { Task { await model.retryProviderSwitch() } }
                            .font(.caption.weight(.semibold))
                            .disabled(model.busy || !model.connected || !model.providerSupported || model.active)
                    }
                }
                .padding(.horizontal, 18)
            }
            if model.modelUncertain {
                HStack {
                    Text(model.modelError ?? "模型修改结果待确认。").font(.caption).foregroundStyle(ArcTheme.warning)
                    Spacer()
                    Button("核对") { Task { await model.selectModel(nil, retry: true) } }
                        .font(.caption.weight(.semibold))
                        .disabled(model.busy || !model.connected)
                }
                .padding(.horizontal, 18)
            }

            // Signature T3 Code floating capsule composer
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button {
                        composing = false
                        showPhotoPicker = true
                    } label: {
                        Label("照片图库", systemImage: "photo.on.rectangle")
                    }
                    .disabled(model.imageAttachments.count >= ChatAttachment.maximumCount)

                    Button {
                        composing = false
                        showFileImporter = true
                    } label: {
                        Label("选择文件", systemImage: "doc")
                    }
                    .disabled(model.fileAttachments.count >= 4)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(canAttach ? ArcTheme.ink : ArcTheme.inkFaint)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .disabled(!canAttach)
                .accessibilityLabel("添加图片或文件")
                .accessibilityIdentifier("managed-upload-button")

                TextField("给 \(managedProvider(snapshot.thread.providerId)) 发消息…", text: $model.draft, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(ArcTheme.ink)
                    .focused($composing)
                    .lineLimit(1...5)
                    .padding(.vertical, 8)

                if loadingAttachments {
                    ProgressView().controlSize(.mini).frame(width: 22, height: 36)
                }

                Button {
                    composing = false
                    onOpenModelPicker()
                } label: {
                    HStack(spacing: 4) {
                        if model.loadingModels || model.switchingProvider {
                            ProgressView().controlSize(.mini).scaleEffect(0.8)
                        } else {
                            AgentIcon(agent: activeAgent, size: 18, tint: ArcTheme.ink)
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ArcTheme.inkMuted)
                    }
                    .padding(.horizontal, 6)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("conversation-agent-picker")

                Button {
                    if model.canInterrupt {
                        Task { await model.interrupt() }
                    } else {
                        composing = false
                        Task { await model.send() }
                    }
                } label: {
                    let active = model.canInterrupt || model.canSend
                    Image(systemName: model.canInterrupt ? "stop.fill" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(active ? ArcTheme.onPrimary : ArcTheme.inkFaint)
                        .frame(width: 34, height: 34)
                        .background(model.canInterrupt ? ArcTheme.ink : (model.canSend ? ArcTheme.primary : ArcTheme.line), in: Circle())
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(model.canInterrupt ? (model.busy || !model.connected) : !model.canSend)
                .accessibilityLabel(model.canInterrupt ? "停止" : "发送消息")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(ArcTheme.line.opacity(0.6), lineWidth: 0.75))
            .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .padding(.top, 6)
        .background(ArcTheme.chatBg)
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedPhotos,
            maxSelectionCount: max(1, ChatAttachment.maximumCount - model.imageAttachments.count),
            matching: .images
        )
        .onChange(of: pickedPhotos) { _, items in
            loadPhotos(items)
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image, .plainText, .sourceCode, .json, .xml, .yaml, .data],
            allowsMultipleSelection: true
        ) { result in
            handleImportedFiles(result)
        }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        pickedPhotos = []
        loadingAttachments = true
        Task {
            defer { loadingAttachments = false }
            for item in items {
                guard model.imageAttachments.count < ChatAttachment.maximumCount else { break }
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let prepared = ChatAttachment.prepare(data) else {
                    model.error = "无法读取所选图片，请选择 10 MB 以内的图片。"
                    continue
                }
                model.imageAttachments.append(ManagedDraftImage(data: prepared))
            }
        }
    }

    private func handleImportedFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.error = "无法读取文件：\(url.lastPathComponent)"
                continue
            }
            // If it's an image file, treat it as an image attachment.
            if ChatAttachment.isValid(data), let prepared = ChatAttachment.prepare(data) {
                guard model.imageAttachments.count < ChatAttachment.maximumCount else {
                    model.error = "最多添加 \(ChatAttachment.maximumCount) 张图片。"
                    continue
                }
                model.imageAttachments.append(ManagedDraftImage(data: prepared))
                continue
            }
            // Otherwise read as UTF-8 text/code file (up to 64 KB).
            guard data.count <= 64 * 1024, let text = String(data: data, encoding: .utf8) else {
                model.error = "仅支持图片或 64 KB 以内的文本/代码文件：\(url.lastPathComponent)"
                continue
            }
            guard model.fileAttachments.count < 4 else {
                model.error = "最多添加 4 个文本附件。"
                continue
            }
            model.fileAttachments.append(ManagedDraftFile(name: url.lastPathComponent, text: text))
        }
    }
}

// MARK: - Spacious Agent & Model Picker Sheet for ManagedThreadView

private struct ManagedThreadModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var snapshot: ManagedThreadSnapshot
    var model: ManagedThreadModel
    @State private var searchText = ""

    private var activeAgent: AgentKind { snapshot.thread.providerId == "claude" ? .claude : .codex }
    private var canSwitchProvider: Bool {
        model.providerSupported && !model.providerStorageBlocked && !model.busy && !model.active && model.connected && !model.providerUncertain && !model.uncertain && !model.modelUncertain
    }
    private var canSwitchModel: Bool {
        model.modelsSupported && !model.providerStorageBlocked && !model.loadingModels && !model.busy && !model.active && model.connected && !model.modelUncertain && !model.uncertain && !model.providerUncertain
    }
    private var filteredModels: [MacModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.availableModels }
        return model.availableModels.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach(AgentKind.allCases) { agent in
                        let selected = snapshot.thread.providerId == agent.agentId
                        Button {
                            guard canSwitchProvider, !selected else { return }
                            Task { await model.selectProvider(agent.agentId) }
                        } label: {
                            HStack(spacing: 6) {
                                AgentIcon(agent: agent, size: 15)
                                Text(agent.shortName).lineLimit(1)
                            }
                            .font(.subheadline.weight(selected ? .semibold : .medium))
                            .foregroundStyle(selected ? ArcTheme.ink : ArcTheme.inkMuted)
                            .frame(maxWidth: .infinity, minHeight: 38)
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ArcTheme.surface)
                                        .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                                }
                            }
                            .opacity(canSwitchProvider || selected ? 1 : 0.45)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSwitchProvider && !selected)
                    }
                }
                .padding(3)
                .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)

                if model.availableModels.count >= 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(ArcTheme.inkFaint)
                        TextField("搜索 \(activeAgent.shortName) 模型…", text: $searchText)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill").font(.footnote).foregroundStyle(ArcTheme.inkFaint)
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        modelRow(title: "客户端默认模型", subtitle: "使用 \(activeAgent.shortName) 在 Mac 上的默认模型", isSelected: (snapshot.thread.model ?? "").isEmpty) {
                            Task { await model.selectModel(nil) }
                            dismiss()
                        }
                        if model.loadingModels {
                            ArcDivider(inset: 16)
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取模型目录…").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 48)
                        } else if let error = model.modelError, filteredModels.isEmpty {
                            ArcDivider(inset: 16)
                            Text(error).font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        } else {
                            ForEach(filteredModels, id: \.id) { item in
                                ArcDivider(inset: 16)
                                modelRow(title: item.name, subtitle: item.id != item.name ? item.id : nil, isSelected: snapshot.thread.model == item.id) {
                                    Task { await model.selectModel(item.id) }
                                    dismiss()
                                }
                            }
                        }
                    }
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                    .disabled(!canSwitchModel)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                    .accessibilityIdentifier("conversation-model-picker")
                }
            }
            .background(ArcTheme.bg)
            .navigationTitle("选择 Agent 与模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.foregroundStyle(ArcTheme.ink)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func modelRow(title: String, subtitle: String?, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(isSelected ? .semibold : .regular)).foregroundStyle(ArcTheme.ink).lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(ArcTheme.inkFaint).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark").font(.footnote.weight(.bold)).foregroundStyle(activeAgent.tint)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 11).frame(minHeight: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

func managedProvider(_ value: String) -> String { value == "claude" ? "Claude" : value == "codex" ? "Codex" : value }

func managedStatus(_ value: String) -> String {
    ["active": "执行中", "idle": "就绪", "attention": "结果待确认", "running": "执行中", "completed": "已完成", "failed": "失败", "outcome_unknown": "结果待确认"][value] ?? value
}

struct ManagedWorkspaceView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var projects: [ManagedProject] = []
    @State private var threads: [String: [ManagedThread]] = [:]
    @State private var error: String?
    @State private var supported = false
    @State private var claudeSupported = false
    @State private var threadProvider = "codex"
    @State private var busy = false
    @State private var addingProject = false
    @State private var choosingFolder = false
    @State private var projectName = ""
    @State private var projectPath = ""
    @State private var threadTitle = ""
    @State private var threadProject: ManagedProject?
    var body: some View {
        List {
            if let error { Section { Text(error).foregroundStyle(ArcTheme.danger) } }
            if projects.isEmpty { ContentUnavailableView("还没有共享项目", systemImage: "folder", description: Text(supported ? "添加 Mac 上的项目，或由 Mac 授予当前手机访问权限。" : "正在检查 Mac 的共享对话能力。")) }
            ForEach(projects, id: \.id) { project in
                Section {
                    ForEach(threads[project.id] ?? [], id: \.id) { thread in
                        Button { path.append(Route.managedThread(thread.id)) } label: {
                            HStack { Image(systemName: "bubble.left.and.bubble.right"); Text(thread.title); Spacer(); Text("\(managedProvider(thread.providerId)) · \(managedStatus(thread.status))").font(.caption).foregroundStyle(ArcTheme.inkMuted) }
                        }.frame(minHeight: ArcTheme.tapMin)
                    }
                    Button { threadProject = project; threadTitle = ""; threadProvider = "codex" } label: { Label("新建共享对话", systemImage: "plus") }.disabled(busy || !supported)
                } header: { Text(project.name) } footer: { Text(project.canonicalRoot).font(.caption) }
            }
        }
        .navigationTitle("共享对话")
        .toolbar { ToolbarItem(placement: .primaryAction) { Button { addingProject = true } label: { Image(systemName: "folder.badge.plus") }.disabled(!supported || busy).accessibilityLabel("添加共享项目") } }
        .task(id: store.selectedDeviceID) { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $addingProject) {
            NavigationStack {
                Form {
                    Section("Mac 项目") { TextField("项目名称", text: $projectName); Button(projectPath.isEmpty ? "选择 Mac 文件夹" : projectPath) { choosingFolder = true }; }
                    if let error { Text(error).foregroundStyle(ArcTheme.danger) }
                    Button("创建共享项目") { Task { await createProject() } }.disabled(busy || projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projectPath.isEmpty)
                }.navigationTitle("添加共享项目").toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { addingProject = false }.disabled(busy) } }
            }.interactiveDismissDisabled(busy).sheet(isPresented: $choosingFolder) { MacFolderPicker { projectPath = $0; if projectName.isEmpty { projectName = URL(fileURLWithPath: $0).lastPathComponent } } }
        }
        .sheet(isPresented: Binding(get: { threadProject != nil }, set: { if !$0 { threadProject = nil } })) {
            NavigationStack {
                Form {
                    Section("共享对话") {
                        TextField("对话标题", text: $threadTitle)
                        Picker("Agent", selection: $threadProvider) {
                            Text("Codex").tag("codex")
                            if claudeSupported { Text("Claude").tag("claude") }
                        }
                    }
                    if !claudeSupported { Text("更新 Mac 客户端后可创建 Claude 共享对话。").font(.footnote).foregroundStyle(ArcTheme.inkMuted) }
                    if let error { Text(error).foregroundStyle(ArcTheme.danger) }
                    Button("创建") { if let project = threadProject { Task { await createThread(project) } } }.disabled(busy)
                }.navigationTitle("新建共享对话")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { threadProject = nil }.disabled(busy) } }
            }.interactiveDismissDisabled(busy)
        }
    }
    private func load() async {
        supported = false; claudeSupported = false
        guard let bridge = store.macBridge, let device = store.selectedDeviceID else { error = "Mac 尚未连接"; return }
        do {
            let environment = try await bridge.describeEnvironment()
            guard !Task.isCancelled, store.selectedDeviceID == device else { return }
            supported = environment.capabilities.contains("managed_execution_v1")
            claudeSupported = environment.capabilities.contains("managed_claude_v1")
            guard supported else { error = "请更新 Mac 客户端以使用共享对话。原有对话仍可继续使用。"; return }
            let rows = try await bridge.listManagedProjects()
            var values: [String: [ManagedThread]] = [:]
            for row in rows { values[row.id] = try await bridge.listManagedThreads(projectId: row.id) }
            guard !Task.isCancelled, store.selectedDeviceID == device else { return }
            projects = rows; threads = values; error = nil
        } catch { if store.selectedDeviceID == device { self.error = error.localizedDescription } }
    }
    private func createProject() async {
        guard !busy, supported, let bridge = store.macBridge, let device = store.selectedDeviceID else { return }
        busy = true; defer { busy = false }
        do { _ = try await bridge.createManagedProject(commandId: UUID().uuidString, path: projectPath, name: projectName.trimmingCharacters(in: .whitespacesAndNewlines)); guard store.selectedDeviceID == device else { return }; addingProject = false; projectName = ""; projectPath = ""; await load() }
        catch { if store.selectedDeviceID == device { self.error = error.localizedDescription } }
    }
    private func createThread(_ project: ManagedProject) async {
        guard !busy, supported, let bridge = store.macBridge, let device = store.selectedDeviceID else { return }
        guard threadProvider != "claude" || claudeSupported else { return }
        busy = true; defer { busy = false }
        do { let value = try await bridge.createManagedThread(commandId: UUID().uuidString, projectId: project.id, providerId: threadProvider, title: threadTitle.isEmpty ? "新对话" : threadTitle); guard store.selectedDeviceID == device else { return }; threadProject = nil; path.append(Route.managedThread(value.id)) }
        catch { if store.selectedDeviceID == device { self.error = error.localizedDescription } }
    }
}

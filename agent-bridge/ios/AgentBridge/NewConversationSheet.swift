import PhotosUI
import SwiftUI

struct NewConversationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var projectID: String
    var onStart: (String, String) -> Void

    enum CheckoutMode: String, CaseIterable, Identifiable {
        case current = "当前工作区"
        case worktree = "新建 Worktree"
        var id: String { rawValue }
        var symbolName: String {
            switch self {
            case .current: "folder"
            case .worktree: "square.stack.3d.up"
            }
        }
    }

    @State private var policy: SessionExecutionPolicy = .workspace
    @State private var checkoutMode: CheckoutMode = .current
    @State private var selectedBranch = ""
    @State private var gitInfo: MacGitInfo?
    @State private var loadingBranches = false
    @State private var branchError: String?
    @State private var showModelPicker = false
    @State private var showBranchPicker = false
    @State private var selectedAgent: AgentKind? = nil
    @State private var selectedModel = ""
    @State private var allAgentModels: [AgentKind: [MacModel]] = [:]
    @State private var modelHint: String?
    @State private var loadingModels = false
    @State private var text = ""
    @State private var images: [Data] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var imageEpoch = UUID()
    @State private var loadingImages = false
    @State private var submitting = false
    @State private var error: String?
    @State private var pendingSessionID: String?
    @FocusState private var messageFocused: Bool

    private var project: ProjectItem? {
        store.projects.first { $0.id == projectID }
    }
    private var activeAgent: AgentKind {
        selectedAgent ?? project?.agent ?? store.selectedAgent
    }
    private var projects: [ProjectItem] {
        let agentProjects = store.projects(for: activeAgent, query: "")
        return agentProjects.isEmpty ? store.projects(for: store.selectedAgent, query: "") : agentProjects
    }
    private var settingsLocked: Bool {
        submitting || pendingSessionID.map { !store.canConfigureUnsentSession($0) } == true
    }
    private var canStart: Bool {
        project != nil && store.canSend && !submitting && !loadingImages
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && (!store.usesRemoteChat || activeAgent == .codex)
    }

    private var currentModelLabel: String {
        if selectedModel.isEmpty { return "\(activeAgent.shortName) 默认" }
        for (_, agentModels) in allAgentModels {
            if let match = agentModels.first(where: { $0.id == selectedModel }) { return match.name }
        }
        return selectedModel
    }

    private var shortPolicyLabel: String {
        switch policy {
        case .readOnly: "只读"
        case .workspace: "项目内读写"
        case .fullAccess: "完全权限"
        }
    }

    private var hostDisplayName: String {
        store.hostName.isEmpty ? "本地 Mac" : store.hostName
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Spacer(minLength: 16)

                VStack(spacing: 14) {
                    heroTitle
                    hostStatusRow
                    if let error {
                        ArcBanner(text: error)
                            .padding(.top, 12)
                            .padding(.horizontal, 20)
                            .accessibilityIdentifier("new-chat-error")
                    }
                    if !store.canSend {
                        inlineNotice(icon: "lock", text: "当前手机权限不能新建对话", color: ArcTheme.warning)
                    }
                    if store.usesRemoteChat && activeAgent != .codex {
                        inlineNotice(icon: "info.circle", text: "远程图文对话目前仅支持 Codex 项目", color: ArcTheme.inkMuted)
                    }
                    if let modelHint {
                        inlineNotice(icon: "sparkle", text: modelHint, color: ArcTheme.inkFaint)
                    }
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { messageFocused = false }

                Spacer(minLength: 16)

                bottomComposerArea
            }
            .background(ArcTheme.chatBg)
            .navigationTitle("新对话")
            .navigationBarTitleDisplayMode(.inline)
            .tint(ArcTheme.ink)
            .toolbarBackground(ArcTheme.chatBg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left")
                                .font(.body.weight(.medium))
                            Text("返回")
                                .font(.body)
                        }
                        .foregroundStyle(ArcTheme.ink)
                    }
                    .accessibilityLabel("返回")
                    .disabled(submitting)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let project {
                        Menu {
                            ForEach(projects) { item in
                                Button {
                                    projectID = item.id
                                } label: {
                                    HStack {
                                        Text(item.name)
                                        if item.id == projectID { Image(systemName: "checkmark") }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "folder")
                                .font(.body)
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                        .disabled(settingsLocked || projects.isEmpty)
                        .accessibilityLabel("切换项目，当前 \(project.name)")
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(submitting)
        .task(id: store.online) {
            if project == nil { projectID = projects.first?.id ?? "" }
            if selectedAgent == nil { selectedAgent = project?.agent ?? store.selectedAgent }
            guard let bridge = store.macBridge else { return }
            let device = store.selectedDeviceID
            loadingModels = true
            defer { loadingModels = false }
            var loadedAny = false
            for agent in AgentKind.allCases where agent.installed {
                guard let result = try? await bridge.listAgentModels(agentId: agent.agentId),
                      !Task.isCancelled, device == store.selectedDeviceID else { continue }
                allAgentModels[agent] = result
                if !result.isEmpty { loadedAny = true }
            }
            if !Task.isCancelled, device == store.selectedDeviceID {
                modelHint = loadedAny ? nil : "Mac 暂无可选模型，将自动使用默认模型。"
            }
        }
        .task(id: "\(projectID)/\(store.online)") { await loadGitBranches() }
        .onChange(of: picked) { _, items in loadImages(items) }
        .onChange(of: store.selectedDeviceID) { _, _ in dismiss() }
        .onDisappear { imageEpoch = UUID() }
        .sheet(isPresented: $showModelPicker) {
            AgentModelPickerSheet(
                activeAgent: activeAgent,
                selectedModel: selectedModel,
                policy: $policy,
                allAgentModels: allAgentModels,
                loadingModels: loadingModels,
                online: store.online
            ) { agent, modelId in
                selectAgentModel(agent: agent, modelId: modelId)
                showModelPicker = false
            }
        }
        .sheet(isPresented: $showBranchPicker) {
            RealBranchPickerSheet(
                selectedBranch: $selectedBranch,
                gitInfo: gitInfo,
                loading: loadingBranches,
                error: branchError
            )
        }
    }

    // MARK: - Centered Hero (T3 Code Signature)

    private var heroTitle: some View {
        VStack(spacing: 6) {
            Text("接下来想构建什么")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(ArcTheme.ink)

            if projects.isEmpty {
                Text("请先添加项目")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(ArcTheme.inkMuted)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("在")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(ArcTheme.ink)

                    Menu {
                        ForEach(projects) { item in
                            Button {
                                projectID = item.id
                            } label: {
                                HStack {
                                    Text(item.name)
                                    if item.id == projectID {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Text(project?.name ?? "选择项目")
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(ArcTheme.ink)
                            .lineLimit(1)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(ArcTheme.inkMuted.opacity(0.55))
                                    .frame(height: 1.5)
                                    .offset(y: 3)
                            }
                    }
                    .disabled(settingsLocked)
                    .accessibilityLabel("选择项目，当前 \(project?.name ?? "未选择")")
                    .accessibilityIdentifier("current-project-picker")

                    Text("中？")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(ArcTheme.ink)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    private var hostStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "server.rack")
                .font(.system(size: 12))
                .foregroundStyle(ArcTheme.inkMuted)
                .accessibilityHidden(true)
            Text("运行于 \(hostDisplayName)")
                .font(.footnote)
                .foregroundStyle(ArcTheme.inkMuted)
            Circle()
                .fill(store.online ? ArcTheme.live : ArcTheme.danger)
                .frame(width: 6, height: 6)
        }
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("运行于 \(hostDisplayName)，\(store.online ? "在线" : "离线")")
    }

    // MARK: - Bottom Composer Area (T3 Code Style)

    private var bottomComposerArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !images.isEmpty {
                attachmentStrip
            }

            if loadingImages {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在读取图片…")
                        .font(.caption)
                        .foregroundStyle(ArcTheme.inkMuted)
                }
                .padding(.horizontal, 18)
            }

            // Lightweight T3 Code metadata bar above the floating pill:
            // Left: Current checkout / New worktree   Right: Choose branch >
            HStack(spacing: 18) {
                Menu {
                    ForEach(CheckoutMode.allCases) { mode in
                        Button { checkoutMode = mode } label: {
                            HStack {
                                Label(mode.rawValue, systemImage: mode.symbolName)
                                if checkoutMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: checkoutMode.symbolName)
                            .font(.system(size: 13.5))
                            .foregroundStyle(ArcTheme.inkMuted)
                        Text(checkoutMode.rawValue)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(ArcTheme.inkMuted)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .disabled(settingsLocked)
                .accessibilityLabel("工作区模式，当前 \(checkoutMode.rawValue)")

                Button { showBranchPicker = true } label: {
                    HStack(spacing: 5) {
                        if loadingBranches {
                            ProgressView().controlSize(.mini).scaleEffect(0.75)
                        } else {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 13))
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                        let branchText: String = {
                            if !selectedBranch.isEmpty { return selectedBranch }
                            if let current = gitInfo?.currentBranch, !current.isEmpty { return current }
                            if gitInfo?.isGitRepo == false { return "非 Git 仓库" }
                            return "选择分支"
                        }()
                        Text(branchText)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle((!selectedBranch.isEmpty || gitInfo?.currentBranch != nil) ? ArcTheme.ink : ArcTheme.inkMuted)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(ArcTheme.inkFaint)
                    }
                    .frame(minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(settingsLocked || gitInfo?.isGitRepo == false)
                .accessibilityLabel("选择分支")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            // Signature T3 Code floating capsule composer
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(
                    selection: $picked,
                    maxSelectionCount: max(1, ChatAttachment.maximumCount - images.count),
                    matching: .images
                ) {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(ArcTheme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .accessibilityLabel("从相册添加图片")
                .disabled(submitting || loadingImages || images.count >= ChatAttachment.maximumCount)

                TextField("描述你想完成的任务…", text: $text, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(ArcTheme.ink)
                    .focused($messageFocused)
                    .lineLimit(1...5)
                    .padding(.vertical, 8)
                    .disabled(submitting)
                    .accessibilityLabel("首条消息")
                    .accessibilityIdentifier("new-chat-message")

                // Agent + Model trigger button -> opens spacious bottom sheet
                Button {
                    messageFocused = false
                    showModelPicker = true
                } label: {
                    HStack(spacing: 4) {
                        if loadingModels {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.8)
                        } else {
                            AgentIcon(agent: activeAgent, size: 18, tint: ArcTheme.ink)
                        }
                        if !selectedModel.isEmpty {
                            Text(currentModelLabel)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ArcTheme.inkMuted)
                                .lineLimit(1)
                                .frame(maxWidth: 76)
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
                .disabled(settingsLocked)
                .accessibilityLabel("切换 Agent 与模型，当前 \(currentModelLabel)")
                .accessibilityIdentifier("new-chat-model")

                // Circular send button
                Button(action: start) {
                    Group {
                        if submitting {
                            ProgressView()
                                .controlSize(.small)
                                .tint(ArcTheme.onPrimary)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(canStart ? ArcTheme.onPrimary : ArcTheme.inkFaint)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(canStart || submitting ? ArcTheme.primary : ArcTheme.line, in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
                .accessibilityLabel(submitting ? "正在开始" : "开始对话")
                .accessibilityIdentifier("start-conversation")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(ArcTheme.line.opacity(0.6), lineWidth: 0.75)
            )
            .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .background(ArcTheme.chatBg)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                    if let image = UIImage(data: data) {
                        ZStack(alignment: .topTrailing) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(ArcTheme.line, lineWidth: 0.5)
                                )
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    images.remove(at: index)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(ArcTheme.chatBg, ArcTheme.ink)
                                    .font(.system(size: 18))
                                    .frame(width: 28, height: 28)
                                    .contentShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .offset(x: 4, y: -4)
                            .accessibilityLabel("移除图片 \(index + 1)")
                        }
                        .padding(.top, 4)
                        .padding(.trailing, 4)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .disabled(submitting)
    }

    private func inlineNotice(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Actions

    private func loadGitBranches() async {
        gitInfo = nil; branchError = nil; loadingBranches = false
        guard let path = project?.path, !path.isEmpty, store.online, let bridge = store.macBridge else { return }
        let captured = path
        loadingBranches = true
        defer { if captured == project?.path { loadingBranches = false } }
        do {
            let info = try await bridge.listGitBranches(path: path)
            guard !Task.isCancelled, captured == project?.path else { return }
            gitInfo = info
            if !info.isGitRepo { checkoutMode = .current }
        } catch {
            if !Task.isCancelled, captured == project?.path {
                branchError = "暂时无法读取 Git 分支，请确认 Mac 端已更新并在线。"
            }
        }
    }

    private func selectAgentModel(agent: AgentKind, modelId: String) {
        selectedAgent = agent
        selectedModel = modelId
        // If another project matches the current path under the newly selected agent, switch to it automatically.
        if let currentPath = project?.path,
           let matching = store.projects(for: agent, query: "").first(where: { $0.path == currentPath }) {
            projectID = matching.id
        }
    }

    private func appendImage(_ data: Data) {
        guard images.count < ChatAttachment.maximumCount else { return }
        guard let image = ChatAttachment.prepare(data) else {
            error = "图片无法读取或超过 10 MB，请重新选择。"
            return
        }
        images.append(image)
    }

    private func loadImages(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let epoch = imageEpoch
        loadingImages = true
        Task { @MainActor in
            defer { if epoch == imageEpoch { loadingImages = false; picked = [] } }
            for item in items {
                guard epoch == imageEpoch, !submitting else { return }
                if let data = try? await item.loadTransferable(type: Data.self) {
                    guard epoch == imageEpoch else { return }
                    appendImage(data)
                } else { error = "无法读取图片，请重新选择。" }
            }
        }
    }

    private func start() {
        guard canStart, let project else { return }
        let device = store.selectedDeviceID
        let model = selectedModel
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.usesRemoteChat && !store.online {
            error = "Mac 当前离线，连接后即可重试，内容已保留。"; return
        }
        let options = ChatSessionOptions(model: model.isEmpty ? nil : model, executionPolicy: policy)
        let id: String
        if let existing = pendingSessionID {
            if store.canConfigureUnsentSession(existing) {
                guard store.configureUnsentSession(existing, projectID: project.id, options: options) else {
                    error = "无法保存对话设置，请重试。"; return
                }
            }
            id = existing
        } else {
            id = store.createSession(projectId: project.id,
                title: message.isEmpty ? "图片对话" : String(message.prefix(24)), options: options)
        }
        guard !id.isEmpty else { error = "无法创建对话，请检查设备权限与存储后重试。"; return }
        pendingSessionID = id
        messageFocused = false
        submitting = true
        error = nil
        Task { @MainActor in
            let accepted = await store.sendMessage(sessionId: id, text: message, images: images, deviceID: device)
            submitting = false
            guard device == store.selectedDeviceID else { return }
            if accepted { onStart(project.id, id); dismiss() }
            else { error = store.chatError(sessionId: id) ?? "对话未能开启，内容已保留。请确认 Mac 在线、模型可用后重试。" }
        }
    }
}

// MARK: - Spacious Agent & Model Picker Sheet (T3 Code Style)

struct AgentModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    var activeAgent: AgentKind
    var selectedModel: String
    @Binding var policy: SessionExecutionPolicy
    var allAgentModels: [AgentKind: [MacModel]]
    var loadingModels: Bool
    var online: Bool
    var onSelect: (AgentKind, String) -> Void

    @State private var browsingAgent: AgentKind
    @State private var searchText = ""

    init(
        activeAgent: AgentKind,
        selectedModel: String,
        policy: Binding<SessionExecutionPolicy>,
        allAgentModels: [AgentKind: [MacModel]],
        loadingModels: Bool,
        online: Bool,
        onSelect: @escaping (AgentKind, String) -> Void
    ) {
        self.activeAgent = activeAgent
        self.selectedModel = selectedModel
        self._policy = policy
        self.allAgentModels = allAgentModels
        self.loadingModels = loadingModels
        self.online = online
        self.onSelect = onSelect
        self._browsingAgent = State(initialValue: activeAgent)
    }

    private var filteredModels: [MacModel] {
        let list = allAgentModels[browsingAgent] ?? []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Agent tabs
                AgentSwitcher(selection: $browsingAgent)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                // Search bar when there are many models
                if (allAgentModels[browsingAgent]?.count ?? 0) >= 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote)
                            .foregroundStyle(ArcTheme.inkFaint)
                        TextField("搜索 \(browsingAgent.shortName) 模型…", text: $searchText)
                            .font(.subheadline)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(ArcTheme.inkFaint)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Model list card
                        VStack(spacing: 0) {
                            modelRow(
                                title: "跟随 Mac 默认",
                                subtitle: "使用 \(browsingAgent.shortName) 在 Mac 上的默认模型",
                                isSelected: activeAgent == browsingAgent && selectedModel.isEmpty
                            ) {
                                onSelect(browsingAgent, "")
                            }

                            if loadingModels {
                                ArcDivider(inset: 16)
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在获取模型列表…")
                                        .font(.footnote)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 48)
                            } else if filteredModels.isEmpty {
                                ArcDivider(inset: 16)
                                HStack(spacing: 8) {
                                    Image(systemName: online ? "tray" : "wifi.slash")
                                        .font(.footnote)
                                        .foregroundStyle(ArcTheme.inkFaint)
                                    Text(online ? "暂无更多可选模型" : "Mac 离线，连接后自动同步完整模型列表")
                                        .font(.footnote)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                    Spacer()
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 48)
                            } else {
                                ForEach(filteredModels, id: \.id) { model in
                                    ArcDivider(inset: 16)
                                    modelRow(
                                        title: model.name,
                                        subtitle: model.id != model.name ? model.id : nil,
                                        isSelected: activeAgent == browsingAgent && selectedModel == model.id
                                    ) {
                                        onSelect(browsingAgent, model.id)
                                    }
                                }
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75)
                        )

                        // Execution policy section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("执行权限")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(ArcTheme.inkMuted)
                                .padding(.horizontal, 4)

                            HStack(spacing: 6) {
                                ForEach(SessionExecutionPolicy.allCases) { item in
                                    let selected = policy == item
                                    let label = switch item {
                                    case .readOnly: "只读"
                                    case .workspace: "项目内读写"
                                    case .fullAccess: "完全权限"
                                    }
                                    Button {
                                        policy = item
                                    } label: {
                                        Text(label)
                                            .font(.footnote.weight(selected ? .semibold : .medium))
                                            .foregroundStyle(selected ? ArcTheme.ink : ArcTheme.inkMuted)
                                            .frame(maxWidth: .infinity, minHeight: 36)
                                            .background(
                                                selected ? ArcTheme.surface : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                                            )
                                            .shadow(color: selected ? .black.opacity(0.06) : .clear, radius: 2, y: 1)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(3)
                            .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                            .accessibilityIdentifier("new-chat-permission")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
            }
            .background(ArcTheme.bg)
            .navigationTitle("选择 Agent 与模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(ArcTheme.ink)
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
                    Text(title)
                        .font(.subheadline.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(ArcTheme.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(ArcTheme.inkFaint)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(ArcTheme.ink)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

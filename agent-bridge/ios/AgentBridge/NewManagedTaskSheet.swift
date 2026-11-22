import SwiftUI

/// One immutable intent survives uncertain replies and app termination. Retrying
/// reuses every command ID on the same device instead of creating another task.
struct PendingManagedTask: Codable {
    var deviceID: String
    var projectPath: String
    var projectName: String
    var provider: String
    var model: String?
    var text: String
    var projectCommand = UUID().uuidString
    var threadCommand = UUID().uuidString
    var modelCommand = UUID().uuidString
    var sendCommand = UUID().uuidString
    var clientMessage = UUID().uuidString
    var projectID: String?
    var threadID: String?
    var modelApplied = false
    var draftText: String? = nil
    var history: ImportedHistoryContinuation? = nil
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentBridge/pending-managed-task-v1.json")
    }
    static func load() throws -> Self? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

struct NewManagedTaskSheet: View {
    enum CheckoutMode: String, CaseIterable, Identifiable {
        case current = "当前工作区"
        case worktree = "新建 Worktree"
        var id: String { rawValue }
        var symbolName: String { self == .current ? "folder" : "square.stack.3d.up" }
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var initialDeviceID: String?
    var initialProjectPath: String = ""
    var historyContinuation: ImportedHistoryContinuation? = nil
    var onStart: (String, String) -> Void

    @State private var deviceID = ""
    @State private var projectPath = ""
    @State private var projectName = ""
    @State private var provider = "codex"
    @State private var selectedModel = ""
    @State private var text = ""
    @State private var models: [MacModel] = []
    @State private var capabilities: [String] = []
    @State private var busyCounts: [String: UInt32] = [:]
    @State private var loading = false
    @State private var modelLoading = false
    @State private var busy = false
    @State private var choosingFolder = false
    @State private var showModelPicker = false
    @State private var checkoutMode: CheckoutMode = .current
    @State private var selectedBranch = ""
    @State private var gitInfo: MacGitInfo?
    @State private var loadingBranches = false
    @State private var branchError: String?
    @State private var showBranchPicker = false
    @State private var error: String?
    @State private var modelError: String?
    @State private var pending: PendingManagedTask?
    @State private var storageBlocked = false
    @State private var canDiscard = false
    @State private var operationStep = ""
    @FocusState private var messageFocused: Bool

    private var history: ImportedHistoryContinuation? {
        if let pending { return pending.history }
        return historyContinuation
    }

    private var activeAgent: AgentKind {
        provider == "claude" ? .claude : .codex
    }

    private var historyPreview: String {
        guard let history else { return "" }
        return history.records.map { record in
            let role = record.role == "user" ? "你" : "助手"
            return "\(role)：\n\(record.text)"
        }.joined(separator: "\n\n")
    }

    private var selectedDeviceName: String {
        store.devices.first { $0.id == deviceID }?.displayName ?? "选择客户端"
    }

    private var availableProviders: [AgentKind] {
        AgentKind.allCases.filter { kind in
            (kind == .codex && capabilities.contains("managed_execution_v1") || kind == .claude && capabilities.contains("managed_claude_v1"))
                && store.agents(for: deviceID).contains { $0.id == kind.agentId && $0.status != "not_found" && $0.validation == "verified" }
        }
    }

    private var outgoingText: String? {
        if let pending { return pending.text }
        if let history { return try? history.message(request: text) }
        return text
    }

    private var ready: Bool {
        !busy && !loading && !modelLoading && !storageBlocked && store.isOnline(deviceID)
            && !projectPath.isEmpty && !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && availableProviders.contains { $0.agentId == provider }
            && (history == nil || (deviceID == history?.deviceID && projectPath == history?.projectPath))
            && outgoingText.map { $0.utf8.count <= 262144 } == true
    }

    private var currentModelLabel: String {
        if selectedModel.isEmpty { return "\(activeAgent.shortName) 默认" }
        return models.first { $0.id == selectedModel }?.name ?? selectedModel
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 14) {
                        heroTitle
                            .padding(.top, 56)
                        hostSelectorRow
                        if let history {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("基于历史继续：\(history.title)", systemImage: "text.bubble").font(.subheadline.weight(.semibold))
                                Text("将在原客户端和项目创建新对话。选择 Agent 并发送后，引用下方公开历史；原对话保持只读。")
                                    .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                if history.truncated { Text("历史较长，仅引用最近的部分内容。").font(.footnote).foregroundStyle(ArcTheme.warning) }
                                DisclosureGroup("查看将引用的 \(history.records.count) 条历史") {
                                    ScrollView {
                                        Text(historyPreview)
                                            .font(.footnote).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    }.frame(maxHeight: 220)
                                }.font(.footnote)
                            }.padding(16).arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.md).padding(.horizontal, 20)
                        }

                        if loading {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("正在读取客户端能力…")
                                    .font(.caption)
                                    .foregroundStyle(ArcTheme.inkMuted)
                            }
                            .padding(.top, 4)
                        }

                        if !deviceID.isEmpty && !loading && availableProviders.isEmpty {
                            inlineNotice(icon: "exclamationmark.triangle", text: "此客户端暂无可执行的 Agent，请确认已安装并更新 ArcLink。", color: ArcTheme.warning)
                        }

                        if let error {
                            ArcBanner(text: error)
                                .padding(.horizontal, 20)
                                .padding(.top, 6)
                                .accessibilityIdentifier("new-task-error")
                        }

                        if pending != nil {
                            VStack(spacing: 8) {
                                Text("已固定客户端与任务内容。点击发送会核对同一个任务，不会重复创建。")
                                    .font(.caption)
                                    .foregroundStyle(ArcTheme.inkMuted)
                                    .multilineTextAlignment(.center)
                                if canDiscard {
                                    Button("取消未发送的任务", role: .destructive) { discardRejectedTask() }
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 4)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)

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
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.medium))
                            .foregroundStyle(ArcTheme.primary)
                    }
                    .accessibilityLabel(pending == nil ? "取消" : "稍后继续")
                    .disabled(busy)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { choosingFolder = true } label: {
                        Image(systemName: "folder")
                            .font(.body)
                            .foregroundStyle(ArcTheme.inkMuted)
                    }
                    .disabled(busy || pending != nil || history != nil || deviceID.isEmpty || !store.isOnline(deviceID))
                    .accessibilityLabel("选择项目文件夹")
                    .accessibilityIdentifier("new-task-folder")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(busy)
        .task {
            do {
                pending = try PendingManagedTask.load()
                if let loaded = pending {
                    deviceID = loaded.deviceID; projectPath = loaded.projectPath; projectName = loaded.projectName
                    provider = loaded.provider; selectedModel = loaded.model ?? ""; text = loaded.draftText ?? loaded.text
                    // If nothing was created on the server yet, keep the draft fields but unlock editing.
                    if loaded.projectID == nil && loaded.threadID == nil {
                        try? PendingManagedTask.clear()
                        pending = nil
                    }
                } else {
                    deviceID = historyContinuation?.deviceID ?? initialDeviceID ?? store.selectedDeviceID ?? ""
                    projectPath = historyContinuation?.projectPath ?? initialProjectPath
                    projectName = projectPath.isEmpty ? "" : URL(fileURLWithPath: projectPath).lastPathComponent
                    provider = historyContinuation?.provider ?? "codex"
                }
            } catch { storageBlocked = true; self.error = "无法读取尚未完成的任务记录，原文件已保留。请先检查存储。" }
            await store.refreshMacStatus()
            for device in store.devices where store.isOnline(device.id) {
                if let bridge = store.bridge(for: device.id), let info = try? await bridge.getSystemInfo() {
                    busyCounts[device.id] = info.activeProcesses
                }
            }
        }
        .task(id: "\(deviceID)/\(store.isOnline(deviceID))") { await loadDevice() }
        .task(id: "\(deviceID)/\(provider)/\(capabilities.contains("managed_models_v1"))") { await loadModels() }
        .task(id: "\(deviceID)/\(projectPath)/\(store.isOnline(deviceID))") { await loadGitBranches() }
        .onChange(of: deviceID) { old, new in
            guard !old.isEmpty, old != new, pending == nil, history == nil else { return }
            projectPath = ""; projectName = ""; selectedModel = ""; models = []; gitInfo = nil; selectedBranch = ""; checkoutMode = .current
        }
        .onChange(of: projectPath) { _, _ in
            if pending == nil { selectedBranch = ""; checkoutMode = .current }
        }
        .onChange(of: provider) { _, _ in if pending == nil { selectedModel = "" } }
        .sheet(isPresented: $choosingFolder) {
            MacFolderPicker(deviceID: deviceID) { value in
                projectPath = value
                projectName = URL(fileURLWithPath: value).lastPathComponent
            }
        }
        .sheet(isPresented: $showModelPicker) {
            ManagedNewTaskModelSheet(
                provider: $provider,
                selectedModel: $selectedModel,
                availableProviders: availableProviders,
                models: models,
                modelsSupported: capabilities.contains("managed_models_v1"),
                loading: modelLoading || loading,
                modelError: modelError
            )
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

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("在")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ArcTheme.ink)

                Button { choosingFolder = true } label: {
                    Text(projectName.isEmpty ? "选择项目" : projectName)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(projectName.isEmpty ? ArcTheme.inkMuted : ArcTheme.ink)
                        .lineLimit(1)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(ArcTheme.inkMuted.opacity(0.55))
                                .frame(height: 1.5)
                                .offset(y: 3)
                        }
                }
                .buttonStyle(.plain)
                .disabled(busy || pending != nil || history != nil || deviceID.isEmpty || !store.isOnline(deviceID))

                Text("中？")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(ArcTheme.ink)
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    private var hostSelectorRow: some View {
        Menu {
            ForEach(store.devices) { device in
                Button {
                    deviceID = device.id
                } label: {
                    HStack {
                        Text("\(device.displayName) · \(deviceStatus(device.id))")
                        if device.id == deviceID { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "server.rack")
                    .font(.system(size: 12))
                    .foregroundStyle(ArcTheme.inkMuted)
                    .accessibilityHidden(true)
                Text("运行于 \(selectedDeviceName)")
                    .font(.footnote)
                    .foregroundStyle(ArcTheme.inkMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ArcTheme.inkFaint)
                Circle()
                    .fill(!deviceID.isEmpty && store.isOnline(deviceID) ? ArcTheme.live : ArcTheme.danger)
                    .frame(width: 6, height: 6)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .disabled(busy || pending != nil || history != nil)
        .accessibilityIdentifier("new-task-device")
    }

    // MARK: - Bottom Composer Area (T3 Code Style)

    private var bottomComposerArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                Menu {
                    ForEach(CheckoutMode.allCases) { mode in
                        Button { checkoutMode = mode } label: {
                            HStack {
                                Label(mode.rawValue, systemImage: mode.symbolName)
                                if checkoutMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                        .disabled(mode == .worktree && gitInfo?.isGitRepo == false)
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
                .disabled(busy || pending != nil || projectPath.isEmpty)

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
                .disabled(busy || pending != nil || projectPath.isEmpty || gitInfo?.isGitRepo == false)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)

            HStack(alignment: .bottom, spacing: 8) {
                Button { choosingFolder = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 19, weight: .regular))
                        .foregroundStyle(ArcTheme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(busy || pending != nil || history != nil || deviceID.isEmpty || !store.isOnline(deviceID))
                .accessibilityLabel("选择项目文件夹")

                TextField("描述你想完成的任务…", text: $text, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(ArcTheme.ink)
                    .focused($messageFocused)
                    .lineLimit(1...5)
                    .padding(.vertical, 8)
                    .disabled(busy || pending != nil)
                    .accessibilityIdentifier("new-task-message")

                Button {
                    messageFocused = false
                    showModelPicker = true
                } label: {
                    HStack(spacing: 4) {
                        if modelLoading || loading {
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
                .disabled(busy || pending != nil)
                .accessibilityIdentifier("new-task-model")

                Button { Task { await start() } } label: {
                    Group {
                        if busy {
                            ProgressView()
                                .controlSize(.small)
                                .tint(ArcTheme.onPrimary)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(ready ? ArcTheme.onPrimary : ArcTheme.inkFaint)
                        }
                    }
                    .frame(width: 34, height: 34)
                    .background(ready || busy ? ArcTheme.primary : ArcTheme.line, in: Circle())
                    .frame(width: 36, height: 36)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!ready)
                .accessibilityLabel(pending == nil ? "开始" : "核对并继续")
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

    private func inlineNotice(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.caption).foregroundStyle(color).accessibilityHidden(true)
            Text(text).font(.caption).foregroundStyle(color)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Backend Logic (unchanged)

    private func deviceStatus(_ id: String) -> String {
        guard store.isOnline(id) else { return store.connectionLabel(for: id) }
        guard let count = busyCounts[id] else { return "在线 · 负载待查询" }
        return count == 0 ? "在线 · 无运行进程" : "在线 · \(count) 个运行进程"
    }

    private func loadDevice() async {
        capabilities = []; models = []; loading = false; modelLoading = false
        guard let bridge = store.bridge(for: deviceID) else { return }
        let captured = deviceID; loading = true
        defer { if captured == deviceID { loading = false } }
        do {
            let result = try await bridge.describeEnvironment()
            guard !Task.isCancelled, captured == deviceID else { return }
            capabilities = result.capabilities
            if pending == nil && !availableProviders.contains(where: { $0.agentId == provider }) {
                provider = availableProviders.first?.agentId ?? "codex"
            }
        } catch {
            if captured == deviceID { self.error = "无法读取此客户端，请确认在线后重新打开新任务。" }
        }
    }

    private func loadModels() async {
        models = []; modelError = nil; modelLoading = false
        guard capabilities.contains("managed_models_v1"), let bridge = store.bridge(for: deviceID) else { return }
        let captured = "\(deviceID)/\(provider)"; modelLoading = true
        defer { if captured == "\(deviceID)/\(provider)" { modelLoading = false } }
        do {
            let result = try await bridge.listAgentModels(agentId: provider)
            guard !Task.isCancelled, captured == "\(deviceID)/\(provider)" else { return }
            models = result
            if result.isEmpty { modelError = "未返回模型目录，可使用客户端默认模型。" }
        } catch {
            if captured == "\(deviceID)/\(provider)" { modelError = "模型目录暂不可用，可使用客户端默认模型。" }
        }
    }

    private func loadGitBranches() async {
        gitInfo = nil; branchError = nil; loadingBranches = false
        guard !projectPath.isEmpty, store.isOnline(deviceID), let bridge = store.bridge(for: deviceID) else { return }
        let captured = "\(deviceID)/\(projectPath)"
        loadingBranches = true
        defer { if captured == "\(deviceID)/\(projectPath)" { loadingBranches = false } }
        do {
            let info = try await bridge.listGitBranches(path: projectPath)
            guard !Task.isCancelled, captured == "\(deviceID)/\(projectPath)" else { return }
            gitInfo = info
            if !info.isGitRepo { checkoutMode = .current }
        } catch {
            if !Task.isCancelled, captured == "\(deviceID)/\(projectPath)" {
                if case BridgeError.Failed(let code, _) = error, code == "unsupported" {
                    branchError = "请更新 Mac 端 ArcLink 以读取 Git 分支。"
                } else {
                    branchError = "暂时无法读取 Git 分支。"
                }
            }
        }
    }

    private func start() async {
        guard ready, let body = outgoingText, let bridge = store.bridge(for: deviceID) else { return }
        busy = true; error = nil; canDiscard = false; operationStep = "准备任务"; messageFocused = false; defer { busy = false }
        do {
            var resolvedPath = projectPath
            var resolvedName = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
            if pending == nil, gitInfo?.isGitRepo == true {
                let needsSwitch = !selectedBranch.isEmpty && selectedBranch != gitInfo?.currentBranch
                if checkoutMode == .worktree || needsSwitch {
                    operationStep = checkoutMode == .worktree ? "创建 Worktree" : "切换分支"
                    let prepared = try await bridge.prepareGitWorkspace(
                        path: projectPath,
                        mode: checkoutMode == .worktree ? "worktree" : "current",
                        branch: selectedBranch.isEmpty ? nil : selectedBranch
                    )
                    resolvedPath = prepared.path
                    if prepared.isWorktree, let b = prepared.branch {
                        resolvedName = "\(resolvedName) (\(b.replacingOccurrences(of: "arclink/", with: "")))"
                    }
                }
            }
            var intent = pending ?? PendingManagedTask(deviceID: deviceID, projectPath: resolvedPath, projectName: resolvedName, provider: provider, model: selectedModel.isEmpty ? nil : selectedModel, text: body)
            if pending == nil { intent.draftText = text; intent.history = history }
            try intent.save(); pending = intent
            if intent.projectID == nil {
                operationStep = "创建项目"
                let project = try await bridge.createManagedProject(commandId: intent.projectCommand, path: intent.projectPath, name: intent.projectName)
                intent.projectID = project.id; try intent.save(); pending = intent
            }
            if intent.threadID == nil {
                operationStep = "创建对话"
                let thread = try await bridge.createManagedThread(commandId: intent.threadCommand, projectId: intent.projectID!, providerId: intent.provider, title: String((intent.draftText ?? intent.text).prefix(40)))
                intent.threadID = thread.id; try intent.save(); pending = intent
            }
            if !intent.modelApplied {
                operationStep = "设置模型"
                if let selected = intent.model {
                    _ = try await bridge.setManagedThreadModel(commandId: intent.modelCommand, threadId: intent.threadID!, model: selected, expectedRevision: nil)
                }
                intent.modelApplied = true; try intent.save(); pending = intent
            }
            operationStep = "发送任务"
            _ = try await bridge.sendManagedThread(commandId: intent.sendCommand, threadId: intent.threadID!, clientMessageId: intent.clientMessage, text: intent.text, expectedRevision: nil)
            try PendingManagedTask.clear()
            pending = nil
            await store.refreshManagedCatalog(deviceID: intent.deviceID)
            onStart(intent.deviceID, intent.threadID!)
            dismiss()
        } catch {
            if case BridgeError.Failed(let code, let message) = error {
                canDiscard = ["invalid_params", "unsupported", "unauthorized", "forbidden", "not_found", "directory_unavailable", "revision_conflict", "conflict", "busy", "resource_limit", "git_error"].contains(code)
                let hint: String = {
                    if code == "unauthorized", message.localizedCaseInsensitiveContains("project") {
                        return "当前设备尚未获得该项目访问权限，请在 Mac 桌面端「共享给设备」中点击「授予访问」。"
                    }
                    return message.isEmpty ? "\(operationStep)被客户端拒绝（\(code)），尚未开始任务，可修改后重试。" : "\(operationStep)失败（\(code)）：\(message)"
                }()
                if canDiscard && pending?.projectID == nil && pending?.threadID == nil {
                    try? PendingManagedTask.clear()
                    pending = nil
                    canDiscard = false
                    self.error = hint
                } else {
                    self.error = canDiscard
                        ? hint
                        : "\(operationStep)结果尚未确认（\(code)）。Mac 可能已经执行，请先刷新项目或进入对话核对，再使用同一按钮重试；不会重新创建任务。"
                }
            } else {
                self.error = "\(operationStep)未完成，任务记录已保留。请检查连接或本机存储后重试。"
            }
        }
    }

    private func discardRejectedTask() {
        guard canDiscard, !busy else { return }
        do { try PendingManagedTask.clear(); pending = nil; canDiscard = false; error = nil }
        catch { self.error = "无法清除任务记录，请检查存储后重试。" }
    }
}

// MARK: - Spacious Model Picker Sheet for NewManagedTaskSheet

private struct ManagedNewTaskModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var provider: String
    @Binding var selectedModel: String
    var availableProviders: [AgentKind]
    var models: [MacModel]
    var modelsSupported: Bool
    var loading: Bool
    var modelError: String?
    @State private var searchText = ""

    private var activeAgent: AgentKind { provider == "claude" ? .claude : .codex }

    private var filteredModels: [MacModel] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return models }
        return models.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Agent Switcher
                HStack(spacing: 2) {
                    ForEach(AgentKind.allCases) { agent in
                        let enabled = availableProviders.contains(agent)
                        let selected = provider == agent.agentId
                        Button {
                            guard enabled else { return }
                            provider = agent.agentId
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
                            .opacity(enabled ? 1 : 0.4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                    }
                }
                .padding(3)
                .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .accessibilityIdentifier("new-task-agent")

                if models.count >= 6 {
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
                        modelRow(title: "跟随客户端默认模型", subtitle: "使用 \(activeAgent.shortName) 在 Mac 上的默认配置", isSelected: selectedModel.isEmpty) {
                            selectedModel = ""
                            dismiss()
                        }
                        if loading {
                            ArcDivider(inset: 16)
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取模型目录…").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 48)
                        } else if let modelError, filteredModels.isEmpty {
                            ArcDivider(inset: 16)
                            Text(modelError).font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 12)
                        } else {
                            ForEach(filteredModels, id: \.id) { model in
                                ArcDivider(inset: 16)
                                modelRow(title: model.name, subtitle: model.id != model.name ? model.id : nil, isSelected: selectedModel == model.id) {
                                    selectedModel = model.id
                                    dismiss()
                                }
                            }
                        }
                    }
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
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

struct RealBranchPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedBranch: String
    var gitInfo: MacGitInfo?
    var loading: Bool
    var error: String?
    @State private var searchText = ""

    private var filteredBranches: [String] {
        let all = gitInfo?.branches ?? []
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if (gitInfo?.branches.count ?? 0) >= 6 {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.footnote).foregroundStyle(ArcTheme.inkFaint)
                        TextField("搜索分支…", text: $searchText)
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
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }

                ScrollView {
                    VStack(spacing: 0) {
                        if loading {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在读取 Mac 上的 Git 分支…").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 16).frame(minHeight: 54)
                        } else if let error {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle").font(.footnote).foregroundStyle(ArcTheme.warning)
                                Text(error).font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        } else if gitInfo?.isGitRepo == false {
                            Text("所选目录不是 Git 仓库。").font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        } else if filteredBranches.isEmpty {
                            Text(searchText.isEmpty ? "当前仓库没有可用分支。" : "没有匹配的分支。")
                                .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        } else {
                            ForEach(filteredBranches, id: \.self) { branch in
                                if branch != filteredBranches.first { ArcDivider(inset: 16) }
                                let isCurrent = branch == gitInfo?.currentBranch
                                let isSelected = selectedBranch.isEmpty ? isCurrent : selectedBranch == branch
                                Button {
                                    selectedBranch = isCurrent ? "" : branch
                                    dismiss()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.triangle.branch")
                                            .font(.footnote)
                                            .foregroundStyle(isSelected ? ArcTheme.primary : ArcTheme.inkMuted)
                                        Text(branch)
                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                            .foregroundStyle(ArcTheme.ink)
                                            .lineLimit(1)
                                        if isCurrent {
                                            Text("当前")
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(ArcTheme.live)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(ArcTheme.liveSoft, in: Capsule())
                                        }
                                        Spacer(minLength: 8)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .font(.footnote.weight(.bold))
                                                .foregroundStyle(ArcTheme.primary)
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .frame(minHeight: 48)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(ArcTheme.line.opacity(0.75), lineWidth: 0.75))
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
            }
            .background(ArcTheme.bg)
            .navigationTitle("选择分支")
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
}

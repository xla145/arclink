import PhotosUI
import SwiftUI

struct NewConversationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var projectID: String
    var onStart: (String, String) -> Void

    @State private var policy: SessionExecutionPolicy = .workspace
    @State private var selectedModel = ""
    @State private var models: [MacModel] = []
    @State private var modelHint: String?
    @State private var loadingModels = false
    @State private var text = ""
    @State private var images: [Data] = []
    @State private var picked: [PhotosPickerItem] = []
    @State private var imageEpoch = UUID()
    @State private var loadingImages = false
    @State private var pendingPastes = 0
    @State private var submitting = false
    @State private var error: String?
    @State private var pendingSessionID: String?
    @FocusState private var messageFocused: Bool

    private var projects: [ProjectItem] { store.projects(for: store.selectedAgent, query: "") }
    private var project: ProjectItem? { projects.first { $0.id == projectID } }
    private var canStart: Bool {
        project != nil && store.canSend && !submitting && !loadingImages
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
            && (!store.usesRemoteChat || project?.agent == .codex)
    }

    var body: some View {
        NavigationStack {
            // Content first, settings below, Start in the top-right corner.
            Form {
                Section {
                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $text)
                            .frame(minHeight: 120)
                            .focused($messageFocused)
                            .accessibilityLabel("首条消息")
                            .accessibilityIdentifier("new-chat-message")
                        if text.isEmpty {
                            Text("描述你想完成的任务…")
                                .foregroundStyle(ArcTheme.inkMuted)
                                .padding(.top, 8).padding(.leading, 5)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 10) {
                                ForEach(Array(images.enumerated()), id: \.offset) { index, data in
                                    if let image = UIImage(data: data) {
                                        VStack(spacing: 4) {
                                            Image(uiImage: image).resizable().scaledToFill()
                                                .frame(width: 80, height: 80).clipped()
                                                .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.sm, style: .continuous))
                                            Button("移除", role: .destructive) { images.remove(at: index) }
                                                .font(.caption).accessibilityLabel("移除图片 \(index + 1)")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    HStack {
                        PhotosPicker(selection: $picked, maxSelectionCount: max(1, ChatAttachment.maximumCount - images.count), matching: .images) {
                            Label("添加图片", systemImage: "photo.badge.plus")
                        }
                        .disabled(loadingImages || images.count >= ChatAttachment.maximumCount)
                        Spacer()
                        PasteButton(supportedContentTypes: [.image]) { providers in
                            let epoch = imageEpoch
                            let selected = Array(providers.prefix(max(0, ChatAttachment.maximumCount - images.count)))
                            pendingPastes = selected.count
                            loadingImages = !selected.isEmpty
                            for provider in selected {
                                _ = provider.loadObject(ofClass: UIImage.self) { object, _ in
                                    let data = (object as? UIImage)?.jpegData(compressionQuality: 0.85)
                                    Task { @MainActor in
                                        guard epoch == imageEpoch else { return }
                                        pendingPastes -= 1
                                        loadingImages = pendingPastes > 0
                                        if let data { appendImage(data) }
                                        else { error = "无法读取粘贴的图片，请重试。" }
                                    }
                                }
                            }
                        }
                        .labelStyle(.iconOnly).accessibilityLabel("粘贴图片")
                        .disabled(loadingImages || images.count >= ChatAttachment.maximumCount)
                    }
                    if loadingImages { ProgressView("正在读取图片…") }
                }
                .listRowBackground(ArcTheme.surface)
                .disabled(submitting)

                Section {
                    if projects.isEmpty {
                        Text("请先添加或导入一个项目。").foregroundStyle(ArcTheme.inkMuted)
                    } else {
                        Picker("项目", selection: $projectID) {
                            ForEach(projects) { Text($0.name).tag($0.id) }
                        }
                        .accessibilityIdentifier("current-project-picker")
                        if let project {
                            Text(project.path).font(.footnote.monospaced()).foregroundStyle(ArcTheme.inkMuted)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    Picker("模型", selection: $selectedModel) {
                        Text("跟随 Mac 设置").tag("")
                        ForEach(models, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("new-chat-model")
                    Picker("权限", selection: $policy) {
                        ForEach(SessionExecutionPolicy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .accessibilityIdentifier("new-chat-permission")
                    if loadingModels { ProgressView("正在读取模型…").font(.caption) }
                    if let modelHint { Text(modelHint).font(.caption).foregroundStyle(ArcTheme.inkMuted) }
                } header: {
                    Text("设置")
                }
                .listRowBackground(ArcTheme.surface)
                .disabled(submitting || pendingSessionID.map { !store.canConfigureUnsentSession($0) } == true)

                if error != nil || !store.canSend || (store.usesRemoteChat && project?.agent != .codex) {
                    Section {
                        if let error { Text(error).foregroundStyle(ArcTheme.danger).accessibilityIdentifier("new-chat-error") }
                        if !store.canSend { Text("当前手机权限不能新建对话。").foregroundStyle(ArcTheme.warning) }
                        if store.usesRemoteChat && project?.agent != .codex {
                            Text("远程图文对话目前支持 Codex，请选择 Codex 项目。").foregroundStyle(ArcTheme.inkMuted)
                        }
                    }
                    .listRowBackground(ArcTheme.surface)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ArcTheme.bg)
            .navigationTitle("新对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(submitting) }
                ToolbarItem(placement: .confirmationAction) {
                    if submitting {
                        ProgressView().accessibilityLabel("正在开始")
                    } else {
                        Button("开始", action: start)
                            .fontWeight(.semibold)
                            .disabled(!canStart)
                            .accessibilityIdentifier("start-conversation")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { messageFocused = false }
                }
            }

        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(submitting)
        .task(id: store.online) {
            if project == nil { projectID = projects.first?.id ?? "" }
            guard let bridge = store.macBridge else { return }
            let device = store.selectedDeviceID
            loadingModels = true
            defer { loadingModels = false }
            do {
                let result = try await bridge.listAgentModels(agentId: store.selectedAgent.agentId)
                guard !Task.isCancelled, device == store.selectedDeviceID else { return }
                models = result
                modelHint = result.isEmpty ? "Mac 暂无可选模型，将自动使用 Mac 默认模型。" : nil
            } catch {
                if !Task.isCancelled, device == store.selectedDeviceID {
                    modelHint = "暂时无法读取模型列表，将使用 Mac 默认模型；重新连接后会自动获取。"
                }
            }
        }
        .onChange(of: picked) { _, items in loadImages(items) }
        .onChange(of: store.selectedDeviceID) { _, _ in dismiss() }
        .onDisappear { imageEpoch = UUID() }
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
            else { error = "对话未能开启，内容已保留。请确认 Mac 在线、模型可用后重试。" }
        }
    }
}

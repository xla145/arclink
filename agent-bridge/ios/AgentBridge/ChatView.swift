import PhotosUI
import SwiftUI

struct ChatView: View {
    @Environment(AppStore.self) private var store
    var projectId: String
    var sessionId: String?
    @Binding var path: NavigationPath

    @State private var liveId: String?
    @State private var draft = ""
    @State private var picked: PhotosPickerItem?
    @State private var attachment: Data?
    @State private var expandedImage: ImagePreview?
    @State private var more = false
    @FocusState private var composing: Bool

    private var resolvedId: String? { liveId ?? sessionId }
    private var title: String {
        store.sessions.first { $0.id == resolvedId }?.title ?? "新会话"
    }
    private var thread: [ChatMessage] {
        store.messages.filter { $0.sessionId == resolvedId }
    }
    private var requests: [ApprovalItem] {
        store.approvals.filter { $0.sessionId == resolvedId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if thread.isEmpty {
                        ContentUnavailableView("新会话", systemImage: "bubble.left.and.bubble.right", description: Text("写下任务，也可以附一张截图。\n发出第一条消息后会创建会话。"))
                            .padding(.top, 32)
                        Button("查看项目结构") { draft = "查看项目结构"; composing = true }
                            .buttonStyle(.bordered)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(thread) { message in bubble(message) }
                    ForEach(requests) { request in
                        Button { composing = false; path.append(Route.approval(request.id)) } label: {
                            Label(request.pending ? "待审批 · \(request.title)" : "\(request.approved == true ? "已批准" : "已拒绝") · \(request.title)", systemImage: request.pending ? "clock" : "checkmark.circle")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain).foregroundStyle(.orange)
                        .accessibilityIdentifier("approval-event-\(request.id)")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: composing) { _, active in
                if active {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(Route.terminal(resolvedId ?? "")) } label: { Image(systemName: "terminal") }
                    .accessibilityLabel("终端")
                    .disabled(resolvedId == nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { more = true } label: { Image(systemName: "ellipsis") }
                    .accessibilityLabel("会话操作")
                    .disabled(resolvedId == nil)
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { composing = false }
            }
        }
        .confirmationDialog("会话", isPresented: $more, titleVisibility: .hidden) {
            if let id = resolvedId {
                Button("取消当前任务") { store.cancelPending(sessionId: id) }
                Button("停止会话") { store.stopSession(id: id) }
                Button("删除会话记录", role: .destructive) {
                    store.deleteSession(id: id)
                    path.removeLast()
                }
            }
        }
        .sheet(item: $expandedImage) { preview in
            NavigationStack {
                Image(uiImage: preview.image).resizable().scaledToFit().padding()
                    .navigationTitle("图片预览")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("完成") { expandedImage = nil } }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 0) {
            if let attachment, let image = UIImage(data: attachment) {
                HStack {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: 54, height: 36)
                    Text("已选 1 张图片").font(.caption)
                    Spacer()
                    Button("移除") { self.attachment = nil }
                }
                .padding(.horizontal, 16).padding(.top, 8)
            }
            if !store.canSend {
                Text(store.permission == "仅查看" ? "当前权限只能查看，不能发送任务。" : "当前权限可以审批，但不能发送新任务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picked, matching: .images) {
                    Image(systemName: "photo").frame(width: 44, height: 44)
                }
                .accessibilityLabel("从相册添加图片")
                .onChange(of: picked) { _, item in
                    guard let item else { return }
                    Task {
                        attachment = try? await item.loadTransferable(type: Data.self)
                    }
                }
                TextField("描述任务", text: $draft, axis: .vertical)
                    .focused($composing)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("composer")
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("发送")
                .disabled(!store.canSend || (draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil))
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
        }
        .background(.bar)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 36) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 5) {
                Text(message.isUser ? "你" : (store.project(projectId)?.agent.rawValue ?? "Agent"))
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .background(message.isUser ? Color.accentColor : Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                if let data = message.imageData, let image = UIImage(data: data) {
                    Button { expandedImage = ImagePreview(image: image) } label: {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .accessibilityLabel("查看图片")
                }
                Text(message.time).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
            if !message.isUser { Spacer(minLength: 36) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard store.canSend, !text.isEmpty || attachment != nil else { return }
        let id = resolvedId ?? store.createSession(projectId: projectId, title: text.isEmpty ? "图片会话" : String(text.prefix(18)))
        liveId = id
        store.send(sessionId: id, text: text.isEmpty ? "请查看这张截图" : text, image: attachment)
        draft = ""
        attachment = nil
        composing = false
    }
}

private struct ImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
}

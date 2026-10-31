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
    @State private var more = false

    private var resolvedId: String? { liveId ?? sessionId }

    private var title: String {
        if let id = resolvedId, let session = store.sessions.first(where: { $0.id == id }) {
            return session.title
        }
        return "新会话"
    }

    private var thread: [ChatMessage] {
        guard let id = resolvedId else { return [] }
        return store.messages.filter { $0.sessionId == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if thread.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "bubble.left.and.bubble.right")
                                .font(.title)
                                .foregroundStyle(.secondary)
                            Text("新会话")
                                .font(.headline)
                            Text("写下任务，也可以附一张截图。发出第一条消息后会创建会话。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                        .padding(.horizontal, 24)
                    }
                    ForEach(thread) { message in
                        bubble(message)
                    }
                    if resolvedId == "s1" || (resolvedId != nil && store.approvals.contains { $0.pending && resolvedId == "s1" }) {
                        Button {
                            path.append(Route.approvals)
                        } label: {
                            Label("待审批 · 写入文件 · 点此处理", systemImage: "clock")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.orange.opacity(0.15), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(16)
            }
            if attachment != nil {
                HStack {
                    Image(systemName: "photo")
                    Text("已选 1 张图片")
                    Spacer()
                    Button("移除") { attachment = nil }
                }
                .font(.footnote)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground))
            }
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $picked, matching: .images) {
                    Image(systemName: "photo")
                        .frame(width: 36, height: 36)
                        .background(Color(.secondarySystemBackground), in: Circle())
                }
                TextField("描述任务", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                Button {
                    send()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 32))
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachment == nil)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { path.append(Route.terminal) } label: { Image(systemName: "terminal") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { more = true } label: { Image(systemName: "ellipsis") }
            }
        }
        .confirmationDialog("会话", isPresented: $more, titleVisibility: .hidden) {
            Button("取消当前任务") { store.show("已请求取消任务") }
            Button("停止会话") { store.show("已停止会话") }
            Button("删除会话记录", role: .destructive) { store.show("已删除会话记录") }
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                attachment = try? await item.loadTransferable(type: Data.self)
            }
        }
    }

    private func bubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .background(
                        message.isUser ? Color.accentColor : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                if message.imageData != nil {
                    Text("图片")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(message.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachment != nil else { return }
        let id: String
        if let existing = resolvedId {
            id = existing
        } else {
            let heading = text.isEmpty ? "图片会话" : String(text.prefix(18))
            id = store.createSession(projectId: projectId, title: heading)
            liveId = id
        }
        store.send(sessionId: id, text: text.isEmpty ? "（图片）" : text, image: attachment)
        draft = ""
        attachment = nil
        picked = nil
    }
}

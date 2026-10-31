import SwiftUI

struct ApprovalListView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath

    var body: some View {
        List {
            Section("待处理 · \(store.pendingCount)") {
                ForEach(store.approvals.filter(\.pending)) { item in row(item) }
                if store.pendingCount == 0 {
                    Label("没有待处理的审批", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                }
            }
            let history = store.approvals.filter { !$0.pending }
            if !history.isEmpty {
                Section("已处理") { ForEach(history) { item in row(item) } }
            }
        }
        .navigationTitle("审批")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ item: ApprovalItem) -> some View {
        Button { path.append(Route.approval(item.id)) } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Claude Code").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Pill(text: item.pending ? "待审批" : (item.approved == true ? "已批准" : "已拒绝"), tint: item.pending ? .orange : (item.approved == true ? .green : .red))
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                Text(item.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(item.detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
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

    var body: some View {
        ScrollView {
            if let item {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkle").font(.title2).foregroundStyle(.purple)
                            .frame(width: 44, height: 44).background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Claude Code").font(.headline)
                            Text("my-app · 会话 #\(item.sessionId)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.kind).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(item.title).font(.title3.bold())
                        Text(item.detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text(item.id == "a1" ? "变更预览" : "命令预览").font(.headline)
                    if item.kind.contains("写入") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("目标 \(item.target)").foregroundStyle(.secondary)
                            Text(item.detail)
                        }
                        .font(.footnote.monospaced())
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("$ \(item.target)").font(.footnote.monospaced()).foregroundStyle(.purple)
                            Text(item.detail)
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    LabeledContent("审批 ID", value: item.id)
                    LabeledContent("状态", value: item.pending ? "待处理" : (item.approved == true ? "已批准" : "已拒绝"))
                }
                .padding(20)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("审批详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let item, item.pending, store.canApprove {
                HStack(spacing: 12) {
                    Button { resolve(false) } label: { Text("拒绝").frame(maxWidth: .infinity, minHeight: 28) }
                        .buttonStyle(.bordered).tint(.red)
                    Button { resolve(true) } label: { Text(item.kind.contains("写入") ? "批准写入" : "批准执行").frame(maxWidth: .infinity, minHeight: 28) }
                        .buttonStyle(.borderedProminent).tint(.green)
                }
                .padding(16).background(.bar)
            }
        }
    }

    private func resolve(_ approved: Bool) {
        store.resolve(id, approved: approved)
        dismiss()
    }
}

struct TerminalView: View {
    @Environment(AppStore.self) private var store
    var sessionId: String

    private var session: SessionItem? { store.sessions.first { $0.id == sessionId } }
    private var lines: [String] {
        var output: [String] = []
        if let session, let project = store.project(session.projectId) {
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
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .foregroundStyle(line.hasPrefix("#") ? Color.orange : Color(white: 0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(.footnote, design: .monospaced))
            .padding(16)
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.09))
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.09, green: 0.11, blue: 0.13), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

import SwiftUI

struct ApprovalListView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let pending = store.approvals.filter(\.pending)
                Text("待处理 · \(pending.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(pending) { item in
                    Button {
                        path.append(Route.approval(item.id))
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Claude Code").font(.subheadline.weight(.semibold))
                                Spacer()
                                Pill(text: "1:48", tint: .orange)
                            }
                            Text(item.kind)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(item.title).font(.body.weight(.medium))
                            Text(item.target)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("拒绝") { store.resolve(item.id, approved: false) }
                                    .buttonStyle(.bordered)
                                Button("批准") { store.resolve(item.id, approved: true) }
                                    .buttonStyle(.borderedProminent)
                                    .tint(.green)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if pending.isEmpty {
                    Text("没有待处理的审批")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(32)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("审批")
        .navigationBarTitleDisplayMode(.inline)
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
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.kind)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(item.title).font(.title3.bold())
                    Text(item.detail).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("@@ -15,8 +15,12 @@").foregroundStyle(.secondary)
                        Text("- import { fetchData } from '../api';").foregroundStyle(.red)
                        Text("+ import { useQuery } from '../hooks/useQuery';").foregroundStyle(.green)
                        Text("+ import { StatCard } from './StatCard';").foregroundStyle(.green)
                    }
                    .font(.caption.monospaced())
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    LabeledContent("审批 ID", value: item.id)
                    LabeledContent("状态", value: item.pending ? "待处理" : (item.approved == true ? "已批准" : "已拒绝"))
                }
                .padding(16)
            }
        }
        .navigationTitle("审批详情")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            if let item, item.pending {
                HStack {
                    Button("拒绝") {
                        store.resolve(item.id, approved: false)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    Button("批准写入") {
                        store.resolve(item.id, approved: true)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(.bar)
            }
        }
    }
}

struct TerminalView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("user ~/project $ claude --print \"重构 Dashboard\"")
                    .foregroundStyle(Color(red: 0.49, green: 0.83, blue: 1))
                Text("I'll help you refactor the Dashboard component.")
                    .foregroundStyle(Color(white: 0.75))
                Text("Tool: Read(\"src/components/Dashboard.tsx\")")
                    .foregroundStyle(Color(red: 0.82, green: 0.66, blue: 1))
                Text("Tool: Write(\"src/components/Dashboard.tsx\")")
                    .foregroundStyle(Color(red: 0.82, green: 0.66, blue: 1))
                Text("等待审批 · 写入文件")
                    .foregroundStyle(.orange)
            }
            .font(.system(.footnote, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(Color(red: 0.05, green: 0.07, blue: 0.09))
        .navigationTitle("终端")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color(red: 0.09, green: 0.11, blue: 0.13), for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }
}

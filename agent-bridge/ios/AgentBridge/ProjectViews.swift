import SwiftUI

struct ProjectDetailView: View {
    @Environment(AppStore.self) private var store
    var projectId: String
    @Binding var path: NavigationPath

    private var project: ProjectItem? { store.project(projectId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let project {
                    HStack(spacing: 12) {
                        Image(systemName: "folder.fill")
                            .frame(width: 40, height: 40)
                            .background(project.agent.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .foregroundStyle(project.agent.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.agent.rawValue).font(.headline)
                            Text(project.path)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.pendingCount(projectId: projectId) > 0 {
                            Pill(text: "\(store.pendingCount(projectId: projectId)) 待审批", tint: .orange)
                        }
                    }

                    let rows = store.sessions(for: projectId)
                    Text("会话 · \(rows.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        if rows.isEmpty {
                            ContentUnavailableView("还没有会话", systemImage: "bubble.left.and.bubble.right", description: Text("点击右上角 + 开始一个任务"))
                        }
                        ForEach(rows) { session in
                            Button {
                                path.append(Route.session(projectId: projectId, sessionId: session.id))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: icon(session.status))
                                        .frame(width: 32, height: 32)
                                        .background(session.status.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                        .foregroundStyle(session.status.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(session.title).font(.body.weight(.medium))
                                        Text(session.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Pill(text: session.status.rawValue, tint: session.status.tint)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("session-\(session.id)")
                            if session.id != rows.last?.id { Divider().padding(.leading, 58) }
                        }
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(project?.name ?? "项目")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(Route.session(projectId: projectId, sessionId: nil))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建会话")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(Route.addProject(editing: projectId))
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("项目设置")
            }
        }
    }

    private func icon(_ status: SessionStatus) -> String {
        switch status {
        case .waiting: "exclamationmark"
        case .running: "play.fill"
        case .done: "checkmark"
        case .cancelled: "minus"
        }
    }
}

struct AddProjectView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var editingId: String?

    @State private var agent: AgentKind = .claude
    @State private var pathText = "~/projects/my-app"
    @State private var name = "my-app"
    @State private var confirmDelete = false

    private var editing: Bool { editingId != nil }

    var body: some View {
        Form {
            Section("选择 Agent") {
                ForEach(AgentKind.allCases) { kind in
                    Button {
                        if kind.installed { agent = kind }
                    } label: {
                        HStack {
                            Text(kind.rawValue)
                            if !kind.installed {
                                Text("未安装").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if agent == kind && kind.installed {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                            }
                        }
                    }
                    .disabled(!kind.installed)
                }
            }
            Section("项目地址") {
                TextField("路径", text: $pathText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            Section("项目名称") {
                TextField("名称", text: $name)
            }
            Section {
                Button(editing ? "保存修改" : "添加项目") {
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    if !editing {
                        store.addProject(name: trimmed, path: pathText, agent: agent)
                    } else if let editingId {
                        store.updateProject(id: editingId, name: trimmed, path: pathText, agent: agent)
                    }
                    dismiss()
                }
            }
            if editing {
                Section {
                    Button("删除项目", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .navigationTitle(editing ? "项目设置" : "添加项目")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if let editingId, let project = store.project(editingId) {
                agent = project.agent
                pathText = project.path
                name = project.name
            } else {
                agent = store.selectedAgent.installed ? store.selectedAgent : .claude
            }
        }
        .confirmationDialog("删除这个项目？会话记录会一起去掉。", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除项目", role: .destructive) {
                if let editingId {
                    store.deleteProject(id: editingId)
                }
                dismiss()
            }
        }
    }
}

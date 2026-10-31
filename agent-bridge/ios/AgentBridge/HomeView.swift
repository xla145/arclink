import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if store.pendingCount > 0 {
                    Button {
                        path.append(Route.approvals)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.circle")
                            Text("\(store.pendingCount) 个待审批")
                                .fontWeight(.medium)
                            Spacer()
                            Text("1:48").monospacedDigit()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .padding(12)
                        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索项目", text: $query)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }

                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(AgentKind.allCases) { agent in
                                Button {
                                    store.selectedAgent = agent
                                } label: {
                                    HStack(spacing: 6) {
                                        Circle().fill(agent.tint).frame(width: 8, height: 8)
                                        Text(agent.rawValue)
                                    }
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .foregroundStyle(store.selectedAgent == agent ? Color(.systemBackground) : .primary)
                                    .background(
                                        store.selectedAgent == agent ? Color.primary : Color(.secondarySystemBackground),
                                        in: Capsule()
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button {
                        path.append(Route.addProject(editing: nil))
                    } label: {
                        Image(systemName: "plus")
                            .font(.body.weight(.semibold))
                            .frame(width: 32, height: 32)
                            .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [3])))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("添加项目")
                }

                if store.selectedAgent.installed {
                    let items = store.projects(for: store.selectedAgent, query: query)
                    VStack(spacing: 0) {
                        if items.isEmpty {
                            Text(query.isEmpty ? "还没有项目" : "没有匹配的项目")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(24)
                        }
                        ForEach(items) { project in
                            Button {
                                path.append(Route.project(project.id))
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder")
                                        .frame(width: 36, height: 36)
                                        .background(store.selectedAgent.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                        .foregroundStyle(store.selectedAgent.tint)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).font(.body.weight(.medium))
                                        Text(projectSubtitle(project))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    if project.pendingApprovals > 0 {
                                        Pill(text: "待审批", tint: .orange)
                                    }
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                            }
                            .buttonStyle(.plain)
                            if project.id != items.last?.id {
                                Divider().padding(.leading, 62)
                            }
                        }
                    }
                    .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text("本机未安装 \(store.selectedAgent.rawValue)")
                        Text("安装后将自动出现在这里")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(32)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(store.hostName)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: Route.settings) {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("更多")
            }
            ToolbarItem(placement: .principal) {
                EmptyView()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(store.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(store.online ? "在线 · 直连" : "离线")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 4)
            .background(.bar)
        }
    }

    private func projectSubtitle(_ project: ProjectItem) -> String {
        let sessions = project.sessionCount == 0 ? "无活跃会话" : "\(project.sessionCount) 个会话"
        return "\(project.path) · \(sessions)"
    }
}

import SwiftUI

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var scope: ProjectScope = .recent
    @State private var showingSearch = false
    @State private var choosingConversation = false
    @State private var chosenProjectID = ""

    private enum ProjectScope: String, CaseIterable {
        case recent = "最近"
        case all = "所有项目"
    }

    private var currentProject: ProjectItem? { store.currentProject(for: store.selectedAgent) }
    private var chosenProject: ProjectItem? {
        store.projects.first { $0.id == chosenProjectID && $0.agent == store.selectedAgent }
    }

    var body: some View {
        VStack(spacing: 0) {
            agentSelector
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if store.selectedAgent.installed {
                        if let project = currentProject {
                            currentProjectCard(project)
                        }
                        projectListHeader
                        if showingSearch { searchField }
                        projectList
                    } else {
                        ContentUnavailableView("未安装 \(store.selectedAgent.rawValue)", systemImage: store.selectedAgent.symbolName, description: Text("在 Mac 上安装后即可使用，也可以切换到其他 Agent。"))
                            .padding(.top, 24)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 96)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottomTrailing) {
            if store.selectedAgent.installed {
                Button {
                    chosenProjectID = currentProject?.id ?? ""
                    choosingConversation = true
                } label: {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(Color(.systemBackground))
                        .frame(width: 56, height: 56)
                        .background(Color.primary, in: Circle())
                        .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("选择对话")
                .accessibilityIdentifier("chat-fab")
                .padding(.trailing, 20)
                .padding(.bottom, 16)
            }
        }
        .navigationTitle("ArcLink")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: Route.devices) {
                    HStack(spacing: 5) {
                        Circle().fill(store.online ? Color.green : Color.secondary)
                            .frame(width: 5, height: 5)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(store.hostName).lineLimit(1)
                            Text(store.connectionStateLabel).font(.system(size: 9)).lineLimit(1)
                        }
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 112)
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(store.hostName) · \(store.connectionStateLabel)")
                }
                .accessibilityHint("切换设备")
                .accessibilityIdentifier("device-switcher")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink(value: Route.approvals) {
                    Image(systemName: "bell")
                        .overlay(alignment: .topTrailing) {
                            if store.pendingCount > 0 {
                                Text(store.pendingCount > 99 ? "99+" : "\(store.pendingCount)")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                                    .background(Color.orange, in: Capsule())
                                    .offset(x: 9, y: -8)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .accessibilityLabel("审批，\(store.pendingCount) 项待处理")
                .accessibilityIdentifier("approval-entry")
                NavigationLink(value: Route.settings) { Image(systemName: "gearshape") }
                    .accessibilityLabel("设置")
                    .accessibilityIdentifier("settings-entry")
            }
        }
        .sheet(isPresented: $choosingConversation) { conversationChooser }
        .onChange(of: store.selectedAgent) { _, _ in
            query = ""
            choosingConversation = false
        }
        .onChange(of: store.selectedDeviceID) { _, _ in choosingConversation = false }
    }

    private var agentSelector: some View {
        HStack(spacing: 6) {
            ForEach(AgentKind.allCases) { agent in
                Button { store.selectedAgent = agent } label: {
                    HStack(spacing: 6) {
                        Image(systemName: agent.symbolName)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(agent.installed ? agent.tint : Color.secondary)
                        Text(agent.shortName)
                            .font(.caption.weight(store.selectedAgent == agent ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(agent.installed ? Color.primary : Color.secondary)
                    .background(store.selectedAgent == agent ? Color(.secondarySystemGroupedBackground) : .clear, in: RoundedRectangle(cornerRadius: 9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(agent.rawValue)
                .accessibilityValue(agent.installed ? (store.selectedAgent == agent ? "已选择" : "") : "未安装")
                .accessibilityAddTraits(store.selectedAgent == agent ? [.isSelected] : [])
            }
        }
    }

    private func currentProjectCard(_ project: ProjectItem) -> some View {
        let latest = store.sessions(for: project.id).max { $0.createdAt < $1.createdAt }
        return VStack(spacing: 0) {
            Button { openProject(project) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.subheadline)
                        .foregroundStyle(project.agent.tint)
                        .frame(width: 32, height: 32)
                        .background(project.agent.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("当前项目").font(.system(size: 9)).foregroundStyle(.secondary)
                        }
                        Text(project.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Text("\(store.sessions(for: project.id).count) 个对话").font(.caption2).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(12)
                .foregroundStyle(.primary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Divider().padding(.horizontal, 12)
            Button {
                store.selectProject(project.id)
                path.append(Route.session(projectId: project.id, sessionId: latest?.id))
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: latest == nil ? "plus.bubble" : "bubble.left")
                    Text(latest?.title ?? "在这个项目中开始新对话").lineLimit(1)
                    Spacer(minLength: 4)
                    Text(latest == nil ? "开始" : "继续")
                    Image(systemName: "arrow.right")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(latest == nil && !store.canSend)
            .accessibilityIdentifier("continue-chat")
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
    }

    private var projectListHeader: some View {
        HStack(spacing: 10) {
            Picker("项目范围", selection: $scope) {
                ForEach(ProjectScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Button {
                showingSearch.toggle()
                if !showingSearch { query = "" }
            } label: { Image(systemName: "magnifyingglass").frame(width: 36, height: 36) }
                .accessibilityLabel("搜索项目")
            Button { path.append(Route.addProject(editing: nil)) } label: {
                Image(systemName: "plus").frame(width: 36, height: 36)
            }
            .accessibilityLabel("添加项目")
        }
        .foregroundStyle(.secondary)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜索项目", text: $query)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("清除项目搜索")
            }
        }
        .font(.subheadline)
        .padding(10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
    }

    private var projectList: some View {
        let items = scopedProjects()
        return VStack(spacing: 0) {
            if items.isEmpty {
                VStack(spacing: 10) {
                    Text(query.isEmpty ? "还没有项目" : "没有匹配的项目").foregroundStyle(.secondary)
                    if query.isEmpty {
                        Button("添加或导入项目") { path.append(Route.addProject(editing: nil)) }
                    }
                }
                .font(.subheadline).frame(maxWidth: .infinity).padding(24)
            }
            ForEach(items) { project in
                Button { openProject(project) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(project.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(Self.relativeFormatter.localizedString(for: project.createdAt, relativeTo: Date()))
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                            Text("\(project.path) · \(store.sessions(for: project.id).count) 个对话")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        if store.pendingCount(projectId: project.id) > 0 {
                            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange)
                                .accessibilityLabel("有待审批操作")
                        }
                        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("project-\(project.id)")
                if project.id != items.last?.id { Divider().padding(.leading, 54) }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var conversationChooser: some View {
        NavigationStack {
            List {
                Section {
                    if store.projects(for: store.selectedAgent, query: "").isEmpty {
                        Text("先为 \(store.selectedAgent.shortName) 添加或导入一个项目。").foregroundStyle(.secondary)
                        Button("添加项目") {
                            choosingConversation = false
                            path.append(Route.addProject(editing: nil))
                        }
                    } else {
                        Picker("当前项目", selection: $chosenProjectID) {
                            ForEach(store.projects(for: store.selectedAgent, query: "")) { project in
                                Text(project.name).tag(project.id)
                            }
                        }
                        .accessibilityIdentifier("current-project-picker")
                        if let project = chosenProject {
                            Text(project.path).font(.caption).foregroundStyle(.secondary)
                            Button {
                                store.selectProject(project.id)
                                choosingConversation = false
                                path.append(Route.session(projectId: project.id, sessionId: nil))
                            } label: { Label("新建 CLI 对话", systemImage: "plus.bubble") }
                            .disabled(!store.canSend)
                            if !store.canSend {
                                Text("当前权限不能创建对话，可继续查看已有记录。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: { Text("\(store.selectedAgent.rawValue) · \(store.hostName)") }
                if let project = chosenProject {
                    let rows = store.sessions(for: project.id).sorted { $0.createdAt > $1.createdAt }
                    Section("最近对话") {
                        if rows.isEmpty { Text("还没有对话，发出第一条消息后创建。").font(.subheadline).foregroundStyle(.secondary) }
                        ForEach(Array(rows.prefix(5))) { session in
                            Button {
                                store.selectProject(project.id)
                                choosingConversation = false
                                path.append(Route.session(projectId: project.id, sessionId: session.id))
                            } label: {
                                HStack {
                                    Image(systemName: session.source == .desktop ? "desktopcomputer" : "terminal")
                                        .foregroundStyle(.secondary)
                                    Text(session.title).foregroundStyle(.primary).lineLimit(1)
                                    Spacer()
                                    Text(session.source == .desktop ? "桌面 · 只读" : "CLI").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("查看项目全部对话") {
                            choosingConversation = false
                            openProject(project)
                        }
                    }
                }
            }
            .navigationTitle("选择对话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { choosingConversation = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: chosenProjectID) { _, id in
            if chosenProject != nil { store.selectProject(id) }
        }
    }

    private func openProject(_ project: ProjectItem) {
        store.selectProject(project.id)
        path.append(Route.project(project.id))
    }

    private func scopedProjects() -> [ProjectItem] {
        let matches = store.projects(for: store.selectedAgent, query: query)
        return scope == .recent ? matches.sorted { $0.createdAt > $1.createdAt } : matches
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

import SwiftUI

@main
struct AgentBridgeApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.reconnectIfNeeded()
            } else {
                store.suspendHealthChecks()
            }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var path = NavigationPath()
    @AppStorage("appearance") private var appearance = "自动"

    var body: some View {
        Group {
            if store.paired {
                // One stack: Workspace is home; approvals and settings are pushed
                // from its top-right buttons, so there is no bottom bar to manage.
                NavigationStack(path: $path) {
                    HomeView(path: $path)
                        .id(store.selectedDeviceID)
                        .routeDestinations(path: $path)
                }
                .tint(ArcTheme.primary)
            } else {
                NavigationStack { UnpairedView() }
            }
        }
        .onChange(of: store.selectedDeviceID) { _, _ in path = NavigationPath() }
        .onChange(of: store.pairingSuccessID) { _, _ in path = NavigationPath() }
        .alert("无法读取设备记录", isPresented: Binding(get: { store.storageError != nil }, set: { if !$0 { store.storageError = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(store.storageError ?? "") }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastBanner(text: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
        .preferredColorScheme(appearance == "深色" ? .dark : (appearance == "浅色" ? .light : nil))
    }
}

private struct RouteDestinations: ViewModifier {
    @Binding var path: NavigationPath

    func body(content: Content) -> some View {
        content.navigationDestination(for: Route.self) { route in
            switch route {
            case .approvals:
                ApprovalListView(path: $path)
            case .approval(let id):
                ApprovalDetailView(id: id)
            case .project(let id):
                ProjectDetailView(projectId: id, path: $path)
            case .session(let projectId, let sessionId):
                ChatView(projectId: projectId, sessionId: sessionId, path: $path)
            case .fork(let projectId, let sourceId):
                ChatView(projectId: projectId, sessionId: nil, path: $path, forkSourceId: sourceId)
            case .terminal(let sessionId):
                TerminalView(sessionId: sessionId)
            case .addProject(let editing):
                AddProjectView(editingId: editing)
            case .settings:
                SettingsView(path: $path)
            case .devices:
                DeviceListView(path: $path)
            }
        }
    }
}

extension View {
    func routeDestinations(path: Binding<NavigationPath>) -> some View {
        modifier(RouteDestinations(path: path))
    }
}

struct UnpairedView: View {
    @Environment(AppStore.self) private var store
    /// Gates the camera behind an explicit tap; scanning opens as its own
    /// full-screen step, not inline content on this page.
    @State private var isScanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: ArcTheme.Space.s6) {
                VStack(spacing: 10) {
                    Image("ArcLinkLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .accessibilityHidden(true)
                    Text("连接你的电脑")
                        .font(.title.bold()).foregroundStyle(ArcTheme.ink)
                        .padding(.top, ArcTheme.Space.s2)
                    Text("在手机上查看电脑上 Claude、Codex 的进展，继续对话，随时批准它们的操作。")
                        .font(.subheadline)
                        .foregroundStyle(ArcTheme.inkMuted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                }
                .padding(.top, ArcTheme.Space.s8)
                UsageStepsCard()
            }
            .padding(.horizontal, ArcTheme.Space.s4)
            .padding(.bottom, ArcTheme.Space.s6)
        }
        .background(ArcTheme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button { isScanning = true } label: {
                Label("扫描二维码", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(.arc(block: true))
            .accessibilityIdentifier("scan-pair")
            .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, 10)
            .background(ArcTheme.bg)
        }
        .toolbar(.hidden, for: .navigationBar)
        .fullScreenCover(isPresented: $isScanning) {
            QRScanScreen { code in
                await store.pair(from: code)
            }
        }
    }
}

/// The three numbered first-run steps.
private struct UsageStepsCard: View {
    private struct Step: Identifiable { let id: String; let title: String; let subtitle: String }
    private let steps = [
        Step(id: "1", title: "在电脑上安装 ArcLink", subtitle: "支持 macOS、Windows 和 Linux"),
        Step(id: "2", title: "扫描屏幕上的二维码", subtitle: "直连与私有中继一次配好，端到端加密"),
        Step(id: "3", title: "开始使用", subtitle: "项目与历史对话自动同步，审批随时处理"),
    ]

    var body: some View {
        ArcListGroup(steps) { step in
            HStack(spacing: ArcTheme.Space.s3) {
                Text(step.id)
                    .font(.subheadline.weight(.semibold)).foregroundStyle(ArcTheme.primary)
                    .frame(width: ArcTheme.iconTile, height: ArcTheme.iconTile)
                    .arcBackground(ArcTheme.primarySoft, radius: ArcTheme.Radius.md)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.callout.weight(.medium)).foregroundStyle(ArcTheme.ink)
                    Text(step.subtitle).font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, ArcTheme.Space.s3)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("第 \(step.id) 步，\(step.title)，\(step.subtitle)")
        }
    }
}

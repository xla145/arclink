import SwiftUI

@main
struct AgentBridgeApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @State private var path = NavigationPath()
    @AppStorage("appearance") private var appearance = "自动"

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if store.paired {
                    HomeView(path: $path)
                } else {
                    UnpairedView()
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .approvals:
                    ApprovalListView(path: $path)
                case .approval(let id):
                    ApprovalDetailView(id: id)
                case .project(let id):
                    ProjectDetailView(projectId: id, path: $path)
                case .session(let projectId, let sessionId):
                    ChatView(projectId: projectId, sessionId: sessionId, path: $path)
                case .terminal(let sessionId):
                    TerminalView(sessionId: sessionId)
                case .addProject(let editing):
                    AddProjectView(editingId: editing)
                case .settings:
                    SettingsView(path: $path)
                case .devices:
                    DeviceListView()
                }
            }
        }
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

struct UnpairedView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .frame(width: 72, height: 72)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    Text("扫描 Mac 上的二维码")
                        .font(.title2.bold())
                    Text("在桌面端打开 Agent Bridge 的配对窗口，用手机对准屏幕上的二维码。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                MacQRScanner { code in
                    await store.pair(from: code)
                }
            }
            .padding(16)
        }
        .navigationTitle("Agent Bridge")
    }
}

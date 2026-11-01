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
    @State private var deviceScanner: DeviceScannerRequest?
    @State private var scanSucceeded = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
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
                    DeviceListView(path: $path) { repairingID in
                        deviceScanner = DeviceScannerRequest(repairingDeviceID: repairingID)
                    }
                }
            }
        }
        .onChange(of: store.selectedDeviceID) { old, new in
            navigationTrace("[NavDebug] device \(old ?? "nil")->\(new ?? "nil") count=\(path.count)")
            path = NavigationPath()
            navigationTrace("[NavDebug] cleared count=\(path.count)")
        }
        .onChange(of: path) { old, new in navigationTrace("[NavDebug] path \(old.count)->\(new.count)") }
        // Present on the shared navigation host, so dismissing the scanner
        // cannot leave a pushed device page holding an obsolete presenter.
        .fullScreenCover(item: $deviceScanner, onDismiss: {
            navigationTrace("[NavDebug] cover dismissed")
            if scanSucceeded { path = NavigationPath() }
            scanSucceeded = false
        }) { request in
            QRScanScreen { code in
                let success = await store.pair(from: code, repairingDeviceID: request.repairingDeviceID)
                scanSucceeded = success
                return success
            }
        }
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

private struct DeviceScannerRequest: Identifiable {
    let id = UUID()
    var repairingDeviceID: String?
}

struct UnpairedView: View {
    @Environment(AppStore.self) private var store
    /// Gates the camera behind an explicit tap, matching the prototype's
    /// "扫码配对" button (`#v-empty .btn-large`) — scanning opens as its own
    /// full-screen step, not inline content on this page.
    @State private var isScanning = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                VStack(spacing: 8) {
                    Image("ArcLinkLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .accessibilityHidden(true)
                    Text("连接你的桌面主机")
                        .font(.title2.bold())
                    Text("扫描桌面端 ArcLink 显示的二维码，即可远程查看和控制 Agent。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 12)

                Button {
                    isScanning = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                        Text("扫码配对")
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(Color(.systemBackground))
                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)

                UsageStepsCard()
            }
            .padding(16)
        }
        .navigationTitle("ArcLink")
        .fullScreenCover(isPresented: $isScanning) {
            QRScanScreen { code in
                await store.pair(from: code)
            }
        }
    }
}

/// The empty state's "使用方式" card group, matching `doc/agent-bridge-mobile.html`'s
/// three numbered steps (`#v-empty .card-group`).
private struct UsageStepsCard: View {
    private let steps: [(number: String, title: String, subtitle: String, tint: Color)] = [
        ("1", "在桌面安装 ArcLink", "支持 macOS、Windows 和 Linux", .accentColor),
        ("2", "扫码配对", "P2P 加密连接，无需公网服务器", .purple),
        ("3", "远程控制 Agent", "提交任务、审批操作、查看终端", .green),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("使用方式")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(spacing: 12) {
                        Text(step.number)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(step.tint)
                            .frame(width: 28, height: 28)
                            .background(step.tint.opacity(0.15), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.title).font(.body.weight(.medium))
                            Text(step.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(14)
                    if index != steps.count - 1 {
                        Divider().padding(.leading, 54)
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }
}

private func unusedNavigationMarker() {}
func navigationTrace(_ value: String) {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("navigation-diagnostic.txt")
    let data = Data(("\(Date().timeIntervalSince1970) " + value + "\n").utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else { try? data.write(to: url) }
}

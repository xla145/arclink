import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var clearHistory = false
    @State private var choosingDevice = false
    @AppStorage("appearance") private var appearance = "自动"
    @AppStorage("retention") private var retention = "7 天"
    @AppStorage("language") private var language = "简体中文"

    var body: some View {
        @Bindable var store = store
        List {
            Section("Mac") {
                Button {
                    choosingDevice = true
                } label: {
                    HStack(spacing: ArcTheme.Space.s3) {
                        IconTile(symbol: "desktopcomputer", accent: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.hostName).font(.callout.weight(.medium)).foregroundStyle(ArcTheme.ink)
                            HStack(spacing: 6) {
                                Circle().fill(store.online ? ArcTheme.live : ArcTheme.inkFaint).frame(width: 7, height: 7)
                                Text("\(store.connectionStateLabel) · \(store.devices.count) 台已配对")
                            }
                            .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ArcTheme.inkFaint)
                    }
                    .contentShape(Rectangle())
                }
                if store.connectionState != nil {
                    LabeledContent("连接状态", value: store.connectionStateLabel)
                }
                if !store.macAgents.isEmpty {
                    LabeledContent("Mac 上的 Agent", value: "\(store.macAgents.count) 个")
                }
            }
            .listRowBackground(ArcTheme.surface)
            Section("智能体") {
                Picker("权限", selection: $store.permission) {
                    Text("完全访问").tag("完全访问")
                    Text("查看和审批").tag("查看和审批")
                    Text("仅查看").tag("仅查看")
                }
            }
            .listRowBackground(ArcTheme.surface)
            Section {
                Toggle("需要批准", isOn: $store.notifyApproval)
                Toggle("已完成", isOn: $store.notifyDone)
                Toggle("在 Mac 上完成", isOn: $store.notifyOnMac)
                Toggle("执行失败", isOn: $store.notifyFailed)
            } header: { Text("通知") } footer: {
                Text("通知偏好保存在本机；暂未接入系统推送。")
            }
            .listRowBackground(ArcTheme.surface)
            Section("ArcLink") {
                Picker("外观", selection: $appearance) {
                    ForEach(["自动", "浅色", "深色"], id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("appearance-picker")
                Picker("会话保留", selection: $retention) {
                    ForEach(["3 天", "7 天", "30 天", "永久"], id: \.self) { Text($0).tag($0) }
                }
                Picker("语言", selection: $language) {
                    Text("简体中文").tag("简体中文")
                }
                Button("清除会话历史", role: .destructive) { clearHistory = true }
            }
            .listRowBackground(ArcTheme.surface)
            Section("记录") {
                NavigationLink(value: Route.approvals) {
                    Label("审批记录", systemImage: "bell.badge")
                }
            }
            .listRowBackground(ArcTheme.surface)
            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
            .listRowBackground(ArcTheme.surface)
        }
        .arcGroupedList()
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $choosingDevice) { DevicePickerSheet() }
        .onAppear { store.prune(retention: retention) }
        .onChange(of: retention) { _, value in store.prune(retention: value) }
        .onChange(of: store.permission) { _, _ in store.save() }
        .onChange(of: store.notifyApproval) { _, _ in store.save() }
        .onChange(of: store.notifyDone) { _, _ in store.save() }
        .onChange(of: store.notifyOnMac) { _, _ in store.save() }
        .onChange(of: store.notifyFailed) { _, _ in store.save() }
        .confirmationDialog("清除当前设备的会话历史？此操作不能撤销。", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("清除会话历史", role: .destructive) {
                store.clearHistory()
            }
        }
    }
}

/// A device chooser has its own presentation lifetime; changing workspace
/// never replaces a pushed route while its scanner is being dismissed.
struct DevicePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            DeviceListView(path: $path, onSelection: { dismiss() })
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

struct DeviceListView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    var onSelection: (() -> Void)? = nil
    @State private var showQR = false
    @State private var removeID: String?
    @State private var repairingDeviceID: String?
    @State private var scanSucceeded = false

    var body: some View {
        List {
            Section {
                ForEach(store.devices) { device in
                    Button {
                        store.selectDevice(device.id)
                        if store.selectedDeviceID == device.id {
                            path = NavigationPath()
                            onSelection?()
                        }
                    } label: {
                        HStack(spacing: ArcTheme.Space.s3) {
                            IconTile(symbol: "desktopcomputer", accent: device.id == store.selectedDeviceID)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName).font(.callout.weight(.medium)).foregroundStyle(ArcTheme.ink)
                                HStack(spacing: 6) {
                                    Circle().fill(store.isOnline(device.id) ? ArcTheme.live : ArcTheme.inkFaint).frame(width: 7, height: 7)
                                    Text(store.connectionLabel(for: device.id))
                                }
                                .font(.footnote).foregroundStyle(ArcTheme.inkMuted)
                                if let endpoint = device.endpointID {
                                    Text(String(endpoint.prefix(10))).font(.caption.monospaced()).foregroundStyle(ArcTheme.inkMuted)
                                }
                            }
                            Spacer()
                            if device.id == store.selectedDeviceID {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(ArcTheme.primary)
                                    .accessibilityLabel("当前设备")
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("device-\(device.id)")
                    .swipeActions {
                        Button("移除", role: .destructive) { removeID = device.id }
                    }
                    Button("重新扫码连接 \(device.displayName)", systemImage: "qrcode.viewfinder") {
                            repairingDeviceID = device.id
                            showQR = true
                    }
                }
            } header: { Text("已配对设备 · \(store.devices.count)") } footer: {
                Text("扫码即可同时设置直连和中继，优先直连，不可用时自动使用中继。重新扫码会更新连接信息，保留项目和会话。")
                Text("多台电脑可同时连接。点选设备切换项目和会话，其他连接会保留。")
            }
            .listRowBackground(ArcTheme.surface)
            Section {
                Button { repairingDeviceID = nil; showQR = true } label: {
                    Label("添加设备", systemImage: "plus")
                }
                .accessibilityIdentifier("add-device")
            }
            .listRowBackground(ArcTheme.surface)
            if !store.macAgents.isEmpty {
                Section("\(store.hostName) 上的 Agent") {
                    ForEach(store.macAgents, id: \.id) { agent in
                        LabeledContent(agent.name, value: Self.agentStatusLabel(agent.status))
                    }
                }
            .listRowBackground(ArcTheme.surface)
            }
            Section {
                Button("移除当前设备", role: .destructive) { removeID = store.selectedDeviceID }
                    .disabled(store.selectedDeviceID == nil)
            } footer: {
                Text("仅移除这台手机保存的设备与本机记录。Mac 上的访问授权可在桌面端撤销。")
            }
            .listRowBackground(ArcTheme.surface)
        }
        .arcGroupedList()
        .navigationTitle("我的设备")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshMacStatus() }
        .refreshable { await store.refreshMacStatus() }
        .confirmationDialog("移除这台设备及其本机记录？", isPresented: Binding(get: { removeID != nil }, set: { if !$0 { removeID = nil } }), titleVisibility: .visible) {
            Button("移除设备", role: .destructive) {
                if let id = removeID { store.removeDevice(id) }
                removeID = nil
            }
            Button("取消", role: .cancel) { removeID = nil }
        }

        .fullScreenCover(isPresented: $showQR, onDismiss: {
            if scanSucceeded {
                path = NavigationPath()
                onSelection?()
            }
            scanSucceeded = false
        }) {
            QRScanScreen { code in
                let success = await store.pair(from: code, repairingDeviceID: repairingDeviceID)
                scanSucceeded = success
                return success
            }
        }
    }

    private static func agentStatusLabel(_ status: String) -> String {
        switch status {
        case "running": "运行中"
        case "installed": "已安装"
        case "available": "可用"
        case "not_found": "未安装"
        case "version_mismatch": "版本不匹配"
        case "probe_failed": "检测失败"
        default: status
        }
    }
}

extension View {
    /// Native grouped list on the design system's surfaces instead of the system greys.
    func arcGroupedList() -> some View {
        scrollContentBackground(.hidden)
            .background(ArcTheme.bg)
            .environment(\.defaultMinListRowHeight, ArcTheme.tapMin)
            .tint(ArcTheme.primary)
    }
}

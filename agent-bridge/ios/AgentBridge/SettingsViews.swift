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
                            .foregroundStyle(ArcTheme.ink)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Paired devices section
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text("已配对设备")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ArcTheme.inkMuted)
                            .accessibilityAddTraits(.isHeader)
                        if !store.devices.isEmpty {
                            Text("\(store.devices.count)")
                                .font(.caption2.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(ArcTheme.inkFaint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(ArcTheme.surfaceSunken, in: Capsule())
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 4)

                    if store.devices.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "laptopcomputer")
                                .font(.title2)
                                .foregroundStyle(ArcTheme.inkFaint)
                            Text("尚未配对 Mac")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(ArcTheme.ink)
                            Text("点击下方按钮扫描桌面端二维码即可连接")
                                .font(.caption)
                                .foregroundStyle(ArcTheme.inkMuted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 28)
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ArcTheme.line.opacity(0.7), lineWidth: 0.75)
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.devices) { device in
                                if device.id != store.devices.first?.id {
                                    ArcDivider(inset: 64)
                                }
                                deviceRow(device)
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ArcTheme.line.opacity(0.7), lineWidth: 0.75)
                        )
                    }
                }

                // Connected Mac agents (compact card with official icons)
                if !store.macAgents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("\(store.hostName) 上的 Agent")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(ArcTheme.inkMuted)
                            .padding(.horizontal, 4)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(store.macAgents, id: \.id) { agent in
                                if agent.id != store.macAgents.first?.id {
                                    ArcDivider(inset: 48)
                                }
                                let kind: AgentKind? = agent.id == "claude" ? .claude : (agent.id == "codex" ? .codex : nil)
                                let isAvailable = ["running", "installed", "available"].contains(agent.status)
                                HStack(spacing: 12) {
                                    if let kind {
                                        AgentIcon(agent: kind, size: 16)
                                            .frame(width: 28, height: 28)
                                            .background(kind.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    } else {
                                        Image(systemName: "cpu")
                                            .font(.caption)
                                            .foregroundStyle(ArcTheme.inkMuted)
                                            .frame(width: 28, height: 28)
                                            .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                    }
                                    Text(agent.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(ArcTheme.ink)
                                    Spacer()
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(isAvailable ? ArcTheme.success : ArcTheme.inkFaint)
                                            .frame(width: 6, height: 6)
                                        Text(Self.agentStatusLabel(agent.status))
                                            .font(.caption)
                                            .foregroundStyle(ArcTheme.inkMuted)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(ArcTheme.line.opacity(0.7), lineWidth: 0.75)
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
        .background(ArcTheme.bg)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    repairingDeviceID = nil
                    showQR = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "qrcode.viewfinder")
                            .font(.subheadline.weight(.semibold))
                        Text("扫码添加设备")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(ArcTheme.onPrimary)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(ArcTheme.primary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("add-device")

                Text("优先局域网直连，不可用时自动切换中继")
                    .font(.caption2)
                    .foregroundStyle(ArcTheme.inkFaint)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(ArcTheme.bg)
        }
        .navigationTitle("我的设备")
        .navigationBarTitleDisplayMode(.inline)
        .tint(ArcTheme.ink)
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

    private func deviceRow(_ device: PairedMac) -> some View {
        let isSelected = device.id == store.selectedDeviceID
        let online = store.isOnline(device.id)
        return HStack(spacing: 12) {
            Button {
                store.selectDevice(device.id)
                if store.selectedDeviceID == device.id {
                    path = NavigationPath()
                    onSelection?()
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "laptopcomputer")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(online ? ArcTheme.live : (isSelected ? ArcTheme.primary : ArcTheme.inkMuted))
                        .frame(width: 38, height: 38)
                        .background(online ? ArcTheme.liveSoft : (isSelected ? ArcTheme.primarySoft : ArcTheme.surfaceSunken),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(device.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ArcTheme.ink)
                                .lineLimit(1)
                            if isSelected {
                                Text("当前")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(ArcTheme.primary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(ArcTheme.primarySoft, in: Capsule())
                            }
                        }
                        HStack(spacing: 5) {
                            Circle()
                                .fill(online ? ArcTheme.live : ArcTheme.inkFaint)
                                .frame(width: 6, height: 6)
                            Text(store.connectionLabel(for: device.id))
                                .font(.caption)
                                .foregroundStyle(ArcTheme.inkMuted)
                                .lineLimit(1)
                            if let endpoint = device.endpointID {
                                Text("· \(String(endpoint.prefix(8)))")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(ArcTheme.inkFaint)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("device-\(device.id)")

            if !online {
                Button {
                    repairingDeviceID = device.id
                    showQR = true
                } label: {
                    Text("重连")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ArcTheme.primary)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(ArcTheme.primarySoft, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重新扫码连接 \(device.displayName)")
            }

            Menu {
                Button {
                    repairingDeviceID = device.id
                    showQR = true
                } label: {
                    Label("重新扫码连接", systemImage: "qrcode.viewfinder")
                }
                Button(role: .destructive) {
                    removeID = device.id
                } label: {
                    Label("移除设备", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ArcTheme.inkMuted)
                    .frame(width: 32, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("设备操作")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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

import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var clearHistory = false
    @State private var choosingDevice = false
    @AppStorage("appearance") private var appearance = "自动"
    @AppStorage("retention") private var retention = "7 天"
    @AppStorage("autoApproveManagedTools") private var autoApproveManagedTools = false

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Host
                sectionGroup {
                    Button { choosingDevice = true } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "desktopcomputer")
                                .font(.system(size: 18, weight: .regular))
                                .foregroundStyle(ArcTheme.ink)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(store.hostName)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(ArcTheme.ink)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(store.online ? ArcTheme.live : ArcTheme.inkFaint)
                                        .frame(width: 6, height: 6)
                                    Text(hostSubtitle)
                                        .font(.footnote)
                                        .foregroundStyle(ArcTheme.inkMuted)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ArcTheme.inkFaint)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Agent
                sectionGroup("智能体", footer: "开启「自动批准」后，对话中工具与命令请求将自动放行。") {
                    HStack {
                        Text("自动批准工具调用")
                            .font(.body)
                            .foregroundStyle(ArcTheme.ink)
                        Spacer()
                        Toggle("", isOn: $autoApproveManagedTools)
                            .labelsHidden()
                            .tint(ArcTheme.ink)
                            .accessibilityLabel("自动批准工具调用")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)

                    rowDivider

                    menuRow("本机权限", value: store.permission) {
                        ForEach(["完全访问", "查看和审批", "仅查看"], id: \.self) { option in
                            Button { store.permission = option } label: {
                                HStack {
                                    Text(option)
                                    if store.permission == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }

                    rowDivider

                    NavigationLink(value: Route.approvals) {
                        HStack {
                            Text("审批记录")
                                .font(.body)
                                .foregroundStyle(ArcTheme.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(ArcTheme.inkFaint)
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // General
                sectionGroup("通用") {
                    HStack {
                        Text("外观")
                            .font(.body)
                            .foregroundStyle(ArcTheme.ink)
                        Spacer()
                        HStack(spacing: 2) {
                            ForEach(["自动", "浅色", "深色"], id: \.self) { mode in
                                let selected = appearance == mode
                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) { appearance = mode }
                                } label: {
                                    Text(mode)
                                        .font(.caption.weight(selected ? .semibold : .regular))
                                        .foregroundStyle(selected ? ArcTheme.ink : ArcTheme.inkMuted)
                                        .padding(.horizontal, 12)
                                        .frame(height: 28)
                                        .background {
                                            if selected {
                                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                    .fill(ArcTheme.surface)
                                                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        .accessibilityIdentifier("appearance-picker")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)

                    rowDivider

                    menuRow("会话保留", value: retention) {
                        ForEach(["3 天", "7 天", "30 天", "永久"], id: \.self) { option in
                            Button { retention = option } label: {
                                HStack {
                                    Text(option)
                                    if retention == option { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                }

                // Notifications
                sectionGroup("通知", footer: "已接入本机系统通知，应用活跃期间实时提醒。") {
                    toggleRow("需要批准", isOn: $store.notifyApproval)
                    rowDivider
                    toggleRow("已完成", isOn: $store.notifyDone)
                    rowDivider
                    toggleRow("在 Mac 上完成", isOn: $store.notifyOnMac)
                    rowDivider
                    toggleRow("执行失败", isOn: $store.notifyFailed)
                }

                // About & Reset
                sectionGroup {
                    HStack {
                        Text("版本")
                            .font(.body)
                            .foregroundStyle(ArcTheme.ink)
                        Spacer()
                        Text("0.1.0")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(ArcTheme.inkFaint)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)

                    rowDivider

                    Button(role: .destructive) { clearHistory = true } label: {
                        HStack {
                            Text("清除会话历史")
                                .font(.body)
                                .foregroundStyle(ArcTheme.danger)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 32)
        }
        .background(ArcTheme.bg.ignoresSafeArea())
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .arcBackButton("首页")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("设置")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ArcTheme.ink)
            }
        }
        .sheet(isPresented: $choosingDevice) { DevicePickerSheet() }
        .onAppear { store.prune(retention: retention) }
        .onChange(of: retention) { _, value in store.prune(retention: value) }
        .onChange(of: store.permission) { _, _ in store.save() }
        .onChange(of: store.notifyApproval) { _, value in
            UserDefaults.standard.set(value, forKey: "arclink.notifyApproval")
            if value { LocalNotificationCenter.shared.requestAuthorizationIfNeeded() }
            store.save()
        }
        .onChange(of: store.notifyDone) { _, value in
            UserDefaults.standard.set(value, forKey: "arclink.notifyDone")
            if value { LocalNotificationCenter.shared.requestAuthorizationIfNeeded() }
            store.save()
        }
        .onChange(of: store.notifyOnMac) { _, value in
            UserDefaults.standard.set(value, forKey: "arclink.notifyOnMac")
            if value { LocalNotificationCenter.shared.requestAuthorizationIfNeeded() }
            store.save()
        }
        .onChange(of: store.notifyFailed) { _, value in
            UserDefaults.standard.set(value, forKey: "arclink.notifyFailed")
            if value { LocalNotificationCenter.shared.requestAuthorizationIfNeeded() }
            store.save()
        }
        .confirmationDialog("清除当前设备的会话历史？此操作不能撤销。", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("清除会话历史", role: .destructive) {
                store.clearHistory()
            }
        }
    }

    private var hostSubtitle: String {
        var parts = [store.connectionStateLabel, "\(store.devices.count) 台设备"]
        if !store.macAgents.isEmpty { parts.append("\(store.macAgents.count) 个 Agent") }
        return parts.joined(separator: " · ")
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(ArcTheme.line.opacity(0.7))
            .frame(height: 0.5)
            .padding(.leading, 16)
    }

    private func sectionGroup<Content: View>(
        _ title: String? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(ArcTheme.inkMuted)
                    .padding(.horizontal, 14)
            }
            VStack(spacing: 0) {
                content()
            }
            .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(ArcTheme.inkFaint)
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
            }
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(ArcTheme.ink)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(ArcTheme.ink)
                .accessibilityLabel(title)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
    }

    private func menuRow<MenuContent: View>(_ title: String, value: String, @ViewBuilder menu: () -> MenuContent) -> some View {
        HStack {
            Text(title)
                .font(.body)
                .foregroundStyle(ArcTheme.ink)
            Spacer()
            Menu {
                menu()
            } label: {
                HStack(spacing: 5) {
                    Text(value)
                        .font(.subheadline)
                        .foregroundStyle(ArcTheme.inkMuted)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(ArcTheme.inkFaint)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("已配对设备")
                            .font(.footnote)
                            .foregroundStyle(ArcTheme.inkMuted)
                            .accessibilityAddTraits(.isHeader)
                        if !store.devices.isEmpty {
                            Text("\(store.devices.count)")
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(ArcTheme.inkFaint)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)

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
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        VStack(spacing: 0) {
                            ForEach(store.devices) { device in
                                if device.id != store.devices.first?.id {
                                    ArcDivider(inset: 52)
                                }
                                deviceRow(device)
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }

                // Connected Mac agents
                if !store.macAgents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(store.hostName) 上的 Agent")
                            .font(.footnote)
                            .foregroundStyle(ArcTheme.inkMuted)
                            .padding(.horizontal, 14)
                            .accessibilityAddTraits(.isHeader)

                        VStack(spacing: 0) {
                            ForEach(store.macAgents, id: \.id) { agent in
                                if agent.id != store.macAgents.first?.id {
                                    ArcDivider(inset: 52)
                                }
                                let kind: AgentKind? = agent.id == "claude" ? .claude : (agent.id == "codex" ? .codex : nil)
                                let isAvailable = ["running", "installed", "available"].contains(agent.status)
                                HStack(spacing: 12) {
                                    if let kind {
                                        AgentIcon(agent: kind, size: 16, tint: ArcTheme.ink)
                                            .frame(width: 24)
                                    } else {
                                        Image(systemName: "cpu")
                                            .font(.subheadline)
                                            .foregroundStyle(ArcTheme.inkMuted)
                                            .frame(width: 24)
                                    }
                                    Text(agent.name)
                                        .font(.body)
                                        .foregroundStyle(ArcTheme.ink)
                                    Spacer()
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(isAvailable ? ArcTheme.live : ArcTheme.inkFaint)
                                            .frame(width: 6, height: 6)
                                        Text(Self.agentStatusLabel(agent.status))
                                            .font(.footnote)
                                            .foregroundStyle(ArcTheme.inkMuted)
                                    }
                                }
                                .padding(.horizontal, 16)
                                .frame(minHeight: 48)
                            }
                        }
                        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                            .font(.subheadline.weight(.medium))
                        Text("扫码添加设备")
                            .font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(ArcTheme.surface)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(ArcTheme.ink, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(ArcTheme.ink)
                        .frame(width: 24)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(device.displayName)
                                .font(.body.weight(.medium))
                                .foregroundStyle(ArcTheme.ink)
                                .lineLimit(1)
                            if isSelected {
                                Text("当前")
                                    .font(.caption)
                                    .foregroundStyle(ArcTheme.inkFaint)
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
                        .font(.caption.weight(.medium))
                        .foregroundStyle(ArcTheme.ink)
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(ArcTheme.surfaceSunken, in: Capsule())
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
            .tint(ArcTheme.ink)
    }
}

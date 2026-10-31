import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var clearHistory = false
    @AppStorage("appearance") private var appearance = "自动"
    @AppStorage("retention") private var retention = "7 天"
    @AppStorage("language") private var language = "简体中文"

    var body: some View {
        @Bindable var store = store
        List {
            Section("Mac") {
                Button {
                    path.append(Route.devices)
                } label: {
                    HStack {
                        Label("Mac", systemImage: "desktopcomputer")
                        Spacer()
                        Circle().fill(store.online ? Color.green : Color.secondary).frame(width: 8, height: 8)
                        Text(store.hostName).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
            Section("智能体") {
                Picker("权限", selection: $store.permission) {
                    Text("完全访问").tag("完全访问")
                    Text("查看和审批").tag("查看和审批")
                    Text("仅查看").tag("仅查看")
                }
            }
            Section("通知") {
                Toggle("需要批准", isOn: $store.notifyApproval)
                Toggle("已完成", isOn: $store.notifyDone)
                Toggle("在 Mac 上完成", isOn: $store.notifyOnMac)
                Toggle("执行失败", isOn: $store.notifyFailed)
            }
            Section("Agent Bridge") {
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
            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.prune(retention: retention) }
        .onChange(of: retention) { _, value in store.prune(retention: value) }
        .onChange(of: store.permission) { _, _ in store.save() }
        .onChange(of: store.notifyApproval) { _, _ in store.save() }
        .onChange(of: store.notifyDone) { _, _ in store.save() }
        .onChange(of: store.notifyOnMac) { _, _ in store.save() }
        .onChange(of: store.notifyFailed) { _, _ in store.save() }
        .confirmationDialog("清除全部会话历史？此操作不能撤销。", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("清除会话历史", role: .destructive) {
                store.clearHistory()
            }
        }
    }
}

struct DeviceListView: View {
    @Environment(AppStore.self) private var store
    @State private var showQR = false

    var body: some View {
        List {
            Section("当前连接") {
                Label {
                    VStack(alignment: .leading) {
                        Text(store.hostName)
                        Text(store.paired ? "已配对 · 未连接桌面进程" : "未配对")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            }
            Section {
                Button {
                    showQR.toggle()
                } label: {
                    Label(showQR ? "收起扫描" : "扫描 Mac 二维码", systemImage: "qrcode.viewfinder")
                }
                if showQR {
                    MacQRScanner { code in
                        let ok = await store.pair(from: code)
                        if ok { showQR = false }
                        return ok
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
                Button("断开配对", role: .destructive) { store.unpair() }
            } footer: {
                Text("二维码由 Mac 显示。手机只负责扫描。断开后会回到未配对页。")
            }
        }
        .navigationTitle("我的 Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

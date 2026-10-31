import SwiftUI

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Binding var path: NavigationPath
    @State private var clearHistory = false

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
                LabeledContent("外观", value: "自动")
                LabeledContent("会话保留", value: "7 天")
                LabeledContent("语言", value: "简体中文")
                Button("清除会话历史", role: .destructive) { clearHistory = true }
            }
            Section("关于") {
                LabeledContent("版本", value: "0.1.0")
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("清除全部会话历史？此操作不能撤销。", isPresented: $clearHistory, titleVisibility: .visible) {
            Button("清除会话历史", role: .destructive) {
                store.messages.removeAll()
                store.sessions.removeAll()
                store.show("已清除会话历史")
            }
        }
    }
}

struct DeviceListView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        List {
            Section("当前连接") {
                Label {
                    VStack(alignment: .leading) {
                        Text(store.hostName)
                        Text(store.online ? "在线 · 直连" : "离线")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "desktopcomputer")
                }
            }
            Section {
                Button {
                    store.showPairQR.toggle()
                } label: {
                    Label(store.showPairQR ? "收起二维码" : "添加新的 Mac", systemImage: "plus")
                }
                if store.showPairQR {
                    QRCodeView(payload: "agent-bridge://pair?host=new")
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }
            } footer: {
                Text("二维码显示在当前页面。桌面端确认后完成配对。首版同一时间只连接一台 Mac。")
            }
        }
        .navigationTitle("我的 Mac")
        .navigationBarTitleDisplayMode(.inline)
    }
}

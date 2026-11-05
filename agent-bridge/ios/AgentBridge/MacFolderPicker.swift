import SwiftUI

/// Browses folders inside the connected Mac's home directory (the Mac refuses
/// anything outside it) and returns the chosen path.
struct MacFolderPicker: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onSelect: (String) -> Void

    @State private var listing: MacDirectoryListing?
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let listing {
                    content(listing)
                } else if let failure {
                    ContentUnavailableView("无法浏览文件夹", systemImage: "folder.badge.questionmark", description: Text(failure))
                } else {
                    ProgressView("正在读取 \(store.hostName) 上的文件夹…").frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(ArcTheme.bg)
            .navigationTitle("选择文件夹")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let listing {
                    Button("选择此文件夹") { onSelect(listing.path); dismiss() }
                        .buttonStyle(.arc(block: true))
                        .accessibilityIdentifier("choose-folder")
                        .padding(.horizontal, ArcTheme.Space.s4).padding(.vertical, 10)
                        .background(ArcTheme.bg)
                }
            }
        }
        .task { await load(nil) }
    }

    private func content(_ listing: MacDirectoryListing) -> some View {
        List {
            Section {
                Label(displayPath(listing.path), systemImage: "folder")
                    .font(.footnote.monospaced()).foregroundStyle(ArcTheme.inkMuted)
                    .lineLimit(2).truncationMode(.head)
                    .accessibilityIdentifier("folder-current-path")
                if let parent = listing.parent {
                    Button { Task { await load(parent) } } label: {
                        Label("上一级", systemImage: "arrow.up.left")
                    }
                    .accessibilityIdentifier("folder-up")
                }
            }
            .listRowBackground(ArcTheme.surface)
            Section {
                if listing.entries.isEmpty {
                    Text("这个文件夹里没有子文件夹").foregroundStyle(ArcTheme.inkMuted)
                }
                ForEach(listing.entries, id: \.path) { entry in
                    Button { Task { await load(entry.path) } } label: {
                        HStack(spacing: ArcTheme.Space.s3) {
                            Image(systemName: entry.isProject ? "folder.fill" : "folder")
                                .foregroundStyle(entry.isProject ? ArcTheme.primary : ArcTheme.inkMuted)
                            Text(entry.name).foregroundStyle(ArcTheme.ink).lineLimit(1)
                            Spacer(minLength: ArcTheme.Space.s2)
                            if entry.isProject { StatusTag(kind: .neutral, text: "项目") }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(ArcTheme.inkFaint)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .accessibilityIdentifier("folder-\(entry.name)")
                }
            } footer: {
                if listing.truncated { Text("文件夹太多，只显示前 400 个。") }
            }
            .listRowBackground(ArcTheme.surface)
        }
        .arcGroupedList()
        .overlay { if loading { ProgressView() } }
    }

    /// Shows `~/…` for paths under the home folder the Mac reported first.
    private func displayPath(_ path: String) -> String {
        guard let home = homePath, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
    @State private var homePath: String?

    private func load(_ path: String?) async {
        failure = nil
        #if DEBUG
        if let fixture = Self.fixture(path) { listing = fixture; homePath = homePath ?? fixture.path; return }
        #endif
        guard let bridge = store.macBridge else {
            failure = "\(store.hostName) 未连接。连接后再试，或直接输入路径。"
            return
        }
        loading = true
        defer { loading = false }
        do {
            let result = try await bridge.listDirectory(path: path)
            listing = result
            if homePath == nil { homePath = result.path }
        } catch BridgeError.Failed(let code, _) where code == "unsupported" {
            failure = "\(store.hostName) 上的 ArcLink 版本较旧，不支持浏览文件夹。请更新 Mac 端后再试，或直接输入路径。"
        } catch BridgeError.Failed(let code, _) where code == "forbidden" {
            failure = "只能浏览个人文件夹（~）里的内容。"
        } catch {
            failure = "读取失败：文件夹不存在或没有权限。"
        }
    }

    #if DEBUG
    /// UI tests describe a fake folder tree as `{"<path>": {"parent": …, "entries": [[name, path, isProject]]}}`
    /// (key "~" is the home folder), under the same isolated launch contract as other fixtures.
    private static func fixture(_ path: String?) -> MacDirectoryListing? {
        let environment = Foundation.ProcessInfo.processInfo.environment
        guard let testID = environment["ARCLINK_UI_TEST_ID"], UUID(uuidString: testID) != nil,
              let json = environment["ARCLINK_UI_TEST_DIRECTORIES"], let data = json.data(using: .utf8),
              let tree = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        let home = tree["~"]?["path"] as? String ?? "/Users/test"
        let key = path.map { $0 == home ? "~" : $0 } ?? "~"
        guard let node = tree[key] else { return nil }
        let entries = (node["entries"] as? [[Any]] ?? []).compactMap { row -> MacDirectoryEntry? in
            guard row.count == 3, let name = row[0] as? String, let path = row[1] as? String, let project = row[2] as? Bool else { return nil }
            return MacDirectoryEntry(name: name, path: path, isProject: project)
        }
        return MacDirectoryListing(path: node["path"] as? String ?? key, parent: node["parent"] as? String, entries: entries, truncated: false)
    }
    #endif
}

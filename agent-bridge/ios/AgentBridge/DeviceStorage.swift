import Foundation
import Observation

struct DeviceWorkspace: Codable {
    var selectedAgent: AgentKind = .claude
    var projects: [ProjectItem] = []
    var sessions: [SessionItem] = []
    var messages: [ChatMessage] = []
    var approvals: [ApprovalItem] = []
    var permission = "完全访问"
    var selectedProjectIDs: [String: String]? = nil
    // nil keeps existing v2 records compatible; an empty catalog is a successful result.
    var projectCatalogs: [String: ProjectCatalogCache]? = nil
}

/// Durable source catalog for the importer/picker, separate from editable workspace rows.
struct ProjectCatalogCache: Codable {
    var fetchedAt: Date
    var projects: [CachedMacProject]
    var sourceSchema: Int?

    init(fetchedAt: Date, projects: [MacProject]) {
        self.sourceSchema = 2
        self.fetchedAt = fetchedAt
        self.projects = projects.map(CachedMacProject.init)
    }
    var values: [MacProject] { projects.map(\.value) }
    func isFresh(at now: Date) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return sourceSchema == 2 && age >= 0 && age < 300
    }
}

struct CachedMacProject: Codable {
    var path: String
    var lastSeen: String?
    var name: String?
    var threads: [CachedMacThread]

    init(_ project: MacProject) {
        path = project.path; lastSeen = project.lastSeen; name = project.name
        threads = project.threads.map(CachedMacThread.init)
    }
    var value: MacProject {
        MacProject(path: path, lastSeen: lastSeen, name: name, threads: threads.map(\.value))
    }
}

struct CachedMacThread: Codable {
    var id: String
    var title: String
    var updatedAt: String?
    var source: String?

    init(_ thread: MacThread) {
        id = thread.id; title = thread.title; updatedAt = thread.updatedAt; source = thread.source
    }
    var value: MacThread { MacThread(id: id, title: title, updatedAt: updatedAt, source: source) }
}

struct PairedMac: Identifiable, Codable {
    var id: String
    var name: String
    var endpointID: String?
    var workspace = DeviceWorkspace()
    var network: SavedPeerNetwork? = nil

    // Older pairing invitations persisted the former product name as the host name.
    var displayName: String { name == "Agent Bridge" ? "ArcLink" : name }
}

struct DeviceSnapshot: Codable {
    var version = 2
    var devices: [PairedMac] = []
    var selectedDeviceID: String?
    // Keep records left by an older unpaired install without assigning them
    // to an unrelated, newly paired computer.
    var orphanedWorkspace: DeviceWorkspace?
    var notifyApproval = true
    var notifyDone = true
    var notifyOnMac = false
    var notifyFailed = true
}

/// Version 1 remains readable, and is never overwritten by the new writer.
struct LegacyDeviceSnapshot: Codable {
    var paired: Bool
    var hostName: String
    var online: Bool
    var selectedAgent: AgentKind
    var projects: [ProjectItem]
    var sessions: [SessionItem]
    var messages: [ChatMessage]
    var approvals: [ApprovalItem]
    var permission: String
    var notifyApproval: Bool
    var notifyDone: Bool
    var notifyOnMac: Bool
    var notifyFailed: Bool
    var macEndpointId: String?

    func migrated() -> DeviceSnapshot {
        let workspace = DeviceWorkspace(selectedAgent: selectedAgent, projects: projects, sessions: sessions,
                                        messages: messages, approvals: approvals, permission: permission)
        let endpoint = macEndpointId.flatMap { $0.isEmpty ? nil : $0 }
        let device = PairedMac(id: UUID().uuidString, name: hostName.isEmpty ? "Mac" : hostName,
                               endpointID: endpoint, workspace: workspace)
        return DeviceSnapshot(devices: paired ? [device] : [], selectedDeviceID: paired ? device.id : nil,
                              orphanedWorkspace: paired ? nil : workspace,
                              notifyApproval: notifyApproval, notifyDone: notifyDone,
                              notifyOnMac: notifyOnMac, notifyFailed: notifyFailed)
    }
}

struct DeviceStorage {
    let directory: URL
    var currentURL: URL { directory.appendingPathComponent("devices-v2.json") }
    var legacyURL: URL { directory.appendingPathComponent("state.json") }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("AgentBridge", isDirectory: true)) {
        #if DEBUG
        // UI automation uses an explicitly named, isolated temporary store.
        // Release builds never accept fixture data or override persisted state.
        let environment = Foundation.ProcessInfo.processInfo.environment
        if let id = environment["ARCLINK_UI_TEST_ID"], UUID(uuidString: id) != nil {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArcLinkUITests-" + id)
            if let state = environment["ARCLINK_UI_TEST_STATE"],
               !FileManager.default.fileExists(atPath: self.directory.appendingPathComponent("devices-v2.json").path) {
                try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
                try? Data(state.utf8).write(to: self.directory.appendingPathComponent("devices-v2.json"), options: .atomic)
            }
            return
        }
        #endif
        self.directory = directory
    }

    func load() throws -> DeviceSnapshot {
        let manager = FileManager.default
        if manager.fileExists(atPath: currentURL.path) {
            let snapshot = try JSONDecoder().decode(DeviceSnapshot.self, from: Data(contentsOf: currentURL))
            guard snapshot.version == 2,
                  Set(snapshot.devices.map(\.id)).count == snapshot.devices.count,
                  Set(snapshot.devices.compactMap(\.endpointID)).count == snapshot.devices.compactMap(\.endpointID).count,
                  snapshot.selectedDeviceID.map({ id in snapshot.devices.contains { $0.id == id } }) ?? snapshot.devices.isEmpty
            else { throw CocoaError(.fileReadCorruptFile) }
            return snapshot
        }
        guard manager.fileExists(atPath: legacyURL.path) else { return DeviceSnapshot() }
        let data = try Data(contentsOf: legacyURL)
        let snapshot = try JSONDecoder().decode(LegacyDeviceSnapshot.self, from: data).migrated()
        let backup = directory.appendingPathComponent("state-v1-backup.json")
        if !manager.fileExists(atPath: backup.path) { try data.write(to: backup, options: .atomic) }
        try save(snapshot)
        return snapshot
    }

    func save(_ snapshot: DeviceSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: currentURL, options: .atomic)
    }
}

/// Narrow injectable boundary for state tests. Production uses the real FFI
/// object; a selected terminal still gets that concrete object's own connection.
@MainActor
protocol DeviceTransport: AnyObject {
    func connect() async -> ConnectionState
    func reconnect() async -> ConnectionState
    func disconnect() async
    func ping() async throws
    func pathKind() async -> String
    func listAgents() async throws -> [AgentInfo]
    func listAgentProjects(agentId: String) async throws -> [MacProject]
}
extension DeviceTransport {
    func pathKind() async -> String { "unknown" }
}
extension BridgeConnection: DeviceTransport {}

@MainActor
@Observable
final class DeviceRuntime {
    let transport: any DeviceTransport
    var state: ConnectionState = .idle
    var pathKind = "unknown"
    var agents: [AgentInfo] = []
    var generation = UUID()
    var refreshing = false
    /// Consecutive health-check RPC failures. One blip does not drop the
    /// link; the connection is redialed only after a second failure.
    var rpcFailures = 0

    init(transport: any DeviceTransport) { self.transport = transport }
}

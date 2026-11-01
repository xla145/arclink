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
}

struct PairedMac: Identifiable, Codable {
    var id: String
    var name: String
    var endpointID: String?
    var workspace = DeviceWorkspace()
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
    func listAgents() async throws -> [AgentInfo]
    func listAgentProjects(agentId: String) async throws -> [MacProject]
}
extension BridgeConnection: DeviceTransport {}

@MainActor
@Observable
final class DeviceRuntime {
    let transport: any DeviceTransport
    var state: ConnectionState = .idle
    var agents: [AgentInfo] = []
    var generation = UUID()
    var refreshing = false
    var importedAgentIDs: Set<String> = []
    /// Consecutive health-check RPC failures. One blip does not drop the
    /// link; the connection is redialed only after a second failure.
    var rpcFailures = 0

    init(transport: any DeviceTransport) { self.transport = transport }
}

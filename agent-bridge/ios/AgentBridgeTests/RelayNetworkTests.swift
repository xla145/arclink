import XCTest
@testable import AgentBridge

@MainActor
final class RelayNetworkTests: XCTestCase {
    private func storage() throws -> DeviceStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return DeviceStorage(directory: directory)
    }
    private let invitation = """
    {"version":1,"token":"one-use","endpoint_id":"endpoint-a","network":{"relay_url":"https://iroh.classktv.com/","relay_access_key":"test-only-key","direct_addresses":["192.168.1.3:1234"]}}
    """
    private var success: PairOutcome { PairOutcome(ok: true, deviceId: "phone", pending: false, errorCode: "", errorMessage: "") }

    func testRelayOnlyInvitationWaitsForApprovalThenPublishesSuccessForEveryRescan() async throws {
        let storage = try storage()
        let credentials = MemoryRelayCredentials()
        var completion: CheckedContinuation<PairOutcome, Never>?
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { _, _, _, _, _, network in
                XCTAssertTrue(network.directAddresses.isEmpty)
                XCTAssertEqual(network.relayUrl, "https://iroh.classktv.com/")
                return await withCheckedContinuation { completion = $0 }
            })
        let payload = """
        {"version":1,"token":"one-use","endpoint_id":"endpoint-a","network":{"relay_url":"https://iroh.classktv.com/","relay_access_key":"test-only-key"}}
        """
        var previousEvent: UUID?
        var selectedID: String?
        for _ in 0..<2 {
            completion = nil
            let task = Task { await store.pair(from: payload) }
            while completion == nil { await Task.yield() }
            XCTAssertEqual(store.pairingPhase, "正在连接 Mac，尝试直连或中继…")
            XCTAssertEqual(store.pairingSuccessID, previousEvent)
            completion?.resume(returning: success)
            let result = await task.value
            XCTAssertTrue(result)
            XCTAssertNil(store.pairingPhase)
            XCTAssertNotNil(store.pairingSuccessID)
            XCTAssertNotEqual(store.pairingSuccessID, previousEvent)
            if let selectedID { XCTAssertEqual(store.selectedDeviceID, selectedID) }
            previousEvent = store.pairingSuccessID
            selectedID = store.selectedDeviceID
        }
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(try storage.load().devices.count, 1)
    }

    func testPendingAndRejectedOutcomesNeverPublishSuccess() async throws {
        for outcome in [
            PairOutcome(ok: true, deviceId: "phone", pending: true, errorCode: "", errorMessage: ""),
            PairOutcome(ok: false, deviceId: "phone", pending: false, errorCode: "unauthorized", errorMessage: "")
        ] {
            let store = AppStore(storage: try storage(), autoConnect: false, credentials: MemoryRelayCredentials(),
                networkPairingOperation: { _, _, _, _, _, _ in outcome })
            let result = await store.pair(from: invitation)
            XCTAssertFalse(result)
            XCTAssertTrue(store.devices.isEmpty)
            XCTAssertNil(store.pairingSuccessID)
        }
    }

    func testLegacyHTTPInvitationCannotCreateUnapprovedDevice() async throws {
        let store = AppStore(storage: try storage(), autoConnect: false)
        let result = await store.pair(from: "{\"token\":\"old\",\"pair_urls\":[\"http://127.0.0.1:9/pair\"]}")
        XCTAssertFalse(result)
        XCTAssertTrue(store.devices.isEmpty)
        XCTAssertNil(store.pairingSuccessID)
        XCTAssertTrue(store.toast?.contains("版本过旧") == true)
    }

    func testPairingStageCopyDoesNotClaimApprovalBeforeMacAcknowledgment() {
        XCTAssertFalse(AppStore.pairingStageLabel(.connecting).contains("确认"))
        XCTAssertFalse(AppStore.pairingStageLabel(.handshaking).contains("请在 Mac 上确认"))
        XCTAssertTrue(AppStore.pairingStageLabel(.awaitingApproval).contains("Mac 已收到"))
        XCTAssertNotEqual(AppStore.localizedPairError(code: "connect_timeout", message: ""),
                          AppStore.localizedPairError(code: "approval_timeout", message: ""))
    }

    func testNativeKeychainRoundTripUsesIsolatedReference() throws {
        let store = KeychainRelayCredentials()
        let reference = "test-" + UUID().uuidString
        defer { try? store.remove(reference) }
        try store.write("isolated-test-value", reference: reference)
        XCTAssertEqual(try store.read(reference), "isolated-test-value")
        try store.remove(reference)
        XCTAssertNil(try store.read(reference))
    }

    func testMissingStoredCredentialCanBeRestoredByRescanningSameMac() async throws {
        let storage = try storage()
        let network = SavedPeerNetwork(relayURL: "https://iroh.classktv.com/", credentialReference: "missing", directAddresses: [])
        let workspace = DeviceWorkspace(projects: [ProjectItem(id: "p", name: "history", path: "/p", agent: .claude)])
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "a", name: "A", endpointID: "endpoint-a", workspace: workspace, network: network)], selectedDeviceID: "a"))
        let credentials = MemoryRelayCredentials()
        var attempts = 0
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { [success] _, _, _, _, _, _ in attempts += 1; return success })
        await store.refreshMacStatus()
        XCTAssertEqual(store.connectionStateLabel, "中继配置或密钥不可用，请重新扫码")
        XCTAssertFalse(store.online)
        let repaired = await store.pair(from: invitation, repairingDeviceID: "a")
        XCTAssertTrue(repaired)
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.id, "a")
        XCTAssertEqual(store.projects.first?.name, "history")
        let saved = try XCTUnwrap(try storage.load().devices.first?.network)
        XCTAssertEqual(try credentials.read(try XCTUnwrap(saved.credentialReference)), "test-only-key")
    }

    func testRescanCannotReplaceAnotherHostsMissingCredential() async throws {
        let storage = try storage()
        let network = SavedPeerNetwork(relayURL: "https://iroh.classktv.com/", credentialReference: "missing", directAddresses: [])
        try storage.save(DeviceSnapshot(devices: [
            PairedMac(id: "a", name: "A", endpointID: "endpoint-a"),
            PairedMac(id: "b", name: "B", endpointID: "endpoint-b", network: network)
        ], selectedDeviceID: "a"))
        let credentials = MemoryRelayCredentials()
        var attempts = 0
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { [success] _, _, _, _, _, _ in attempts += 1; return success })
        let repaired = await store.pair(from: invitation, repairingDeviceID: "a")
        XCTAssertFalse(repaired)
        XCTAssertEqual(attempts, 0)
        XCTAssertTrue(credentials.items.isEmpty)
        XCTAssertEqual(store.devices.last?.network, network)
    }

    func testStatusFollowsActualTransportPath() async throws {
        let storage = try storage()
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "a", name: "A", endpointID: "endpoint-a")], selectedDeviceID: "a"))
        let transport = PathTransport()
        let store = AppStore(storage: storage, autoConnect: false, connectionFactory: { _ in transport })
        await store.refreshMacStatus()
        XCTAssertEqual(store.connectionStateLabel, "在线 · 中继")
        transport.path = "direct"
        await store.refreshMacStatus()
        XCTAssertEqual(store.connectionStateLabel, "在线 · 直连")
        transport.path = "unknown"
        await store.refreshMacStatus()
        XCTAssertEqual(store.connectionStateLabel, "在线")
    }

    func testTypedBoundarySupportsLegacyAndRejectsMalformedOrFutureVersion() throws {
        XCTAssertNil(try PairInvitation.decode("{\"token\":\"legacy\"}").network)
        XCTAssertThrowsError(try PairInvitation.decode("{\"version\":2,\"token\":\"x\"}"))
        XCTAssertThrowsError(try PairInvitation.decode("{\"token\":\"x\",\"network\":{\"direct_addresses\":[3]}}"))
        let malformed = try PairInvitation.decode("{\"token\":\"x\",\"network\":{\"relay_url\":\"http://bad.example\"}}")
        XCTAssertThrowsError(try malformed.network?.validated())
    }

    func testRefreshPreservesWorkspaceAndPersistsNoSecret() async throws {
        let storage = try storage()
        let credentials = MemoryRelayCredentials()
        let workspace = DeviceWorkspace(projects: [ProjectItem(id: "p", name: "history", path: "/p", agent: .claude)])
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "a", name: "A", endpointID: "endpoint-a", workspace: workspace)], selectedDeviceID: "a"))
        var importedNetwork: PeerNetworkConfig?
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { [success] _, _, _, _, _, network in
                importedNetwork = network
                return success
            })
        let ok = await store.pair(from: invitation, repairingDeviceID: "a")
        XCTAssertTrue(ok)
        XCTAssertEqual(importedNetwork?.relayUrl, "https://iroh.classktv.com/")
        XCTAssertEqual(importedNetwork?.relayAccessKey, "test-only-key")
        XCTAssertEqual(importedNetwork?.directAddresses, ["192.168.1.3:1234"])
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.id, "a")
        XCTAssertEqual(store.projects.first?.name, "history")
        XCTAssertEqual(credentials.items.count, 1)
        let persisted = try String(contentsOf: storage.currentURL, encoding: .utf8)
        XCTAssertFalse(persisted.contains("test-only-key"))
        XCTAssertFalse(persisted.contains("one-use"))
        let saved = try XCTUnwrap(try storage.load().devices.first?.network)
        XCTAssertEqual(saved.relayURL, importedNetwork?.relayUrl)
        XCTAssertEqual(saved.directAddresses, importedNetwork?.directAddresses)
        XCTAssertEqual(try credentials.read(try XCTUnwrap(saved.credentialReference)), "test-only-key")
    }

    func testCancelledLateSuccessNeverWritesCredential() async throws {
        let storage = try storage()
        let credentials = MemoryRelayCredentials()
        var continuation: CheckedContinuation<PairOutcome, Never>?
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { _, _, _, _, _, _ in await withCheckedContinuation { continuation = $0 } })
        let task = Task { await store.pair(from: invitation) }
        while continuation == nil { await Task.yield() }
        store.cancelPairing()
        continuation?.resume(returning: success)
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertTrue(credentials.items.isEmpty)
        XCTAssertTrue(store.devices.isEmpty)
    }

    func testRefreshAndRemovalDeleteOnlyUnreferencedCredentials() async throws {
        let storage = try storage()
        let credentials = MemoryRelayCredentials()
        credentials.items["shared"] = "test-only-key"
        let network = SavedPeerNetwork(relayURL: "https://iroh.classktv.com/",
            credentialReference: "shared", directAddresses: [])
        try storage.save(DeviceSnapshot(devices: [
            PairedMac(id: "a", name: "A", endpointID: "endpoint-a", network: network),
            PairedMac(id: "b", name: "B", endpointID: "endpoint-b", network: network)
        ], selectedDeviceID: "a"))
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { [success] _, _, _, _, _, _ in success })
        let firstRefresh = await store.pair(from: invitation, repairingDeviceID: "a")
        XCTAssertTrue(firstRefresh)
        XCTAssertEqual(credentials.items.count, 2)
        XCTAssertEqual(credentials.items["shared"], "test-only-key")
        let oldReference = try XCTUnwrap(store.devices.first?.network?.credentialReference)
        let secondRefresh = await store.pair(from: invitation, repairingDeviceID: "a")
        XCTAssertTrue(secondRefresh)
        XCTAssertNil(credentials.items[oldReference])
        XCTAssertEqual(credentials.items.count, 2)
        store.removeDevice("a")
        XCTAssertEqual(credentials.items, ["shared": "test-only-key"])
        store.removeDevice("b")
        XCTAssertTrue(credentials.items.isEmpty)
    }

    func testKeychainAndPersistenceFailureLeaveNoCandidateCredential() async throws {
        for failKeychain in [true, false] {
            let storage = try storage()
            let credentials = MemoryRelayCredentials()
            credentials.failWrites = failKeychain
            let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
                networkPairingOperation: { [success] _, _, _, _, _, _ in success })
            if !failKeychain {
                // Introduce a save-only failure after loading the valid empty store.
                try FileManager.default.createDirectory(at: storage.currentURL, withIntermediateDirectories: true)
            }
            let ok = await store.pair(from: invitation)
            XCTAssertFalse(ok)
            XCTAssertTrue(credentials.items.isEmpty)
            XCTAssertTrue(store.devices.isEmpty)
            XCTAssertNil(store.pairingSuccessID)
        }
    }

    func testSharedOriginConflictNeverAttemptsPairOrChangesExistingKey() async throws {
        let storage = try storage()
        let credentials = MemoryRelayCredentials()
        credentials.items["existing"] = "working-key"
        let saved = SavedPeerNetwork(relayURL: "https://iroh.classktv.com/", credentialReference: "existing", directAddresses: [])
        try storage.save(DeviceSnapshot(devices: [PairedMac(id: "a", name: "A", endpointID: "endpoint-a", network: saved)], selectedDeviceID: "a"))
        var attempts = 0
        let store = AppStore(storage: storage, autoConnect: false, credentials: credentials,
            networkPairingOperation: { [success] _, _, _, _, _, _ in attempts += 1; return success })
        let ok = await store.pair(from: invitation)
        XCTAssertFalse(ok)
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(credentials.items, ["existing": "working-key"])
        XCTAssertEqual(store.devices.first?.network, saved)
    }
}

@MainActor
private final class MemoryRelayCredentials: RelayCredentialStore {
    var items: [String: String] = [:]
    var failWrites = false
    func read(_ reference: String) throws -> String? { items[reference] }
    func write(_ value: String, reference: String) throws {
        if failWrites { throw RelayStorageError.keychain }
        items[reference] = value
    }
    func remove(_ reference: String) throws { items.removeValue(forKey: reference) }
}

@MainActor
private final class PathTransport: DeviceTransport {
    var path = "relay"
    func connect() async -> ConnectionState { .connected }
    func reconnect() async -> ConnectionState { .connected }
    func disconnect() async {}
    func ping() async throws {}
    func pathKind() async -> String { path }
    func listAgents() async throws -> [AgentInfo] { [] }
    func listAgentProjects(agentId: String) async throws -> [MacProject] { [] }
}

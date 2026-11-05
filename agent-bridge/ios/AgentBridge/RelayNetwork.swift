import Foundation
import Security

/// Public reconnect metadata. Access keys exist only in Keychain and transient invitations.
struct SavedPeerNetwork: Codable, Equatable {
    var relayURL: String?
    var credentialReference: String?
    var directAddresses: [String]
}

struct PairInvitation: Decodable {
    var version: Int?
    var token: String
    var sessionID: String?
    var endpointID: String?
    var deviceName: String?
    var pairURLs: [String]?
    var network: InvitationNetwork?
    enum CodingKeys: String, CodingKey {
        case version, token, network
        case sessionID = "session_id", endpointID = "endpoint_id", deviceName = "device_name", pairURLs = "pair_urls"
    }
    static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 16_384 else { throw RelayStorageError.invalidInvitation }
        let value = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        guard (value.version == nil || value.version == 1), !value.token.isEmpty,
              value.token.utf8.count <= 4096, (value.pairURLs?.count ?? 0) <= 16 else {
            throw RelayStorageError.invalidInvitation
        }
        return value
    }
}

struct InvitationNetwork: Decodable {
    var relayURL: String?
    var relayAccessKey: String?
    var directAddresses: [String]?
    enum CodingKeys: String, CodingKey {
        case relayURL = "relay_url", relayAccessKey = "relay_access_key", directAddresses = "direct_addresses"
    }
    func validated() throws -> PeerNetworkConfig {
        try validatePeerNetwork(network: PeerNetworkConfig(relayUrl: relayURL,
            relayAccessKey: relayAccessKey, directAddresses: directAddresses ?? []))
    }
}

enum RelayStorageError: Error { case keychain, missingCredential, conflict, invalidInvitation }

@MainActor
protocol RelayCredentialStore {
    func read(_ reference: String) throws -> String?
    func write(_ value: String, reference: String) throws
    func remove(_ reference: String) throws
}

struct KeychainRelayCredentials: RelayCredentialStore {
    private func query(_ reference: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.agentbridge.ios.private-relay",
         kSecAttrAccount as String: reference]
    }
    func read(_ reference: String) throws -> String? {
        var attributes = query(reference)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw RelayStorageError.keychain }
        return value
    }
    func write(_ value: String, reference: String) throws {
        var attributes = query(reference)
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        // References are unique staged items: never replace a working credential.
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw RelayStorageError.keychain }
    }
    func remove(_ reference: String) throws {
        let status = SecItemDelete(query(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayStorageError.keychain }
    }
}

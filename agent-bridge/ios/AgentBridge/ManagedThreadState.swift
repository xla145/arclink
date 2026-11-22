import Foundation

/// Public Thread projections only; no provider-native protocol is interpreted here.
enum ManagedThreadState {
    struct ProviderSwitch: Codable, Equatable {
        var command: String
        var threadId: String
        var providerId: String
        var model: String?
        var revision: String
    }
    enum Failure: Error { case malformed, resync, unsupported }

    static func provider(_ message: ManagedMessage) -> String? {
        content(message)["provider_id"] as? String
    }
    static func switchMarker(_ message: ManagedMessage) -> (from: String, to: String, model: String?)? {
        let value = content(message)
        guard message.role == "system", value["type"] as? String == "provider_switch",
              let from = value["from_provider_id"] as? String, let to = value["to_provider_id"] as? String else { return nil }
        return (from, to, value["model"] as? String)
    }
    static func text(_ message: ManagedMessage) -> String {
        guard let data = message.contentJson.data(using: .utf8),
              let content = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "消息格式无法读取" }
        return content["text"] as? String ?? ""
    }
    static func content(_ message: ManagedMessage) -> [String: Any] {
        guard let data = message.contentJson.data(using: .utf8) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    static func apply(_ replay: ManagedThreadReplay, to snapshot: ManagedThreadSnapshot) throws -> ManagedThreadSnapshot {
        guard replay.environmentId == snapshot.environmentId, replay.threadId == snapshot.thread.id,
              let cursor = UInt64(snapshot.sequence), let next = UInt64(replay.sequence), next >= cursor else { throw Failure.resync }
        var result = snapshot
        var previous = cursor
        for event in replay.events {
            guard let sequence = UInt64(event.sequence) else { throw Failure.malformed }
            if sequence <= cursor { continue }
            guard sequence <= next, sequence > previous else { throw Failure.malformed }
            previous = sequence
            guard event.schemaVersion == 1 else { throw Failure.unsupported }
            guard let data = event.payloadJson.data(using: .utf8), let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
            switch event.eventType {
            case "message.created", "message.updated":
                let content = payload["content"] ?? [:]
                let encoded = try JSONSerialization.data(withJSONObject: content, options: [.sortedKeys, .fragmentsAllowed])
                let value = ManagedMessage(id: try string(payload, "id"), threadId: try string(payload, "thread_id"), runId: payload["run_id"] as? String, clientMessageId: payload["client_message_id"] as? String, role: try string(payload, "role"), contentJson: String(decoding: encoded, as: UTF8.self), revision: try string(payload, "revision"))
                if let old = result.messages.first(where: { $0.id == value.id }), try revision(old.revision) >= revision(value.revision) { continue }
                result.messages = merge(result.messages, value, key: \.id)
            case "thread.updated":
                let value = ManagedThread(id: try string(payload, "id"), projectId: try string(payload, "project_id"), providerId: try string(payload, "provider_id"), model: payload["model"] as? String, title: try string(payload, "title"), cwd: try string(payload, "cwd"), status: try string(payload, "status"), revision: try string(payload, "revision"), createdAt: try string(payload, "created_at"), updatedAt: try string(payload, "updated_at"))
                if try revision(value.revision) > revision(result.thread.revision) { result.thread = value }
            case "run.queued", "run.updated":
                let value = ManagedRun(id: try string(payload, "id"), threadId: try string(payload, "thread_id"), status: try string(payload, "status"), revision: try string(payload, "revision"))
                if let old = result.runs.first(where: { $0.id == value.id }), try revision(old.revision) >= revision(value.revision) { continue }
                result.runs = merge(result.runs, value, key: \.id)
            case "approval.created", "approval.updated":
                let value = ManagedApproval(id: try string(payload, "id"), runId: try string(payload, "run_id"), state: try string(payload, "state"), kind: try string(payload, "kind"), target: try string(payload, "target"), detail: try string(payload, "detail"))
                result.approvals = merge(result.approvals, value, key: \.id)
            default: break
            }
        }
        result.sequence = replay.sequence
        return result
    }
    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw Failure.malformed }; return value
    }
    private static func revision(_ value: String) throws -> UInt64 { guard let number = UInt64(value), String(number) == value else { throw Failure.malformed }; return number }
    private static func merge<T>(_ rows: [T], _ value: T, key: KeyPath<T, String>) -> [T] {
        var rows = rows
        if let index = rows.firstIndex(where: { $0[keyPath: key] == value[keyPath: key] }) { rows[index] = value } else { rows.append(value) }
        return rows
    }
    private static func url(device: String, thread: String) -> URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        // Both IDs originate locally or as opaque server IDs. Encode the key so
        // no provider-controlled path component reaches the filesystem.
        let key = Data("\(device)/\(thread)".utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("managed-v2-\(key).json")
    }
    private struct Cache: Codable { var version: Int; var bytes: Data }
    static func save(_ snapshot: ManagedThreadSnapshot, device: String) throws {
        guard let url = url(device: device, thread: snapshot.thread.id) else { return }
        var bytes: [UInt8] = []
        FfiConverterTypeManagedThreadSnapshot.write(snapshot, into: &bytes)
        guard bytes.count < 2 * 1024 * 1024 else { return }
        try JSONEncoder().encode(Cache(version: 2, bytes: Data(bytes))).write(to: url, options: .atomic)
    }
    private static func pendingURL(device: String, thread: String) -> URL? {
        guard let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = directory.appendingPathComponent("AgentBridge", isDirectory: true)
        let key = Data("\(device)/\(thread)".utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent("managed-provider-switch-\(key).json")
    }
    static func saveProviderSwitch(_ value: ProviderSwitch, device: String) throws {
        guard let url = pendingURL(device: device, thread: value.threadId) else { throw Failure.malformed }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
    static func loadProviderSwitch(device: String, thread: String) throws -> ProviderSwitch? {
        guard let url = pendingURL(device: device, thread: thread) else { throw Failure.malformed }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(ProviderSwitch.self, from: Data(contentsOf: url))
        guard value.threadId == thread, ["claude", "codex"].contains(value.providerId), !value.command.isEmpty, UInt64(value.revision).map({ String($0) == value.revision }) == true else { throw Failure.malformed }
        return value
    }
    static func clearProviderSwitch(device: String, thread: String) throws {
        if let url = pendingURL(device: device, thread: thread), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    static func load(device: String, thread: String) -> ManagedThreadSnapshot? {
        guard let url = url(device: device, thread: thread), let data = try? Data(contentsOf: url), data.count < 3 * 1024 * 1024,
              let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.version == 2 else { return nil }
        var buffer = (data: cache.bytes, offset: 0)
        guard let snapshot = try? FfiConverterTypeManagedThreadSnapshot.read(from: &buffer), snapshot.thread.id == thread else { return nil }
        return snapshot
    }
}

import Foundation

struct ChatExecutionStep: Codable, Hashable {
    let id: String
    var failed: Bool?
    var completed: Bool
    var title: String? = nil
    var input: String? = nil
    var output: String? = nil

    static func native(_ item: [String: Any], completed: Bool) -> Self? {
        guard let id = item["id"] as? String,
              let type = item["type"] as? String,
              ["commandExecution", "fileChange", "mcpToolCall", "dynamicToolCall", "webSearch"].contains(type) else { return nil }
        var failed: Bool?
        if completed {
            let status = item["status"] as? String
            if ["failed", "declined", "cancelled"].contains(status) { failed = true }
            else if let code = item["exitCode"] as? Int { failed = code != 0 }
            else if let success = item["success"] as? Bool { failed = !success }
            else if let error = item["error"], !(error is NSNull) { failed = true }
            else if let result = item["result"] as? [String: Any], let isError = result["isError"] as? Bool { failed = isError }
            else if status == "completed" { failed = false }
        }
        func json(_ value: Any?) -> String? {
            guard let value, !(value is NSNull) else { return nil }
            if let text = value as? String { return text }
            guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
                  let text = String(data: data, encoding: .utf8) else { return nil }
            return text
        }
        let title = ["commandExecution": "执行命令", "fileChange": "修改文件", "mcpToolCall": "工具调用", "dynamicToolCall": "工具调用", "webSearch": "搜索网页"][type]
        let input = json(item["command"] ?? item["arguments"] ?? item["changes"] ?? item["action"])
        let output = json(item["aggregatedOutput"] ?? item["result"] ?? item["contentItems"] ?? item["error"])
        return Self(id: id, failed: failed, completed: completed, title: title, input: input, output: output)
    }
}

struct ChatTurnMetrics: Codable, Hashable {
    let turnID: String
    var startedAt: Date?
    var completedAt: Date?
    var finished = false
    var steps: [ChatExecutionStep] = []

    mutating func record(_ detail: ChatExecutionStep) {
        let step = ChatExecutionStep(id: detail.id, failed: detail.failed, completed: detail.completed)
        if let index = steps.firstIndex(where: { $0.id == step.id }) {
            // Replayed starts cannot erase a terminal result.
            if !steps[index].completed { steps[index] = step }
        } else { steps.append(step) }
    }
}

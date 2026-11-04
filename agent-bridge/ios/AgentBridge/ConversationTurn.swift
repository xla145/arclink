import Foundation

/// A display projection only: native message identities and stored content stay intact.
struct ConversationTurn: Identifiable {
    let id: String
    var isUser: Bool
    var text: String
    var time: String
    var images: [Data] = []
    var steps: [MessageStep] = []
    var summary = ConversationSummary()
    var metricsText: String { summary.metricsText }

    static func live(_ messages: [ChatMessage]) -> [Self] {
        let finalIDs = finalMessageIDs(messages.map {
            SourceItem(id: $0.id, isUser: $0.isUser, isAssistant: $0.executionStep == nil && (!$0.text.isEmpty || !$0.images.isEmpty), phase: $0.assistantPhase,
                       isRunning: $0.turnMetrics.map { !$0.finished } ?? false)
        })
        var turns = group(messages.map { message in
            var steps: [MessageStep] = []
            if !message.isUser {
                if let execution = message.executionStep {
                    steps.append(MessageStep(id: "\(message.id)-execution", title: execution.title ?? "工具调用",
                        summary: MessageStep.preview(execution.input ?? execution.output ?? "执行中"), input: execution.input, output: execution.output, completed: execution.completed, failed: execution.failed))
                }
                if let summary = message.thinkingSummary, !summary.isEmpty {
                    steps.append(MessageStep(id: "\(message.id)-summary", title: "思考摘要", summary: MessageStep.preview(summary), output: summary, isSummary: true))
                }
                if let tool = message.toolOutput, !tool.isEmpty {
                    steps.append(MessageStep(id: "\(message.id)-tool", title: "工具结果", summary: MessageStep.preview(tool), output: tool))
                }
                if !finalIDs.contains(message.id), !message.text.isEmpty || !message.images.isEmpty {
                    steps.append(MessageStep(id: "\(message.id)-commentary", title: "过程说明", summary: MessageStep.preview(message.text), output: message.text,
                        isCommentary: true, images: message.images))
                }
            }
            let body = message.isUser || finalIDs.contains(message.id)
            return Self(id: message.id, isUser: message.isUser, text: body ? message.text : "",
                        time: message.time, images: body ? message.images : [], steps: steps)
        })
        let metricsByUser = Dictionary(uniqueKeysWithValues: messages.filter(\.isUser).map { ($0.id, $0.turnMetrics) })
        var metrics: ChatTurnMetrics?
        for index in turns.indices {
            if turns[index].isUser { metrics = metricsByUser[turns[index].id] ?? nil }
            else if let metrics {
                let elapsed = duration(start: metrics.startedAt, end: metrics.completedAt)
                let count = metrics.startedAt != nil || !metrics.steps.isEmpty ? metrics.steps.count : nil
                turns[index].summary = ConversationSummary(elapsed: elapsed,
                    isRunning: !metrics.finished && elapsed == nil, executionCount: count,
                    executionIsLowerBound: metrics.startedAt == nil,
                    outcomes: count == nil ? nil : metrics.steps.map(\.failed))
            }
        }
        return turns
    }

    @MainActor static func history(_ messages: [MacMessage], formatTime: (String?) -> String) -> [Self] {
        let steps = MessageStep.history(messages)
        let finalIDs = finalMessageIDs(messages.enumerated().map { index, message in
            SourceItem(id: "history-message-\(index)", isUser: message.role == "user", isAssistant: message.role == "assistant",
                       phase: message.assistantPhase, isRunning: false)
        })
        var turns = group(messages.enumerated().compactMap { index, message in
            let id = "history-message-\(index)"
            if let step = steps[index] {
                return Self(id: id, isUser: false, text: "", time: formatTime(message.timestamp), steps: [step])
            }
            guard message.role == "user" || message.role == "assistant" else { return nil }
            if message.role == "assistant", !finalIDs.contains(id) {
                let commentary = MessageStep(id: "history-commentary-\(index)", title: "过程说明", summary: MessageStep.preview(message.text), output: message.text, isCommentary: true)
                return Self(id: id, isUser: false, text: "", time: formatTime(message.timestamp), steps: [commentary])
            }
            return Self(id: id, isUser: message.role == "user", text: message.text,
                        time: formatTime(message.timestamp))
        })
        var userIndex: Int?
        for index in turns.indices {
            guard let sourceIndex = Int(turns[index].id.replacingOccurrences(of: "history-message-", with: "")) else { continue }
            if turns[index].isUser { userIndex = sourceIndex; continue }
            let endIndex = index + 1 < turns.count
                ? Int(turns[index + 1].id.replacingOccurrences(of: "history-message-", with: "")) ?? messages.count
                : messages.count
            let records = Array(messages[(userIndex ?? sourceIndex)..<endIndex])
            let dates = records.compactMap { $0.timestamp.flatMap(AppStore.parseRFC3339) }
            let ordered = zip(dates, dates.dropFirst()).allSatisfy { $0 <= $1 }
            let start = userIndex == nil ? nil : records.first?.timestamp.flatMap(AppStore.parseRFC3339)
            let end = records.last?.timestamp.flatMap(AppStore.parseRFC3339)
            let elapsed = ordered ? duration(start: start, end: end) : nil
            var countedCalls = Set<String>()
            let executionSteps = turns[index].steps.filter { step in
                guard step.isExecution else { return false }
                guard let stepIndex = Int(step.id.replacingOccurrences(of: "history-step-", with: "")),
                      let call = messages[stepIndex].toolCallId, !call.isEmpty else { return true }
                return countedCalls.insert(call).inserted
            }
            let outcomes: [Bool?] = executionSteps.map { step in
                guard let stepIndex = Int(step.id.replacingOccurrences(of: "history-step-", with: "")) else { return nil }
                let message = messages[stepIndex]
                if ["input", "output"].contains(message.toolPhase ?? ""), let call = message.toolCallId {
                    let results = records.filter { $0.toolCallId == call && $0.toolPhase == "output" }
                    if results.contains(where: { $0.toolFailed == true }) { return true }
                    if results.contains(where: { $0.toolFailed == false }) { return false }
                    return nil
                }
                return message.toolFailed
            }
            turns[index].summary = ConversationSummary(elapsed: elapsed, executionCount: outcomes.count, outcomes: outcomes)
        }
        return turns
    }

    private struct SourceItem {
        let id: String
        let isUser: Bool
        let isAssistant: Bool
        let phase: String?
        let isRunning: Bool
    }

    /// Prefer explicit native phases. Legacy completed turns keep their last
    /// whole assistant item as the result; all earlier content stays in steps.
    private static func finalMessageIDs(_ items: [SourceItem]) -> Set<String> {
        var result = Set<String>()
        var candidates: [SourceItem] = []
        var running = false
        func flush() {
            let explicit = candidates.filter { ["final_answer", "final"].contains($0.phase ?? "") }
            if !explicit.isEmpty { result.formUnion(explicit.map(\.id)) }
            else if !running, let last = candidates.last(where: { $0.phase != "commentary" }) { result.insert(last.id) }
        }
        for item in items {
            if item.isUser {
                flush()
                candidates = []
                running = item.isRunning
            } else if item.isAssistant { candidates.append(item) }
        }
        flush()
        return result
    }

    private static func duration(start: Date?, end: Date?) -> String? {
        guard let start, let end, end >= start else { return nil }
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite else { return nil }
        let rounded = seconds.rounded()
        return seconds < 59.95 ? String(format: "%.1f 秒", seconds) : String(format: "%.0f 分 %.0f 秒", floor(rounded / 60), rounded.truncatingRemainder(dividingBy: 60))
    }

    /// A real user message is the boundary, including consecutive/image-only users.
    /// Keep the first source ID stable as later native items or deltas arrive.
    private static func group(_ items: [Self]) -> [Self] {
        var result: [Self] = []
        for item in items {
            if !item.isUser, let last = result.indices.last, !result[last].isUser {
                if !item.text.isEmpty {
                    if !result[last].text.isEmpty { result[last].text += "\n\n" }
                    result[last].text += item.text
                }
                if result[last].time.isEmpty { result[last].time = item.time }
                result[last].images.append(contentsOf: item.images)
                result[last].steps.append(contentsOf: item.steps)
            } else {
                result.append(item)
            }
        }
        return result
    }
}

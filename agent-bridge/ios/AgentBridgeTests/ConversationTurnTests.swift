import XCTest
@testable import AgentBridge

@MainActor
final class ConversationTurnTests: XCTestCase {
    func testReadingEarlierContentDoesNotFollowGrowthAndCanReturnToLatest() {
        var state = ChatScrollFollowState()
        state.observe(ChatScrollPosition(top: -900, bottom: 600), viewport: 600)
        XCTAssertTrue(state.followsLatest)
        // VoiceOver or other non-touch scroll toward older messages.
        state.observe(ChatScrollPosition(top: -300, bottom: 1200), viewport: 600)
        XCTAssertFalse(state.followsLatest)
        // Output appended below the reader must not restore following.
        state.observe(ChatScrollPosition(top: -300, bottom: 1800), viewport: 600)
        XCTAssertFalse(state.followsLatest)
        state.observe(ChatScrollPosition(top: -1500, bottom: 600), viewport: 600)
        XCTAssertTrue(state.followsLatest)
        state.observe(ChatScrollPosition(top: -1500, bottom: 700), viewport: 600)
        XCTAssertTrue(state.followsLatest, "Content growth alone keeps following intent")
    }

    func testLiveStepIdentityResolvesLatestInputOutputAndOutcome() throws {
        var message = ChatMessage(id: "native-row", sessionId: "s", isUser: false, text: "", imageData: nil, time: "")
        message.executionStep = ChatExecutionStep(id: "call", completed: false, title: "执行命令", input: "swift test")
        let selected = try XCTUnwrap(ConversationTurn.live([message]).first?.steps.first)
        XCTAssertEqual(selected.statusLabel, "执行中")
        XCTAssertNil(selected.output)
        message.executionStep?.completed = true
        message.executionStep?.failed = true
        message.executionStep?.output = "Test failed: expected value"
        let latest = try XCTUnwrap(ConversationTurn.live([message]).first?.steps.first { $0.id == selected.id })
        XCTAssertEqual(latest.input, "swift test")
        XCTAssertEqual(latest.output, "Test failed: expected value")
        XCTAssertEqual(latest.statusLabel, "执行失败")
        XCTAssertEqual(selected.statusLabel, "执行中", "A captured snapshot is stale; the detail must resolve identity again")
    }

    func testHistoricalStepOutcomesPairByCallIDWithoutInferringMissingSuccess() throws {
        let records = [
            history("user", "first"),
            MacMessage(role: "tool", text: "input A", timestamp: nil, toolCallId: "a", toolName: "tool A", toolPhase: "input", toolFailed: nil, assistantPhase: nil),
            MacMessage(role: "tool", text: "input B", timestamp: nil, toolCallId: "b", toolName: "tool B", toolPhase: "input", toolFailed: nil, assistantPhase: nil),
            MacMessage(role: "tool", text: "output B", timestamp: nil, toolCallId: "b", toolName: nil, toolPhase: "output", toolFailed: false, assistantPhase: nil),
            MacMessage(role: "tool", text: "output A", timestamp: nil, toolCallId: "a", toolName: nil, toolPhase: "output", toolFailed: true, assistantPhase: nil),
            history("user", "second"),
            MacMessage(role: "tool", text: "new input A", timestamp: nil, toolCallId: "a", toolName: nil, toolPhase: "input", toolFailed: nil, assistantPhase: nil),
            history("tool", "success in prose is not evidence")
        ]
        let steps = MessageStep.history(records)
        XCTAssertEqual(steps[1]?.failed, true)
        XCTAssertEqual(steps[2]?.failed, false)
        XCTAssertEqual(steps[1]?.completed, true)
        XCTAssertNil(steps[6]?.output)
        XCTAssertNil(steps[6]?.failed)
        XCTAssertNil(steps[6]?.completed)
        XCTAssertEqual(steps[6]?.statusLabel, "状态未知")
        XCTAssertEqual(steps[7]?.statusLabel, "状态未知")
        XCTAssertNil(steps[3], "Paired output must not create a duplicate step")
    }

    func testAuthoritativePhasesKeepFinalPartsAndOriginalStepOrder() {
        var commentary = history("assistant", "start")
        commentary.assistantPhase = "commentary"
        var final = history("assistant", "final A")
        final.assistantPhase = "final_answer"
        var finalB = history("assistant", "final B")
        finalB.assistantPhase = "final_answer"
        let records = [history("user", "request"), commentary, history("tool", "tool"),
                       history("summary", "public summary"), final, finalB, commentary]
        let turn = ConversationTurn.history(records) { _ in "" }[1]
        XCTAssertEqual(turn.text, "final A\n\nfinal B")
        XCTAssertEqual(turn.steps.map(\.output), ["start", "tool", "public summary", "start"])
        XCTAssertEqual(turn.steps.map(\.isExecution), [false, true, false, false])
        XCTAssertEqual(ConversationTurn.history([records[0], commentary]) { _ in "" }[1].text, "")
        XCTAssertEqual(records[1].text, "start")
    }

    func testUnphasedRunningLiveTextStaysInStepsUntilFinished() {
        var user = ChatMessage(id: "u", sessionId: "s", isUser: true, text: "request", imageData: nil, time: "")
        user.turnMetrics = ChatTurnMetrics(turnID: "t", startedAt: Date())
        let answer = ChatMessage(id: "a", sessionId: "s", isUser: false, text: "partial", imageData: nil, time: "")
        XCTAssertEqual(ConversationTurn.live([user, answer])[1].text, "")
        XCTAssertEqual(ConversationTurn.live([user, answer])[1].steps[0].output, "partial")
        user.turnMetrics?.finished = true
        XCTAssertEqual(ConversationTurn.live([user, answer])[1].text, "partial")
        var explicit = answer
        explicit.assistantPhase = "commentary"
        XCTAssertEqual(ConversationTurn.live([user, explicit])[1].text, "")
    }

    func testHistoricalMetricsUseTimestampIntervalAndStructuredFailureOnly() {
        let messages = [
            MacMessage(role: "user", text: "request", timestamp: "2026-11-01T00:00:00Z", toolCallId: nil, toolName: nil, toolPhase: nil, toolFailed: nil, assistantPhase: nil),
            MacMessage(role: "tool", text: "error is only prose", timestamp: "2026-11-01T00:00:01Z", toolCallId: "a", toolName: nil, toolPhase: "output", toolFailed: false, assistantPhase: nil),
            MacMessage(role: "tool", text: "", timestamp: "2026-11-01T00:00:02Z", toolCallId: "b", toolName: nil, toolPhase: "output", toolFailed: true, assistantPhase: nil),
            MacMessage(role: "tool", text: "unknown", timestamp: "2026-11-01T00:00:03Z", toolCallId: nil, toolName: nil, toolPhase: nil, toolFailed: nil, assistantPhase: nil),
            MacMessage(role: "assistant", text: "done", timestamp: "2026-11-01T00:01:59.8Z", toolCallId: nil, toolName: nil, toolPhase: nil, toolFailed: nil, assistantPhase: nil)
        ]
        let turn = ConversationTurn.history(messages) { _ in "" }[1]
        XCTAssertEqual(turn.metricsText, "耗时约 2 分 0 秒 · 执行步骤 3 · 失败 1（1 项结果未知）")
        var reversed = messages
        reversed[4].timestamp = "2026-10-31T23:59:59Z"
        XCTAssertTrue(ConversationTurn.history(reversed) { _ in "" }[1].metricsText.hasPrefix("耗时 —"))
    }

    func testReplayedHistoricalCallCountsOnceAndTerminalResultSettlesUnknown() {
        var result = history("tool", "done", call: "a", phase: "output")
        result.toolFailed = false
        let turns = ConversationTurn.history([
            history("user", "one"), history("tool", "input", call: "a", phase: "input"),
            history("tool", "input", call: "a", phase: "input"),
            history("tool", "pending", call: "a", phase: "output"), result,
            history("assistant", "done")
        ]) { _ in "" }
        XCTAssertEqual(turns[1].steps.count, 2)
        XCTAssertEqual(turns[1].metricsText, "耗时 — · 执行步骤 1 · 失败 0")
        result.toolFailed = true
        let unmatched = ConversationTurn.history([
            history("user", "request"), history("tool", "pending", call: "a", phase: "output"), result
        ]) { _ in "" }
        XCTAssertEqual(unmatched[1].metricsText, "耗时 — · 执行步骤 1 · 失败 1")
    }

    func testRepeatedCallIDsCannotPairAcrossUserBoundaries() {
        let messages = [history("user", "one"), history("tool", "input", call: "same", phase: "input"),
                        history("user", "two"), history("tool", "result", call: "same", phase: "output")]
        let turns = ConversationTurn.history(messages) { _ in "" }
        XCTAssertNil(turns[1].steps[0].output)
        XCTAssertEqual(turns[3].steps[0].output, "result")
    }

    func testMetricsPreserveTerminalOutcomeAndLegacyDecoding() throws {
        var metrics = ChatTurnMetrics(turnID: "t", startedAt: Date(timeIntervalSince1970: 0))
        metrics.record(ChatExecutionStep(id: "a", failed: nil, completed: false))
        metrics.record(ChatExecutionStep(id: "a", failed: true, completed: true))
        metrics.record(ChatExecutionStep(id: "a", failed: nil, completed: false))
        metrics.record(ChatExecutionStep(id: "a", failed: true, completed: true))
        XCTAssertEqual(metrics.steps.count, 1)
        XCTAssertEqual(metrics.steps[0].failed, true)
        let legacy = Data(#"{"id":"u","sessionId":"s","isUser":true,"text":"hi","time":"12:00"}"#.utf8)
        let message = try JSONDecoder().decode(ChatMessage.self, from: legacy)
        XCTAssertNil(message.turnMetrics)
        var user = message
        user.turnMetrics = metrics
        XCTAssertEqual(try JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(user)).turnMetrics, metrics)
    }

    private func history(_ role: String, _ text: String, call: String? = nil, phase: String? = nil) -> MacMessage {
        MacMessage(role: role, text: text, timestamp: nil, toolCallId: call, toolName: nil, toolPhase: phase, toolFailed: nil, assistantPhase: nil)
    }

    func testHistoryMergesCommentaryFinalAndCorrelatedStepsWithoutDeduplication() {
        let messages = [history("user", "request"), history("assistant", "same"),
                        history("tool", "input", call: "a", phase: "input"),
                        history("summary", "public summary"), history("assistant", "same"),
                        history("tool", "output", call: "a", phase: "output")]
        let turns = ConversationTurn.history(messages) { _ in "" }
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].text, "same")
        XCTAssertEqual(turns[1].steps[0].output, "same")
        XCTAssertTrue(turns[1].steps[0].isCommentary)
        XCTAssertEqual(turns[1].steps.count, 3)
        XCTAssertEqual(turns[1].steps[1].input, "input")
        XCTAssertEqual(turns[1].steps[1].output, "output")
        XCTAssertTrue(turns[1].steps[2].isSummary)
        XCTAssertEqual(messages[1].text, "same")
        XCTAssertEqual(messages.count, 6)
    }

    func testUserBoundariesAndLeadingTrailingStepsAreRetained() {
        let turns = ConversationTurn.history([
            history("tool", "leading"), history("assistant", "intro"),
            history("user", "one"), history("user", "two"),
            history("summary", "trailing")
        ]) { _ in "" }
        XCTAssertEqual(turns.map(\.isUser), [false, true, true, false])
        XCTAssertEqual(turns[0].text, "intro")
        XCTAssertEqual(turns[0].steps[0].output, "leading")
        XCTAssertEqual(turns[3].steps[0].output, "trailing")
    }

    func testLiveStreamingKeepsStableCardIdentityAndImagesAndDistinctStepIDs() {
        func message(_ id: String, _ user: Bool, _ text: String, _ image: UInt8) -> ChatMessage {
            ChatMessage(id: id, sessionId: "s", isUser: user, text: text, imageData: Data([image]),
                        time: "12:00", thinkingSummary: "summary", toolOutput: "tool")
        }
        var messages = [message("u", true, "", 1), message("a", false, "partial", 2)]
        let first = ConversationTurn.live(messages)
        messages[1].text = "complete"
        messages.append(message("b", false, "final", 3))
        let updated = ConversationTurn.live(messages)
        XCTAssertEqual(updated.count, 2)
        XCTAssertEqual(first[1].id, updated[1].id)
        XCTAssertEqual(updated[1].text, "final")
        XCTAssertEqual(updated[1].steps.first(where: \.isCommentary)?.output, "complete")
        XCTAssertEqual(updated[0].images, [Data([1])])
        XCTAssertTrue(updated[0].steps.isEmpty)
        XCTAssertEqual(updated[1].images, [Data([3])])
        XCTAssertEqual(updated[1].steps.first(where: \.isCommentary)?.images, [Data([2])])
        XCTAssertEqual(Set(updated[1].steps.map(\.id)).count, 5)
        XCTAssertEqual(messages[1].text, "complete")
    }
}

import SwiftUI

/// Typed presentation values; missing evidence stays distinct from a recorded zero.
struct ConversationSummary {
    var elapsed: String?
    var isRunning = false
    var executionCount: Int?
    var executionIsLowerBound = false
    var failureCount: Int?
    var unknownCount = 0

    init(elapsed: String? = nil, isRunning: Bool = false, executionCount: Int? = nil,
         executionIsLowerBound: Bool = false, outcomes: [Bool?]? = nil) {
        self.elapsed = elapsed
        self.isRunning = isRunning
        self.executionCount = executionCount
        self.executionIsLowerBound = executionIsLowerBound
        if let outcomes {
            unknownCount = outcomes.filter { $0 == nil }.count
            if outcomes.isEmpty || unknownCount < outcomes.count {
                failureCount = outcomes.filter { $0 == true }.count
            }
        }
    }

    var durationValue: String { elapsed.map { "约 \($0)" } ?? (isRunning ? "进行中" : "—") }
    var stepsValue: String { executionCount.map { (executionIsLowerBound ? "至少 " : "") + String($0) } ?? "—" }
    var failuresValue: String { failureCount.map(String.init) ?? "—" }
    var metricsText: String {
        let duration = elapsed.map { "耗时约 \($0)" } ?? "耗时 \(durationValue)"
        return duration + " · 执行步骤 \(stepsValue) · 失败 \(failuresValue)"
            + (unknownCount > 0 ? "（\(unknownCount) 项结果未知）" : "")
    }
}

struct ConversationSummaryView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var summary: ConversationSummary

    private var hasAnyInfo: Bool {
        summary.isRunning || summary.elapsed != nil || (summary.executionCount ?? 0) > 0 || (summary.failureCount ?? 0) > 0
    }

    var body: some View {
        if hasAnyInfo {
            HStack(spacing: 6) {
                if summary.isRunning {
                    Circle()
                        .fill(ArcTheme.live)
                        .frame(width: 5, height: 5)
                    Text("进行中")
                } else if let elapsed = summary.elapsed {
                    Text(elapsed)
                        .monospacedDigit()
                }
                if let count = summary.executionCount, count > 0 {
                    if summary.isRunning || summary.elapsed != nil {
                        Text("·")
                    }
                    Text("\(summary.executionIsLowerBound ? "至少 " : "")\(count) 步")
                        .monospacedDigit()
                }
                if let failures = summary.failureCount, failures > 0 {
                    Text("·")
                    Text("\(failures) 失败")
                        .foregroundStyle(ArcTheme.danger)
                        .monospacedDigit()
                }
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(ArcTheme.inkFaint)
            .padding(.top, 2)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary.metricsText)
            .accessibilityIdentifier("turn-metrics")
        }
    }
}

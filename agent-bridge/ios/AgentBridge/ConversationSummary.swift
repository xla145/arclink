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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
            layout {
                metric("耗时", value: summary.durationValue, icon: "clock")
                metric("执行步骤", value: summary.stepsValue, icon: "list.bullet.rectangle")
                metric("失败", value: summary.failuresValue, icon: "exclamationmark.circle", failed: (summary.failureCount ?? 0) > 0)
            }
            if summary.unknownCount > 0 {
                Text("\(summary.unknownCount) 项结果未知")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.metricsText)
        .accessibilityIdentifier("turn-metrics")
    }

    private func metric(_ title: String, value: String, icon: String, failed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
                .foregroundStyle(failed ? Color.orange : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

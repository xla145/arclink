import ImageIO
import SwiftUI

/// Shared by local messages and Mac history, so the same Markdown has the
/// same appearance and link/image policy regardless of conversation source.
struct AgentThinkingIndicator: View {
    var agent: AgentKind
    var label: String = "正在思考"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 8) {
                AgentIcon(agent: agent, size: 15, tint: agent.tint)
                    .scaleEffect(reduceMotion ? 1.0 : (0.94 + 0.08 * sin(t * 3.0)))
                    .opacity(reduceMotion ? 1.0 : (0.78 + 0.22 * sin(t * 3.0)))

                Text(label)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(ArcTheme.inkMuted)

                HStack(spacing: 3.5) {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = sin(t * 4.2 - Double(index) * 0.85)
                        let opacity = reduceMotion ? 0.55 : (0.28 + 0.72 * max(0, phase))
                        let offsetY = reduceMotion ? 0.0 : (-2.2 * max(0, phase))
                        Circle()
                            .fill(ArcTheme.inkMuted)
                            .frame(width: 4, height: 4)
                            .opacity(opacity)
                            .offset(y: offsetY)
                    }
                }
                .padding(.top, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(ArcTheme.surfaceSunken.opacity(0.65), in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(agent.shortName) \(label)")
        .accessibilityIdentifier("agent-thinking-indicator")
    }
}

struct MacMessageText: View {
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MessageMarkdown.parse(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            MessageMarkdown.safeLink(url) ? .systemAction : .discarded
        })
    }

    @ViewBuilder
    private func blockView(_ block: MessageBlock) -> some View {
        switch block {
        case .text(let text):
            inline(text)
                .font(.subheadline)
                .foregroundStyle(ArcTheme.ink)
                .lineSpacing(5)
        case .heading(let level, let text):
            inline(text)
                .font(level < 3 ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(ArcTheme.ink)
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2).fill(ArcTheme.line).frame(width: 2.5)
                inline(text).font(.subheadline).foregroundStyle(ArcTheme.inkMuted).lineSpacing(4)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 2)
        case .list(let marker, let text, let depth, let checked):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let checked {
                    Image(systemName: checked ? "checkmark.square.fill" : "square")
                        .font(.footnote)
                        .foregroundStyle(checked ? ArcTheme.success : ArcTheme.inkMuted)
                        .accessibilityLabel(checked ? "已完成" : "未完成")
                } else {
                    Text(marker.first?.isNumber == true ? marker : "•")
                        .font(.subheadline)
                        .foregroundStyle(ArcTheme.inkMuted)
                }
                inline(text).font(.subheadline).foregroundStyle(ArcTheme.ink).lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, CGFloat(depth) * 12)
        case .code(let language, let code):
            MessageCodeBlock(language: language, code: code)
        case .table(let headers, let rows):
            table(headers: headers, rows: rows)
        case .image(let alt, let source):
            MessageInlineImage(source: source, caption: alt).id(source)
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func inline(_ text: String) -> some View {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        // Text renders HTML literally. Also strip unsupported link actions
        // from attributed runs before SwiftUI makes them interactive.
        for run in result.runs {
            if let url = run.link, !MessageMarkdown.safeLink(url) { result[run.range].link = nil }
        }
        return Text(result).textSelection(.enabled)
    }

    private func table(headers: [String], rows: [[String]]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                        inline(header).font(.caption.weight(.semibold))
                            .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
                            .padding(10)
                    }
                }
                .background(ArcTheme.surfaceSunken)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            inline(cell).font(.caption)
                                .frame(minWidth: 110, maxWidth: 220, alignment: .leading)
                                .padding(10)
                        }
                    }
                    .background(index.isMultiple(of: 2) ? Color.clear : ArcTheme.bg)
                }
            }
        }
        .background(ArcTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous).strokeBorder(ArcTheme.line))
        .accessibilityLabel("表格，可横向滚动")
    }
}

/// Only displays text supplied by a message's explicit summary/tool role.
/// No synthetic private reasoning is generated by this presentation layer.
struct MessageDisclosure: View {
    var title: String
    var text: String
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            MacMessageText(text: text)
                .font(.subheadline)
                .padding(.top, 8)
        } label: {
            Label(title, systemImage: title.contains("思考") ? "sparkle" : "terminal")
                .font(.footnote.weight(.medium))
                .foregroundStyle(ArcTheme.inkMuted)
        }
        .disclosureGroupStyle(MessageDisclosureStyle())
        .padding(12)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous).stroke(ArcTheme.line))
    }
}

/// A public transcript step; missing historical input/output stays explicit.
struct MessageStep: Identifiable {
    let id: String
    var title: String
    var summary: String
    var input: String?
    var output: String?
    var completed: Bool? = nil
    var failed: Bool? = nil
    var isSummary = false
    var isCommentary = false
    var images: [Data] = []
    var isExecution: Bool { !isSummary && !isCommentary }

    var statusLabel: String {
        if !isExecution { return isSummary ? "公开摘要" : "过程说明" }
        if failed == true { return "执行失败" }
        if completed == false { return "执行中" }
        if failed == false { return "已成功" }
        return completed == true ? "已结束 · 结果未知" : "状态未知"
    }

    var statusSymbol: String {
        if !isExecution { return "text.alignleft" }
        if failed == true { return "exclamationmark.circle" }
        if completed == false { return "clock" }
        return failed == false ? "checkmark.circle" : "questionmark.circle"
    }

    /// Pairs with `statusSymbol`; the symbol and `statusLabel` carry the meaning, not the color.
    var statusColor: Color {
        if !isExecution { return ArcTheme.inkMuted }
        if failed == true { return ArcTheme.danger }
        if completed == false { return ArcTheme.live }
        return failed == false ? ArcTheme.success : ArcTheme.inkMuted
    }

    static func preview(_ text: String) -> String {
        let line = text.prefix(512).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return String(line.prefix(120)) + (line.count > 120 ? "…" : "")
    }

    private static func toolPreview(_ text: String, title: String) -> String {
        // A native tool input is a named fenced block. Show a short supplied
        // argument/command excerpt rather than repeating the tool name.
        let lines = text.prefix(2048).split(whereSeparator: \.isNewline)
        let excerpt = lines.first { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed != title && !trimmed.hasPrefix("```")
                && !trimmed.hasPrefix("~~~") && trimmed != "{" && trimmed != "}"
        }
        return preview(excerpt.map(String.init) ?? text)
    }

    /// Correlate by native call ID, never by adjacency: parallel outputs can
    /// arrive in a different order, even across intervening assistant prose.
    static func history(_ messages: [MacMessage]) -> [Int: MessageStep] {
        var result: [Int: MessageStep] = [:]
        var start = 0
        for end in messages.indices where messages[end].role == "user" {
            result.merge(historyChunk(Array(messages[start..<end]), offset: start)) { _, new in new }
            start = end
        }
        result.merge(historyChunk(Array(messages[start...]), offset: start)) { _, new in new }
        return result
    }

    private static func historyChunk(_ messages: [MacMessage], offset: Int) -> [Int: MessageStep] {
        var inputs = Set<String>()
        var outputs: [String: String] = [:]
        var outcomes: [String: Bool] = [:]
        for message in messages where message.role == "tool" {
            guard let id = message.toolCallId, !id.isEmpty else { continue }
            if message.toolPhase == "input" { inputs.insert(id) }
            if message.toolPhase == "output" {
                if let failed = message.toolFailed { outcomes[id] = outcomes[id] == true || failed }
                let previous = outputs[id]
                outputs[id] = previous.map { $0 + "\n\n" + message.text } ?? message.text
            }
        }
        var result: [Int: MessageStep] = [:]
        for (localIndex, message) in messages.enumerated() {
            let index = offset + localIndex
            let id = "history-step-\(index)"
            if ["summary", "reasoning_summary"].contains(message.role) {
                result[index] = MessageStep(id: id, title: "思考摘要", summary: preview(message.text), output: message.text, isSummary: true)
            } else if ["tool", "tool_result"].contains(message.role) {
                if message.toolPhase == "output", let call = message.toolCallId, inputs.contains(call) { continue }
                let isInput = message.toolPhase == "input"
                let title = message.toolName ?? (isInput ? "工具调用" : "工具结果")
                result[index] = MessageStep(id: id, title: title, summary: toolPreview(message.text, title: title),
                    input: isInput ? message.text : nil,
                    output: isInput ? message.toolCallId.flatMap { outputs[$0] } : message.text,
                    completed: isInput ? (message.toolCallId.flatMap { outputs[$0] } == nil ? nil : true) : (message.toolPhase == "output" ? true : nil),
                    failed: isInput ? message.toolCallId.flatMap { outcomes[$0] } : message.toolFailed)
            }
        }
        return result
    }
}

/// Refined collapsible execution trace inspired by Claude iOS & T3 Code:
/// Whisper-light surface container separating agent work from final prose,
/// with smart command/file/commentary extraction and bounded scroll for long runs.
struct InlineStepsGroup: View {
    var steps: [MessageStep]
    @State private var expanded: Bool

    init(steps: [MessageStep]) {
        self.steps = steps
        let hasRunning = steps.contains { $0.isExecution && $0.completed == false && $0.failed != true }
        self._expanded = State(initialValue: hasRunning)
    }

    private var runningStep: MessageStep? {
        steps.last { $0.isExecution && $0.completed == false && $0.failed != true }
    }

    private var failedCount: Int {
        steps.filter { $0.failed == true }.count
    }

    private var groupIcon: String {
        let execSteps = steps.filter(\.isExecution)
        let kinds = Set((execSteps.isEmpty ? steps : execSteps).map { Self.toolCategory($0) })
        if kinds.count == 1, let only = kinds.first {
            switch only {
            case .read: return "eye"
            case .edit: return "pencil"
            case .command: return "terminal"
            case .search: return "magnifyingglass"
            case .thinking: return "sparkles"
            case .commentary: return "text.alignleft"
            case .other: return "wrench.and.screwdriver"
            }
        }
        return "wrench.and.screwdriver"
    }

    private var headerTitle: String {
        if let active = runningStep, !expanded {
            let detail = Self.extractDetail(for: active)
            if !detail.isEmpty { return "正在执行 \(detail)" }
            return "正在执行 \(active.title) · \(steps.count) 步"
        }
        var reads = 0, edits = 0, cmds = 0, searches = 0, notes = 0, others = 0
        for step in steps {
            switch Self.toolCategory(step) {
            case .read: reads += 1
            case .edit: edits += 1
            case .command: cmds += 1
            case .search: searches += 1
            case .thinking, .commentary: notes += 1
            case .other: others += 1
            }
        }
        var parts: [String] = []
        if reads > 0 { parts.append("读取 \(reads) 个文件") }
        if edits > 0 { parts.append("编辑 \(edits) 个文件") }
        if searches > 0 { parts.append("搜索 \(searches) 次") }
        if cmds > 0 { parts.append("执行 \(cmds) 条命令") }
        if others > 0 { parts.append("\(others) 项操作") }
        if parts.isEmpty {
            parts.append(notes > 0 ? "思考与说明 · \(notes) 条" : "执行 \(steps.count) 个步骤")
        }
        let summary = parts.joined(separator: "、")
        if failedCount > 0 { return "\(summary) · \(failedCount) 失败" }
        return summary
    }

    enum ToolCategory { case read, edit, command, search, thinking, commentary, other }

    static func toolCategory(_ step: MessageStep) -> ToolCategory {
        if step.isSummary { return .thinking }
        if step.isCommentary { return .commentary }
        let name = step.title.lowercased()
        if name.contains("read") || name.contains("view") || name.contains("cat") || name.contains("读取") { return .read }
        if name.contains("edit") || name.contains("write") || name.contains("patch") || name.contains("编辑") || name.contains("写入") { return .edit }
        if name.contains("bash") || name.contains("shell") || name.contains("exec") || name.contains("run") || name.contains("command") || name.contains("命令") { return .command }
        if name.contains("grep") || name.contains("find") || name.contains("search") || name.contains("glob") || name.contains("搜索") { return .search }
        return .other
    }

    /// Extract a meaningful human-readable excerpt (command, file path, or commentary text)
    /// rather than showing raw `exec`, `{`, or `过程说明`.
    static func extractDetail(for step: MessageStep) -> String {
        if step.isCommentary || step.isSummary {
            let source = step.output ?? step.summary
            return cleanLine(source)
        }
        if let raw = step.input, !raw.isEmpty {
            let unfenced = stripFences(raw)
            // Try parsing JSON tool arguments (e.g. Codex `exec` / Claude tool input)
            if unfenced.hasPrefix("{"), let data = unfenced.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let priorityKeys = ["cmd", "command", "file_path", "filePath", "path", "pattern", "query", "url", "target"]
                for key in priorityKeys {
                    if let val = obj[key] as? String, !val.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        return cleanLine(val)
                    }
                    if let arr = obj[key] as? [String], !arr.isEmpty {
                        return cleanLine(arr.joined(separator: " "))
                    }
                }
            }
            // Fallback: find first meaningful non-boilerplate line
            for line in unfenced.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "{" || trimmed == "}" || trimmed == step.title { continue }
                return cleanLine(trimmed)
            }
        }
        let fallback = cleanLine(step.summary)
        return fallback == step.title ? "" : fallback
    }

    private static func stripFences(_ text: String) -> String {
        let lines = text.prefix(4096).split(whereSeparator: \.isNewline).map(String.init)
        let filtered = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return !t.hasPrefix("```") && !t.hasPrefix("~~~")
        }
        return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanLine(_ text: String) -> String {
        let single = text.prefix(240)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(single.prefix(90)) + (single.count > 90 ? "…" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    if runningStep != nil {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.8)
                            .frame(width: 18, height: 18)
                    } else {
                        Image(systemName: groupIcon)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(ArcTheme.inkMuted)
                            .frame(width: 18, height: 18)
                    }
                    Text(headerTitle)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(ArcTheme.inkMuted)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(ArcTheme.inkFaint)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(headerTitle)
            .accessibilityValue(expanded ? "已展开" : "已收起")
            .accessibilityHint(expanded ? "点击收起执行过程" : "点击展开执行过程")
            .accessibilityIdentifier("steps-toggle")

            if expanded {
                Rectangle()
                    .fill(ArcTheme.line.opacity(0.6))
                    .frame(height: 0.5)
                    .padding(.horizontal, 12)

                let content = VStack(alignment: .leading, spacing: 2) {
                    ForEach(steps) { step in
                        InlineStepCard(step: step)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if steps.count > 8 {
                    ScrollView {
                        content
                    }
                    .frame(maxHeight: 280)
                } else {
                    content
                }
            }
        }
        .background(ArcTheme.surfaceSunken.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(ArcTheme.line.opacity(0.6), lineWidth: 0.75)
        )
    }
}

/// Compact inline step inside `InlineStepsGroup`:
/// Semantic icon badge + extracted command / filename / commentary + trailing chevron.
struct InlineStepCard: View {
    var step: MessageStep
    @State private var showDetail = false

    private var isRunning: Bool {
        step.isExecution && step.completed == false && step.failed != true
    }

    private var category: InlineStepsGroup.ToolCategory {
        InlineStepsGroup.toolCategory(step)
    }

    private var detailText: String {
        InlineStepsGroup.extractDetail(for: step)
    }

    private var isCodeStyle: Bool {
        category == .command || category == .read || category == .edit || category == .search
    }

    var body: some View {
        Button { showDetail = true } label: {
            HStack(spacing: 8) {
                stepIcon
                    .frame(width: 20, height: 20, alignment: .center)

                if category == .commentary || category == .thinking {
                    Text(detailText.isEmpty ? step.title : detailText)
                        .font(.footnote)
                        .foregroundStyle(ArcTheme.inkMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else if category == .command {
                    Text(detailText.isEmpty ? step.title : detailText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(step.failed == true ? ArcTheme.danger : ArcTheme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    HStack(spacing: 5) {
                        Text(step.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(step.failed == true ? ArcTheme.danger : ArcTheme.inkMuted)
                            .fixedSize()
                        if !detailText.isEmpty {
                            Text(detailText)
                                .font(.system(size: 12.5, design: .monospaced))
                                .foregroundStyle(ArcTheme.ink)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(ArcTheme.inkFaint.opacity(0.7))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(step.title) \(step.statusLabel)")
        .sheet(isPresented: $showDetail) {
            MessageStepDetail(step: step) { showDetail = false }
        }
    }

    @ViewBuilder
    private var stepIcon: some View {
        if isRunning {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.78)
        } else if step.failed == true {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(ArcTheme.danger)
        } else {
            let symbol = switch category {
            case .read: "eye"
            case .edit: "pencil"
            case .command: "terminal"
            case .search: "magnifyingglass"
            case .thinking: "sparkles"
            case .commentary: "text.alignleft"
            case .other: "wrench.and.screwdriver"
            }
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(ArcTheme.inkMuted)
        }
    }
}

/// First expand to lightweight summaries, then open a single step's details.
struct AgentStepsDisclosure: View {
    var steps: [MessageStep]
    @State private var expanded: Bool
    @State private var selected: StepSelection?

    private struct StepSelection: Identifiable { let id: String }

    init(steps: [MessageStep]) {
        self.steps = steps
        // ≤ 5 steps: default open so the agent's work process is immediately visible
        self._expanded = State(initialValue: steps.count <= 5)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(steps) { step in
                    Button { selected = StepSelection(id: step.id) } label: {
                        HStack(spacing: 10) {
                            stepStatusIcon(step)
                                .frame(width: 18)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(.footnote.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                                Text(step.summary).font(.caption.monospaced()).foregroundStyle(ArcTheme.inkMuted).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(ArcTheme.inkFaint)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier(step.id)
                    .accessibilityValue(step.statusLabel)
                    .accessibilityHint("查看步骤输入和输出")
                    if step.id != steps.last?.id { Rectangle().fill(ArcTheme.line).frame(height: 0.5) }
                }
            }.padding(.top, 4)
        } label: {
            Label("工具步骤 · \(steps.count) 项", systemImage: "list.bullet.rectangle")
                .font(.footnote.weight(.medium)).foregroundStyle(ArcTheme.inkMuted)
        }
        .disclosureGroupStyle(MessageDisclosureStyle())
        .padding(.horizontal, 12)
        .background(ArcTheme.surface, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous).stroke(ArcTheme.line))
        .sheet(item: $selected) { selection in
            // Resolve identity against the latest projection, not a captured step snapshot.
            MessageStepDetail(step: steps.first { $0.id == selection.id }) { selected = nil }
        }
    }

    /// Richer status icon: in-progress steps pulse, completed use filled variants.
    @ViewBuilder
    private func stepStatusIcon(_ step: MessageStep) -> some View {
        if step.completed == false && step.failed != true {
            // In-progress: pulsing dot
            Image(systemName: "circle.dotted")
                .font(.caption)
                .foregroundStyle(ArcTheme.live)
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)
        } else if step.failed == false {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ArcTheme.success)
        } else if step.failed == true {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(ArcTheme.danger)
        } else {
            Image(systemName: step.statusSymbol)
                .font(.caption)
                .foregroundStyle(step.statusColor)
        }
    }
}

struct MessageStepDetail: View {
    var step: MessageStep?
    var dismiss: () -> Void
    @State private var copiedSection: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let step {
                    LazyVStack(alignment: .leading, spacing: 22) {
                        Label(step.statusLabel, systemImage: step.statusSymbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(step.statusColor)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(ArcTheme.surfaceSunken, in: Capsule())
                            .accessibilityIdentifier("step-status")
                        if !step.isExecution {
                            detailSection(step.isSummary ? "摘要" : "过程说明", text: step.output, missing: "没有内容记录", code: false)
                            ForEach(Array(step.images.enumerated()), id: \.offset) { _, data in
                                MessageInlineImage(source: "data:image/png;base64," + data.base64EncodedString(), caption: "过程图片")
                            }
                        } else {
                            if let input = step.input, input != step.output {
                                detailSection("输入", text: input, missing: "记录未提供输入", code: true)
                            }
                            detailSection(step.input == nil ? "详情" : "输出", text: step.output,
                                          missing: step.completed == false ? "等待输出…" : "记录未提供输出", code: true)
                        }
                    }.padding(20)
                } else {
                    ContentUnavailableView("步骤已不可用", systemImage: "doc.questionmark", description: Text("这条步骤记录已不在当前对话中。"))
                }
            }
            .background(ArcTheme.bg)
            .navigationTitle(step?.title ?? "步骤详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: dismiss) } }
            .tint(ArcTheme.primary)
        }
        .presentationDragIndicator(.visible)
    }

    private func detailSection(_ title: String, text: String?, missing: String, code: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(ArcTheme.inkMuted)
                Spacer()
                if let text {
                    Button {
                        UIPasteboard.general.string = text
                        copiedSection = title
                    } label: {
                        Label(copiedSection == title ? "已复制" : "复制", systemImage: copiedSection == title ? "checkmark" : "doc.on.doc")
                            .font(.caption).frame(minHeight: 44)
                    }
                    .accessibilityLabel("复制\(title)")
                }
            }
            Group {
                if let text {
                    if code {
                        Text(text.isEmpty ? "（空内容）" : text)
                            .font(.system(.footnote, design: .monospaced)).foregroundStyle(ArcTheme.codeInk)
                            .textSelection(.enabled)
                    } else { MacMessageText(text: text).font(.subheadline).textSelection(.enabled) }
                } else { Text(missing).font(.subheadline).foregroundStyle(code ? ArcTheme.codeMuted : ArcTheme.inkMuted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(code ? ArcTheme.codeBg : ArcTheme.surface,
                        in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
            .overlay {
                if !code { RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous).stroke(ArcTheme.line) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Use an explicit full-width header and create the detail tree only after a
/// tap. Imported turns can contain many large tool outputs, unlike local rows.
private struct MessageDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    configuration.label
                    Spacer(minLength: 8)
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "已展开" : "已收起")
            .accessibilityHint(configuration.isExpanded ? "收起详情" : "展开详情")
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct MessageCodeBlock: View {
    var language: String?
    var code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "text").lineLimit(1)
                Spacer()
                Button {
                    UIPasteboard.general.string = code
                    copied = true
                } label: {
                    Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copied ? "已复制代码" : "复制代码")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(ArcTheme.codeMuted)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) }
            ScrollView([.horizontal, .vertical]) {
                Text(code)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(ArcTheme.codeInk)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(12)
            }
            .frame(height: min(360, max(45, CGFloat(code.components(separatedBy: "\n").count) * 18 + 24)))
        }
        .background(ArcTheme.codeBg, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
        .task(id: copied) {
            if copied {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                copied = false
            }
        }
    }
}

private struct MessageImagePreview: Identifiable {
    let id = UUID()
    let image: UIImage
    let caption: String
}

private struct MessageInlineImage: View {
    var source: String
    var caption: String
    @State private var image: UIImage?
    @State private var requested = false
    @State private var loading = false
    @State private var failed = false
    @State private var attempt = 0
    @State private var preview: MessageImagePreview?

    private var label: String { caption.isEmpty ? "图片" : caption }
    private var remoteURL: URL? { MessageMarkdown.imageURL(source) }

    /// Captions that are just generic labels (image, screenshot, file names)
    /// add noise when the image is already visible — suppress them.
    private static func isGenericCaption(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        if ["image", "img", "图片", "screenshot", "photo", "picture"].contains(lower) { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("data:") { return true }
        let ext = ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif", "bmp"]
        return ext.contains(where: { lower.hasSuffix(".\($0)") })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Button { preview = MessageImagePreview(image: image, caption: label) } label: {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("放大 \(label)")
            } else if loading {
                ProgressView("正在加载图片…").font(.caption).frame(maxWidth: .infinity).padding(20)
            } else if remoteURL != nil {
                Button {
                    requested = true; attempt += 1
                } label: {
                    Label(failed ? "图片加载失败 · 点击重试" : "外部图片 · 点击加载", systemImage: failed ? "arrow.clockwise" : "photo")
                        .font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 70)
                        .foregroundStyle(ArcTheme.inkMuted)
                        .background(ArcTheme.surfaceSunken, in: RoundedRectangle(cornerRadius: ArcTheme.Radius.md, style: .continuous))
                }
                .buttonStyle(.plain)
            } else {
                Label("无法显示图片：不支持的地址或图片格式", systemImage: "photo.badge.exclamationmark")
                    .font(.caption).foregroundStyle(ArcTheme.inkMuted)
            }
            if !caption.isEmpty, image == nil || !Self.isGenericCaption(caption) {
                Text(caption).font(.caption).foregroundStyle(ArcTheme.inkMuted)
            }
        }
        .task(id: "\(source)-\(attempt)") { await load() }
        .sheet(item: $preview) { item in
            NavigationStack {
                ScrollView([.horizontal, .vertical]) {
                    Image(uiImage: item.image).resizable().scaledToFit()
                        .containerRelativeFrame(.horizontal)
                }
                .background(ArcTheme.bg)
                .navigationTitle(item.caption)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { preview = nil } } }
            }
        }
    }

    private func load() async {
        if let data = MessageMarkdown.imageData(source) {
            image = Self.decode(data); failed = image == nil; return
        }
        guard requested, let url = remoteURL else { return }
        loading = true; failed = false
        do {
            let data = try await Self.download(url)
            try Task.checkCancellation()
            guard let decoded = Self.decode(data) else { throw URLError(.cannotDecodeContentData) }
            image = decoded
        } catch {
            if !Task.isCancelled { failed = true }
        }
        if !Task.isCancelled { loading = false }
    }

    /// Keep byte streaming off the UI actor while bounding the actual
    /// response size even when Content-Length is missing or incorrect.
    nonisolated private static func download(_ url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= 10 * 1024 * 1024 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            if data.count >= 10 * 1024 * 1024 { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

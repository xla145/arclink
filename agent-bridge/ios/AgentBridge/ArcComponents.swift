import SwiftUI

// Shared building blocks from the ArcLink iOS design system. Screens compose
// these instead of styling rows, tags and buttons individually.

// MARK: - Buttons

struct ArcButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, ghost }

    var kind: Kind = .primary
    /// Full width, 50pt tall: the single action of a screen.
    var block = false
    /// Capsule with a float shadow: the New-chat button.
    var pill = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(kind == .ghost ? .medium : .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, kind == .ghost ? ArcTheme.Space.s2 : ArcTheme.Space.s4)
            .frame(minHeight: block ? 50 : ArcTheme.tapMin)
            .frame(maxWidth: block ? .infinity : nil)
            .background(background, in: RoundedRectangle(cornerRadius: pill ? 999 : ArcTheme.Radius.md, style: .continuous))
            .shadow(color: pill ? .black.opacity(0.14) : .clear, radius: 10, y: 6)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: pill ? 999 : ArcTheme.Radius.md, style: .continuous))
    }

    private var foreground: Color {
        switch kind {
        case .primary: ArcTheme.onPrimary
        case .secondary: ArcTheme.ink
        case .danger: ArcTheme.danger
        case .ghost: ArcTheme.primary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: ArcTheme.primary
        case .secondary: ArcTheme.surfaceSunken
        case .danger: ArcTheme.dangerSoft
        case .ghost: .clear
        }
    }
}

extension ButtonStyle where Self == ArcButtonStyle {
    static func arc(_ kind: ArcButtonStyle.Kind = .primary, block: Bool = false, pill: Bool = false) -> ArcButtonStyle {
        ArcButtonStyle(kind: kind, block: block, pill: pill)
    }
}

// MARK: - Tiles, cards, lists

struct IconTile: View {
    var symbol: String
    var accent = false
    var tint: Color?

    var body: some View {
        Image(systemName: symbol)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(tint ?? (accent ? ArcTheme.primary : ArcTheme.inkMuted))
            .frame(width: ArcTheme.iconTile, height: ArcTheme.iconTile)
            .arcBackground(accent ? ArcTheme.primarySoft : ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
            .accessibilityHidden(true)
    }
}

struct ArcCard<Content: View>: View {
    var padding: CGFloat = ArcTheme.Space.s4
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.lg)
    }
}

/// An inset group of rows with hairlines that start after the icon tile.
struct ArcListGroup<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    var data: Data
    var dividerInset: CGFloat = ArcTheme.Space.s4 + ArcTheme.iconTile + ArcTheme.Space.s3
    @ViewBuilder var row: (Data.Element) -> Row

    init(_ data: Data, dividerInset: CGFloat = ArcTheme.Space.s4 + ArcTheme.iconTile + ArcTheme.Space.s3,
         @ViewBuilder row: @escaping (Data.Element) -> Row) {
        self.data = data
        self.dividerInset = dividerInset
        self.row = row
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(data) { item in
                if item.id != data.first?.id { ArcDivider(inset: dividerInset) }
                row(item)
            }
        }
        .frame(maxWidth: .infinity)
        .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.lg)
    }
}

/// Hairline between rows of a group; use directly in a hand-built `ArcCard` list.
struct ArcDivider: View {
    var inset: CGFloat = ArcTheme.Space.s4 + ArcTheme.iconTile + ArcTheme.Space.s3

    var body: some View {
        Rectangle().fill(ArcTheme.line).frame(height: 0.5).padding(.leading, inset)
    }
}

/// The one row shape for projects, conversations, approvals and devices.
/// Wrap it in a plain `Button` or `NavigationLink`; it supplies its own hit shape.
struct ArcListRow<Leading: View, Tags: View>: View {
    var title: String
    var subtitle: String?
    var trailing: String?
    var monospacedSubtitle = false
    var chevron = true
    @ViewBuilder var leading: Leading
    @ViewBuilder var tags: Tags
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: ArcTheme.Space.s3) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: ArcTheme.Space.s2) {
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(ArcTheme.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    Spacer(minLength: 0)
                    if let trailing, !typeSize.isAccessibilitySize {
                        Text(trailing).font(.caption).foregroundStyle(ArcTheme.inkMuted).fixedSize()
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(monospacedSubtitle ? .footnote.monospaced() : .footnote)
                        .foregroundStyle(ArcTheme.inkMuted)
                        .lineLimit(1).truncationMode(.middle)
                }
                if let trailing, typeSize.isAccessibilitySize {
                    Text(trailing).font(.caption).foregroundStyle(ArcTheme.inkMuted)
                }
                if Tags.self != EmptyView.self {
                    HStack(spacing: 6) { tags }.padding(.top, 4)
                }
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ArcTheme.inkFaint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, ArcTheme.Space.s4)
        .padding(.vertical, ArcTheme.Space.s3)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}

extension ArcListRow where Tags == EmptyView {
    init(title: String, subtitle: String? = nil, trailing: String? = nil, monospacedSubtitle: Bool = false,
         chevron: Bool = true, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, trailing: trailing, monospacedSubtitle: monospacedSubtitle,
                  chevron: chevron, leading: leading, tags: { EmptyView() })
    }
}

struct ArcSectionHeader<Actions: View>: View {
    var title: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(ArcTheme.inkMuted)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            actions.foregroundStyle(ArcTheme.inkMuted)
        }
        .padding(.horizontal, ArcTheme.Space.s1)
        .frame(minHeight: 28)
    }
}

extension ArcSectionHeader where Actions == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Status

/// One word plus an icon or dot, so state never relies on color alone.
struct StatusTag: View {
    enum Kind { case running, waiting, done, failed, neutral }

    var kind: Kind
    var text: String

    var body: some View {
        HStack(spacing: ArcTheme.Space.s1) {
            switch kind {
            case .running: Circle().fill(ArcTheme.live).frame(width: 6, height: 6)
            case .waiting: Image(systemName: "clock")
            case .done: Image(systemName: "checkmark")
            case .failed: Image(systemName: "xmark")
            case .neutral: EmptyView()
            }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, ArcTheme.Space.s2)
        .frame(minHeight: 22)
        .arcBackground(background, radius: ArcTheme.Radius.sm)
        .accessibilityElement(children: .combine)
    }

    private var foreground: Color {
        switch kind {
        case .running: ArcTheme.live
        case .waiting: ArcTheme.warning
        case .done: ArcTheme.success
        case .failed: ArcTheme.danger
        case .neutral: ArcTheme.inkMuted
        }
    }

    private var background: Color {
        switch kind {
        case .running: ArcTheme.primarySoft
        case .waiting: ArcTheme.warningSoft
        case .done: ArcTheme.successSoft
        case .failed: ArcTheme.dangerSoft
        case .neutral: ArcTheme.surfaceSunken
        }
    }
}

extension StatusTag {
    init(_ status: SessionStatus) {
        switch status {
        case .waiting: self.init(kind: .waiting, text: status.rawValue)
        case .running: self.init(kind: .running, text: status.rawValue)
        case .done: self.init(kind: .done, text: status.rawValue)
        case .cancelled: self.init(kind: .failed, text: status.rawValue)
        }
    }
}

/// Inline problem the user can act on: send failures, lost connections, wrong QR codes.
struct ArcBanner: View {
    var text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: ArcTheme.Space.s2) {
            Image(systemName: "exclamationmark.circle").accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArcTheme.ink)
                    .padding(.horizontal, 10).frame(minHeight: 32)
                    .arcBackground(ArcTheme.surface, radius: ArcTheme.Radius.sm)
            }
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(ArcTheme.danger)
        .padding(.leading, ArcTheme.Space.s3).padding(.trailing, ArcTheme.Space.s2).padding(.vertical, ArcTheme.Space.s2)
        .arcBackground(ArcTheme.dangerSoft, radius: ArcTheme.Radius.md)
    }
}

// MARK: - Navigation

/// The current Mac: dot + name + state word. Opens the device switcher.
struct DeviceStatusPill: View {
    var name: String
    var online: Bool
    var stateLabel: String
    /// Off inside a toolbar, where the system already draws a capsule.
    var chrome = true

    var body: some View {
        HStack(spacing: ArcTheme.Space.s2) {
            Circle().fill(online ? ArcTheme.live : ArcTheme.inkFaint).frame(width: 8, height: 8)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(ArcTheme.ink)
                .lineLimit(1).layoutPriority(1)
            Text(stateLabel).font(.caption).foregroundStyle(ArcTheme.inkMuted).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(ArcTheme.inkMuted)
        }
        .padding(.horizontal, chrome ? ArcTheme.Space.s3 : ArcTheme.Space.s1)
        .frame(minHeight: 36)
        .background {
            if chrome {
                Capsule().fill(ArcTheme.surface).overlay(Capsule().stroke(ArcTheme.line))
            }
        }
        .frame(minHeight: ArcTheme.tapMin)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) · \(stateLabel)")
    }
}

/// Segmented control choosing which agent's projects to show.
struct AgentSwitcher: View {
    @Binding var selection: AgentKind
    var installed: (AgentKind) -> Bool = { $0.installed }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AgentKind.allCases) { agent in
                let selected = selection == agent
                Button { selection = agent } label: {
                    HStack(spacing: 6) {
                        Image(systemName: agent.symbolName).font(.subheadline).foregroundStyle(agent.tint)
                        Text(agent.shortName).lineLimit(1).minimumScaleFactor(0.85)
                    }
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .foregroundStyle(selected ? ArcTheme.ink : ArcTheme.inkMuted)
                    .frame(maxWidth: .infinity, minHeight: 38)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous).fill(ArcTheme.surface)
                                .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                        }
                    }
                    .opacity(installed(agent) ? 1 : 0.55)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(agent.rawValue)
                .accessibilityValue(installed(agent) ? (selected ? "已选择" : "") : "未安装")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .frame(minHeight: ArcTheme.tapMin)
        .arcBackground(ArcTheme.surfaceSunken, radius: ArcTheme.Radius.md)
    }
}

// MARK: - Previews

private struct ComponentsPreview: View {
    @State private var agent = AgentKind.claude
    private struct Item: Identifiable { let id: String; let path: String; let time: String; let tagged: Bool }
    private let items = [Item(id: "agent-bridge", path: "~/mac-dev/agent-bridge · 4 个对话", time: "刚刚", tagged: true),
                         Item(id: "TokenEconomizer", path: "~/mac-dev/TokenEconomizer", time: "周一", tagged: false)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ArcTheme.Space.s3) {
                DeviceStatusPill(name: "MacBook Pro", online: true, stateLabel: "在线")
                AgentSwitcher(selection: $agent)
                ArcSectionHeader(title: "项目") {
                    Image(systemName: "magnifyingglass"); Image(systemName: "plus")
                }
                ArcListGroup(items) { item in
                    ArcListRow(title: item.id, subtitle: item.path, trailing: item.time) {
                        IconTile(symbol: "folder")
                    } tags: {
                        if item.tagged {
                            StatusTag(kind: .waiting, text: "1 待审批")
                            StatusTag(.running)
                        }
                    }
                }
                HStack { StatusTag(.done); StatusTag(.cancelled); StatusTag(kind: .neutral, text: "只读历史") }
                ArcBanner(text: "发送失败：Mac 已离线", actionTitle: "重试") {}
                HStack {
                    Button("拒绝") {}.buttonStyle(.arc(.secondary, block: true))
                    Button("允许") {}.buttonStyle(.arc(.primary, block: true))
                }
                Button("移除设备") {}.buttonStyle(.arc(.danger))
                Button { } label: { Label("新对话", systemImage: "plus") }.buttonStyle(.arc(pill: true))
                ToastBanner(text: "已复制")
            }
            .padding(ArcTheme.Space.s4)
        }
        .background(ArcTheme.bg)
    }
}

#Preview("Components · Light") { ComponentsPreview().preferredColorScheme(.light) }
#Preview("Components · Dark") { ComponentsPreview().preferredColorScheme(.dark) }
#Preview("Components · AX") { ComponentsPreview().dynamicTypeSize(.accessibility3) }

import SwiftUI

/// Scoped conversation surfaces; the app's existing appearance preference still owns the theme.
enum ChatStyle {
    static let background = adaptive(0xFAFBF8, 0x171D19)
    static let surface = adaptive(0xF0F2ED, 0x222A24)
    static let user = adaptive(0xE6EEE3, 0x2C3C2F)
    static let accent = adaptive(0x286347, 0x9ECAA8)
    static let onAccent = adaptive(0xFFFFFF, 0x15251B)
    static let failure = adaptive(0x965116, 0xF5B76F)
    static let border = adaptive(0xDEE4DA, 0x39443A)

    private static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let rgb = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
    }
}

struct ChatScrollPosition: Equatable {
    var top: CGFloat
    var bottom: CGFloat
}

struct ChatBottomPreference: PreferenceKey {
    static var defaultValue: ChatScrollPosition? = nil
    static func reduce(value: inout ChatScrollPosition?, nextValue: () -> ChatScrollPosition?) {
        if let next = nextValue() { value = next }
    }
}

/// Content growth alone is not scroll intent. A move toward older content is,
/// including VoiceOver scroll actions which do not produce a DragGesture.
struct ChatScrollFollowState {
    var followsLatest = true
    private(set) var previous: ChatScrollPosition?

    mutating func observe(_ position: ChatScrollPosition, viewport: CGFloat) {
        defer { previous = position }
        guard viewport > 0 else { return }
        if position.bottom <= viewport + 32 { followsLatest = true }
        else if let previous, position.top > previous.top + 1 { followsLatest = false }
    }
}

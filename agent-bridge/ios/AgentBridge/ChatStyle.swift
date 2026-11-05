import SwiftUI

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

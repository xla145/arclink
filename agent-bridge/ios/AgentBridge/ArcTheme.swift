import SwiftUI

/// The ArcLink iOS design tokens. Names match the published design system's
/// tokens.json; values are copied exactly. Every color adapts to the trait
/// collection, so the app's appearance preference keeps owning the theme.
enum ArcTheme {
    // Brand (identity only: pairing hero, scan line)
    static let brandNavy = rgb(0x171C38)
    static let brandTeal = rgb(0x50E3D4)
    static let brandBlue = rgb(0x568BFF)

    // Surfaces
    static let bg = adaptive(0xF5F6FA, 0x0F1326)
    static let surface = adaptive(0xFFFFFF, 0x181D33)
    static let surfaceSunken = adaptive(0xECEEF5, 0x232944)
    static let line = adaptive(0xE1E4EE, 0x2B3046)

    // Text
    static let ink = adaptive(0x171C38, 0xF3F5FC)
    static let inkMuted = adaptive(0x585E76, 0xA3AABD)
    /// Chevrons and decorative glyphs only, never text a person must read.
    static let inkFaint = adaptive(0x8B91A7, 0x6F7692)

    // Action
    static let primary = adaptive(0x2F62E0, 0x6B9AFF)
    static let onPrimary = adaptive(0xFFFFFF, 0x0F1326)
    static let primarySoft = adaptive(0xE7EDFD, 0x1F2A52)

    // State: always paired with an icon or a word
    static let live = adaptive(0x0B7F7B, 0x50E3D4)
    static let success = adaptive(0x1D7F4E, 0x5FD49A)
    static let successSoft = adaptive(0xE4F3EA, 0x173326)
    static let warning = adaptive(0xA8540F, 0xF5B76F)
    static let warningSoft = adaptive(0xFCF0E1, 0x3A2A17)
    static let danger = adaptive(0xC2362B, 0xFF8A7A)
    static let dangerSoft = adaptive(0xFBE9E7, 0x3D1F1D)

    // Agents: icons only
    static let agentClaude = adaptive(0x9A3FC9, 0xC98AF0)
    static let agentCodex = adaptive(0x1F8A43, 0x5FD47E)
    static let agentHerdr = adaptive(0x0B78B0, 0x6CD0FB)

    // Code, commands and terminal: dark in both themes
    static let codeBg = adaptive(0x141932, 0x0A0D1C)
    static let codeInk = rgb(0xE3E7F5)
    static let codeMuted = rgb(0x8E95B3)
    /// Error lines and Stop on `codeBg` (the dark-theme `danger`, 7:1 there).
    static let codeDanger = rgb(0xFF9C8F)

    static let scrim = adaptive(0x0F1326, 0x000000, lightAlpha: 0.45, darkAlpha: 0.6)

    enum Space {
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
        static let xl: CGFloat = 24
    }

    static let tapMin: CGFloat = 44
    static let iconTile: CGFloat = 36
    static let sendButton: CGFloat = 36

    private static func rgb(_ hex: UInt32) -> Color {
        Color(uiColor: uiColor(hex, alpha: 1))
    }

    private static func adaptive(_ light: UInt32, _ dark: UInt32,
                                 lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? uiColor(dark, alpha: darkAlpha) : uiColor(light, alpha: lightAlpha)
        })
    }

    private static func uiColor(_ hex: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: alpha)
    }
}

extension View {
    /// Continuous rounded background, the only corner style the design system uses.
    func arcBackground(_ color: Color, radius: CGFloat) -> some View {
        background(color, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

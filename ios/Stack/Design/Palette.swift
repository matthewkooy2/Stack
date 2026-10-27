import SwiftUI

extension Color {
    /// `Color(hex: 0xFFFDE7)`
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// Parses `#RRGGBB`; falls back to the oat surface for anything else.
    init(cssHex: String) {
        let digits = cssHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if digits.count == 6, let value = UInt32(digits, radix: 16) { self.init(hex: value) }
        else { self.init(hex: 0xFFF1D8) }
    }
}

/// The shared tokens behind the older components and screens. They resolve to `Brand` (see `ios/UI_STYLE.md`), so
/// every screen built on them follows the blue look. New code should use `Brand` directly.
enum Palette {
    static let page = Brand.page
    static let surface = Color.white
    static let surfaceRaised = Color.white
    static let button = Brand.accent
    static let oat = Color.white
    static let field = Color.white
    static let backChip = Color.white
    static let rule = Brand.rule
    static let outline = Brand.rule
    static let halo = Brand.accent.opacity(0.10)
    static let ring = Brand.accent.opacity(0.25)
    static let ink = Brand.ink
    static let text = Brand.ink
    static let icon = Brand.ink
    static let muted = Brand.muted
    static let dark = Brand.ink
    static let onDark = Color.white
    static let danger = Color(hex: 0x9C4638)
    static let success = Color(hex: 0x5E7A3A)
}

enum Typeface {
    static let display = Font.system(size: 36, weight: .heavy)
    static let title = Font.system(.title2, design: .default).weight(.bold)
    static let section = Font.system(.title3, design: .default).weight(.semibold)
    static let option = Font.system(.title3, design: .default)
    static let body = Font.system(.body, design: .default)
    static let button = Font.system(.headline, design: .default).weight(.regular)
    static let caption = Font.system(.subheadline, design: .default)
}

/// Standard spacing, kept in one place so screens share rhythm.
enum Spacing {
    static let page: CGFloat = 24
    static let stack: CGFloat = 24
    static let group: CGFloat = 16
    static let option: CGFloat = 12
    static let radius: CGFloat = 20
    static let cardRadius: CGFloat = 22
}

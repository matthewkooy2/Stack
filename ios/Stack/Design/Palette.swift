import SwiftUI
import UIKit

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

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }

    /// Parses `#RRGGBB`; falls back to the oat surface for anything else.
    init(cssHex: String) {
        let digits = cssHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if digits.count == 6, let value = UInt32(digits, radix: 16) { self.init(hex: value) }
        else { self.init(hex: 0xFFF1D8) }
    }
}

enum Palette {
    static let page = Brand.page
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C2027)
    static let surfaceRaised = Color(light: 0xFFFFFF, dark: 0x252A33)
    static let button = Color(light: 0x2256CB, dark: 0x365FCA)
    static let oat = surface
    static let field = surface
    static let backChip = surfaceRaised
    static let rule = Brand.rule
    static let outline = Brand.rule
    static let halo = Brand.accent.opacity(0.10)
    static let ring = Brand.accent.opacity(0.25)
    static let ink = Brand.ink
    static let text = Brand.ink
    static let icon = Brand.ink
    static let muted = Brand.muted
    static let dark = Brand.ink
    static let onDark = Color(light: 0xFFFFFF, dark: 0x161A21)
    static let danger = Color(light: 0xA03939, dark: 0xFF9B98)
    static let success = Color(light: 0x226B50, dark: 0x8EDBB5)
    static let warning = Color(light: 0x8A5A0B, dark: 0xF0C877)
}

// MARK: - Identity tints

extension Palette {
    /// A soft fill with the ink that reads on it, used by avatars and tinted symbol discs.
    struct Tint {
        let fill: Color
        let ink: Color
    }

    /// Six harmonious tints. The same name always maps to the same tint.
    static let tints: [Tint] = [
        Tint(fill: Color(light: 0xE3ECFD, dark: 0x22304F), ink: Color(light: 0x2256CB, dark: 0x9DBBFF)),
        Tint(fill: Color(light: 0xDDF3EF, dark: 0x1D3A37), ink: Color(light: 0x17695C, dark: 0x8FDCCB)),
        Tint(fill: Color(light: 0xE4F3DF, dark: 0x273821), ink: Color(light: 0x3C6E22, dark: 0xAEDB95)),
        Tint(fill: Color(light: 0xFBEFD6, dark: 0x40331A), ink: Color(light: 0x8A5A0B, dark: 0xF0C877)),
        Tint(fill: Color(light: 0xFBE4E6, dark: 0x40242A), ink: Color(light: 0xA1344A, dark: 0xF3A3B1)),
        Tint(fill: Color(light: 0xECE6FB, dark: 0x33284F), ink: Color(light: 0x5B3DB0, dark: 0xC2B0F5)),
    ]

    /// Deterministic (not `hashValue`, which changes per launch).
    static func tint(for seed: String) -> Tint {
        let key = seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hash: UInt32 = 5381
        for byte in key.utf8 { hash = hash &* 33 &+ UInt32(byte) }
        return tints[Int(hash % UInt32(tints.count))]
    }
}

extension String {
    /// "Ada Lovelace" -> "AL", "ada" -> "A", "" -> "".
    var stackInitials: String {
        let words = split(whereSeparator: { $0.isWhitespace || $0 == "-" }).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        if words.count > 1, let last = words.last?.first { return (String(first) + String(last)).uppercased() }
        return String(first).uppercased()
    }
}

enum Typeface {
    static let display = Font.system(.largeTitle).weight(.bold)
    static let title = Font.system(.title2, design: .default).weight(.bold)
    static let section = Font.system(.title3, design: .default).weight(.semibold)
    static let option = Font.system(.headline)
    static let body = Font.system(.body, design: .default)
    static let button = Font.system(.headline, design: .default).weight(.regular)
    static let caption = Font.system(.subheadline, design: .default)
}

/// Standard spacing, kept in one place so screens share rhythm.
enum Spacing {
    static let page: CGFloat = 20
    static let stack: CGFloat = 24
    static let group: CGFloat = 16
    static let option: CGFloat = 12
    static let radius: CGFloat = Radius.card
    static let cardRadius: CGFloat = Radius.card
}

/// Corner radii (continuous): cards 20, controls and fields 14, buttons 16.
enum Radius {
    static let card: CGFloat = 20
    static let control: CGFloat = 14
    static let button: CGFloat = 16
}

extension View {
    /// Very soft lift for surfaces on the page in light mode; flat in dark mode.
    func stackElevation(_ on: Bool = true) -> some View { modifier(StackElevation(on: on)) }
}

private struct StackElevation: ViewModifier {
    let on: Bool
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.shadow(color: on && scheme == .light ? .black.opacity(0.05) : .clear, radius: 12, y: 4)
    }
}

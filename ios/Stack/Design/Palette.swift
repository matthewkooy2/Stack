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

/// The cream palette from the Prep workflow, applied across the whole app.
enum Palette {
    static let page = Color(hex: 0xFFFDE7)
    static let surface = Color(hex: 0xFFF8D5)
    static let surfaceRaised = Color(hex: 0xFFFBCB)
    static let button = Color(hex: 0xFFF5CB)
    static let oat = Color(hex: 0xFFF1D8)
    static let field = Color(hex: 0xFFF6DC)
    static let backChip = Color(hex: 0xFFF3D3)
    static let rule = Color(hex: 0xE8D6AF)
    static let outline = Color(hex: 0xD7CCB5)
    static let halo = Color(hex: 0xF6E3BA)
    static let ring = Color(hex: 0xE6D1A0)
    static let ink = Color(hex: 0x2C1D10)
    static let text = Color(hex: 0x3F3022)
    static let icon = Color(hex: 0x342416)
    static let muted = Color(hex: 0x927E69)
    static let dark = Color(hex: 0x5A4729)
    static let onDark = Color(hex: 0xFFFDE7)
    static let danger = Color(hex: 0x9C4638)
    static let success = Color(hex: 0x5E7A3A)
}

enum Typeface {
    static let display = Font.system(.largeTitle, design: .default).weight(.bold)
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

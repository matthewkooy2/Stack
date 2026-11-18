import SwiftUI

/// Semantic colors shared by navigation, controls and content.
enum Brand {
    static let page = Color(light: 0xF5F6F8, dark: 0x101216)
    static let ink = Color(light: 0x191D25, dark: 0xF1F3F7)
    static let accent = Color(light: 0x2256CB, dark: 0x8CB1FF)
    static let muted = Color(light: 0x586170, dark: 0xADB5C4)
    static let rule = Color(light: 0xD7DCE4, dark: 0x373E49)
    /// Blue gradient for identity marks (account avatar); pair with white text.
    static let gradient = LinearGradient(
        colors: [Color(light: 0x4A86F0, dark: 0x4B7BE0), Color(light: 0x2256CB, dark: 0x2D52B5)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
}

extension Brand {
    /// Linear blend of two sRGB hex colours, `t` 0 = `a`, 1 = `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        func lerp(_ shift: UInt32) -> Double { channel(a, shift) + (channel(b, shift) - channel(a, shift)) * t }
        return Color(.sRGB, red: lerp(16), green: lerp(8), blue: lerp(0), opacity: 1)
    }
}

/// The Stack mark: a dense stack of coins whose offsets trace an uneven S. The coins drop in one after another,
/// bottom first. `look` runs from 0 (white coins, for the blue icon and launch field) to 1 (blue coins on the page)
/// and animates smoothly in between. `tiled` draws the rounded blue app-icon tile behind white coins.
struct StackMark: View, Animatable {
    var look: Double = 1
    var tiled = false
    var size: CGFloat = 160
    var animateIn = true
    var delay: Double = 0
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var built = false

    var animatableData: Double {
        get { look }
        set { look = newValue }
    }

    fileprivate enum Metrics {
        static let count = 13
        static let rx: CGFloat = 22
        static let ry: CGFloat = 7
        static let thick: CGFloat = 7
        static let step: CGFloat = 5
        static let swing: CGFloat = 20
    }

    /// Point-symmetric S: x = -A sin(2 pi t), from just before the top coin to just past the bottom one.
    private func x(_ i: Int) -> CGFloat {
        let u = Double(i) / Double(Metrics.count - 1)     // 0 = bottom coin, 1 = top coin
        let t = -0.12 + 1.24 * (1 - u)
        return -Metrics.swing * CGFloat(sin(2 * Double.pi * t))
    }

    /// Vertical centre of coin `i`'s frame, bottom coin first, so the whole stack is centred in the 100 x 100 box.
    private func y(_ i: Int) -> CGFloat {
        26.5 - CGFloat(i) * Metrics.step + (Metrics.thick + 2 * Metrics.ry) / 2 - Metrics.ry
    }

    private var shown: Bool { built || reduceMotion || !animateIn }

    var body: some View {
        let k = tiled ? 0 : look
        ZStack {
            if tiled {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Palette.button)
                    .scaleEffect(shown ? 1 : 0.8)
                    .opacity(shown ? 1 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7).delay(delay), value: built)
            }
            ZStack {
                ForEach(0..<Metrics.count, id: \.self) { i in
                    Coin(top: Brand.mix(0xFFFFFF, 0x2563FF, k),
                         side: Brand.mix(0xC9D9FF, 0x1E4FD6, k),
                         edge: Brand.mix(0x2563FF, 0xF5F3F0, k))
                        .offset(x: x(i), y: y(i))
                        .offset(y: shown ? 0 : -140)
                        .opacity(shown ? 1 : 0)
                        .animation(reduceMotion ? nil : drop(i), value: built)
                }
            }
            .scaleEffect(0.78 + 0.22 * k)
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: tiled ? 26 : 0, style: .continuous))
        }
        .frame(width: 100, height: 100)
        .scaleEffect(size / 100)
        .frame(width: size, height: size)
        .onAppear {
            if reduceMotion || !animateIn { built = true } else { DispatchQueue.main.async { built = true } }
        }
        .accessibilityHidden(true)
    }

    private func drop(_ i: Int) -> Animation {
        .spring(response: 0.5, dampingFraction: 0.72).delay(delay + 0.1 + Double(i) * 0.05)
    }
}

/// One coin seen from slightly above: a rim, a side and a top face.
private struct Coin: View {
    let top: Color
    let side: Color
    let edge: Color

    var body: some View {
        let rx = StackMark.Metrics.rx, ry = StackMark.Metrics.ry, thick = StackMark.Metrics.thick
        ZStack(alignment: .topLeading) {
            Rectangle().fill(side).frame(width: 2 * rx, height: thick).offset(y: ry)
            face(side).frame(width: 2 * rx, height: 2 * ry).offset(y: thick)
            face(top).frame(width: 2 * rx, height: 2 * ry)
        }
        .frame(width: 2 * rx, height: 2 * ry + thick, alignment: .topLeading)
    }

    private func face(_ fill: Color) -> some View {
        Ellipse().fill(fill).overlay(Ellipse().stroke(edge, lineWidth: 1.2))
    }
}

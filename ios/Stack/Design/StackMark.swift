import SwiftUI

/// The bold blue-on-off-white identity used by the welcome and launch screens.
enum Brand {
    static let page = Color(hex: 0xF5F3F0)
    static let ink = Color(hex: 0x111111)
    static let accent = Color(hex: 0x2563FF)
    static let muted = Color(hex: 0x5E5C58)
    static let rule = Color(hex: 0xDAD7D2)
}

extension Brand {
    /// Linear blend of two sRGB hex colours, `t` 0 = `a`, 1 = `b`.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> Color {
        func channel(_ value: UInt32, _ shift: UInt32) -> Double { Double((value >> shift) & 0xFF) / 255 }
        func lerp(_ shift: UInt32) -> Double { channel(a, shift) + (channel(b, shift) - channel(a, shift)) * t }
        return Color(.sRGB, red: lerp(16), green: lerp(8), blue: lerp(0), opacity: 1)
    }
}

private struct MarkInFlightKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True while `LaunchSequence` is flying the splash mark toward its place on the destination screen. The
    /// destination's own mark waits, invisible and not animating in, until the flying one lands.
    var markInFlight: Bool {
        get { self[MarkInFlightKey.self] }
        set { self[MarkInFlightKey.self] = newValue }
    }
}

struct MarkFrameKey: PreferenceKey {
    static let defaultValue: CGRect? = nil
    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) { value = value ?? nextValue() }
}

extension View {
    /// Reports this view's frame in window coordinates, so the launch sequence knows where to land the mark.
    func reportsMarkFrame() -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: MarkFrameKey.self, value: proxy.frame(in: .global))
        })
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
                    .fill(Brand.accent)
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

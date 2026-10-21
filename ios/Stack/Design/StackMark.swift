import SwiftUI

/// The bold blue-on-off-white identity used by the welcome and launch screens.
enum Brand {
    static let page = Color(hex: 0xF5F3F0)
    static let ink = Color(hex: 0x111111)
    static let accent = Color(hex: 0x2563FF)
    static let muted = Color(hex: 0x5E5C58)
    static let rule = Color(hex: 0xDAD7D2)
}

/// Staggered bars that stack up: the bottom bar lands first, then each one drops onto it. `scale` 1 is the hero
/// size (270 x 151); the logo mark uses two bars at a small scale. Plays once when it appears.
struct StackBars: View {
    var count = 3
    var scale: CGFloat = 1
    var color: Color = Brand.accent
    var delay: Double = 0
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var built = false

    private static let widths: [CGFloat] = [148, 187, 223]
    private static let inset: [CGFloat] = [0, 25, 47]
    private static let height: CGFloat = 43
    private static let gap: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: Self.gap * scale) {
            ForEach(0..<count, id: \.self) { index in
                Rectangle()
                    .fill(color)
                    .frame(width: Self.widths[index] * scale, height: Self.height * scale)
                    .padding(.leading, Self.inset[index] * scale)
                    .offset(y: built ? 0 : -(150 * scale + 60))
                    .opacity(built ? 1 : 0)
                    .animation(reduceMotion ? nil : drop(index), value: built)
            }
        }
        .frame(width: (Self.inset[count - 1] + Self.widths[count - 1]) * scale, alignment: .leading)
        .onAppear {
            if reduceMotion { built = true } else { DispatchQueue.main.async { built = true } }
        }
        .accessibilityHidden(true)
    }

    /// Bottom bar first, each following bar a beat later.
    private func drop(_ index: Int) -> Animation {
        .spring(response: 0.55, dampingFraction: 0.72).delay(delay + Double(count - 1 - index) * 0.16)
    }
}

/// Logo tile for headers: two bars and the lowercase wordmark.
struct StackWordmark: View {
    var body: some View {
        HStack(spacing: 12) {
            StackBars(count: 2, scale: 0.14)
            Text("stack").font(.system(size: 30, weight: .heavy)).tracking(-1.2).foregroundStyle(Brand.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Stack")
    }
}

import SwiftUI

// Shared list and action pieces used by Prep, Library, Interview and Network.

extension View {
    /// The bar that pins a sheet's primary action: page margins, a bar material and a hairline above.
    func pinnedActionBar() -> some View {
        padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

/// A raised surface for a set of rows with inset dividers.
struct GroupedList<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
    }
}

/// One tappable row of a `GroupedList`: tinted disc, title and detail, then a trailing view (a chevron by default).
@MainActor
struct GroupRow<Trailing: View>: View {
    let symbol: String
    var tint = 0
    let title: String
    var detail = ""
    var divider = true
    var disabled = false
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                SymbolDisc(systemName: symbol, size: 40, tint: tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.leading).lineLimit(2)
                    if !detail.isEmpty {
                        Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted)
                            .multilineTextAlignment(.leading).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if divider { Divider().padding(.leading, 70) }
            }
        }
        .buttonStyle(.tap(scale: 0.985, dim: 0.5))
        .disabled(disabled)
        .accessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
    }
}

extension GroupRow where Trailing == RowChevron {
    init(symbol: String, tint: Int = 0, title: String, detail: String = "", divider: Bool = true, disabled: Bool = false,
         action: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, divider: divider, disabled: disabled, action: action) {
            RowChevron()
        }
    }
}

/// The chevron that ends a row.
struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted.opacity(0.7))
            .accessibilityHidden(true)
    }
}

/// A score out of four with a tone that matches how well it went.
struct ScoreChip: View {
    let score: Int
    private var tone: StatusPill.Tone { score >= 3 ? .success : (score >= 1 ? .warning : .danger) }

    var body: some View {
        StatusPill(text: "\(score)/4", tone: tone)
            .accessibilityHidden(true)
    }
}

/// A soft ring that swells and fades behind a button while it waits to be tapped. Still under Reduce Motion.
struct IdlePulse: ViewModifier {
    var active: Bool
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var out = false

    func body(content: Content) -> some View {
        content.background {
            if active && !reduceMotion {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .fill(Palette.button.opacity(0.30))
                    .scaleEffect(x: out ? 1.06 : 1, y: out ? 1.28 : 1)
                    .opacity(out ? 0 : 0.8)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false), value: out)
                    .onAppear { out = true }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

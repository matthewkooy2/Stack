import SwiftUI

/// The app's icon names mapped onto SF Symbols.
enum Glyph {
    static func symbol(_ name: String) -> String {
        switch name {
        case "mic": return "mic.fill"
        case "chevron": return "chevron.right"
        case "return": return "arrow.left"
        case "add-session": return "plus.circle"
        case "continue-session": return "play.circle"
        case "clock": return "clock"
        case "chat": return "bubble.left"
        case "code": return "chevron.left.forwardslash.chevron.right"
        case "shuffle": return "shuffle"
        case "applications": return "briefcase"
        case "network": return "person.2"
        case "sprout": return "leaf"
        case "question-file": return "questionmark.circle"
        case "sparkles": return "sparkles"
        case "check": return "checkmark"
        case "done": return "checkmark.circle"
        case "next": return "arrow.right"
        case "play": return "play.fill"
        case "pause": return "pause.fill"
        case "jobs": return "square.stack"
        case "resume": return "doc.text"
        case "prep": return "text.bubble"
        case "bell": return "bell"
        case "upload": return "arrow.up.doc"
        case "close": return "xmark"
        case "pass": return "xmark"
        case "save": return "bookmark"
        case "location": return "mappin.and.ellipse"
        case "link": return "arrow.up.right"
        case "logout": return "rectangle.portrait.and.arrow.right"
        case "shield": return "lock.shield"
        case "profile": return "person.crop.circle"
        case "activity": return "waveform.path.ecg"
        case "refresh": return "arrow.clockwise"
        case "star": return "star"
        case "trash": return "trash"
        default: return "circle"
        }
    }
}

@MainActor
struct GlyphView: View {
    let name: String
    var size: CGFloat = 22
    var color: Color = Palette.icon

    var body: some View {
        Image(systemName: Glyph.symbol(name))
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
}

/// The primary action: a cream button. `dark` is the filled brown variant, `secondary` a quiet text link.
@MainActor
struct StackButton: View {
    enum Kind { case primary, secondary, dark }

    let label: String
    var icon: String = ""
    var kind: Kind = .primary
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                if !icon.isEmpty { GlyphView(name: icon, size: 21, color: kind == .dark ? Palette.onDark : Palette.icon) }
                Text(label)
                    .font(kind == .secondary ? Typeface.caption : Typeface.button)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: kind == .dark ? nil : .infinity, minHeight: kind == .secondary ? 48 : 58)
            .padding(.horizontal, kind == .dark ? 26 : 17)
            .background(background, in: RoundedRectangle(cornerRadius: kind == .dark ? 32 : Spacing.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: kind == .secondary ? 0.985 : 0.97))
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: kind == .dark ? .leading : .center)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.icon
        case .secondary: return Palette.muted
        case .dark: return Palette.onDark
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Palette.button
        case .secondary: return .clear
        case .dark: return Palette.dark
        }
    }
}

/// A large tappable row with an icon and a chevron.
@MainActor
struct OptionRow: View {
    let label: String
    var icon: String = ""
    var detail: String = ""
    var oat = false
    var disabled = false
    var showsChevron = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 20) {
                if !icon.isEmpty { GlyphView(name: icon, size: 26).frame(width: 32) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Typeface.option).foregroundStyle(Palette.icon)
                    if !detail.isEmpty { Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron { GlyphView(name: "chevron", size: 16, color: Palette.muted) }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(minHeight: 72)
            .background(oat ? Palette.oat : Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98))
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

/// A hairline-separated row for lists on the page background (the Prep home rows).
@MainActor
struct ListRow<Trailing: View>: View {
    let label: String
    var icon: String = ""
    var detail: String = ""
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            HStack(spacing: 22) {
                if !icon.isEmpty { GlyphView(name: icon, size: 26).frame(width: 32) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(Typeface.option).foregroundStyle(Palette.icon)
                    if !detail.isEmpty { Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.vertical, 20)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
        }
        .buttonStyle(.tap(scale: 0.985, dim: 1))
        .accessibilityLabel(detail.isEmpty ? label : "\(label), \(detail)")
    }
}

extension ListRow where Trailing == AnyView {
    init(label: String, icon: String = "", detail: String = "", action: @escaping () -> Void) {
        self.init(label: label, icon: icon, detail: detail, action: action) {
            AnyView(GlyphView(name: "chevron", size: 16, color: Palette.muted))
        }
    }
}

@MainActor
struct BackButton: View {
    var label = "Back"
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlyphView(name: "return", size: 20, color: Palette.muted)
                .frame(width: 44, height: 44)
                .background(Palette.backChip, in: Circle())
        }
        .buttonStyle(.tap(scale: 0.92, dim: 1))
        .disabled(disabled)
        .accessibilityLabel(label)
    }
}

@MainActor
struct Card<Content: View>: View {
    var tint: Color = Palette.surface
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(tint, in: RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
    }
}

@MainActor
struct Chip: View {
    let label: String
    var selected = false
    var action: (() -> Void)?

    var body: some View {
        let chip = Text(label)
            .font(Typeface.caption)
            .foregroundStyle(selected ? Palette.onDark : Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(selected ? Palette.dark : Palette.oat, in: Capsule())
            .animation(Motion.fadeAnimation, value: selected)
        if let action {
            Button(action: action) { chip }.buttonStyle(.tap(scale: 0.95, dim: 1)).accessibilityLabel(label)
        } else {
            chip
        }
    }
}

@MainActor
struct Avatar: View {
    let initials: String
    var tint: Color = Palette.halo
    var size: CGFloat = 52

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(Palette.icon)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }
}

@MainActor
struct StackField: View {
    let label: String
    @Binding var text: String
    var placeholder = ""
    var multiline = false
    var secure = false
    var keyboard: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(Typeface.caption).foregroundStyle(Palette.muted)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else if multiline {
                    TextField(placeholder, text: $text, axis: .vertical).lineLimit(4...12)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(Typeface.body)
            .accessibilityLabel(label)
            .foregroundStyle(Palette.text)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(keyboard != .default || secure)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: multiline ? 140 : 54, alignment: .topLeading)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        }
    }
}

/// A calm inline message for errors and notices; fades rather than snaps.
@MainActor
struct MessageLine: View {
    let text: String
    var isError = true

    var body: some View {
        Text(text)
            .font(Typeface.caption)
            .foregroundStyle(isError ? Palette.danger : Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Screen title with the account button, used at the top of each tab.
@MainActor
struct ScreenHeader: View {
    let title: String
    var subtitle: String = ""
    var onProfile: (() -> Void)?
    @Environment(AppStore.self) var store

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                if !subtitle.isEmpty { Text(subtitle).font(Typeface.caption).foregroundStyle(Palette.muted) }
            }
            Spacer(minLength: 12)
            if let onProfile {
                Button(action: onProfile) {
                    GlyphView(name: "profile", size: 26, color: Palette.icon)
                        .frame(width: 44, height: 44)
                        .background(Palette.backChip, in: Circle())
                        .overlay(alignment: .topTrailing) {
                            if store.account.attentionRunCount > 0 {
                                Circle().fill(Color(hex: 0xC8742B)).frame(width: 12, height: 12)
                                    .overlay(Circle().stroke(Palette.page, lineWidth: 2))
                            }
                        }
                }
                .buttonStyle(.tap(scale: 0.92, dim: 1))
                .accessibilityLabel(store.account.attentionRunCount > 0
                                    ? "Your account, \(store.account.attentionRunCount) agent tasks need you" : "Your account")
            }
        }
    }
}

@MainActor
struct EmptyNote: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 14) {
            Halo(size: 76) { GlyphView(name: icon, size: 30) }
            Text(title).font(Typeface.section).foregroundStyle(Palette.ink)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

/// Standard scrolling page with the shared margins and entrance.
@MainActor
struct Page<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.stack, content: content)
                .padding(.horizontal, Spacing.page)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

func shortDate(_ seconds: Double) -> String {
    Date(timeIntervalSince1970: seconds).formatted(.dateTime.month(.abbreviated).day())
}

func dateTime(_ seconds: Double) -> String {
    Date(timeIntervalSince1970: seconds).formatted(.dateTime.month(.abbreviated).day().hour().minute())
}

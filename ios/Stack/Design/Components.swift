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
        case "warning": return "exclamationmark.circle"
        case "graduation": return "graduationcap"
        case "refresh": return "arrow.clockwise"
        case "star": return "star"
        case "trash": return "trash"
        case "details": return "info.circle"
        case "video": return "video.fill"
        case "industry": return "building.2"
        case "library": return "rectangle.stack.badge.play"
        case "speaker": return "speaker.wave.2"
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

/// Full-width primary action, quiet secondary action or compact ink button.
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
            HStack(spacing: 9) {
                if !icon.isEmpty { GlyphView(name: icon, size: 18, color: foreground) }
                Text(label)
                    .font(kind == .secondary ? Typeface.caption.weight(.semibold) : .system(.headline).weight(.semibold))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: kind == .dark ? nil : .infinity, minHeight: kind == .secondary ? 44 : 52)
            .padding(.horizontal, kind == .dark ? 26 : 17)
            .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: kind == .secondary ? 0.985 : 0.97))
        .disabled(disabled)
        .frame(maxWidth: .infinity, alignment: kind == .dark ? .leading : .center)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Brand.accent
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
            HStack(spacing: 14) {
                if !icon.isEmpty { GlyphView(name: icon, size: 20, color: Brand.accent).frame(width: 26) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.headline).foregroundStyle(Palette.icon)
                    if !detail.isEmpty { Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if showsChevron { GlyphView(name: "chevron", size: 13, color: Palette.muted) }
            }
            .padding(.vertical, 13)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Divider() }
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
            HStack(spacing: 14) {
                if !icon.isEmpty { GlyphView(name: icon, size: 20, color: Brand.accent).frame(width: 26) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label).font(.headline).foregroundStyle(Palette.icon)
                    if !detail.isEmpty { Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing()
            }
            .padding(.vertical, 14)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Divider() }
        }
        .buttonStyle(.tap(scale: 0.985, dim: 1))
        .accessibilityLabel(detail.isEmpty ? label : "\(label), \(detail)")
    }
}

extension ListRow where Trailing == AnyView {
    init(label: String, icon: String = "", detail: String = "", action: @escaping () -> Void) {
        self.init(label: label, icon: icon, detail: detail, action: action) {
            AnyView(GlyphView(name: "chevron", size: 13, color: Palette.muted))
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
            Image(systemName: label.hasPrefix("Close") || label == "Cancel" ? "xmark" : "chevron.backward")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .frame(width: 34, height: 34)
                .background(Palette.backChip, in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.96))
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
            .padding(16)
            .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
struct Chip: View {
    let label: String
    var selected = false
    @Environment(\.stackReduceMotion) private var reduceMotion
    var action: (() -> Void)?

    var body: some View {
        let chip = Text(label)
            .font(Typeface.caption)
            .fontWeight(selected ? .semibold : .regular)
            .foregroundStyle(selected ? Brand.accent : Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(selected ? Palette.halo : Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.clear : Palette.rule, lineWidth: 1))
            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: selected)
        if let action {
            Button(action: action) {
                chip.frame(minHeight: 44).contentShape(Rectangle())
            }
                .buttonStyle(.tap(scale: 0.98))
                .accessibilityLabel(label)
                .accessibilityAddTraits(selected ? .isSelected : [])
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
    @FocusState private var focused: Bool

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
            .focused($focused)
            .keyboardDismissToolbar($focused)
            .font(Typeface.body)
            .accessibilityLabel(label)
            .foregroundStyle(Palette.text)
            .tint(Brand.accent)
            .keyboardType(keyboard)
            .textInputAutocapitalization(autocapitalization)
            .autocorrectionDisabled(keyboard != .default || secure)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(minHeight: multiline ? 140 : 54, alignment: .topLeading)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Brand.accent : Palette.rule, lineWidth: focused ? 1.5 : 1))
        }
    }
}

/// Places a dismissal action above the keyboard for the currently focused field.
@MainActor
private struct KeyboardDismissControl: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .keyboardDismissToolbar($focused)
    }
}

extension View {
    func keyboardDismissControl() -> some View { modifier(KeyboardDismissControl()) }

    fileprivate func keyboardDismissToolbar(_ focus: FocusState<Bool>.Binding) -> some View {
        toolbar {
            if focus.wrappedValue {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focus.wrappedValue = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                }
            }
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
struct ScreenHeader<Accessory: View>: View {
    let title: String
    let onProfile: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                heading.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                actions.fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: 0) {
                actions.frame(maxWidth: .infinity, alignment: .trailing)
                heading
            }
        }
    }

    private var heading: some View {
        Text(title).font(Typeface.display).tracking(-0.8).foregroundStyle(Brand.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        HStack(spacing: 2) {
            accessory()
            if let onProfile { AccountButton(action: onProfile) }
        }
    }
}

@MainActor
private struct AccountButton: View {
    @Environment(AppStore.self) private var store
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 25, weight: .regular))
                .foregroundStyle(Brand.muted)
                .overlay(alignment: .topTrailing) {
                    if store.account.attentionRunCount > 0 {
                        Circle().fill(Brand.accent).frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Brand.page, lineWidth: 1))
                    }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.account.attentionRunCount > 0
                            ? "Your account, \(store.account.attentionRunCount) agent tasks need you" : "Your account")
    }
}

/// Collection roots share the same margins and toolbar. The body gets the remaining
/// viewport height so an empty collection can place its invitation deliberately.
@MainActor
struct CollectionPage<Accessory: View, Content: View>: View {
    let title: String
    let onProfile: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: (CGFloat) -> Content

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: title, onProfile: onProfile, accessory: accessory)
                .padding(.horizontal, Spacing.page)
                .padding(.top, 6)
                .padding(.bottom, 8)

            GeometryReader { viewport in
                ScrollView {
                    content(max(0, viewport.size.height - 16))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.page)
                        .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
        .background(Brand.page.ignoresSafeArea())
    }
}

@MainActor
struct CollectionEmptyState: View {
    let symbol: String
    let title: String
    let actionTitle: String
    let titleIdentifier: String?
    let actionIdentifier: String?
    let action: () -> Void
    @ScaledMetric(relativeTo: .title) private var symbolSize: CGFloat = 60

    init(symbol: String, title: String, actionTitle: String, titleIdentifier: String? = nil,
         actionIdentifier: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.title = title
        self.actionTitle = actionTitle
        self.titleIdentifier = titleIdentifier
        self.actionIdentifier = actionIdentifier
        self.action = action
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: symbolSize, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier(titleIdentifier ?? title)
            Button(actionTitle, action: action)
                .accessibilityIdentifier(actionIdentifier ?? actionTitle)
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Palette.button)
                .foregroundStyle(.white)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

@MainActor
struct EmptyNote: View {
    let icon: String
    let title: String
    var message: String = ""

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: Glyph.symbol(icon))
                .font(.system(size: 42, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
            Text(title).font(Typeface.section).foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
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

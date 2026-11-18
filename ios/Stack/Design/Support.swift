import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// Keeps the title and dismissal action in reach while a long form scrolls.
@MainActor
struct SheetPage<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var closeLabel = "Close"
    var closeDisabled = false
    var onClose: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if closeLabel == "Back" { closeControl }
                Text(title)
                    .font(Typeface.title)
                    .foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .accessibilityAddTraits(.isHeader)
                if closeLabel != "Back" { closeControl }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.top, 14)
            .padding(.bottom, 8)
            Divider()
            Page {
                if !subtitle.isEmpty {
                    Text(subtitle).font(Typeface.caption).foregroundStyle(Brand.muted)
                }
                content()
            }
        }
        .background(Palette.page.ignoresSafeArea())
        .presentationDragIndicator(.visible)
    }

    private var closeControl: some View {
        BackButton(label: closeLabel, disabled: closeDisabled) {
            if let onClose { onClose() } else { dismiss() }
        }
    }
}

/// The store's current error and notice, faded in and out.
@MainActor
struct StoreMessages: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if !store.error.isEmpty || !store.notice.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !store.error.isEmpty { MessageLine(text: store.error) }
                if !store.notice.isEmpty { MessageLine(text: store.notice, isError: false) }
            }
            .transition(.opacity)
        }
    }
}

@MainActor
struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.subheadline).weight(.semibold))
            .foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(Typeface.body)
            .foregroundStyle(Palette.text)
            .tint(Brand.accent)
    }
}

@MainActor
struct StatusPill: View {
    enum Tone { case attention, active, done, quiet }

    let label: String
    var tone: Tone = .quiet

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var foreground: Color {
        switch tone {
        case .attention: return Palette.danger
        case .active: return Brand.accent
        case .done: return Palette.success
        case .quiet: return Palette.muted
        }
    }

    private var background: Color {
        switch tone {
        case .attention: return Palette.danger.opacity(0.10)
        case .active: return Palette.halo
        case .done: return Palette.success.opacity(0.12)
        case .quiet: return Palette.muted.opacity(0.10)
        }
    }
}

/// A hairline row that reveals secondary content on demand, so a screen leads with one thing.
@MainActor
struct DisclosureSection<Content: View>: View {
    let title: String
    var detail = ""
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var open: Bool
    @ViewBuilder var content: () -> Content

    init(_ title: String, detail: String = "", open: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content
        _open = State(initialValue: open)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { open.toggle() }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).font(Typeface.option).foregroundStyle(Palette.icon)
                        if !detail.isEmpty { Text(detail).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    GlyphView(name: "chevron", size: 16, color: Palette.muted)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.vertical, 16)
                .contentShape(Rectangle())
                .overlay(alignment: .bottom) { Divider() }
            }
            .buttonStyle(.tap(scale: 0.985, dim: 1))
            .accessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open { content().transition(.opacity) }
        }
    }
}

/// A scrollable block of selectable text, such as LaTeX source or extracted resume text.
@MainActor
struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Palette.text)
                .textSelection(.enabled)
                .padding(16)
        }
        .background(Palette.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

extension PDFPreview {
    /// Decodes an API document `{name, content}` (base64 PDF) into something the PDF sheet can show.
    static func make(name: String, base64: String) throws -> PDFPreview {
        guard let data = Data(base64Encoded: base64), PDFDocument(data: data) != nil else {
            throw APIError(message: "This document is not available to preview.")
        }
        return PDFPreview(name: name, data: data)
    }
}

enum DocumentKinds {
    /// `.tex` has no reliable system type, so the file name is checked after picking.
    static let latexTypes: [UTType] = [.item]

    static func isLatexSource(_ url: URL) -> Bool {
        ["tex", "zip"].contains(url.pathExtension.lowercased())
    }
}

/// Loads a file the person picked, enforcing a size limit, and returns its name and base64 content.
func readPickedFile(_ url: URL, limit: Int, tooLarge: String) throws -> (name: String, content: String) {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let data = try Data(contentsOf: url)
    guard data.count <= limit else { throw APIError(message: tooLarge) }
    return (url.lastPathComponent, data.base64EncodedString())
}

/// `readPickedFile` on a background thread. Reading a large or not-yet-downloaded file and encoding it takes long
/// enough to freeze the screen, so callers show their progress first and await this.
func readPickedFileInBackground(_ url: URL, limit: Int, tooLarge: String) async throws -> (name: String, content: String) {
    try await Task.detached(priority: .userInitiated) {
        try readPickedFile(url, limit: limit, tooLarge: tooLarge)
    }.value
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var commaSeparated: [String] {
        split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

extension Array where Element: Equatable {
    /// Adds the item when absent, removes it when present.
    func toggled(_ item: Element) -> [Element] {
        contains(item) ? filter { $0 != item } : self + [item]
    }
}

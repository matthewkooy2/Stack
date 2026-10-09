import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// A full-height sheet: close button, display title and scrolling content in the shared page style.
struct SheetPage<Content: View>: View {
    let title: String
    var subtitle: String = ""
    var onClose: (() -> Void)?
    @Environment(\.dismiss) var dismiss
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            Page {
                HStack {
                    BackButton(label: "Close") { if let onClose { onClose() } else { dismiss() } }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                    if !subtitle.isEmpty { Text(subtitle).font(Typeface.caption).foregroundStyle(Palette.muted) }
                }
                .reveal(0)
                content()
            }
        }
    }
}

/// The store's current error and notice, faded in and out.
struct StoreMessages: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
            MessageLine(text: store.notice, isError: false).fadeSwitch(!store.notice.isEmpty)
        }
    }
}

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Palette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn)
            .font(Typeface.body)
            .foregroundStyle(Palette.text)
            .tint(Palette.dark)
    }
}

struct StatusPill: View {
    enum Tone { case attention, active, done, quiet }

    let label: String
    var tone: Tone = .quiet

    var body: some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
            .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .attention: return Color(hex: 0x8A4B08)
        case .active: return Palette.dark
        case .done: return Palette.success
        case .quiet: return Palette.muted
        }
    }

    private var background: Color {
        switch tone {
        case .attention: return Color(hex: 0xFFE7C2)
        case .active: return Palette.halo
        case .done: return Color(hex: 0xE4EBCB)
        case .quiet: return Palette.oat
        }
    }
}

/// A scrollable block of selectable text, such as LaTeX source or extracted resume text.
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

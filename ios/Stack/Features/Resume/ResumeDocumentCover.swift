import SwiftUI
import PDFKit

/// A real first page where the original is a small PDF. Other files get their own file-type cover.
@MainActor
struct ResumeDocumentCover: View {
    let resume: ResumeItem
    let isActive: Bool
    let onIdentify: (String) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var fileType = ""
    @State private var loaded = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Brand.rule.opacity(0.8), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
                    .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
            } else {
                ResumePaper(type: fileType)
            }
        }
        .accessibilityHidden(true)
        .task(id: isActive) {
            // The API serves the complete original. Keep browsing inexpensive and keep thumbnails in view memory.
            guard isActive, !loaded, (1...1_048_576).contains(resume.size) else { return }
            do {
                let result = try await store.call("read_resume", ["id": .string(resume.id)])
                try Task.checkCancellation()
                let content = result["content"].string
                guard content.utf8.count <= 1_400_000 else { loaded = true; return }
                let cover = await Task.detached(priority: .utility) { () -> (type: String, bitmap: Data?) in
                    guard let data = Data(base64Encoded: content) else { return ("", nil) }
                    // Names can change after upload. A Word package has a ZIP header and the Word document part.
                    if data.starts(with: [0x50, 0x4b, 0x03, 0x04]) {
                        let isWord = data.range(of: Data("word/document.xml".utf8)) != nil
                        return (isWord ? "DOCX" : "", nil)
                    }
                    guard let document = PDFDocument(data: data), let page = document.page(at: 0) else { return ("", nil) }
                    return ("PDF", page.thumbnail(of: CGSize(width: 480, height: 640), for: .cropBox).pngData())
                }.value
                try Task.checkCancellation()
                let thumbnail = cover.bitmap.flatMap { UIImage(data: $0) }
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                    image = thumbnail
                    fileType = cover.type
                }
                onIdentify(cover.type)
                loaded = true
            } catch {
                // Retain the file cover for this visit. Opening Preview explicitly can retry the original.
                if !Task.isCancelled { loaded = true }
            }
        }
    }
}

extension ResumeItem {
    var librarySize: String {
        size > 0 ? ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) : ""
    }

    /// "Nov 17", with the year only when it is not this one.
    var shortLibraryDate: String {
        guard createdAt > 0 else { return "" }
        let date = Date(timeIntervalSince1970: createdAt)
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month(.abbreviated).day()) : date.formatted(date: .abbreviated, time: .omitted)
    }

    /// The name without a trailing file extension.
    var displayName: String {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension.lowercased()
        guard ["pdf", "docx", "doc", "txt", "rtf", "pages", "tex", "zip"].contains(ext) else { return name }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? name : stem
    }

    /// "PDF" or "DOCX" from the file name, or empty.
    var fileKind: String {
        let ext = URL(fileURLWithPath: name).pathExtension.uppercased()
        return ["PDF", "DOCX", "DOC", "TXT", "RTF", "PAGES", "TEX", "ZIP"].contains(ext) ? ext : ""
    }

    var libraryDate: String {
        guard createdAt > 0 else { return "" }
        return Date(timeIntervalSince1970: createdAt).formatted(date: .abbreviated, time: .omitted)
    }
}

/// A folded page with a real file type, or a typographic drawing for the first-use illustration.
struct ResumePaper: View {
    var type = ""

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let inset: CGFloat = 1
            let fold = w * 0.24
            let edge = w - inset
            var page = Path()
            page.move(to: CGPoint(x: inset, y: inset))
            page.addLine(to: CGPoint(x: edge - fold, y: inset))
            page.addLine(to: CGPoint(x: edge, y: inset + fold))
            page.addLine(to: CGPoint(x: edge, y: h - inset))
            page.addLine(to: CGPoint(x: inset, y: h - inset))
            page.closeSubpath()
            context.fill(page, with: .color(Palette.surfaceRaised))
            context.stroke(page, with: .color(Brand.rule), lineWidth: 1)
            var corner = Path()
            corner.move(to: CGPoint(x: edge - fold, y: inset))
            corner.addLine(to: CGPoint(x: edge - fold, y: inset + fold))
            corner.addLine(to: CGPoint(x: edge, y: inset + fold))
            corner.closeSubpath()
            context.fill(corner, with: .color(Palette.halo))
            context.stroke(corner, with: .color(Brand.rule), lineWidth: 1)

            if type.isEmpty {
                for (index, length) in [0.42, 0.68, 0.56].enumerated() {
                    let y = h * (0.42 + CGFloat(index) * 0.12)
                    let rule = CGRect(x: w * 0.16, y: y, width: w * length, height: max(1, w * 0.035))
                    context.fill(Path(roundedRect: rule, cornerRadius: 1), with: .color(index == 0 ? Brand.accent : Brand.rule))
                }
            } else {
                let label = Text(type).font(.system(size: w * 0.2, weight: .semibold, design: .rounded))
                    .foregroundColor(Brand.accent)
                context.draw(context.resolve(label), at: CGPoint(x: w * 0.14, y: h * 0.76), anchor: .leading)
            }
        }
        .aspectRatio(0.76, contentMode: .fit)
        .shadow(color: .black.opacity(0.09), radius: 10, y: 5)
        .shadow(color: .black.opacity(0.05), radius: 1.5, y: 1)
        .accessibilityHidden(true)
    }
}

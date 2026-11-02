import SwiftUI

/// How tailored versions of one resume are laid out: one of the built-in designs, filled from confirmed details.
/// A resume that already uses an uploaded source file keeps it, and can replace or remove it here; nobody is asked
/// for one.
@MainActor
struct ResumeFormatView: View {
    let resume: ResumeItem
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""

    private var format: JSON { store.account.format(of: resume.id) }
    private var kind: String { format["kind"].string }

    var body: some View {
        SheetPage(title: "Tailoring format", subtitle: resume.name) {
            Card(spacing: 10) {
                let label = format["label"].string.isEmpty ? "Not set" : format["label"].string
                Text(label + (format["file"].string.isEmpty ? "" : " · \(format["file"].string)"))
                    .font(Typeface.option).foregroundStyle(Palette.icon)
                if !kind.isEmpty && kind != "records" {
                    let pages = format["pages"].int
                    let summary = format["summary"]
                    Text("\(pages) \(pages == 1 ? "page" : "pages") · \(summary["sections"].int) sections · \(summary["entries"].int) entries · \(summary["bullets"].int) bullets")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                if kind == "upload", !format["skipped"].strings.isEmpty {
                    Text("Not used from your file: \(format["skipped"].strings.prefix(5).joined(separator: ", "))")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                Text(kind == "upload"
                     ? "Stack edits only the content of your uploaded file and keeps its layout."
                     : resume.detailsStatus == "Confirmed"
                        ? "Built from your confirmed resume details."
                        : "Confirm your resume details first, then choose a design.")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            }
            SectionLabel(text: "Designs")
            ResumeTemplatePicker(resume: resume)
            if kind == "upload" {
                StackButton(label: working ? "Uploading…" : "Replace uploaded file", icon: "upload", kind: .secondary,
                            disabled: working) { importing = true }
            }
            if kind == "upload" || kind == "builtin" {
                Chip(label: "Remove format") {
                    change("use_resume_template", ["id": .string(resume.id), "template": ""], done: "Format removed.")
                }
            }
            if working { Text("Working… The first build can take a minute.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentKinds.latexTypes) { result in
            Task { await upload(result) }
        }
    }

    private func change(_ endpoint: String, _ args: JSON, done: String) {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        Task {
            do {
                try await store.callAccount(endpoint, args, timeout: 60)
                notice = done
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            working = false
        }
    }

    /// Replaces an existing uploaded source file (kept for resumes that already use one).
    private func upload(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result, !working else { return }
        error = ""
        notice = ""
        guard DocumentKinds.isLatexSource(url) else {
            error = "Choose the same kind of file you uploaded before (.tex or .zip)."
            return
        }
        working = true
        defer { working = false }
        do {
            let file = try await readPickedFileInBackground(url, limit: 2 * 1024 * 1024, tooLarge: "This file must be 2 MB or smaller.")
            try await store.callAccount("upload_resume_source",
                                        ["id": .string(resume.id), "name": .string(file.name), "content": .string(file.content)],
                                        timeout: 90)
            notice = "File saved. Stack keeps preparing it if you close the app."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

/// Resumes Stack tailored for saved jobs, kept apart from uploads.
@MainActor
struct TailoredResumesSection: View {
    @Environment(AppStore.self) private var store
    @State private var preview: PDFPreview?
    @State private var tex: [String: String] = [:]
    @State private var shown: Set<String> = []
    @State private var working: String?
    @State private var error = ""
    @State private var deleting: TailoredResume?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("One per job. Your uploads are never changed.").font(Typeface.caption).foregroundStyle(Palette.muted)
            if store.account.tailored.isEmpty {
                Text("Tailored resumes appear here.").font(Typeface.body).foregroundStyle(Palette.text)
            }
            ForEach(store.account.tailored) { item in card(item) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .confirmationDialog("Delete this tailored resume?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete tailored resume", role: .destructive) {
                if let target = deleting { Task { await remove(target) } }
                deleting = nil
            }
        } message: { Text("Your upload stays.") }
    }

    private func card(_ item: TailoredResume) -> some View {
        Card(spacing: 10) {
            Text(item.jobTitle.isEmpty ? item.name : item.jobTitle).font(Typeface.option).foregroundStyle(Palette.icon)
            Text(item.company.isEmpty ? "Tailored resume" : "Tailored for \(item.company)").font(Typeface.caption).foregroundStyle(Palette.text)
            Text("\(shortDate(item.createdAt)) · \(item.pages) \(item.pages == 1 ? "page" : "pages")" + (item.sourceName.isEmpty ? "" : " · from \(item.sourceName)"))
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if !item.score["after"].isNull {
                ScoreCardView(after: item.score["after"], before: item.score["before"], title: "Score for this job")
            }
            HStack(spacing: 8) {
                Chip(label: working == item.id ? "Working…" : "Preview PDF") { Task { await open(item, source: false) } }
                Chip(label: shown.contains(item.id) ? "Hide LaTeX" : "Show LaTeX", selected: shown.contains(item.id)) {
                    if shown.contains(item.id) { shown.remove(item.id) } else { Task { await open(item, source: true) } }
                }
                Chip(label: "Delete") { deleting = item }
            }
            if shown.contains(item.id), let text = tex[item.id] { CodeBlock(text: text) }
        }
    }

    private func open(_ item: TailoredResume, source: Bool) async {
        guard working == nil else { return }
        working = item.id
        error = ""
        defer { working = nil }
        do {
            let result = try await store.call("read_tailored_resume", ["id": .string(item.id)], timeout: 60)
            tex[item.id] = result["tex"].string
            if source { shown.insert(item.id) }
            else { preview = try PDFPreview.make(name: result["pdf"]["name"].string, base64: result["pdf"]["content"].string) }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func remove(_ item: TailoredResume) async {
        guard working == nil else { return }
        working = item.id
        defer { working = nil }
        do { try await store.callAccount("delete_tailored_resume", ["id": .string(item.id)]) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

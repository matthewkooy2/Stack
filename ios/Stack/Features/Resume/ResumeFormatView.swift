import SwiftUI

/// How tailored versions of one resume are formatted: the person's own LaTeX, or a built-in template.
struct ResumeFormatView: View {
    let resume: ResumeItem
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""
    @State private var tex = ""
    @State private var showTex = false
    @State private var preview: PDFPreview?

    private let templates = [("jake", "Jake's Resume"), ("classic", "Classic")]

    private var format: JSON { store.account.format(of: resume.id) }
    private var kind: String { format["kind"].string }
    private var source: JSON { store.account.processing(of: resume.id)["source"] }

    var body: some View {
        SheetPage(title: "Tailoring format", subtitle: resume.name) {
            ProcessingStatusView(resumeID: resume.id, kind: "source", processing: source)
            Card(spacing: 10) {
                let label = format["label"].string.isEmpty ? "Not set" : format["label"].string
                Text(label + (format["file"].string.isEmpty ? "" : " · \(format["file"].string)"))
                    .font(Typeface.option).foregroundStyle(Palette.icon)
                if !kind.isEmpty {
                    let pages = format["pages"].int
                    let summary = format["summary"]
                    Text("\(pages) \(pages == 1 ? "page" : "pages") · \(summary["sections"].int) sections · \(summary["entries"].int) entries · \(summary["bullets"].int) bullets")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                if !format["skipped"].strings.isEmpty {
                    Text("Not used from your .zip: \(format["skipped"].strings.prefix(5).joined(separator: ", "))")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                Text(kind != "builtin"
                     ? "Stack edits only the content of your LaTeX (bullets, their order, skill lists) and keeps your layout. In Overleaf: Menu → Download → Source."
                     : "Built from your confirmed resume details. Upload your own LaTeX to keep your exact layout.")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            }
            StackButton(label: kind == "upload" ? "Replace LaTeX source" : "Upload LaTeX (.tex or Overleaf .zip)", icon: "upload",
                        kind: kind == "upload" ? .secondary : .primary, disabled: working) { importing = true }
            SectionLabel(text: "Built-in templates")
            FlowLayout(spacing: 8) {
                ForEach(templates, id: \.0) { key, label in
                    Chip(label: label, selected: kind == "builtin" && format["template"].string == key) {
                        change("use_resume_template", ["id": .string(resume.id), "template": .string(key)],
                               done: "Template saved. Compilation continues if you close Stack.")
                    }
                }
                if !kind.isEmpty {
                    Chip(label: "Remove format") {
                        change("use_resume_template", ["id": .string(resume.id), "template": ""],
                               done: "Removed. Upload LaTeX or choose a template to tailor this resume again.")
                    }
                }
            }
            if !kind.isEmpty || resume.detailsStatus == "Confirmed" {
                HStack(spacing: 8) {
                    Chip(label: "Preview format") { Task { await open(showSource: false) } }
                    Chip(label: showTex ? "Hide LaTeX" : "Show LaTeX", selected: showTex) {
                        if showTex { showTex = false } else { Task { await open(showSource: true) } }
                    }
                }
            }
            if working { Text("Working… The first LaTeX compile can take a minute.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            if showTex, !tex.isEmpty { CodeBlock(text: tex) }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentKinds.latexTypes) { result in
            Task { await upload(result) }
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .pollsWhileProcessing(["queued", "parsing", "compiling"].contains(source["status"].string))
    }

    private func change(_ endpoint: String, _ args: JSON, done: String) {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        tex = ""
        showTex = false
        Task {
            do {
                try await store.callAccount(endpoint, args, timeout: 60)
                notice = done
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            working = false
        }
    }

    private func upload(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        error = ""
        notice = ""
        guard DocumentKinds.isLatexSource(url) else {
            error = "Choose a .tex file, or the source .zip from Overleaf (Menu → Download → Source)."
            return
        }
        working = true
        defer { working = false }
        do {
            let file = try readPickedFile(url, limit: 2 * 1024 * 1024, tooLarge: "LaTeX source must be 2 MB or smaller.")
            try await store.callAccount("upload_resume_source",
                                        ["id": .string(resume.id), "name": .string(file.name), "content": .string(file.content)],
                                        timeout: 90)
            notice = "Source saved. Compilation continues if you close Stack."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func open(showSource: Bool) async {
        guard !working else { return }
        working = true
        error = ""
        defer { working = false }
        do {
            let result = try await store.call("read_resume_source", ["id": .string(resume.id)], timeout: 60)
            tex = result["tex"].string
            if showSource { showTex = true }
            else { preview = try PDFPreview.make(name: result["preview"]["name"].string, base64: result["preview"]["content"].string) }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

/// Resumes Stack tailored for saved jobs, kept apart from uploads.
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
            SectionLabel(text: "Tailored resumes")
            Text("Made by resume tailoring, one per job. Your uploads above are never changed.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if store.account.tailored.isEmpty {
                Text("Resumes you tailor for a saved job appear here.").font(Typeface.body).foregroundStyle(Palette.text)
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

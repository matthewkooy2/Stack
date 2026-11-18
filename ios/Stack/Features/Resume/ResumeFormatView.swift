import SwiftUI

/// How tailored versions of one resume are formatted: the person's own LaTeX, or a built-in template.
@MainActor
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

    private var format: JSON { store.account.format(of: resume.id) }
    private var kind: String { format["kind"].string }
    private var source: JSON { store.account.processing(of: resume.id)["source"] }

    var body: some View {
        SheetPage(title: "Resume template", subtitle: resume.displayName) {
            ProcessingStatusView(resumeID: resume.id, kind: "source", processing: source)
            Card(spacing: 6) {
                let label = kind == "upload" ? "Your layout" : ResumeTemplate.label(for: format["template"].string,
                                                                                    fallback: format["label"].string.isEmpty ? "Not set" : format["label"].string)
                HStack {
                    Text(label + (format["file"].string.isEmpty ? "" : " · \(format["file"].string)"))
                        .font(.headline).foregroundStyle(Palette.icon)
                    Spacer(minLength: 8)
                    if !kind.isEmpty && kind != "records" { StatusPill(text: "In use", tone: .success) }
                }
                if !kind.isEmpty && kind != "records" {
                    let pages = format["pages"].int
                    let summary = format["summary"]
                    let sections = summary["sections"].int
                    let entries = summary["entries"].int
                    let bullets = summary["bullets"].int
                    let counts = [pages > 0 ? "\(pages) \(pages == 1 ? "page" : "pages")" : "",
                                  sections > 0 ? "\(sections) \(sections == 1 ? "section" : "sections")" : "",
                                  entries > 0 ? "\(entries) \(entries == 1 ? "entry" : "entries")" : "",
                                  bullets > 0 ? "\(bullets) \(bullets == 1 ? "bullet" : "bullets")" : ""]
                        .filter { !$0.isEmpty }
                    if !counts.isEmpty {
                        Text(counts.joined(separator: " · ")).font(.footnote).foregroundStyle(Palette.muted)
                    }
                }
                if !format["skipped"].strings.isEmpty {
                    Text("Skipped: \(format["skipped"].strings.prefix(5).joined(separator: ", "))")
                        .font(.footnote).foregroundStyle(Palette.muted)
                }
            }
            if kind == "upload" {
                StackButton(label: "Replace layout", icon: "upload", kind: .secondary, disabled: working) { importing = true }
            }
            SectionHeader(title: "Templates")
            ResumeDesignMenu(selectedKey: ["builtin", "records"].contains(kind) ? format["template"].string : "") { key in
                change("use_resume_template", ["id": .string(resume.id), "template": .string(key)],
                       done: "Template saved")
            }
            .disabled(working || (store.account.resume(resume.id) ?? resume).detailsStatus != "Confirmed")
            if !kind.isEmpty || resume.detailsStatus == "Confirmed" {
                FlowLayout(spacing: 8) {
                    Chip(label: "Preview") { Task { await open(showSource: false) } }
                    if kind != "records" {
                        Chip(label: showTex ? "Hide source" : "View source", selected: showTex) {
                            if showTex { showTex = false } else { Task { await open(showSource: true) } }
                        }
                    }
                    if !kind.isEmpty && kind != "records" {
                        Chip(label: "Remove template") {
                            change("use_resume_template", ["id": .string(resume.id), "template": ""],
                                   done: "Removed")
                        }
                        .disabled(working)
                    }
                }
            }
            if resume.detailsStatus != "Confirmed" && kind != "upload" {
                Text("Confirm your details to choose a template").font(.footnote).foregroundStyle(Palette.muted)
            }
            if working { HStack(spacing: 8) { ProgressView(); Text("Preparing…").font(.footnote).foregroundStyle(Palette.muted) } }
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
            error = "Choose a .tex file or a source .zip"
            return
        }
        working = true
        defer { working = false }
        do {
            let file = try await readPickedFileInBackground(url, limit: 2 * 1024 * 1024, tooLarge: "The source file must be 2 MB or smaller.")
            try await store.callAccount("upload_resume_source",
                                        ["id": .string(resume.id), "name": .string(file.name), "content": .string(file.content)],
                                        timeout: 90)
            notice = "Layout saved"
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
            if store.account.tailored.isEmpty {
                VStack(spacing: 12) {
                    SymbolDisc(systemName: "doc.on.doc", size: 64)
                    Text("No tailored resumes yet").font(Typeface.section).foregroundStyle(Palette.ink)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 40)
            }
            ForEach(store.account.tailored) { item in card(item) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .confirmationDialog("Delete this tailored resume?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleting { Task { await remove(target) } }
                deleting = nil
            }
        }
    }

    private func card(_ item: TailoredResume) -> some View {
        Card(spacing: 10) {
            Text(item.jobTitle.isEmpty ? item.name : item.jobTitle).font(.headline).foregroundStyle(Palette.icon)
            Text([item.company, shortDate(item.createdAt), "\(item.pages) \(item.pages == 1 ? "page" : "pages")"]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(Palette.muted)
            if !item.score["after"].isNull {
                ScoreCardView(after: item.score["after"], before: item.score["before"], title: "Job match")
            }
            FlowLayout(spacing: 8) {
                Chip(label: working == item.id ? "Working…" : "Preview") { Task { await open(item, source: false) } }
                Chip(label: shown.contains(item.id) ? "Hide source" : "View source", selected: shown.contains(item.id)) {
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

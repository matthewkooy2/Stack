import SwiftUI

/// Background work the server does for a resume (PDF parsing, LaTeX compilation), with retry.
@MainActor
struct ProcessingStatusView: View {
    let resumeID: String
    var kind = "pdf"
    let processing: JSON
    @Environment(AppStore.self) private var store
    @State private var retrying = false
    @State private var error = ""

    private var status: String { processing["status"].string }

    var body: some View {
        if !status.isEmpty, status != "cancelled" {
            VStack(alignment: .leading, spacing: 6) {
                Text(label)
                    .font(Typeface.caption)
                    .foregroundStyle(status == "failed" ? Palette.danger : Palette.dark)
                    .breathe(["queued", "parsing", "compiling"].contains(status), minimum: 0.6)
                if ["queued", "parsing", "compiling"].contains(status) {
                    Text("Saved on the server. You can close Stack and reopen later.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                if !timings.isEmpty { Text(timings).font(Typeface.caption).foregroundStyle(Palette.muted) }
                if !processing["error"].string.isEmpty {
                    Text(processing["error"].string).font(Typeface.caption).foregroundStyle(Palette.danger)
                }
                if status == "failed" {
                    StackButton(label: retrying ? "Retrying…" : "Retry processing", kind: .secondary, disabled: retrying) {
                        retrying = true
                        error = ""
                        Task {
                            do {
                                try await store.callAccount("retry_resume_processing", ["id": .string(resumeID), "kind": .string(kind)])
                            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                            retrying = false
                        }
                    }
                }
                MessageLine(text: error).fadeSwitch(!error.isEmpty)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
        }
    }

    private var label: String {
        switch status {
        case "queued": return "Saved · Waiting to process"
        case "parsing": return kind == "pdf" ? "Reading PDF…" : "Reading LaTeX source…"
        case "compiling": return "Compiling LaTeX…"
        case "completed": return kind == "pdf" ? "PDF ready to review" : "LaTeX compiled"
        case "failed": return "Processing failed"
        default: return status
        }
    }

    private var timings: String {
        let values = processing["timings"]
        let parts: [(String, String)] = [("transfer_ms", "Upload"), ("queue_ms", "Queue"), ("parse_ms", "Parse"), ("compile_ms", "Compile")]
        return parts.compactMap { key, name in
            let value = values[key].double
            return value > 0 ? "\(name) \(String(format: "%.2f", value / 1000))s" : nil
        }.joined(separator: " · ")
    }
}

/// Re-reads the account while a resume is being processed.
struct ProcessingPoll: ViewModifier {
    let active: Bool
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        content.task(id: active) {
            guard active else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2.5))
                if Task.isCancelled { break }
                await store.refresh()
            }
        }
    }
}

extension View {
    func pollsWhileProcessing(_ active: Bool) -> some View { modifier(ProcessingPoll(active: active)) }
}

/// Tailoring edits LaTeX, so a resume that is only a PDF gets its LaTeX here and then continues.
@MainActor
struct LatexSetupView: View {
    let resume: ResumeItem
    let others: [ResumeItem]
    let onReady: (String) async -> Void
    @Environment(AppStore.self) private var store
    @State private var importing = false
    @State private var working = false
    @State private var error = ""
    @State private var pending = false

    private var source: JSON { store.account.processing(of: resume.id)["source"] }

    var body: some View {
        Card(tint: Palette.oat, spacing: 12) {
            Text("Add the LaTeX for \(resume.name)").font(Typeface.option).foregroundStyle(Palette.icon)
            ProcessingStatusView(resumeID: resume.id, kind: "source", processing: source)
            Text("Tailoring rewrites and trims your LaTeX for this job, so your layout stays exactly the same. A PDF alone can't be tailored.")
                .font(Typeface.caption).foregroundStyle(Palette.text)
            ForEach(others) { other in
                StackButton(label: "Use \(other.name) instead · has LaTeX", icon: "check", disabled: working) {
                    Task { await onReady(other.id) }
                }
            }
            StackButton(label: working ? "Uploading…" : "Upload LaTeX (.tex or Overleaf .zip)", icon: "upload",
                        kind: others.isEmpty ? .primary : .secondary, disabled: working || pending) { importing = true }
            Text("In Overleaf: Menu → Download → Source.").font(Typeface.caption).foregroundStyle(Palette.muted)
            Text("Building a template from PDF details is temporarily unavailable. Upload your LaTeX source to continue.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: DocumentKinds.latexTypes) { result in
            Task { await upload(result) }
        }
        .pollsWhileProcessing(pending || ["queued", "parsing", "compiling"].contains(source["status"].string))
        .onChange(of: source["status"].string) { _, status in
            guard pending else { return }
            if status == "completed" {
                pending = false
                Task { await onReady(resume.id) }
            } else if status == "failed" {
                pending = false
            }
        }
    }

    private func upload(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        error = ""
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
            pending = true
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

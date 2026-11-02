import SwiftUI

/// Background work the server does for a resume (reading it into details, building its design), with retry.
@MainActor
struct ProcessingStatusView: View {
    let resumeID: String
    var kind = ResumeLane.structured
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
                    Text("Saved. You can close Stack and reopen later.")
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
        case "parsing": return kind == ResumeLane.source ? "Reading your file…" : "Reading resume…"
        case "compiling": return "Preparing your design…"
        case "completed": return kind == ResumeLane.source ? "Design ready" : "Resume ready to review"
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

/// The built-in designs in picker order: Jake plus the five requested designs. The server keeps legacy Classic
/// readable for saved resumes and older clients; it is not offered here.
struct ResumeTemplate: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }

    static let all: [ResumeTemplate] = [
        ResumeTemplate(key: "jake", label: "Jake's Resume"),
        ResumeTemplate(key: "awesome-cv", label: "Awesome-CV"),
        ResumeTemplate(key: "bill-ryan", label: "Bill Ryan's Elegant Resume"),
        ResumeTemplate(key: "sb2nov", label: "Sourabh Bajaj's Resume"),
        ResumeTemplate(key: "deedy", label: "Deedy Resume"),
        ResumeTemplate(key: "jan-kuster", label: "Jan Kuster's Classic CV"),
    ]
}

/// Chooses a design for one resume (`use_resume_template`) and previews it (`read_resume_source`). The server fills
/// the design from the resume's confirmed details and refuses unconfirmed details with a message saying so.
@MainActor
struct ResumeTemplatePicker: View {
    let resume: ResumeItem
    var onSaving: (Bool) -> Void = { _ in }
    @Environment(AppStore.self) private var store
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""
    @State private var preview: PDFPreview?

    private var format: JSON { store.account.format(of: resume.id) }
    private var kind: String { format["kind"].string }
    private var source: JSON { store.account.processing(of: resume.id)[ResumeLane.source] }
    private var building: Bool { ["queued", "parsing", "compiling"].contains(source["status"].string) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.source, processing: source)
            FlowLayout(spacing: 8) {
                ForEach(ResumeTemplate.all) { template in
                    Chip(label: template.label,
                         selected: ["builtin", "records"].contains(kind) && format["template"].string == template.key) {
                        choose(template.key)
                    }
                    .accessibilityIdentifier("resume-template-\(template.key)")
                }
            }
            Chip(label: working ? "Working…" : "Preview design") { Task { await open() } }
                .disabled(working || building)
                .accessibilityIdentifier("resume-template-preview")
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .pollsWhileProcessing(building)
    }

    private func choose(_ key: String) {
        guard !working else { return }
        working = true
        onSaving(true)
        error = ""
        notice = ""
        Task {
            do {
                try await store.callAccount("use_resume_template", ["id": .string(resume.id), "template": .string(key)], timeout: 60)
                notice = "Design saved."
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            working = false
            onSaving(false)
        }
    }

    private func open() async {
        guard !working else { return }
        working = true
        error = ""
        defer { working = false }
        do {
            let result = try await store.call("read_resume_source", ["id": .string(resume.id)], timeout: 60)
            preview = try PDFPreview.make(name: result["preview"]["name"].string, base64: result["preview"]["content"].string)
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

/// One step before tailoring. Tailoring writes from a resume's confirmed details into a built-in design, so a PDF or
/// DOCX upload is confirmed here, a design is chosen and previewed, and tailoring continues once the resume is ready.
/// Older uploaded source files still tailor as before; they are never asked for.
@MainActor
struct TailorResumeSetup: View {
    let resume: ResumeItem
    /// Other resumes that are ready to tailor now.
    let others: [ResumeItem]
    let onReady: (String) async -> Void
    @Environment(AppStore.self) private var store
    @State private var details: ResumeItem?
    @State private var continuing = false
    @State private var savingDesign = false

    private var current: ResumeItem { store.account.resume(resume.id) ?? resume }
    private var ready: Bool { store.account.canTailor(resume.id) }
    private var reading: JSON { store.account.processing(of: resume.id)[ResumeLane.structured] }
    private var readingActive: Bool { ["queued", "parsing"].contains(reading["status"].string) }
    private var designBuilding: Bool {
        ["queued", "parsing", "compiling"].contains(store.account.processing(of: resume.id)[ResumeLane.source]["status"].string)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if ready {
                Text("Choose a design").font(Typeface.option).foregroundStyle(Brand.ink)
                Text("Stack writes your confirmed details for this job into the design you choose.")
                    .font(Typeface.caption).foregroundStyle(Brand.muted)
                ResumeTemplatePicker(resume: current, onSaving: { savingDesign = $0 })
                StackButton(label: continuing ? "Starting…" : "Continue tailoring", icon: "check",
                            disabled: continuing || savingDesign || designBuilding || store.busy) {
                    Task { await go(resume.id) }
                }
                .accessibilityIdentifier("tailor-setup-continue")
            } else {
                Text("Confirm the details in \(current.name)").font(Typeface.option).foregroundStyle(Brand.ink)
                ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.structured, processing: reading)
                Text("Stack tailors only from details you confirm. Then you choose a design.")
                    .font(Typeface.caption).foregroundStyle(Brand.muted)
                StackButton(label: "Review details", icon: "check", disabled: continuing) { details = current }
                    .accessibilityIdentifier("tailor-setup-details")
                ForEach(others) { other in
                    StackButton(label: "Use \(other.name) instead", icon: "resume", kind: .secondary, disabled: continuing) {
                        Task { await go(other.id) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .pollsWhileProcessing(readingActive)
        .fullScreenCover(item: $details) { item in
            // Confirming refreshes the account, so this step shows the designs when the cover closes.
            ResumeDetailsView(resume: item, onConfirmed: { details = nil }).environment(store)
        }
    }

    private func go(_ id: String) async {
        guard !continuing, !savingDesign, !designBuilding, !store.busy else { return }
        continuing = true
        defer { continuing = false }
        await onReady(id)
    }
}

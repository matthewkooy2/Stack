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
        case "compiling": return "Preparing your template…"
        case "completed": return kind == ResumeLane.source ? "Template ready" : "Resume ready to review"
        case "failed": return kind == ResumeLane.source ? "Couldn’t prepare the template" : "Couldn’t read resume details"
        default: return status
        }
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

/// The built-in templates in picker order. The server keeps legacy Classic readable for saved resumes and
/// older clients; it is not offered here.
struct ResumeTemplate: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }

    /// The display name for a template key, falling back to the server's label.
    static func label(for key: String, fallback: String = "") -> String {
        key == "classic" ? "Classic" : (all.first { $0.key == key }?.label ?? fallback)
    }

    static let all: [ResumeTemplate] = [
        ResumeTemplate(key: "jake", label: "Jake's Resume"),
        ResumeTemplate(key: "awesome-cv", label: "Awesome-CV"),
        ResumeTemplate(key: "bill-ryan", label: "Bill Ryan's Elegant Resume"),
        ResumeTemplate(key: "sb2nov", label: "Sourabh Bajaj's Resume"),
        ResumeTemplate(key: "deedy", label: "Deedy Resume"),
        ResumeTemplate(key: "jan-kuster", label: "Jan Kuster's Classic CV"),
    ]
}

/// The six templates as small pages in a row; the chosen one is ringed.
struct ResumeTemplateStrip: View {
    let selectedKey: String
    var disabled = false
    let choose: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(ResumeTemplate.all) { template in
                    let selected = template.key == selectedKey
                    Button { if !disabled { choose(template.key) } } label: {
                        VStack(spacing: 8) {
                            Image("resume-template-\(template.key)")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 72, height: 94)
                                .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                                .accessibilityHidden(true)
                                .padding(4)
                                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .strokeBorder(selected ? Brand.accent : Color.clear, lineWidth: 2))
                            Text(template.label).font(.footnote.weight(selected ? .semibold : .regular))
                                .foregroundStyle(selected ? Brand.accent : Brand.muted)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(width: 100)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.tap(scale: 0.96))
                    .accessibilityLabel(template.label)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("resume-template-\(template.key)")
                }
            }
            .padding(.horizontal, Spacing.page).padding(.vertical, 6)
        }
        .padding(.horizontal, -Spacing.page)
        .opacity(disabled ? 0.8 : 1)
        .sensoryFeedback(.selection, trigger: selectedKey)
    }
}

/// Both format entry points use the same options and real template IDs.
struct ResumeDesignMenu: View {
    let selectedKey: String
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(ResumeTemplate.all) { template in
                Button {
                    choose(template.key)
                } label: {
                    if template.key == selectedKey {
                        Label(template.label, systemImage: "checkmark")
                    } else {
                        Text(template.label)
                    }
                }
                .accessibilityAddTraits(template.key == selectedKey ? .isSelected : [])
                .accessibilityIdentifier("resume-template-\(template.key)")
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text").foregroundStyle(Brand.accent)
                Text(ResumeTemplate.label(for: selectedKey, fallback: "Choose a template"))
                    .font(.headline).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(minHeight: 52)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .stackElevation()
        }
    }
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
            ResumeDesignMenu(selectedKey: ["builtin", "records"].contains(kind) ? format["template"].string : "",
                             choose: choose)
                .disabled(working)
            Chip(label: working ? "Working…" : "Preview template") { Task { await open() } }
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
                notice = "Template saved"
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
                SectionHeader(title: "PDF layout")
                ResumeTemplatePicker(resume: current, onSaving: { savingDesign = $0 })
                StackButton(label: continuing ? "Starting…" : "Tailor resume", icon: "check",
                            disabled: continuing || savingDesign || designBuilding || store.busy) {
                    Task { await go(resume.id) }
                }
                .accessibilityIdentifier("tailor-setup-continue")
            } else {
                Text("Confirm \(current.displayName)").font(Typeface.option).foregroundStyle(Brand.ink)
                ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.structured, processing: reading)
                StackButton(label: "Review details", icon: "check", disabled: continuing) { details = current }
                    .accessibilityIdentifier("tailor-setup-details")
                ForEach(others) { other in
                    StackButton(label: "Use \(other.displayName) instead", icon: "resume", kind: .secondary, disabled: continuing) {
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

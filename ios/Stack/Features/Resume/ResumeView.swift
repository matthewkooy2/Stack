import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
struct ResumeView: View {
    @Environment(AppStore.self) private var store
    var onProfile: () -> Void

    @State var importing = false
    @State var uploading = false
    @State var managing: ResumeItem?
    @State var showTailor = false
    @State var showTailored = false
    @State var showBank = false
    @State private var setupFor = ""
    @State private var scores: [String: JSON] = [:]

    private var processingActive: Bool {
        store.account.resumes.contains { resume in
            let state = store.account.processing(of: resume.id)
            return ["queued", "parsing", "compiling"].contains(state[ResumeLane.structured]["status"].string)
                || ["queued", "parsing", "compiling"].contains(state["source"]["status"].string)
        }
    }

    var body: some View {
        Group {
            if store.account.resumes.isEmpty {
                ResumeUploadScreen(uploading: uploading, disabled: store.busy, error: store.error,
                                   attentionCount: store.account.attentionRunCount,
                                   onUpload: { importing = true }, onProfile: onProfile)
            } else {
                library
            }
        }
        .refreshable { await store.refresh() }
        .pollsWhileProcessing(processingActive)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            Task { await upload(result) }
        }
        .sheet(item: $managing) { resume in ManageResumeSheet(resume: resume).environment(store) }
        .onChange(of: store.sessionGeneration) { _, _ in setupFor = ""; scores = [:] }
        .sheet(isPresented: $showTailor) { ResumeTailorSheet(setupFor: $setupFor, scores: $scores).environment(store) }
        .sheet(isPresented: $showTailored) {
            SheetPage(title: "Tailored resumes") { TailoredResumesSection() }.environment(store)
        }
        .sheet(isPresented: $showBank) { ExperienceBankView().environment(store) }
    }

    private var library: some View {
        Page {
            ScreenHeader(title: "Resume", onProfile: onProfile).reveal(0)
            StackButton(label: uploading ? "Uploading…" : "Upload a PDF resume", icon: "upload", disabled: uploading || store.busy) {
                importing = true
            }
            .reveal(1)

            StoreMessages()

            VStack(spacing: 0) {
                ForEach(Array(store.account.resumes.enumerated()), id: \.element.id) { index, resume in
                    resumeRow(resume).reveal(index + 2)
                }
            }

            VStack(spacing: 0) {
                ListRow(label: "Tailor for a job", icon: "sparkles", detail: tailorDetail) { showTailor = true }
                if !store.account.tailored.isEmpty {
                    ListRow(label: "Tailored resumes", icon: "resume", detail: "\(store.account.tailored.count) saved") { showTailored = true }
                }
                ListRow(label: "Experience bank", icon: "star", detail: "Confirmed facts for tailoring") { showBank = true }
            }
        }
    }

    private var tailorDetail: String {
        store.account.applications.contains { !$0.isDemo } ? "Score or rewrite for a saved job" : "Save a job from Jobs first"
    }

    private func needsAttention(_ processing: JSON) -> Bool {
        ["queued", "parsing", "compiling", "failed"].contains(processing["status"].string)
    }

    /// One quiet row per resume. Progress and failures surface here; everything else is one tap away.
    private func resumeRow(_ resume: ResumeItem) -> some View {
        let state = store.account.processing(of: resume.id)
        var parts: [String] = []
        if resume.id == store.account.selectedResumeID { parts.append("Default") }
        parts.append(resume.detailsStatus)
        return VStack(alignment: .leading, spacing: 0) {
            ListRow(label: resume.name, icon: "resume", detail: parts.joined(separator: " · ")) { managing = resume }
            if needsAttention(state[ResumeLane.structured]) {
                ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.structured, processing: state[ResumeLane.structured])
                    .padding(.vertical, 10)
            }
            if needsAttention(state["source"]) {
                ProcessingStatusView(resumeID: resume.id, kind: "source", processing: state["source"]).padding(.vertical, 10)
            }
        }
    }

    private func upload(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }
        let generation = store.sessionGeneration
        guard store.phase == .ready else { return }
        uploading = true
        store.error = ""
        defer { uploading = false }
        do {
            let file = try readPickedFile(url, limit: 10 * 1024 * 1024, tooLarge: "PDF must be 10 MB or smaller.")
            await store.mutate(
                "upload_resume",
                ["name": .string(file.name), "content": .string(file.content)],
                notice: "Your resume is saved privately.",
                timeout: 90
            )
        } catch { if generation == store.sessionGeneration { store.fail(error) } }
    }
}

/// Scoring and tailoring live on their own screen so the resume list stays short.
@MainActor
private struct ResumeTailorSheet: View {
    @Binding var setupFor: String
    @Binding var scores: [String: JSON]
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskTarget?
    @State private var details: ResumeItem?
    @State private var showBank = false

    var body: some View {
        SheetPage(title: "Tailor for a job") {
            ResumeAgentsSection(setupFor: $setupFor, scores: $scores, onOpenTask: { task = TaskTarget(id: $0) }, onNavigate: navigate)
        }
        .sheet(item: $task) { target in AgentTaskSheet(taskID: target.id).environment(store) }
        .sheet(item: $details) { resume in ResumeDetailsView(resume: resume).environment(store) }
        .sheet(isPresented: $showBank) { ExperienceBankView().environment(store) }
    }

    private func navigate(_ action: String) {
        switch action {
        case "resume-details":
            if let first = store.account.resumes.first { details = store.account.resume(store.account.selectedResumeID) ?? first }
        case "resume-bank":
            showBank = true
        case "resume":
            break
        default:
            dismiss()
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
        }
    }
}

struct TaskTarget: Identifiable {
    let id: String
}

struct PDFPreview: Identifiable {
    let id = UUID()
    let name: String
    let data: Data
}

@MainActor
struct PDFSheet: View {
    let preview: PDFPreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    BackButton(label: "Close") { dismiss() }
                        .accessibilityIdentifier("pdf-preview-close")
                    Text(preview.name).font(Typeface.section).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, Spacing.page)
                PDFKitView(data: preview.data).clipShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
                    .padding(.horizontal, 12)
                    .accessibilityIdentifier("pdf-preview")
            }
            .padding(.top, 16)
        }
    }
}

struct PDFKitView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(data: data)
        view.backgroundColor = UIColor(Palette.oat)
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {}
}

/// Everything you can do with one resume: look at it, review what Stack read, set its format, or manage it.
@MainActor
struct ManageResumeSheet: View {
    let resume: ResumeItem
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var name = ""
    @State var confirmDelete = false
    @State private var preview: PDFPreview?
    @State private var details: ResumeItem?
    @State private var formatting: ResumeItem?
    @State private var opening = false
    @State private var seeded = false

    var body: some View {
        SheetPage(title: resume.name) {
            VStack(spacing: 0) {
                ListRow(label: opening ? "Opening…" : "Preview", icon: "play") { Task { await open() } }
                ListRow(label: "Review details", icon: "check", detail: resume.detailsStatus) { details = resume }
                ListRow(label: "Format", icon: "resume", detail: store.account.format(of: resume.id)["label"].string) { formatting = resume }
            }
            MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
            DisclosureSection("Manage") {
                VStack(alignment: .leading, spacing: Spacing.option) {
                    StackField(label: "Resume name", text: $name)
                    StackButton(label: "Rename", disabled: store.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || name == resume.name) {
                        Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "rename", "name": .string(name)]) { dismiss() } }
                    }
                    StackButton(label: "Use as default resume", icon: "check", disabled: store.busy || resume.id == store.account.selectedResumeID) {
                        Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "select"]) { dismiss() } }
                    }
                    StackButton(label: "Delete this resume", icon: "trash", kind: .secondary, disabled: store.busy) { confirmDelete = true }
                }
            }
        }
        .onAppear { if !seeded { name = resume.name; seeded = true } }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .sheet(item: $details) { resume in ResumeDetailsView(resume: resume).environment(store) }
        .sheet(item: $formatting) { resume in ResumeFormatView(resume: resume).environment(store) }
        .confirmationDialog("Delete this resume?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "delete"], notice: "Resume deleted.") { dismiss() } }
            }
        } message: {
            Text("This removes the file from your Stack account.")
        }
    }

    private func open() async {
        guard !opening else { return }
        opening = true
        store.error = ""
        defer { opening = false }
        do {
            let result = try await store.call("read_resume", ["id": .string(resume.id)], timeout: 45)
            preview = try PDFPreview.make(name: resume.name, base64: result["content"].string)
        } catch { store.fail(error) }
    }
}

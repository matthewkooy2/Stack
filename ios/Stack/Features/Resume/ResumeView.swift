import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
struct ResumeView: View {
    @Environment(AppStore.self) private var store
    var onProfile: () -> Void

    @State var importing = false
    @State var uploading = false
    @State var preview: PDFPreview?
    @State var managing: ResumeItem?
    @State var details: ResumeItem?
    @State var formatting: ResumeItem?
    @State var taskID: TaskTarget?
    @State var showBank = false

    private var processingActive: Bool {
        store.account.resumes.contains { resume in
            let state = store.account.processing(of: resume.id)
            return ["queued", "parsing", "compiling"].contains(state["pdf"]["status"].string)
                || ["queued", "parsing", "compiling"].contains(state["source"]["status"].string)
        }
    }

    var body: some View {
        Page {
            ScreenHeader(title: "Resume", subtitle: "Kept private to your account", onProfile: onProfile).reveal(0)
            StackButton(label: uploading ? "Uploading…" : "Upload a PDF resume", icon: "upload", disabled: uploading || store.busy) {
                importing = true
            }
            .reveal(1)

            StoreMessages()

            if store.account.resumes.isEmpty {
                EmptyNote(icon: "resume", title: "No resume yet", message: "Upload a PDF and Stack will read it so you can tailor it to each role.")
            } else {
                VStack(spacing: Spacing.option) {
                    ForEach(Array(store.account.resumes.enumerated()), id: \.element.id) { index, resume in
                        resumeRow(resume, index: index)
                    }
                }
            }

            TailoredResumesSection()
            ResumeAgentsSection(onOpenTask: { taskID = TaskTarget(id: $0) }, onNavigate: navigate)
            StackButton(label: "Experience bank", icon: "resume", kind: .secondary) { showBank = true }
        }
        .refreshable { await store.refresh() }
        .pollsWhileProcessing(processingActive)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            Task { await upload(result) }
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .sheet(item: $managing) { resume in ManageResumeSheet(resume: resume).environment(store) }
        .sheet(item: $details) { resume in ResumeDetailsView(resume: resume).environment(store) }
        .sheet(item: $formatting) { resume in ResumeFormatView(resume: resume).environment(store) }
        .sheet(item: $taskID) { target in AgentTaskSheet(taskID: target.id).environment(store) }
        .sheet(isPresented: $showBank) { ExperienceBankView().environment(store) }
    }

    private func navigate(_ action: String) {
        if action == "resume-details", let first = store.account.resumes.first {
            details = store.account.resume(store.account.selectedResumeID) ?? first
        } else if action == "resume-bank" {
            showBank = true
        } else if action != "resume" {
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
        }
    }

    private func resumeRow(_ resume: ResumeItem, index: Int) -> some View {
        let isDefault = resume.id == store.account.selectedResumeID
        let state = store.account.processing(of: resume.id)
        let format = store.account.format(of: resume.id)
        return Card(tint: index.isMultiple(of: 2) ? Palette.surface : Palette.oat, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                GlyphView(name: "resume", size: 26).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(resume.name).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text("\(resume.detailsStatus) · \(shortDate(resume.createdAt))")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    if !format["label"].string.isEmpty {
                        Text("Format: \(format["label"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
                Spacer()
                if isDefault { Chip(label: "Default", selected: true) }
            }
            ProcessingStatusView(resumeID: resume.id, kind: "pdf", processing: state["pdf"])
            ProcessingStatusView(resumeID: resume.id, kind: "source", processing: state["source"])
            FlowLayout(spacing: 8) {
                Chip(label: "Preview") { Task { await open(resume) } }
                Chip(label: "Review details") { details = resume }
                Chip(label: "Format") { formatting = resume }
                Chip(label: "Manage") { managing = resume }
            }
        }
        .reveal(index + 2)
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

    private func open(_ resume: ResumeItem) async {
        store.error = ""
        do {
            let result = try await store.call("read_resume", ["id": .string(resume.id)], timeout: 45)
            preview = try PDFPreview.make(name: resume.name, base64: result["content"].string)
        } catch { store.fail(error) }
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
                    Text(preview.name).font(Typeface.section).foregroundStyle(Palette.ink).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, Spacing.page)
                PDFKitView(data: preview.data).clipShape(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
                    .padding(.horizontal, 12)
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

@MainActor
struct ManageResumeSheet: View {
    let resume: ResumeItem
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var name = ""
    @State var confirmDelete = false

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.stack) {
                HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                Text("Manage resume").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                StackField(label: "Resume name", text: $name)
                StackButton(label: "Rename", disabled: store.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || name == resume.name) {
                    Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "rename", "name": .string(name)]) { dismiss() } }
                }
                StackButton(label: "Use as default resume", icon: "check", disabled: store.busy || resume.id == store.account.selectedResumeID) {
                    Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "select"]) { dismiss() } }
                }
                StackButton(label: "Delete this resume", icon: "trash", kind: .secondary, disabled: store.busy) { confirmDelete = true }
                MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                Spacer()
            }
            .padding(Spacing.page)
        }
        .onAppear { name = resume.name }
        .presentationDetents([.medium])
        .confirmationDialog("Delete this resume?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "delete"], notice: "Resume deleted.") { dismiss() } }
            }
        } message: {
            Text("This removes the file from your Stack account.")
        }
    }
}

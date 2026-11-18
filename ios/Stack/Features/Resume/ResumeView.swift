import SwiftUI
import PDFKit
import UniformTypeIdentifiers

@MainActor
struct ResumeView: View {
    @Environment(AppStore.self) private var store
    var onProfile: () -> Void
    var isActive = true
    @Environment(\.dynamicTypeSize) private var typeSize

    @State var importing = false
    @State private var uploader = ResumeUploader()
    @State private var uploadGeneration = -1
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State var managing: ResumeItem?
    @State private var linkedDetails: ResumeItem?
    @State var showTailor = false
    @State var showTailored = false
    @State var showBank = false
    @State private var setupFor = ""
    @State private var scores: [String: JSON] = [:]
    @State private var verifiedTypes: [String: String] = [:]

    private var processingActive: Bool {
        store.account.raw["resumes"].array.contains { resume in
            let state = resume["processing"]
            return ["queued", "parsing", "compiling"].contains(state[ResumeLane.structured]["status"].string)
                || ["queued", "parsing", "compiling"].contains(state["source"]["status"].string)
        }
    }

    var body: some View {
        CollectionPage(title: "Resume", onProfile: onProfile) {
            if !store.account.resumes.isEmpty {
                Button(action: chooseFile) {
                    Image(systemName: "plus").font(.title3.weight(.medium))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .foregroundStyle(Brand.accent).disabled(uploader.isBusy)
                .accessibilityLabel("Upload a resume")
                .accessibilityIdentifier("resume-upload")
            }
            if store.account.resumes.isEmpty || store.account.resumes.count > 2 { libraryMenu }
        } content: { height in
            if store.account.resumes.isEmpty {
                ResumeUploadScreen(uploading: uploader.isBusy, fileName: uploader.fileName,
                                   error: uploader.phase == .failed ? uploader.message : store.error,
                                   progress: uploader.progress, onUpload: chooseFile, onRetry: retryAction)
                    .invitation.frame(minHeight: height)
                    .transition(.opacity)
            } else {
                library(viewportHeight: height).id(store.sessionGeneration).transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: min(store.account.resumes.count, 3))
        .refreshable { await store.refresh() }
        .pollsWhileProcessing(isActive && processingActive)
        .fileImporter(isPresented: $importing, allowedContentTypes: ResumeFiles.allowedTypes) { result in
            // Progress shows in this turn of the run loop; the read and the request happen after it.
            guard store.phase == .ready, uploadGeneration == store.sessionGeneration, uploader.picked(result) else { return }
            startUpload()
        }
        .onChange(of: importing) { _, open in
            if !open { uploader.pickerClosed(); openLinkedRoute() }
        }
        .sheet(item: $managing, onDismiss: openLinkedRoute) { resume in ManageResumeSheet(resume: resume).environment(store) }
        .onChange(of: store.sessionGeneration) { _, _ in
            setupFor = ""; scores = [:]; verifiedTypes = [:]; importing = false; uploader.reset()
        }
        .fullScreenCover(isPresented: $showTailor, onDismiss: openLinkedRoute) {
            ResumeTailorSheet(setupFor: $setupFor, scores: $scores).environment(store)
        }
        .sheet(isPresented: $showTailored, onDismiss: openLinkedRoute) {
            SheetPage(title: "Tailored resumes") { TailoredResumesSection() }.environment(store)
        }
        .fullScreenCover(isPresented: $showBank, onDismiss: openLinkedRoute) { MemoryBankView().environment(store) }
        .fullScreenCover(item: $linkedDetails, onDismiss: openLinkedRoute) { resume in
            ResumeDetailsView(resume: resume).environment(store)
        }
        .onChange(of: store.pendingOpen["resume_route"]) { _, _ in openLinkedRoute() }
        .onChange(of: isActive, initial: true) { _, _ in openLinkedRoute() }
    }

    /// A link may arrive while another document sheet is presented. Finish dismissing it first.
    private func openLinkedRoute() {
        guard isActive, !importing, let route = store.pendingOpen["resume_route"],
              ["resume-bank", "resume-details"].contains(route) else { return }
        if managing != nil { managing = nil; return }
        if showTailor { showTailor = false; return }
        if showTailored { showTailored = false; return }
        if showBank && route != "resume-bank" { showBank = false; return }
        if linkedDetails != nil && route != "resume-details" { linkedDetails = nil; return }

        store.pendingOpen.removeValue(forKey: "resume_route")
        if route == "resume-bank" {
            showBank = true
        } else {
            linkedDetails = store.account.resume(store.account.selectedResumeID) ?? sortedFiles.first
        }
    }

    private var libraryMenu: some View {
        Menu {
            if store.account.resumes.isEmpty {
                Button { showTailor = true } label: { Label("Tailor for a job", systemImage: "wand.and.stars") }
            }
            if !store.account.tailored.isEmpty {
                Button { showTailored = true } label: { Label("Tailored resumes", systemImage: "doc.on.doc") }
            }
            Button { showBank = true } label: { Label("Memory bank", systemImage: "archivebox") }
        } label: {
            Image(systemName: "ellipsis").font(.title3.weight(.semibold))
                .foregroundStyle(Brand.ink).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Resume options")
    }

    private var sortedFiles: [ResumeItem] {
        let selected = store.account.selectedResumeID
        return store.account.resumes.sorted { lhs, rhs in
            if (lhs.id == selected) != (rhs.id == selected) { return lhs.id == selected }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func library(viewportHeight: CGFloat) -> some View {
        let files = sortedFiles
        return VStack(alignment: .leading, spacing: 16) {
            StoreMessages()
            if uploader.isBusy {
                ProgressView(uploader.progress).font(Typeface.caption)
            } else if uploader.phase == .failed {
                MessageLine(text: uploader.message).accessibilityIdentifier("resume-upload-error")
                if uploader.canRetry {
                    Button("Try again", action: retryUpload)
                        .frame(minHeight: 44).foregroundStyle(Brand.accent)
                        .accessibilityHint(uploader.fileName)
                        .accessibilityIdentifier("resume-upload-retry")
                }
            }

            if files.count <= 2 {
                let featured = files.count == 1
                let columns = featured || typeSize.isAccessibilitySize ? 1 : 2
                let coverHeight = featured ? min(340, max(176, viewportHeight * 0.46)) : 144
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: columns),
                          alignment: .leading, spacing: 18) {
                    ForEach(files) { resume in
                        shelfFile(resume, height: coverHeight, featured: featured)
                    }
                }
                .padding(.top, featured ? min(32, viewportHeight * 0.04) : 12)
                ForEach(files) { resume in
                    processingStatus(resume, showName: files.count > 1)
                }
                Divider()
                VStack(alignment: .leading, spacing: 0) {
                    ListRow(label: "Tailor for a job", icon: "sparkles") { showTailor = true }
                    if !store.account.tailored.isEmpty {
                        ListRow(label: "Tailored resumes", icon: "resume", detail: "\(store.account.tailored.count) saved") { showTailored = true }
                    }
                    ListRow(label: "Memory bank", icon: "star") { showBank = true }
                }
            } else {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                    : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
                layout {
                    Text("\(files.count) files").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.muted)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    tailorAction
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(files) { resume in
                        compactFile(resume)
                        processingStatus(resume, showName: false)
                        Divider()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tailorAction: some View {
        Button { showTailor = true } label: {
            Label("Tailor for a job", systemImage: "wand.and.stars")
                .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        }
        .foregroundStyle(Brand.accent)
        .accessibilityHint(store.account.applications.contains { !$0.isDemo } ? "Score or rewrite for a saved job" : "Save a job from Jobs first")
    }

    private func shelfFile(_ resume: ResumeItem, height: CGFloat, featured: Bool) -> some View {
        Button { managing = resume } label: {
            VStack(alignment: featured ? .center : .leading, spacing: featured ? 18 : 10) {
                ResumeDocumentCover(resume: resume, isActive: isActive) { format in
                    verifiedTypes[resume.id] = format
                }
                .id(resume.size)
                .frame(height: height)
                .frame(maxWidth: .infinity, alignment: .center)
                fileCaption(resume, compact: false, centered: featured)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(resume.name)
        .accessibilityValue(fileAccessibilityValue(resume))
        .accessibilityHint("Open file actions")
    }

    private func compactFile(_ resume: ResumeItem) -> some View {
        Button { managing = resume } label: {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.title3).foregroundStyle(Brand.accent)
                    .frame(width: 28).accessibilityHidden(true)
                fileCaption(resume, compact: true)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .padding(.vertical, 12).frame(minHeight: 58).contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.99))
        .accessibilityLabel(resume.name)
        .accessibilityValue(fileAccessibilityValue(resume))
        .accessibilityHint("Open file actions")
    }

    private func fileCaption(_ resume: ResumeItem, compact: Bool, centered: Bool = false) -> some View {
        let isDefault = resume.id == store.account.selectedResumeID
        let status = resume.detailsStatus == "Review" ? "Needs review" : resume.detailsStatus
        let metadata = [verifiedTypes[resume.id] ?? "", resume.librarySize, resume.libraryDate]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        return VStack(alignment: centered ? .center : .leading, spacing: 4) {
            Text(resume.name).font(centered ? .title3.weight(.semibold) : .headline)
                .lineLimit(compact ? 1 : 2).truncationMode(.middle).foregroundStyle(Brand.ink)
            if !metadata.isEmpty {
                Text(metadata).font(.footnote).foregroundStyle(Brand.muted)
            }
            if isDefault || !status.isEmpty {
                Text([isDefault ? "Default" : "", status].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption.weight(.medium)).foregroundStyle(isDefault ? Brand.accent : Brand.muted)
            }
        }
        .multilineTextAlignment(centered ? .center : .leading)
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    private func fileAccessibilityValue(_ resume: ResumeItem) -> String {
        [resume.id == store.account.selectedResumeID ? "Default" : "", resume.detailsStatus,
         verifiedTypes[resume.id] ?? "", resume.librarySize, resume.libraryDate].filter { !$0.isEmpty }.joined(separator: ", ")
    }

    @ViewBuilder
    private func processingStatus(_ resume: ResumeItem, showName: Bool) -> some View {
        let state = store.account.processing(of: resume.id)
        let lanes = [ResumeLane.structured, ResumeLane.source].filter {
            ["queued", "parsing", "compiling", "failed"].contains(state[$0]["status"].string)
        }
        if !lanes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if showName {
                    Text(resume.name).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                        .lineLimit(1).truncationMode(.middle)
                }
                ForEach(lanes, id: \.self) { lane in
                    ProcessingStatusView(resumeID: resume.id, kind: lane, processing: state[lane])
                }
            }
            .padding(.vertical, 8)
        }
    }

    /// The upload tap: shows "Opening files…" at once and opens the picker only if no upload is open or running.
    private func chooseFile() {
        guard uploader.begin() else { return }
        uploadGeneration = store.sessionGeneration
        importing = true
    }

    private var retryAction: (() -> Void)? { uploader.canRetry ? { retryUpload() } : nil }

    private func retryUpload() {
        guard uploader.retry() else { return }
        startUpload()
    }

    private func startUpload() {
        store.error = ""
        store.notice = ""
        Task { await upload() }
    }

    /// One request per attempt. `callAccount` drops answers for an ended session and reports a busy account
    /// instead of silently skipping the upload; a failure keeps the file for Try again.
    private func upload() async {
        let generation = uploadGeneration
        let uploaded = await uploader.run { file in
            guard generation == store.sessionGeneration, store.phase == .ready else { throw CancellationError() }
            _ = try await store.callAccount("upload_resume", ["name": .string(file.name), "content": .string(file.content)], timeout: 90)
        }
        if uploaded { store.notice = "Your resume is saved privately." }
    }
}

/// Scoring and tailoring live on their own screen so the resume list stays short.
@MainActor
struct ResumeTailorSheet: View {
    @Binding var setupFor: String
    @Binding var scores: [String: JSON]
    var initialApplicationID = ""
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskTarget?
    @State private var details: ResumeItem?
    @State private var showBank = false

    var body: some View {
        ResumeAgentsSection(setupFor: $setupFor, scores: $scores, onOpenTask: { task = TaskTarget(id: $0) },
                            onNavigate: navigate, initialApplicationID: initialApplicationID)
        .sheet(item: $task) { target in AgentTaskSheet(taskID: target.id).environment(store) }
        .fullScreenCover(item: $details) { resume in ResumeDetailsView(resume: resume).environment(store) }
        .fullScreenCover(isPresented: $showBank) { MemoryBankView().environment(store) }
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
        view.backgroundColor = UIColor(Palette.page)
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
                ListRow(label: opening ? "Opening…" : "Preview", icon: "resume") { Task { await open() } }
                ListRow(label: "Review details", icon: "check", detail: resume.detailsStatus) { details = resume }
                let format = store.account.format(of: resume.id)
                ListRow(label: "Format", icon: "resume", detail: format["kind"].string == "upload" ? "Uploaded design" : format["label"].string) { formatting = resume }
                if resume.id != store.account.selectedResumeID {
                    ListRow(label: "Use as default resume", icon: "check") {
                        Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "select"]) { dismiss() } }
                    }
                    .disabled(store.busy)
                }
            }
            MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
            DisclosureSection("Manage") {
                VStack(alignment: .leading, spacing: Spacing.option) {
                    StackField(label: "Resume name", text: $name)
                    StackButton(label: "Rename", disabled: store.busy || name.trimmingCharacters(in: .whitespaces).isEmpty || name == resume.name) {
                        Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "rename", "name": .string(name)]) { dismiss() } }
                    }
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete this resume", systemImage: "trash").frame(minHeight: 44)
                    }
                    .disabled(store.busy)
                }
            }
        }
        .onAppear { if !seeded { name = resume.name; seeded = true } }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .fullScreenCover(item: $details) { resume in ResumeDetailsView(resume: resume).environment(store) }
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

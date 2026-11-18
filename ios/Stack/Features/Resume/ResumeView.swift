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
                HeaderIconButton(systemName: "plus", label: "Upload a resume", action: chooseFile)
                    .disabled(uploader.isBusy)
                    .accessibilityIdentifier("resume-upload")
            }
            libraryMenu
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
        HeaderMenu("ellipsis", label: "Resume options") {
            if store.account.resumes.isEmpty {
                Button { showTailor = true } label: { Label("Tailor for a job", systemImage: "wand.and.stars") }
            }
            if !store.account.tailored.isEmpty {
                Button { showTailored = true } label: { Label("Tailored resumes", systemImage: "doc.on.doc") }
            }
            Button { showBank = true } label: { Label("Experience", systemImage: "archivebox") }
        }
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
        let selected = store.account.selectedResumeID
        let defaultFile = files.first { $0.id == selected }
        let others = files.filter { $0.id != defaultFile?.id }
        return VStack(alignment: .leading, spacing: Spacing.stack) {
            StoreMessages()
            if uploader.isBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(uploader.progress).font(Typeface.caption).foregroundStyle(Brand.muted)
                }
            } else if uploader.phase == .failed {
                VStack(alignment: .leading, spacing: 4) {
                    MessageLine(text: uploader.message).accessibilityIdentifier("resume-upload-error")
                    if uploader.canRetry {
                        Button("Try again", action: retryUpload)
                            .frame(minHeight: 44).foregroundStyle(Brand.accent)
                            .accessibilityHint(uploader.fileName)
                            .accessibilityIdentifier("resume-upload-retry")
                    }
                }
            }

            tailorCard

            if files.count <= 2 {
                let featured = files.count == 1
                let columns = featured || typeSize.isAccessibilitySize ? 1 : 2
                let coverHeight = featured ? min(300, max(176, viewportHeight * 0.40)) : 150
                VStack(alignment: .leading, spacing: 12) {
                    if !featured { SectionHeader(title: "Resumes · \(files.count)") }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                              alignment: .leading, spacing: 12) {
                        ForEach(files) { resume in
                            shelfFile(resume, height: coverHeight, showsDefault: !featured)
                        }
                    }
                    ForEach(files) { resume in
                        processingStatus(resume, showName: files.count > 1)
                    }
                }
                libraryLinks
            } else {
                if let defaultFile {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Default resume")
                        defaultCard(defaultFile)
                        processingStatus(defaultFile, showName: false)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: defaultFile == nil ? "All resumes · \(files.count)" : "Other resumes · \(others.count)")
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(others.enumerated()), id: \.element.id) { index, resume in
                            if index > 0 { Divider().padding(.leading, 52) }
                            compactFile(resume)
                            processingStatus(resume, showName: false)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 4)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .stackElevation()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tailorCard: some View {
        Button { showTailor = true } label: {
            HStack(spacing: 14) {
                Image(systemName: "wand.and.stars").font(.title3.weight(.semibold))
                    .foregroundStyle(.white).frame(width: 44, height: 44)
                    .background(.white.opacity(0.18), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tailor for a job").font(.headline).foregroundStyle(.white)
                    Text("Match a resume to a saved job").font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward").font(.footnote.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85)).accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Brand.gradient, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98))
        .accessibilityLabel("Tailor for a job")
        .accessibilityHint(store.account.applications.contains { !$0.isDemo } ? "Score or rewrite for a saved job" : "Save a job from Jobs first")
    }

    /// Quiet entry points under the shelf; with a longer library these live in the header menu.
    private var libraryLinks: some View {
        VStack(spacing: 0) {
            if !store.account.tailored.isEmpty {
                libraryLink("Tailored resumes", symbol: "doc.on.doc", detail: "\(store.account.tailored.count)") { showTailored = true }
                Divider().padding(.leading, 52)
            }
            libraryLink("Experience", symbol: "archivebox", detail: "") { showBank = true }
        }
        .padding(.horizontal, 16).padding(.vertical, 4)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .stackElevation()
    }

    private func libraryLink(_ title: String, symbol: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.body.weight(.medium)).foregroundStyle(Brand.accent)
                    .frame(width: 40, height: 40).background(Palette.halo, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                Text(title).font(.body.weight(.medium)).foregroundStyle(Brand.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(Brand.muted) }
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .padding(.vertical, 10).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(detail.isEmpty ? title : "\(title), \(detail)")
    }

    // MARK: Files

    private func isDefault(_ resume: ResumeItem) -> Bool { resume.id == store.account.selectedResumeID }

    private func metaLine(_ resume: ResumeItem) -> String {
        [verifiedTypes[resume.id] ?? resume.fileKind, resume.shortLibraryDate].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Only states that need attention get a pill; a confirmed resume is the normal case.
    @ViewBuilder
    private func statePill(_ resume: ResumeItem) -> some View {
        switch resume.detailsStatus {
        case "Review", "Needs review": StatusPill(text: "Needs review", tone: .warning)
        case "Processing": StatusPill(text: "Processing", tone: .accent).shimmer()
        case "Import failed": StatusPill(text: "Import failed", tone: .danger)
        default: EmptyView()
        }
    }

    private func pills(_ resume: ResumeItem, showsDefault: Bool) -> some View {
        HStack(spacing: 6) {
            if showsDefault && isDefault(resume) { StatusPill(text: "Default", tone: .accent) }
            statePill(resume)
        }
    }

    private func shelfFile(_ resume: ResumeItem, height: CGFloat, showsDefault: Bool) -> some View {
        Button { managing = resume } label: {
            VStack(alignment: .leading, spacing: 12) {
                ResumeDocumentCover(resume: resume, isActive: isActive) { format in
                    verifiedTypes[resume.id] = format
                }
                .id(resume.size)
                .frame(height: height)
                .padding(.vertical, 18).padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .background(Brand.page, in: RoundedRectangle(cornerRadius: Radius.control + 2, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(resume.displayName).font(.headline).foregroundStyle(Brand.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !metaLine(resume).isEmpty {
                        Text(metaLine(resume)).font(.footnote).foregroundStyle(Brand.muted)
                    }
                    pills(resume, showsDefault: showsDefault).padding(.top, 3)
                }
                .padding(.horizontal, 4).padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(resume.name)
        .accessibilityValue(fileAccessibilityValue(resume))
        .accessibilityHint("Open file actions")
    }

    private func defaultCard(_ resume: ResumeItem) -> some View {
        Button { managing = resume } label: {
            HStack(spacing: 16) {
                ResumeDocumentCover(resume: resume, isActive: isActive) { format in
                    verifiedTypes[resume.id] = format
                }
                .id(resume.size)
                .frame(width: 76, height: 100)
                VStack(alignment: .leading, spacing: 4) {
                    Text(resume.displayName).font(.headline).foregroundStyle(Brand.ink)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if !metaLine(resume).isEmpty {
                        Text(metaLine(resume)).font(.footnote).foregroundStyle(Brand.muted)
                    }
                    pills(resume, showsDefault: true).padding(.top, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(resume.name)
        .accessibilityValue(fileAccessibilityValue(resume))
        .accessibilityHint("Open file actions")
    }

    /// PDF is rose, Word is blue, anything else neutral, each with its own symbol.
    private func fileTile(for resume: ResumeItem) -> (symbol: String, tint: Palette.Tint) {
        switch verifiedTypes[resume.id] ?? resume.fileKind {
        case "PDF": return ("doc.richtext.fill", Palette.tints[4])
        case "DOCX", "DOC": return ("doc.text.fill", Palette.tints[0])
        default: return ("doc.fill", Palette.Tint(fill: Palette.muted.opacity(0.12), ink: Palette.muted))
        }
    }

    private func compactFile(_ resume: ResumeItem) -> some View {
        let tile = fileTile(for: resume)
        return Button { managing = resume } label: {
            HStack(spacing: 12) {
                Image(systemName: tile.symbol).font(.body)
                    .foregroundStyle(tile.tint.ink)
                    .frame(width: 40, height: 40)
                    .background(tile.tint.fill, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(resume.displayName).font(.body.weight(.medium)).foregroundStyle(Brand.ink).lineLimit(1)
                    if !metaLine(resume).isEmpty {
                        Text(metaLine(resume)).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                statePill(resume)
                Image(systemName: "chevron.forward").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .padding(.vertical, 10).frame(minHeight: 56).contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel(resume.name)
        .accessibilityValue(fileAccessibilityValue(resume))
        .accessibilityHint("Open file actions")
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
        if uploaded { store.notice = "Resume saved" }
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
        SheetPage(title: resume.displayName, subtitle: [resume.fileKind, resume.shortLibraryDate].filter { !$0.isEmpty }.joined(separator: " · ")) {
            VStack(spacing: 0) {
                ListRow(label: opening ? "Opening…" : "Preview", icon: "resume") { Task { await open() } }
                ListRow(label: "Review details", icon: "check") { details = resume } trailing: {
                    HStack(spacing: 8) {
                        if ["Review", "Needs review"].contains(resume.detailsStatus) { StatusPill(text: "Needs review", tone: .warning) }
                        GlyphView(name: "chevron", size: 13, color: Palette.muted)
                    }
                }
                let format = store.account.format(of: resume.id)
                let template = ResumeTemplate.label(for: format["template"].string, fallback: format["label"].string)
                ListRow(label: "Template", icon: "resume", detail: format["kind"].string == "upload" ? "Your layout" : template) { formatting = resume }
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
                        Label("Delete resume", systemImage: "trash").frame(minHeight: 44)
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
                Task { if await store.mutate("change_resume", ["id": .string(resume.id), "action": "delete"], notice: "Resume deleted") { dismiss() } }
            }
        } message: {
            Text("This can't be undone")
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

import SwiftUI
import PDFKit

@MainActor
struct ResumeAgentsSection: View {
    @Binding var setupFor: String
    @Binding var scores: [String: JSON]
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var jobID = ""
    @State private var resumeID = ""
    @State private var showJobs = false
    @State private var showResumes = false
    @State private var showSetup = false
    @State private var showProfile = false
    @State private var profileMessage = ""
    @State private var working = false
    @State private var error = ""
    @State private var pdf: PDFDocument?
    @State private var startedTask = ""

    private var applications: [Application] { store.account.applications.filter { !$0.isDemo } }
    private var job: Application? { applications.first { $0.id == jobID } }
    private var resume: ResumeItem? { store.account.resumes.first { $0.id == resumeID } }

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            if !startedTask.isEmpty {
                progressScreen.transition(.opacity)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BackButton(label: "Close") { dismiss() }
                        Spacer()
                        if store.account.feature("profile") != nil {
                            Menu { Button("Profile suggestions") { showProfile = true } } label: {
                                Image(systemName: "ellipsis").foregroundStyle(Brand.ink).frame(width: 44, height: 44).background(.white, in: Circle())
                            }.accessibilityLabel("More options")
                        }
                    }.padding(.bottom, 32)
                    Text("Tailor your resume").font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                    if let pdf {
                        PDFKitView(data: pdf.dataRepresentation() ?? Data())
                            .frame(height: 260).frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4)).padding(.vertical, 28)
                            .allowsHitTesting(false).accessibilityLabel("Resume preview")
                    } else {
                        Image(systemName: "doc.text").font(.system(size: 56, weight: .light)).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity).frame(height: 210).accessibilityHidden(true)
                    }
                    row(label: resume?.name ?? "Choose a resume", action: { showResumes = true })
                    row(label: job.map { "\($0.job.title) · \($0.job.company)" } ?? "Choose a saved job", action: { showJobs = true })
                    if let job {
                        if let score = scores[job.id] { ScoreCardView(after: score["score"], title: "Job fit") }
                        Button("Check job fit") { Task { await score(job) } }
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                            .frame(minHeight: 44).disabled(working || resume == nil)
                    }
                    MessageLine(text: error).fadeSwitch(!error.isEmpty)
                }.padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 24)
            }.safeAreaInset(edge: .bottom) {
                StackButton(label: working ? "Preparing…" : "Tailor resume", disabled: working || job == nil || resume == nil) {
                    Task { await start() }
                }.padding(.horizontal, Spacing.page).padding(.vertical, 12).background(Brand.page)
            }
            }
        }
        .replayable()
        .onAppear {
            if jobID.isEmpty { jobID = applications.first?.id ?? "" }
            if resumeID.isEmpty {
                let suggested = job?.tailorResumeID ?? ""
                resumeID = !suggested.isEmpty ? suggested : store.account.selectedResumeID
                if resumeID.isEmpty { resumeID = store.account.resumes.first?.id ?? "" }
            }
        }
        .onChange(of: resumeID) { _, _ in scores.removeAll() }
        .task(id: resumeID) { await loadPDF() }
        .sheet(isPresented: $showJobs) {
            SheetPage(title: "Choose a job") {
                if applications.isEmpty { Text("Save a job first.").foregroundStyle(Brand.muted) }
                ForEach(applications) { item in
                    ListRow(label: item.job.title, icon: "briefcase", detail: item.job.company) { jobID = item.id; showJobs = false }
                }
            }
        }
        .sheet(isPresented: $showResumes) {
            SheetPage(title: "Choose a resume") {
                ForEach(store.account.resumes) { item in
                    ListRow(label: item.name, icon: "resume", detail: item.detailsStatus) { resumeID = item.id; showResumes = false }
                }
            }
        }
        .sheet(isPresented: $showProfile) {
            SheetPage(title: "Profile suggestions") {
                if let profile = store.account.feature("profile") {
                    FeatureCardView(feature: profile, onAction: onNavigate, compact: true)
                    ForEach(Array(store.account.runViews.filter { $0["target_id"].string == "self" && $0["kind"].string == "profile" }.prefix(1).enumerated()), id: \.offset) { _, run in
                        TaskRow(run: run) { onOpenTask(run["id"].string) }
                    }
                    StackButton(label: "Suggest headline & about", kind: .secondary, disabled: working || profile.state == "unavailable") {
                        Task {
                            working = true; defer { working = false }
                            do { let result = try await store.call("agent_start", ["kind": "profile", "target_id": "self"]); profileMessage = "\(result["title"].string) started." }
                            catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                        }
                    }
                    MessageLine(text: profileMessage, isError: false).fadeSwitch(!profileMessage.isEmpty)
                    MessageLine(text: error).fadeSwitch(!error.isEmpty)
                }
            }
        }
        .sheet(isPresented: $showSetup) {
            if let resume {
                SheetPage(title: "Prepare your resume") {
                    LatexSetupView(resume: resume, others: store.account.resumes.filter { store.account.hasLatex($0.id) && $0.id != resume.id }) { chosen in
                        resumeID = chosen; showSetup = false; await start()
                    }
                }
            }
        }
    }

    private var progressScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            BackButton(label: "Back to tailoring") {
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { startedTask = "" }
            }.padding(.bottom, 32)
            Text("Tailoring for\n\(job?.job.company ?? "this job")")
                .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            VStack(spacing: 16) {
                ProgressView().tint(Brand.accent).scaleEffect(1.3)
                Text("Tailoring started").font(.system(size: 25, weight: .semibold)).foregroundStyle(Brand.ink)
                Text("Follow your task for progress and review.").font(Typeface.caption).foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
            Spacer()
            StackButton(label: "View task") { onOpenTask(startedTask) }
        }.padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 12)
    }

    private func row(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(label).font(Typeface.section).foregroundStyle(Brand.ink).multilineTextAlignment(.leading)
                Spacer()
                Text("Change").font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
            }.frame(minHeight: 72).contentShape(Rectangle())
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
        }.buttonStyle(.plain)
    }

    private func loadPDF() async {
        pdf = nil
        guard !resumeID.isEmpty else { return }
        let id = resumeID
        do {
            let result = try await store.call("read_resume", ["id": .string(id)])
            if id == resumeID, let data = Data(base64Encoded: result["content"].string) { pdf = PDFDocument(data: data) }
        } catch { }
    }
    private func selectResume(for job: Application) async throws {
        if resumeID != job.tailorResumeID {
            try await store.callAccount("select_application_resume", ["id": .string(job.id), "resume_id": .string(resumeID)])
        }
    }
    private func start() async {
        guard let job, resume != nil, !working else { return }
        working = true; error = ""; defer { working = false }
        do {
            try await selectResume(for: job)
            if !(store.account.applications.first { $0.id == job.id }?.tailorReady ?? false) { showSetup = true; return }
            let result = try await store.call("agent_start", ["kind": "resume", "target_id": .string(job.id)])
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { startedTask = result["id"].string }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
    private func score(_ job: Application) async {
        guard !working else { return }; working = true; error = ""; defer { working = false }
        let scoredResumeID = resumeID
        do {
            try await selectResume(for: job)
            let result = try await store.call("score_resume", ["application_id": .string(job.id)])
            if resumeID == scoredResumeID { scores[job.id] = result }
        }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

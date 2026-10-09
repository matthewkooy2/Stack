import SwiftUI

/// Resume-side agents: scoring and tailoring for a saved job, and profile suggestions.
@MainActor
struct ResumeAgentsSection: View {
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var working = false
    @State private var setupFor = ""
    @State private var scores: [String: JSON] = [:]
    @State private var scoring = ""
    @State private var message = ""
    @State private var error = ""

    private var applications: [Application] { store.account.applications.filter { !$0.isDemo } }
    private var tailoring: AgentFeature? { store.account.feature("tailoring") }
    private var profile: AgentFeature? { store.account.feature("profile") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                GlyphView(name: "sparkles", size: 20)
                Text("Resume agents").font(Typeface.title).foregroundStyle(Palette.ink)
            }
            if let tailoring {
                FeatureCardView(feature: tailoring, onAction: onNavigate, compact: true)
                ForEach(applications.prefix(5)) { app in applicationCard(app, unavailable: tailoring.state == "unavailable") }
                if applications.isEmpty {
                    Text("Save a real job from Jobs to tailor for it.").font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            if let profile {
                FeatureCardView(feature: profile, onAction: onNavigate, compact: true)
                ForEach(Array(runs(for: "self", kinds: ["profile"]).prefix(1).enumerated()), id: \.offset) { _, run in
                    TaskRow(run: run) { onOpenTask(run["id"].string) }
                }
                StackButton(label: "Suggest headline & about", kind: .secondary, disabled: working || profile.state == "unavailable") {
                    Task { await start(kind: "profile", target: "self", opens: false) }
                }
            }
            MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
    }

    private func applicationCard(_ app: Application, unavailable: Bool) -> some View {
        Card(spacing: 10) {
            Text(app.job.title).font(Typeface.option).foregroundStyle(Palette.icon)
            Text(app.job.company).font(Typeface.caption).foregroundStyle(Palette.muted)
            if !app.tailorResumeID.isEmpty {
                Text("Resume: \(app.tailorResumeName)\(app.tailorReady ? " · LaTeX ready" : " · needs its LaTeX")")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            } else {
                Text("Upload your resume above to tailor for this job.").font(Typeface.caption).foregroundStyle(Palette.text)
            }
            ForEach(Array(runs(for: app.id, kinds: ["resume"]).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { onOpenTask(run["id"].string) }
            }
            if let score = scores[app.id] {
                ScoreCardView(after: score["score"], title: "Score for this job · " + (score["source"].string == "latex" ? "your LaTeX" : "your PDF"))
            }
            if !app.tailorResumeID.isEmpty {
                Chip(label: scoring == app.id ? "Scoring…" : (scores[app.id] != nil ? "Score again" : "Score my resume")) {
                    Task { await score(app) }
                }
            }
            if setupFor == app.id, let resume = store.account.resume(app.tailorResumeID) {
                LatexSetupView(resume: resume,
                               others: store.account.resumes.filter { store.account.hasLatex($0.id) && $0.id != resume.id }) { resumeID in
                    await tailor(app, with: resumeID)
                }
            } else {
                StackButton(label: "Tailor for this job", kind: .secondary,
                            disabled: working || unavailable || app.tailorResumeID.isEmpty) {
                    if app.tailorReady { Task { await start(kind: "resume", target: app.id, opens: true) } }
                    else { setupFor = app.id }
                }
            }
        }
    }

    private func runs(for target: String, kinds: [String]) -> [JSON] {
        store.account.runViews.filter { $0["target_id"].string == target && kinds.contains($0["kind"].string) }
    }

    private func start(kind: String, target: String, opens: Bool) async {
        guard !working else { return }
        working = true
        error = ""
        message = ""
        defer { working = false }
        do {
            let result = try await store.call("agent_start", ["kind": .string(kind), "target_id": .string(target)])
            if opens { onOpenTask(result["id"].string) }
            else { message = "\(result["title"].string) started. Follow it here or in Agents." }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func score(_ app: Application) async {
        guard scoring.isEmpty else { return }
        scoring = app.id
        error = ""
        defer { scoring = "" }
        do { scores[app.id] = try await store.call("score_resume", ["application_id": .string(app.id)]) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    /// Tailor with this resume, attaching it to the job first when a different one was chosen.
    private func tailor(_ app: Application, with resumeID: String) async {
        error = ""
        if resumeID != app.tailorResumeID {
            do { try await store.callAccount("select_application_resume", ["id": .string(app.id), "resume_id": .string(resumeID)]) }
            catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
                return
            }
        }
        setupFor = ""
        await start(kind: "resume", target: app.id, opens: true)
    }
}

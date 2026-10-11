import SwiftUI

/// Contextual agent help for one saved application, with live task status. Nothing starts until the
/// person chooses it, and nothing is sent without approval.
@MainActor
struct ApplicationAgentSection: View {
    let application: Application

    @Environment(AppStore.self) private var store
    @State private var working = false
    @State private var message = ""
    @State private var error = ""
    @State private var task: TaskTarget?
    @State private var showInterview = false
    @State private var offerPrep = false
    @State private var showPrepPlan = false

    private struct Action: Identifiable {
        let kind: String
        let label: String
        let text: String
        var id: String { kind }
    }

    private let actions = [
        Action(kind: "jobs", label: "Explain my fit", text: "Strengths, gaps and unknowns"),
        Action(kind: "resume", label: "Tailor my resume", text: "One page for this job; you keep or reject each change"),
        Action(kind: "application", label: "Prepare & apply", text: "Prepared for your review; you approve each step"),
        Action(kind: "plan", label: "Build interview plan", text: "Adds practice sessions to Prep"),
    ]

    private var started: [JSON] {
        store.account.runViews.filter { $0["target_id"].string == application.id && ["jobs", "resume", "application"].contains($0["kind"].string) }
    }

    /// True when any agent behind these actions is missing a required setup step.
    private var needsSetup: Bool {
        actions.contains { action in
            action.kind != "plan" && !(store.account.feature(forKind: action.kind)?.missingRequired.isEmpty ?? true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(started.enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { task = TaskTarget(id: run["id"].string) }
            }
            DisclosureSection("Agent help", detail: needsSetup ? "Needs setup. Nothing starts or sends without you."
                                                              : "Optional. Nothing starts or sends without you.",
                              open: !started.isEmpty || needsSetup) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(actions) { action in
                        let feature = action.kind == "plan" ? nil : store.account.feature(forKind: action.kind)
                        let unavailable = feature?.state == "unavailable"
                        VStack(alignment: .leading, spacing: 4) {
                            ListRow(label: action.label, detail: action.text) {
                                Task { await start(action.kind) }
                            }
                            .disabled(working || unavailable)
                            .opacity(working || unavailable ? 0.5 : 1)
                            if let feature {
                                if feature.state != "ready" {
                                    StatusPill(label: AgentLabels.featureState[feature.state] ?? feature.state,
                                               tone: AgentLabels.featureTone(feature.state))
                                }
                                ForEach(feature.missingRequired) { Text("✕ \($0.fix)").font(Typeface.caption).foregroundStyle(Palette.muted) }
                                if unavailable, !feature.alternative.isEmpty {
                                    Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }
                    ListRow(label: "Mock interview for this role", icon: "chat") { showInterview = true }
                }
            }
            MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
            if offerPrep {
                Chip(label: "Open Prep for this role") { showPrepPlan = true }
            }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .sheet(item: $task) { AgentTaskSheet(taskID: $0.id).environment(store) }
        .sheet(isPresented: $showInterview) { InterviewView(initialApplicationID: application.id).environment(store) }
        .sheet(isPresented: $showPrepPlan) { ApplicationPrepPlanView(application: application).environment(store) }
    }

    private func start(_ kind: String) async {
        guard !working else { return }
        working = true
        error = ""
        message = ""
        offerPrep = false
        defer { working = false }
        do {
            if kind == "plan" {
                let result = try await store.call("prep_for_application", ["application_id": .string(application.id)])
                message = "Added \(result["plan"].array.count) practice sessions to Prep."
                offerPrep = true
            } else {
                let result = try await store.call("agent_start", ["kind": .string(kind), "target_id": .string(application.id)])
                if kind == "resume" || kind == "application" { task = TaskTarget(id: result["id"].string) }
                else { message = "\(result["title"].string) started. Progress appears below and in Agents." }
            }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

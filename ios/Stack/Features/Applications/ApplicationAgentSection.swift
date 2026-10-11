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

    /// The agents behind these actions, each once, however many actions share one.
    private var features: [AgentFeature] {
        var seen = Set<String>()
        return actions.compactMap { $0.kind == "plan" ? nil : store.account.feature(forKind: $0.kind) }
            .filter { seen.insert($0.key).inserted }
    }

    /// Agents that are not ready, or that are missing a required setup step.
    private var shortfalls: [AgentFeature] {
        features.filter { $0.state != "ready" || !$0.missingRequired.isEmpty }
    }

    /// Fixes every short agent needs, in the order the first one lists them. Said once, in the open.
    private var commonFixes: [String] {
        guard let first = shortfalls.first else { return [] }
        var fixes: [String] = []
        for check in first.missingRequired where !check.fix.isEmpty && !fixes.contains(check.fix) {
            if shortfalls.allSatisfy({ $0.missingRequired.contains { $0.fix == check.fix } }) { fixes.append(check.fix) }
        }
        return fixes
    }

    /// Whether some agent needs more than the shared fixes; that detail waits under Agent help.
    private var hasSpecificGuidance: Bool {
        shortfalls.contains { feature in feature.missingRequired.contains { !commonFixes.contains($0.fix) } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(started.enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { task = TaskTarget(id: run["id"].string) }
            }
            if !shortfalls.isEmpty { setupSummary }
            // Collapsed: the choices and their per-agent detail are one tap away, never in the way of Notes.
            DisclosureSection("Agent help", detail: "Nothing starts or sends without you.") {
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
                                // Shared fixes are in the summary above; only what is specific to this agent repeats here.
                                ForEach(feature.missingRequired.filter { !commonFixes.contains($0.fix) }) {
                                    Text("✕ \($0.fix)").font(Typeface.caption).foregroundStyle(Palette.muted)
                                }
                                if unavailable {
                                    StatusPill(label: AgentLabels.featureState["unavailable"] ?? "Unavailable", tone: .quiet)
                                    if !feature.alternative.isEmpty {
                                        Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
                                    }
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

    /// One short, always-visible statement of what is missing, with each fix said once.
    private var setupSummary: some View {
        let allUnavailable = shortfalls.allSatisfy { $0.state == "unavailable" }
        return VStack(alignment: .leading, spacing: 6) {
            StatusPill(label: allUnavailable ? (AgentLabels.featureState["unavailable"] ?? "Unavailable")
                                              : (AgentLabels.featureState["setup"] ?? "Needs setup"),
                       tone: AgentLabels.featureTone(allUnavailable ? "unavailable" : "setup"))
            ForEach(commonFixes, id: \.self) { fix in
                Text("✕ \(fix)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if hasSpecificGuidance {
                Text("Some tasks need more. Open Agent help for each one.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
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

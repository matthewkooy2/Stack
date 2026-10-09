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

    private struct Action: Identifiable {
        let kind: String
        let label: String
        let text: String
        var id: String { kind }
    }

    private let actions = [
        Action(kind: "jobs", label: "Explain my fit",
               text: "Strengths, gaps and unknowns, quoted from the listing and your confirmed facts. Nothing leaves Stack."),
        Action(kind: "resume", label: "Tailor my resume",
               text: "Rewords, reorders and trims your LaTeX resume to one page for this job, in your format. You keep or reject every change."),
        Action(kind: "plan", label: "Build interview plan",
               text: "Adds practice sessions to Prep based on this job. No model needed."),
    ]

    private var started: [JSON] {
        store.account.runViews.filter { $0["target_id"].string == application.id && ["jobs", "resume"].contains($0["kind"].string) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                GlyphView(name: "sparkles", size: 20)
                Text("Agent help").font(Typeface.title).foregroundStyle(Palette.ink)
            }
            Text("Optional. Nothing starts until you choose it, and nothing is sent without your approval.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(started.enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { task = TaskTarget(id: run["id"].string) }
            }
            ForEach(actions) { action in
                let feature = action.kind == "plan" ? nil : store.account.feature(forKind: action.kind)
                let unavailable = feature?.state == "unavailable"
                Card(spacing: 8) {
                    HStack {
                        Text(action.label).font(Typeface.option).foregroundStyle(Palette.icon)
                        Spacer()
                        if let feature {
                            StatusPill(label: AgentLabels.featureState[feature.state] ?? feature.state,
                                       tone: AgentLabels.featureTone(feature.state))
                        }
                    }
                    Text(action.text).font(Typeface.caption).foregroundStyle(Palette.text)
                    if let feature {
                        ForEach(feature.missingRequired) { Text("✕ \($0.fix)").font(Typeface.caption).foregroundStyle(Palette.muted) }
                        if unavailable, !feature.alternative.isEmpty {
                            Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    StackButton(label: action.label, kind: .secondary, disabled: working || unavailable) {
                        Task { await start(action.kind) }
                    }
                }
            }
            StackButton(label: "Mock interview for this role", icon: "chat", kind: .secondary) { showInterview = true }
            MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
            if offerPrep {
                Chip(label: "Open Prep") {
                    NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": "prep"])
                }
            }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .sheet(item: $task) { AgentTaskSheet(taskID: $0.id).environment(store) }
        .sheet(isPresented: $showInterview) { InterviewView(initialApplicationID: application.id).environment(store) }
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
                if kind == "resume" { task = TaskTarget(id: result["id"].string) }
                else { message = "\(result["title"].string) started. Progress appears below and in Agents." }
            }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

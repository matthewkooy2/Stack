import SwiftUI

/// Keeps the role and real session identifiers together while practicing a job's plan.
@MainActor
struct ApplicationPrepPlanView: View {
    let application: Application
    @Environment(AppStore.self) private var store
    @State private var plan: [JSON] = []
    @State private var sessions: [JSON] = []
    @State private var practice: TaskTarget?
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        SheetPage(title: "Interview plan", subtitle: application.job.title + " · " + application.job.company) {
            if loading { ProgressView().tint(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            if !error.isEmpty { StackButton(label: "Retry plan", kind: .secondary) { Task { await load() } } }
            ForEach(Array(plan.enumerated()), id: \.offset) { _, row in
                let sessionID = row["session_id"].string
                let session = sessions.first { $0["id"].string == sessionID }
                Card(spacing: 10) {
                    Text(row["title"].string).font(Typeface.option).foregroundStyle(Palette.ink)
                    Text(row["reason"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    Text((session?["data"]["elapsed_seconds"].double ?? 0) > 0 ? "Practiced" : "Ready to practice")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    StackButton(label: "Practice this question", kind: .secondary, disabled: sessionID.isEmpty || loading) {
                        practice = TaskTarget(id: sessionID)
                    }
                }
            }
            if !loading, plan.isEmpty, error.isEmpty {
                Text("No practice questions are available for this role yet.").font(Typeface.body).foregroundStyle(Palette.muted)
            }
        }
        .task { await load() }
        .sheet(item: $practice, onDismiss: { Task { await load() } }) { target in
            PracticeView(initialSessionID: target.id, applicationID: application.id).environment(store)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let generation = store.sessionGeneration
        do {
            let result = try await store.call("prep_for_application", ["application_id": .string(application.id)])
            guard generation == store.sessionGeneration else { throw CancellationError() }
            plan = result["plan"].array
            sessions = try await store.call("prep_sessions")["sessions"].array
            error = ""
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

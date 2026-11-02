import SwiftUI

/// A job-specific mock interview: choose a saved role, review each answer, get local coaching.
@MainActor
struct InterviewView: View {
    var initialApplicationID = ""

    @Environment(AppStore.self) private var store

    @State private var role = ""
    @State private var sessions: [JSON] = []
    @State private var current: JSON = [:]
    @State private var draft = ""
    @State private var recordingID = ""
    @State private var offered: (text: String, id: String)?
    @State private var correction = -1
    @State private var edited = ""
    @State private var fixing = false
    @State private var busy = false
    @State private var error = ""
    @State private var createID = InterviewView.requestID()
    @State private var answerID = InterviewView.requestID()

    private var applications: [Application] { store.account.applications.filter { !$0.isDemo } }
    private var data: JSON { current["data"] }
    private var turns: [JSON] { data["turns"].array }
    private var questions: [JSON] { data["questions"].array }
    private var run: JSON { current["run"] }
    private var analysis: JSON { data["analysis"][String(turns.count)] }
    private var coaching: JSON { data["coaching"] }
    private var active: Bool { data["status"].string == "active" }
    private var finished: Bool { data["status"].string == "finished" }
    /// Coaching has been requested and the worker has not returned or stopped yet.
    private var working: Bool {
        !data["pending"].string.isEmpty && !["needs_input", "blocked", "failed", "cancelled"].contains(run["status"].string)
    }

    static func requestID() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.lowercased() }

    var body: some View {
        SheetPage(title: "Mock interview", subtitle: "Choose a saved role, review each answer, and get coaching. You can record or type.") {
            if current.object.isEmpty { setup } else { session }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .task {
            if role.isEmpty { role = initialApplicationID }
            await reloadSessions()
        }
        .task(id: current["id"].string) {
            while !Task.isCancelled, !current["id"].string.isEmpty {
                try? await Task.sleep(for: .milliseconds(1500))
                if Task.isCancelled { break }
                await refresh()
            }
        }
    }

    // MARK: Setup

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Saved role")
            if applications.isEmpty {
                Text("Save a real job from Jobs to practice for it.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            FlowLayout(spacing: 8) {
                ForEach(applications) { app in
                    Chip(label: "\(app.job.title) · \(app.job.company)", selected: role == app.id) {
                        if !busy { role = app.id; createID = Self.requestID() }
                    }
                }
            }
            StackButton(label: "Start job interview", icon: "chat", disabled: busy || role.isEmpty) { Task { await start() } }
            if !sessions.isEmpty {
                SectionLabel(text: "Saved interviews")
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, row in
                    OptionRow(label: savedLabel(row), icon: "chat", disabled: busy) { Task { await open(row["id"].string) } }
                }
            }
        }
    }

    private func savedLabel(_ row: JSON) -> String {
        "\(row["data"]["job"]["title"].string) · \(row["data"]["turns"].array.count) answers · \(row["data"]["status"].string)"
    }

    // MARK: Session

    private var session: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(data["job"]["title"].string) · \(data["status"].string)").font(Typeface.title).foregroundStyle(Palette.ink)
            StackButton(label: "Back to interviews", icon: "return", kind: .secondary, disabled: busy) { leave() }
            if !run["id"].string.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(run["message"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if ["needs_input", "blocked", "failed"].contains(run["status"].string) {
                        StackButton(label: "Retry coaching", disabled: busy) { Task { await retry() } }
                    }
                }
            }
            // Coaching first; the answers it is about follow below.
            if working {
                // The worker is writing coaching; the screen reloads every 1.5 s until it arrives.
                Card(tint: Palette.surfaceRaised, spacing: 8) {
                    HStack(spacing: 12) {
                        ProgressView().tint(Brand.accent)
                        Text(finished ? "Writing your final coaching…" : "Coaching your answer…")
                            .font(Typeface.body.weight(.semibold)).foregroundStyle(Brand.ink)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !coaching.object.isEmpty, !(working && finished) {
                Card(tint: Palette.surfaceRaised, spacing: 8) {
                    Text("Final coaching").font(Typeface.option).foregroundStyle(Palette.icon)
                    InterviewCoachingView(coaching: coaching)
                }
            }
            if !analysis.object.isEmpty, !finished {
                Card(tint: Palette.surfaceRaised, spacing: 8) {
                    Text("Answer \(turns.count) coaching").font(Typeface.option).foregroundStyle(Palette.icon)
                    InterviewCoachingView(coaching: analysis)
                    StackButton(label: "Ask answer follow-up", kind: .secondary, disabled: busy || turns.count >= 6 || !active) {
                        Task { await action("followup") }
                    }
                }
            }
            if active, turns.count < questions.count, turns.count < 6 { currentQuestion }
            if !turns.isEmpty, data["pending"].string.isEmpty, finished || analysis.object.isEmpty {
                StackButton(label: finished ? "Get final coaching" : "Analyze reviewed answer", disabled: busy) {
                    Task { await action("analyze") }
                }
            }
            if active {
                StackButton(label: "Finish interview", disabled: busy || turns.isEmpty) { Task { await action("finish") } }
            }
            SectionLabel(text: "Your answers")
            ForEach(Array(turns.enumerated()), id: \.offset) { index, turn in
                Card(spacing: 6) {
                    let attempts = turn["previous"].array.count + 1
                    Text("Question \(index + 1)" + (attempts > 1 ? " · attempt \(attempts)" : ""))
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    Text(turn["question"]["question"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    Text(turn["answer"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    HStack(spacing: 8) {
                        // A retry is a new answer to the same question; the earlier one stays saved.
                        Chip(label: "Try this question again") {
                            if !busy { correction = index; fixing = false; edited = "" }
                        }
                        // Fixing only applies to a spoken answer, where the transcription can mishear words.
                        if !turn["recording_id"].string.isEmpty {
                            Chip(label: "Fix transcript") {
                                if !busy { correction = index; fixing = true; edited = turn["answer"].string }
                            }
                        }
                    }
                }
            }
            if correction >= 0 {
                StackField(label: fixing ? "Fix words the transcription got wrong" : "Your new answer to question \(correction + 1)",
                           text: $edited, multiline: true)
                StackButton(label: fixing ? "Save transcript fix" : "Save new answer", disabled: busy || edited.isBlank) {
                    Task {
                        await act("interview_correct", ["id": current["id"], "revision": current["revision"],
                                                        "index": .number(Double(correction)), "answer": .string(edited)])
                    }
                }
                StackButton(label: "Cancel", kind: .secondary, disabled: busy) { correction = -1; edited = "" }
            }
        }
    }

    private var currentQuestion: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Current question").font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(questions.indices.contains(turns.count) ? questions[turns.count]["question"].string : "")
                .font(Typeface.section).foregroundStyle(Palette.ink)
            StackField(label: "Review your answer", text: $draft, multiline: true)
            TranscriptionPanel(onUse: { text, id in
                if draft.isBlank { draft = text; recordingID = id } else { offered = (text, id) }
            }, disabled: busy, questionNumber: turns.count + 1, questionCount: min(questions.count, 6),
                               prompt: questions.indices.contains(turns.count) ? questions[turns.count]["question"].string : "")
            .id(current["id"].string + ":" + String(turns.count))
            if let offered {
                Card(tint: Palette.oat, spacing: 8) {
                    Text("Your typed answer is preserved. A reviewed recorded transcript is ready.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    Text(offered.text).font(Typeface.body).foregroundStyle(Palette.text)
                    StackButton(label: "Use recorded transcript", disabled: busy) {
                        draft = offered.text
                        recordingID = offered.id
                        self.offered = nil
                    }
                }
            }
            if !data["pending"].string.isEmpty {
                StackButton(label: "Continue with typed role question", disabled: busy) { Task { await action("next") } }
            } else {
                StackButton(label: "Save reviewed answer and analyze", disabled: busy || draft.isBlank) {
                    Task {
                        await act("interview_answer", ["id": current["id"], "revision": current["revision"], "answer": .string(draft),
                                                       "client_id": .string(answerID), "recording_id": .string(recordingID)], clear: true)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func reloadSessions() async {
        do { sessions = try await store.call("interview_sessions")["sessions"].array }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func refresh() async {
        let id = current["id"].string
        guard !id.isEmpty, !busy else { return }
        do {
            let result = try await store.call("interview_get", ["id": .string(id)])
            if current["id"].string == id { current = result }
        } catch {
            if !(error is CancellationError) { self.error = "Connection failed. Your answer is retained. " + error.localizedDescription }
        }
    }

    private func open(_ id: String) async {
        guard !busy else { return }
        if !draft.isBlank || correction >= 0 {
            error = "Save or clear your answer and correction before opening another interview."
            return
        }
        busy = true
        defer { busy = false }
        do {
            current = try await store.call("interview_get", ["id": .string(id)])
            recordingID = ""
            offered = nil
            error = ""
            answerID = Self.requestID()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func leave() {
        guard draft.isBlank, correction < 0 else {
            error = "Save or clear your answer and correction before leaving this interview."
            return
        }
        current = [:]
        error = ""
        Task { await reloadSessions() }
    }

    private func start() async {
        if !draft.isBlank || correction >= 0 {
            error = "Save or clear your answer and correction before starting another interview."
            return
        }
        await act("interview_create", ["application_id": .string(role), "client_id": .string(createID)], clear: true)
        if error.isEmpty { createID = Self.requestID() }
    }

    private func action(_ value: String) async {
        await act("interview_continue", ["id": current["id"], "revision": current["revision"], "action": .string(value)])
    }

    private func act(_ endpoint: String, _ args: JSON, clear: Bool = false) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            current = try await store.call(endpoint, args)
            if clear {
                draft = ""
                recordingID = ""
                offered = nil
                correction = -1
                answerID = Self.requestID()
            }
            if endpoint == "interview_correct" {
                correction = -1
                edited = ""
            }
            await reloadSessions()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func retry() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if run["status"].string == "needs_input" {
                try await store.call("agent_respond", ["id": run["id"], "values": [], "reuse": false])
            } else {
                try await store.call("agent_retry", ["id": run["id"]])
            }
            current = try await store.call("interview_get", ["id": current["id"]])
            error = ""
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

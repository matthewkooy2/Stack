import SwiftUI
import Observation

/// A job-specific mock interview in the Prep look: it picks a saved role by itself, asks the role's questions one at a
/// time, coaches each answer, and ends with a final coaching. It replaces the old setup form with its transcript
/// correction and manual analyze and finish steps. Talks to the existing `interview_*` backend functions.
@MainActor
@Observable
final class MockInterviewModel {
    enum Phase { case starting, noRole, question, typing, recording, working, coaching, finishing, final }

    var phase: Phase = .starting
    var session: JSON = [:]
    var draft = ""
    var error = ""
    var busy = false
    var role: Application?

    let recorder = AudioRecorder()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var answerID = MockInterviewModel.requestID()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var polling: Task<Void, Never>?

    static func requestID() -> String { String(Int(Date().timeIntervalSince1970 * 1000)) + "-" + UUID().uuidString.lowercased() }

    func bind(_ store: AppStore) { if self.store == nil { self.store = store } }

    // MARK: Derived

    var data: JSON { session["data"] }
    var turns: [JSON] { data["turns"].array }
    var questions: [JSON] { data["questions"].array }
    var total: Int { max(1, min(questions.count, 6)) }
    var prompt: String { questions.indices.contains(turns.count) ? questions[turns.count]["question"].string : "" }
    /// Which question the person is on. A just-sent answer is already in `turns` while its coaching is pending.
    var progress: String {
        let done = turns.count
        let number = (phase == .coaching || phase == .working) ? done : done + 1
        return "\(min(max(number, 1), total)) of \(total)"
    }
    /// The question without the quoted listing excerpt that some questions open with ("This role asks for "…".").
    var askPrompt: String {
        let full = prompt
        guard full.hasPrefix("This role asks for"), let end = full.range(of: "\".", options: .backwards) else { return full }
        let rest = full[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? full : rest
    }
    var analysis: JSON { data["analysis"][String(turns.count)] }
    var coaching: JSON { data["coaching"] }
    var run: JSON { session["run"] }
    var canFinish: Bool { turns.count >= 2 }
    var runStalled: Bool { ["needs_input", "blocked", "failed", "cancelled"].contains(run["status"].string) }

    /// The answer's coaching, read into one line of what worked and one thing to work on.
    var analysisText: String { analysis["text"].string.isBlank ? analysis["improvement"].string : analysis["text"].string }
    var note: InterviewNote { InterviewNote.parse(analysisText) }
    var finalText: String { coaching["text"].string.isBlank ? coaching["summary"].string : coaching["text"].string }

    // MARK: Starting

    /// The role to practice for: one at the interview stage, otherwise the most recently saved.
    private func pickRole(_ store: AppStore) -> Application? {
        let roles = store.account.applications.filter { !$0.isDemo }
        return roles.first { $0.status.lowercased().contains("interview") } ?? roles.max { $0.createdAt < $1.createdAt }
    }

    func start() async {
        guard let store, phase == .starting else { return }
        guard let chosen = pickRole(store) else { phase = .noRole; return }
        role = chosen
        generation = store.sessionGeneration
        do {
            let list = try await store.call("interview_sessions")["sessions"].array
            let existing = list.first { $0["data"]["job"]["title"].string == chosen.job.title && $0["data"]["status"].string == "active" }
            if let existing { session = try await store.call("interview_get", ["id": existing["id"]]) }
            else { session = try await store.call("interview_create", ["application_id": .string(chosen.id), "client_id": .string(Self.requestID())]) }
            #if DEBUG
            PrepTrace.dump("interview-session", session)
            #endif
            route()
        } catch { fail(error) }
    }

    /// Chooses the screen that matches where the saved interview stands.
    private func route() {
        error = ""
        if !coaching.object.isEmpty, data["status"].string == "finished" { phase = .final; return }
        if data["status"].string == "finished" { phase = .finishing; poll(); return }
        if !turns.isEmpty, analysis.object.isEmpty, turns.count > 0 { phase = .working; poll(); return }
        phase = .question
    }

    // MARK: Answering

    func record() async {
        guard let store, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await recorder.start(owner: store.account.userID)
            draft = ""
            phase = .recording
        } catch { fail(error) }
    }

    func cancelRecording() {
        _ = recorder.stop(cancelled: true)
        phase = .question
    }

    func togglePause() {
        do { if recorder.isPaused { try recorder.resume() } else { recorder.pause() } } catch { fail(error) }
    }

    /// Stops the recording and uses what the phone heard as the answer; with no transcript, asks for typing.
    func finishRecording() async {
        guard !busy else { return }
        busy = true
        guard let saved = recorder.stop() else {
            busy = false
            error = "No audio was saved. Record your answer again."
            phase = .question
            return
        }
        await saved.finalized.value
        busy = false
        let heard = RecordingStore.transcript(at: saved.url)?.text ?? ""
        draft = heard
        if heard.isBlank {
            error = "We couldn’t hear anything. Type your answer instead."
            phase = .typing
        } else {
            await submit()
        }
    }

    func submit() async {
        guard let store, !busy, !draft.isBlank else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            session = try await store.call("interview_answer", ["id": session["id"], "revision": session["revision"],
                                                                "answer": .string(draft), "client_id": .string(answerID),
                                                                "recording_id": ""])
            draft = ""
            answerID = Self.requestID()
            #if DEBUG
            PrepTrace.dump("interview-after-answer", session)
            #endif
            phase = .working
            poll()
        } catch { fail(error) }
    }

    func next() {
        error = ""
        if turns.count >= total { Task { await finish() } } else { phase = .question }
    }

    func finish() async {
        guard let store, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            session = try await store.call("interview_continue", ["id": session["id"], "revision": session["revision"], "action": "finish"])
            session = try await store.call("interview_continue", ["id": session["id"], "revision": session["revision"], "action": "analyze"])
            phase = .finishing
            poll()
        } catch { fail(error) }
    }

    func retry() async {
        guard let store, !busy, !run["id"].string.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            if run["status"].string == "needs_input" { try await store.call("agent_respond", ["id": run["id"], "values": [], "reuse": false]) }
            else { try await store.call("agent_retry", ["id": run["id"]]) }
            session = try await store.call("interview_get", ["id": session["id"]])
            error = ""
            poll()
        } catch { fail(error) }
    }

    // MARK: Waiting for the worker

    /// Reloads the saved interview until its analysis or final coaching appears, a little under every second.
    func poll() {
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, let store = self.store, !Task.isCancelled else { return }
                guard store.sessionGeneration == self.generation else { return }
                do {
                    let fresh = try await store.call("interview_get", ["id": self.session["id"]])
                    guard !Task.isCancelled else { return }
                    self.session = fresh
                    if self.phase == .working, !self.analysis.object.isEmpty {
                        #if DEBUG
                        PrepTrace.dump("interview-analysis", self.analysis)
                        #endif
                        self.phase = .coaching
                        return
                    }
                    if self.phase == .finishing, !self.coaching.object.isEmpty {
                        #if DEBUG
                        PrepTrace.dump("interview-final", self.coaching)
                        #endif
                        self.phase = .final
                        return
                    }
                } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            }
        }
    }

    func stop() {
        polling?.cancel()
        _ = recorder.stop(cancelled: true)
    }

    private func fail(_ failure: Error) {
        if failure is CancellationError { return }
        error = failure.localizedDescription
    }
}

struct MockInterviewFlow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = MockInterviewModel()

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if model.phase != .final {
                    HStack {
                        BrandBackButton(disabled: model.recorder.isRecording) { model.stop(); dismiss() }
                        Spacer()
                    }
                    .padding(.bottom, 4)
                }
                content.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, 12)
        }
        .task {
            model.bind(store)
            await model.start()
        }
        .onDisappear { model.stop() }
        .environment(\.launchHold, false)
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .starting:
            PrepWorkingScreen(progress: "", message: "Finding your role…")
        case .noRole:
            PrepWorkingScreen(progress: "", message: "Save a job first.", detail: "Mock interviews are built from a role you saved in Jobs.",
                              stalled: true, primary: "Done", onPrimary: { dismiss() })
        case .question:
            PrepQuestionScreen(progress: model.progress, context: model.role.map { "\($0.job.title) · \($0.job.company)" },
                               prompt: model.askPrompt, busy: model.busy, message: model.error,
                               links: [ScreenLink("Type instead") { model.phase = .typing }]
                                   + (model.canFinish ? [ScreenLink("Finish interview") { Task { await model.finish() } }] : []),
                               onPrimary: { Task { await model.record() } })
        case .typing:
            typing
        case .recording:
            PrepRecordingScreen(recorder: model.recorder, progress: model.progress, busy: model.busy, message: model.error,
                                onDone: { Task { await model.finishRecording() } },
                                onTogglePause: { model.togglePause() }, onCancel: { model.cancelRecording() })
        case .working:
            working(message: "Reading your answer…")
        case .finishing:
            working(message: "Writing your final coaching…")
        case .coaching:
            PrepCoachingScreen(progress: "\(model.turns.count) of \(model.total)",
                               verdict: model.note.strength.isBlank ? "Here’s how that went." : model.note.strength,
                               criteria: [], focus: model.note.improvement,
                               primary: model.turns.count >= model.total ? "Finish" : "Next question",
                               busy: model.busy, message: model.error,
                               onAnswer: {}, onPrimary: { model.next() }, onAgain: { Task { await model.finish() } },
                               secondary: model.canFinish && model.turns.count < model.total ? "Finish interview" : nil)
        case .final:
            finalScreen
        }
    }

    private func working(message: String) -> some View {
        PrepWorkingScreen(progress: model.progress, message: model.runStalled ? "We couldn’t finish your coaching." : message,
                          detail: model.runStalled ? model.run["message"].string : model.error, stalled: model.runStalled,
                          primary: model.runStalled ? "Try again" : nil, busy: model.busy,
                          onPrimary: { Task { await model.retry() } })
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.askPrompt).font(.system(size: 30, weight: .heavy)).tracking(-1.4).foregroundStyle(Brand.ink).padding(.top, 12)
                    AnswerEditor(text: $model.draft, placeholder: "Your answer…", label: "Your answer", disabled: model.busy)
                    if !model.error.isEmpty { Text(model.error).font(Typeface.caption).foregroundStyle(Palette.danger) }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Outside the scroll view, so it stays above the keyboard and is always tappable.
            PrimaryPill(title: "Get coaching", disabled: model.busy || model.draft.isBlank) { Task { await model.submit() } }
        }
    }

    private var finalScreen: some View {
        let shown = CoachingPresentation.make(from: ["text": .string(model.finalText)])
        return VStack(spacing: 0) {
            ScrollView {
                PrepSavedAnswerScreen(heading: "Interview coaching", prompt: model.role.map { "\($0.job.title) · \($0.job.company)" } ?? "",
                                      answer: "", verdict: shown.verdict, criteria: shown.criteria, focus: shown.focus,
                                      onBack: { dismiss() }) { EmptyView() }
            }
            .scrollIndicators(.hidden)
            PrimaryPill(title: "Done") { dismiss() }
        }
    }
}

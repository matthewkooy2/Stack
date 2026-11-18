import SwiftUI
import Observation

/// A job-specific mock interview in the Prep look: it picks a saved role by itself, asks the role's questions one at a
/// time, coaches each answer, and ends with a final coaching. It replaces the old setup form with its transcript
/// correction and manual analyze and finish steps. Talks to the existing `interview_*` backend functions.
@MainActor
@Observable
final class MockInterviewModel {
    enum Phase { case starting, noRole, question, typing, recording, readingCapture, working, coaching, finishing, final }

    var phase: Phase = .starting
    var session: JSON = [:]
    var draft = ""
    private(set) var recordedAnswer: URL?
    var error = ""
    var busy = false
    var role: Application?

    let recorder = AudioRecorder()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var answerID = MockInterviewModel.requestID()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var captureToken: UUID?
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
    /// One reviewed answer is enough for a shortened interview; the backend refuses to assess an empty one.
    var canFinish: Bool { turns.count >= 1 }
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
        guard let store, phase == .starting, !busy else { return }
        busy = true
        defer { busy = false }
        error = ""
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
        guard let store, store.sessionGeneration == generation, !busy else { return }
        busy = true
        defer { busy = false }
        let token = UUID()
        captureToken = token
        recorder.onAutoStop = { [weak self] saved in
            guard let self, self.captureToken == token, self.phase != .readingCapture else { return }
            self.phase = .readingCapture
            Task { await self.readCapture(saved, token: token, interrupted: true) }
        }
        do {
            _ = try await recorder.start(owner: store.account.userID)
            guard captureToken == token, phase != .readingCapture else { return }
            error = ""
            phase = .recording
        } catch {
            guard captureToken == token, phase != .readingCapture else { return }
            captureToken = nil
            recorder.onAutoStop = nil
            fail(error)
        }
    }

    func cancelRecording() {
        captureToken = nil
        recorder.onAutoStop = nil
        _ = recorder.stop(cancelled: true)
        phase = recordedAnswer == nil && draft.isBlank ? .question : .typing
    }

    func togglePause() {
        do { if recorder.isPaused { try recorder.resume() } else { recorder.pause() } } catch { fail(error) }
    }

    func finishRecording() async {
        guard phase == .recording, !busy, let token = captureToken else { return }
        guard let saved = recorder.stop() else {
            cancelRecording()
            error = "Nothing recorded. Try again"
            return
        }
        phase = .readingCapture
        await readCapture(saved, token: token, interrupted: false)
    }

    /// Only Done requests coaching. A phone call, route change or time limit returns to review.
    private func readCapture(_ saved: CapturedRecording, token: UUID, interrupted: Bool) async {
        await saved.finalized.value
        guard captureToken == token, phase == .readingCapture,
              let store, store.sessionGeneration == generation, store.phase == .ready else { return }
        captureToken = nil
        recorder.onAutoStop = nil
        recordedAnswer = FileManager.default.fileExists(atPath: saved.url.path) ? saved.url : nil
        draft = RecordingStore.transcript(at: saved.url)?.text ?? ""
        if interrupted || draft.isBlank {
            let guidance: String
            if !draft.isBlank { guidance = "Review, then get feedback" }
            else if recordedAnswer != nil { guidance = "Type your answer or record again" }
            else { guidance = "Type your answer or record again" }
            error = [recorder.stopNotice, guidance].filter { !$0.isEmpty }.joined(separator: " ")
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
            recordedAnswer = nil
            answerID = Self.requestID()
            #if DEBUG
            PrepTrace.dump("interview-after-answer", session)
            #endif
            phase = .working
            poll()
        } catch {
            if phase == .readingCapture { phase = .typing }
            fail(error)
        }
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
        captureToken = nil
        recorder.onAutoStop = nil
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
    @State private var showingAnswer = false

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                if model.phase != .final {
                    HStack(spacing: 8) {
                        BackButton(disabled: model.phase == .recording || (model.busy && model.phase != .starting)) { model.stop(); dismiss() }
                        Text("Mock interview").font(.headline).foregroundStyle(Brand.ink)
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                    }
                    .padding(.leading, -6)
                    .padding(.bottom, 4)
                }
                if [.typing, .coaching, .final].contains(model.phase) {
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    GeometryReader { geometry in
                        ScrollView {
                            content.frame(maxWidth: .infinity, minHeight: geometry.size.height)
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.page)
            .padding(.vertical, 12)
        }
        .task {
            model.bind(store)
            await model.start()
        }
        .onDisappear { model.stop() }
        .sheet(isPresented: $showingAnswer) {
            SheetPage(title: "Your answer") {
                if let turn = model.turns.last {
                    Text(turn["question"]["question"].string).font(Typeface.section).foregroundStyle(Palette.ink)
                    Text(turn["answer"].string).font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .starting:
            PrepWorkingScreen(progress: "", message: model.error.isEmpty ? "Loading…" : "Couldn’t load this interview",
                              detail: model.error, stalled: !model.error.isEmpty,
                              primary: model.error.isEmpty ? nil : "Try again", busy: model.busy,
                              onPrimary: { Task { await model.start() } })
        case .noRole:
            PrepWorkingScreen(progress: "", message: "Choose a job",
                              detail: "Save a job to get questions",
                              stalled: true, primary: "Browse jobs", onPrimary: {
                                  dismiss()
                                  NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": "jobs"])
                              })
        case .question:
            PrepQuestionScreen(progress: model.progress, context: model.role.map { "\($0.job.title) · \($0.job.company)" },
                               prompt: model.askPrompt, busy: model.busy, message: model.error,
                               links: [ScreenLink("Type instead") { model.phase = .typing }]
                                   + (model.recorder.permissionDenied ? [ScreenLink("Open microphone settings") { AppSettings.open() }] : [])
                                   + (model.canFinish ? [ScreenLink("Finish interview") { Task { await model.finish() } }] : []),
                               onPrimary: { Task { await model.record() } })
        case .typing:
            typing
        case .recording:
            PrepRecordingScreen(recorder: model.recorder, progress: model.progress, prompt: model.askPrompt, busy: model.busy, message: model.error,
                                onDone: { Task { await model.finishRecording() } },
                                onTogglePause: { model.togglePause() }, onCancel: { model.cancelRecording() })
        case .readingCapture:
            PrepWorkingScreen(progress: model.progress, message: "Saving…", spinner: true)
        case .working:
            working(message: "Reviewing your answer…")
        case .finishing:
            working(message: "Writing feedback…", spinner: true)
        case .coaching:
            PrepCoachingScreen(progress: "\(model.turns.count) of \(model.total)",
                               verdict: !model.analysis["verdict"].string.isBlank ? model.analysis["verdict"].string
                                   : model.note.strength.isBlank ? "Here’s how that went." : model.note.strength,
                               criteria: CoachingPresentation.criteria(from: model.analysis),
                               focus: model.analysis["work_on"].string.isBlank ? model.note.improvement : model.analysis["work_on"].string,
                               primary: model.turns.count >= model.total ? "Finish" : "Next question",
                               busy: model.busy, message: model.error,
                               onAnswer: { showingAnswer = true }, onPrimary: { model.next() }, onAgain: { Task { await model.finish() } },
                               secondary: model.canFinish && model.turns.count < model.total ? "Finish interview" : nil)
        case .final:
            finalScreen
        }
    }

    private func working(message: String, spinner: Bool = false) -> some View {
        PrepWorkingScreen(progress: model.progress, message: model.runStalled ? "Couldn’t finish your feedback" : message,
                          detail: model.runStalled ? model.run["message"].string : model.error, stalled: model.runStalled,
                          primary: model.runStalled ? "Try again" : nil, busy: model.busy,
                          onPrimary: { Task { await model.retry() } }, spinner: spinner)
    }

    private var typing: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(model.askPrompt).font(Typeface.title).foregroundStyle(Brand.ink).padding(.top, 12)
                        .fixedSize(horizontal: false, vertical: true)
                    if let url = model.recordedAnswer {
                        AnswerPlayback(url: url, isActive: !model.busy)
                    }
                    AnswerEditor(text: $model.draft, placeholder: "Your answer", label: "Your answer", disabled: model.busy)
                    if !model.error.isEmpty { Text(model.error).font(Typeface.caption).foregroundStyle(Palette.danger) }
                    StackButton(label: model.recordedAnswer == nil ? "Record answer" : "Record again", icon: "mic.fill", kind: .soft,
                               disabled: model.busy) { Task { await model.record() } }
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            // Outside the scroll view, so it stays above the keyboard and is always tappable.
            StackButton(label: "Get feedback", disabled: model.busy || model.draft.isBlank) { Task { await model.submit() } }
        }
    }

    private var finalScreen: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack { BackButton(action: { dismiss() }); Spacer() }
                    Text("Interview feedback").font(Typeface.display).foregroundStyle(Brand.ink)
                        .padding(.top, 18)
                    if let role = model.role {
                        StatusPill(text: "\(role.job.title) · \(role.job.company)", tone: .accent, prominent: true, symbol: "briefcase.fill").padding(.top, 10)
                    }
                    InterviewCoachingView(coaching: model.coaching).padding(.top, 22)
                }
            }
            .scrollIndicators(.hidden)
            StackButton(label: "Done") { dismiss() }
        }
    }
}

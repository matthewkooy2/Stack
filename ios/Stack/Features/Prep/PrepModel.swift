import Foundation
import Observation

enum PrepPage: String, StageKey {
    case home, question, answer, recording, review, processing, coaching, complete
    case past, history, savedAnswer

    var depth: Int {
        switch self {
        case .home: return 0
        case .question, .past: return 1
        case .answer, .recording: return 2
        case .review: return 3
        case .processing: return 4
        case .coaching: return 5
        case .complete, .history: return 6
        case .savedAnswer: return 7
        }
    }
}

enum PrepFocus: String, CaseIterable {
    case mixed = "Mixed questions"
    case projects = "Projects and ownership"
    case teamwork = "Teamwork and disagreement"
    case setbacks = "Setbacks and learning"

    var icon: String {
        switch self {
        case .mixed: return "shuffle"
        case .projects: return "applications"
        case .teamwork: return "network"
        case .setbacks: return "sprout"
        }
    }

    var shortName: String {
        switch self {
        case .mixed: return "Mixed"
        case .projects: return "Projects"
        case .teamwork: return "Teamwork"
        case .setbacks: return "Setbacks"
        }
    }

    var bases: [String] {
        switch self {
        case .mixed: return ["project", "disagreement", "setback"]
        case .projects: return ["project"]
        case .teamwork: return ["disagreement"]
        case .setbacks: return ["setback"]
        }
    }
}

/// The behavioral practice workflow: choose a focus, answer by voice or text, review, get coaching.
/// The state machine and its persistence follow the account's existing prep sessions, so a session
/// started here continues on any other client.
@MainActor
@Observable
final class PrepModel {
    // Navigation
    var page: PrepPage = .home
    var focus: PrepFocus = .mixed
    /// How many times "Another question" was tapped for the current focus.
    var skipped = 0
    /// Set when the person chose to start fresh instead of continuing a session in progress.
    var startedFresh = false

    // Server state
    var loaded = false
    var sessions: [JSON] = []
    var catalog: [PrepQuestion] = []
    var current: JSON = [:]
    var runtime: JSON = [:]
    var recording: JSON = [:]
    var submitted: JSON = [:]
    var coaching = false
    var feedback: JSON = [:]
    var archived: JSON = [:]
    var archivedURL: URL?

    // Answer in progress
    var draft = ""
    var localClientID = ""
    var localURL: URL?

    // Status
    var busy = false
    /// True while the recorder is stopping.
    var finishing = false
    /// True when a saved answer was opened without the list in between, so Back returns to History.
    var openedDirectly = false
    var error = ""

    let recorder = AudioRecorder()
    @ObservationIgnored private let liveActivity = PrepLiveActivity()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var boundGeneration: Int?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var pendingCapture: CapturedRecording?
    @ObservationIgnored private let drafts: PrepDraftStore

    init(drafts: PrepDraftStore = PrepDraftStore()) { self.drafts = drafts }

    func bind(_ store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        boundGeneration = store.sessionGeneration
        recorder.onAutoStop = { [weak self] saved in
            Task { @MainActor in await self?.captureStopped(saved) }
        }
    }

    private var api: APIClient { store!.api }
    private var transport: PrepTransport { store!.prep }
    private var owner: String { store?.account.userID ?? "" }

    private func requireSession() throws {
        guard let store, store.phase == .ready, boundGeneration == store.sessionGeneration else {
            throw CancellationError()
        }
    }

    private func sessionRequest<T>(_ operation: () async throws -> T) async throws -> T {
        try requireSession()
        let result = try await operation()
        try requireSession()
        return result
    }

    @discardableResult
    private func call(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        try await sessionRequest { try await api.call(name, args, timeout: timeout) }
    }

    // MARK: Derived

    var workflow: JSON { current["data"]["behavioral"] }
    var index: Int { workflow["index"].int }
    var plan: [String] { workflow["plan"].strings }
    var history: [JSON] { workflow["history"].array }
    var isLastQuestion: Bool { index + 1 == plan.count }
    var question: PrepQuestion? {
        let id = current["data"]["problem_id"].string
        return catalog.first { $0.id == id }
    }
    var activeSessions: [JSON] { sessions.filter { !$0["data"]["behavioral"]["complete"].bool } }
    var recordingActive: Bool { recorder.isRecording || recorder.isPaused || recorder.finalizing }
    var locked: Bool { busy || recorder.isRecording || recorder.isPaused }
    var transcribing: Bool {
        !recording.object.isEmpty && recording["status"].string != "completed"
    }
    var transcriptionUnavailable: Bool { runtime["status"].string == "unavailable" }
    var canReviewPhoneText: Bool {
        !recorder.finalizing && localURL.flatMap { RecordingStore.transcript(at: $0) } != nil
    }

    var strengths: [JSON] { feedback["rubric"].array.filter { $0["score"].double >= 3 } }
    /// The first thing that went well, from structured scores or an older rubric.
    var worked: String {
        CoachingPresentation.criteria(from: feedback).first { $0.score >= 3 }?.why ?? strengths.first?["feedback"].string ?? ""
    }
    var improvements: [JSON] { feedback["rubric"].array.filter { $0["score"].double < 3 } }

    /// Consecutive days with practice, counted back from today (or from yesterday while today has none yet).
    var streak: Int {
        let calendar = Calendar(identifier: .gregorian)
        let days = Set(sessions.compactMap { row -> Date? in
            let behavioral = row["data"]["behavioral"]
            guard behavioral["complete"].bool || !behavioral["history"].array.isEmpty else { return nil }
            return calendar.startOfDay(for: Date(timeIntervalSince1970: row["updated_at"].double))
        })
        var day = calendar.startOfDay(for: Date())
        if !days.contains(day) { day = calendar.date(byAdding: .day, value: -1, to: day) ?? day }
        var count = 0
        while days.contains(day), count < 400 {
            count += 1
            day = calendar.date(byAdding: .day, value: -1, to: day) ?? day
        }
        return count
    }

    /// Days of the current week (Monday first) and which of them had practice.
    var week: [(label: String, practiced: Bool)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let practiced = Set(sessions.compactMap { row -> Date? in
            let behavioral = row["data"]["behavioral"]
            guard behavioral["complete"].bool || !behavioral["history"].array.isEmpty else { return nil }
            return calendar.startOfDay(for: Date(timeIntervalSince1970: row["updated_at"].double))
        })
        guard let start = calendar.dateInterval(of: .weekOfYear, for: Date())?.start else { return [] }
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            return (labels[offset], practiced.contains(calendar.startOfDay(for: day)))
        }
    }

    // MARK: Loading

    func load() async {
        guard store != nil, !loaded else { return }
        do {
            catalog = try await sessionRequest { try await transport.catalog() }
            await reload()
        } catch { fail(error) }
        loaded = true
    }

    func reload() async {
        do {
            let rows = try await sessionRequest { try await transport.sessions() }
            sessions = rows.filter { !$0["data"]["behavioral"].isNull }
            let list = try await call("transcription_list")
            runtime = list["runtime"]
        } catch { fail(error) }
    }

    // MARK: Starting and resuming sessions

    func go(_ next: PrepPage) {
        error = ""
        page = next
    }

    /// Creates a session whose first question is `first` and fills the rest from the same pool.
    @discardableResult
    func begin(first: PrepQuestion, count: Int = 3) async -> Bool {
        guard !busy else { return false }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let plan = sessionPlan(first: first, count: count)
            current = try await sessionRequest { try await transport.create(problemID: plan[0]) }
            var data = current["data"]
            data["behavioral"] = [
                "focus": .string(focus.rawValue),
                "plan": .array(plan.map { .string($0) }),
                "index": 0,
                "history": [],
                "complete": false,
            ]
            try await save(data)
            resetAnswer()
            page = .question
            return true
        } catch {
            fail(error)
            return false
        }
    }

    // MARK: Today's question

    private func base(_ id: String) -> String { String(id.split(separator: "-").first ?? "") }

    /// Behavioral prompts for the chosen focus.
    private var pool: [PrepQuestion] {
        catalog.filter { $0.track == "Behavioral" && focus.bases.contains(base($0.id)) }
    }

    /// Question ids already answered in this account's sessions.
    private var asked: Set<String> {
        Set(sessions.flatMap { row in row["data"]["behavioral"]["history"].array.map { $0["problem_id"].string } })
    }

    /// Prefers questions not answered yet; falls back to the whole pool once all have been.
    private var freshPool: [PrepQuestion] {
        let fresh = pool.filter { !asked.contains($0.id) }
        return fresh.isEmpty ? pool : fresh
    }

    private var rotation: Int { Int(Date().timeIntervalSince1970 / 86_400) + skipped }

    /// The question home offers. It changes daily, and with each "Another question".
    var offered: PrepQuestion? {
        let list = freshPool
        return list.isEmpty ? nil : list[rotation % list.count]
    }

    /// A session in progress that home offers to continue, with the question it is on.
    var continuing: (id: String, prompt: String, label: String)? {
        guard !startedFresh, let row = activeSessions.first else { return nil }
        let behavioral = row["data"]["behavioral"]
        let prompt = catalog.first { $0.id == row["data"]["problem_id"].string }?.prompt ?? ""
        guard !prompt.isEmpty else { return nil }
        return (row["id"].string, prompt, "\(behavioral["index"].int + 1) of \(behavioral["plan"].array.count)")
    }

    /// `first`, then questions from other topics first, so a session has some variety.
    private func sessionPlan(first: PrepQuestion, count: Int) -> [String] {
        let rest = freshPool.filter { $0.id != first.id }
        let offset = rest.isEmpty ? 0 : rotation % rest.count
        let rotated = Array(rest[offset...] + rest[..<offset])
        var plan = [first.id]
        var topics: Set<String> = [base(first.id)]
        for item in rotated where plan.count < count && !topics.contains(base(item.id)) {
            plan.append(item.id)
            topics.insert(base(item.id))
        }
        for item in rotated where plan.count < count && !plan.contains(item.id) { plan.append(item.id) }
        return plan
    }

    func choose(_ next: PrepFocus) {
        focus = next
        skipped = 0
        startedFresh = true
    }

    func another() { skipped += 1; startedFresh = true }

    /// Starts a session from the offered question and goes straight to recording, or to typing.
    func answerOffered(typing: Bool = false) async {
        guard let first = offered, await begin(first: first) else { return }
        if typing { go(.answer) } else { await recordAnswer() }
    }

    /// Throws the take away and returns to the question.
    func cancelRecording() {
        epoch += 1
        liveActivity.end()
        pendingCapture = nil
        _ = recorder.stop(cancelled: true)
        resetAnswer()
        remember()
        error = ""
        page = .question
    }

    func openSession(_ id: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            epoch += 1
            current = try await sessionRequest { try await transport.get(id) }
            draft = current["data"]["answer"].string
            dirty = !draft.isEmpty
            feedback = [:]
            if let match = current["feedback"].array.last(where: { $0["revision"].int == current["revision"].int }) {
                feedback = match["data"]
            }
            if feedback.object.isEmpty, current["data"]["behavioral"]["complete"].bool,
               let last = current["data"]["behavioral"]["history"].array.last {
                feedback = last["feedback"]
            }
            #if DEBUG
            if !feedback.object.isEmpty { PrepTrace.dump("prep-last-feedback", feedback) }
            #endif
            let behavioral = current["data"]["behavioral"]
            localClientID = behavioral["local_id"].string
            localURL = RecordingStore.exists(owner: owner, clientID: localClientID)
            if let url = localURL, let phone = RecordingStore.transcript(at: url), phone.hasPendingEdits || draft.isEmpty {
                draft = phone.text; dirty = true
            }
            recording = [:]
            let recordingID = behavioral["recording_id"].string
            if !recordingID.isEmpty {
                recording = try await call("transcription_get", ["id": .string(recordingID)])
                if localURL == nil { localURL = try? await cacheAudio(recordingID: recordingID) }
            }
            submitted = ["data": current["data"], "feedback": feedback, "saved": true]
            if let pair = current["feedback"].array.last(where: { !$0["session"].isNull && $0["session"]["behavioral"]["index"].int == index }) {
                submitted = ["key": pair["submission_id"], "session_id": .string(id), "index": .number(Double(index)), "data": pair["session"], "feedback": pair["data"], "saved": true]
                feedback = pair["data"]
            }
            if let recovered = drafts.load(owner: owner, session: id, index: index) {
                draft = recovered["draft"].string
                localClientID = recovered["local_id"].string
                localURL = RecordingStore.exists(owner: owner, clientID: localClientID)
                if draft.isEmpty, !recovered["edited"].bool, let url = localURL,
                   let phone = RecordingStore.transcript(at: url) { draft = phone.text }
                if !recovered["recording"].object.isEmpty { recording = recovered["recording"] }
                submitted = recovered["submission"]; feedback = submitted["feedback"]
            }
            dirty = !draft.isEmpty
            if !feedback.object.isEmpty && draft == submitted["data"]["answer"].string { page = .coaching }
            else if !draft.isEmpty || localURL != nil || !recording.object.isEmpty { page = .review }
            else { page = .question }
            // A finished session opens to its answers (straight to the answer when there is only one). One still in
            // progress carries on from where it stopped.
            if behavioral["complete"].bool {
                let answers = behavioral["history"].array
                if answers.count == 1, let only = answers.first { await viewSaved(only); openedDirectly = true } else if !answers.isEmpty { page = .history }
            }
        } catch { fail(error) }
    }

    private func resetAnswer() {
        draft = ""
        dirty = false
        feedback = [:]
        submitted = [:]
        recording = [:]
        localClientID = ""
        localURL = nil
    }

    // MARK: Saving

    private func save(_ data: JSON) async throws {
        let generation = store!.sessionGeneration
        guard store?.phase == .ready else { throw CancellationError() }
        let saved = try await sessionRequest { try await transport.save(id: current["id"].string, revision: current["revision"].int, data: data) }
        guard store?.sessionGeneration == generation, store?.phase == .ready else { throw CancellationError() }
        current = saved
        await reload()
    }

    private func remember() {
        do {
            try drafts.save(owner: owner, session: current["id"].string, index: index,
                            value: ["draft": .string(draft), "edited": .bool(dirty), "local_id": .string(localClientID), "recording": recording, "submission": submitted])
        } catch { fail(error) }
    }

    func edited(_ text: String) {
        draft = text; dirty = true
        if let url = localURL {
            do { try RecordingStore.editTranscript(text, at: url) } catch { fail(error) }
        }
        remember()
    }

    // MARK: Navigation

    func back() async {
        guard !locked else { return }
        error = ""
        epoch += 1
        switch page {
        case .history: page = .past
        case .savedAnswer:
            page = openedDirectly ? .past : .history
            openedDirectly = false
        case .answer, .review:
            remember(); page = .home
        default:
            page = .home
            await reload()
        }
    }

    // MARK: Recording

    /// Hidden tabs stay mounted, so leaving Prep must explicitly release the microphone.
    func suspendCapture() {
        remember()
        epoch += 1
        // Only a recording ends the activity here. Leaving the tab during the wait for coaching must not clear it.
        if recordingActive { liveActivity.end() }
        let stopped = recorder.stop(reason: "Recording stopped when you left Prep. The partial answer was kept.")
        let captured = stopped ?? pendingCapture
        pendingCapture = nil
        guard let saved = captured else { return }
        localClientID = saved.clientID
        localURL = saved.url
        recording = [:]
        page = .review
        let generation = store?.sessionGeneration
        let observed = epoch
        Task { @MainActor [weak self] in
            guard let self, let store = self.store, store.phase == .ready,
                  store.sessionGeneration == generation else { return }
            await saved.finalized.value
            guard store.sessionGeneration == generation, store.phase == .ready, observed == self.epoch else { return }
            if !self.dirty, let phone = RecordingStore.transcript(at: saved.url) {
                self.draft = phone.text; self.dirty = true
            }
            self.remember()
        }
    }

    func recordAnswer() async {
        guard !busy, !coaching else { return }
        busy = true
        error = ""
        defer {
            busy = false
            if let pending = pendingCapture {
                pendingCapture = nil
                Task { @MainActor [weak self] in
                    await self?.captureStopped(pending)
                }
            }
        }
        do {
            try requireSession()
            let started = try await recorder.start(owner: owner)
            try requireSession()
            localClientID = started.clientID
            localURL = started.url
            recording = [:]
            draft = ""
            feedback = [:]
            submitted = [:]
            dirty = false
            page = .recording
            liveActivity.startRecording(question: question?.prompt ?? "")
            remember()
        } catch {
            _ = recorder.stop(cancelled: true)
            fail(error)
        }
    }

    func togglePause() {
        guard !busy else { return }
        error = ""
        do {
            if recorder.isPaused { try recorder.resume() } else { recorder.pause() }
            liveActivity.setPaused(recorder.isPaused, elapsed: recorder.elapsed)
        } catch { fail(error) }
    }

    func finishAnswer() async {
        guard !busy, !finishing else { return }
        #if DEBUG
        PrepTrace.mark("done tapped", restart: true)
        #endif
        finishing = true
        busy = true
        error = ""
        guard let saved = recorder.stop() else {
            busy = false
            finishing = false
            liveActivity.end()
            error = "No audio was saved. Record your answer again."
            return
        }
        liveActivity.end()
        busy = false
        finishing = false
        await keepCapture(saved)
    }

    private func captureStopped(_ saved: CapturedRecording) async {
        guard page == .recording, store?.phase == .ready, store?.sessionGeneration == boundGeneration else { return }
        if busy { pendingCapture = saved; return }
        liveActivity.end()
        await keepCapture(saved)
    }

    private func keepCapture(_ saved: CapturedRecording) async {
        let observed = epoch
        localClientID = saved.clientID; localURL = saved.url
        recording = [:]; page = .review; remember()
        await saved.finalized.value
        do {
            try requireSession()
            guard observed == epoch else { return }
            if !dirty { draft = RecordingStore.transcript(at: saved.url)?.text ?? ""; dirty = !draft.isEmpty }
            remember()
            try await uploadAnswer()
        } catch { if observed == epoch { fail(error) } }
    }

    private func uploadAnswer() async throws {
        guard let url = localURL else { throw APIError(message: "Recording file is unavailable.") }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw APIError(message: "This recording has no saved audio. Record another answer.") }
        guard data.count <= 10 * 1024 * 1024 else { throw APIError(message: "Recording must be 10 MB or less.") }
        let phone = RecordingStore.transcript(at: url)
        var args: JSON = ["client_id": .string(localClientID), "content": .string(data.base64EncodedString())]
        if let phone {
            let capability = try await call("transcription_list")
            guard capability["client_transcripts"].bool else {
                throw APIError(message: "Your transcript is saved on this phone. Server sync needs the transcription update.")
            }
            args["local_transcript"] = .string(phone.original)
        }
        let observed = epoch
        let result = try await call("transcription_upload", args, timeout: 90)
        try RecordingStore.markSynced(result["id"].string, text: phone?.original, at: url)
        guard observed == epoch else { return }
        recording = result
        remember()
    }

    func retryUpload() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do { try await uploadAnswer() } catch { fail(error) }
    }

    func retryTranscription() async {
        guard !busy else { return }
        let id = recording["id"].string
        guard !id.isEmpty else { return }
        do { recording = try await call("transcription_action", ["id": .string(id), "action": "retry"]) }
        catch { fail(error) }
    }

    /// Writes a server copy of an answer's audio next to the phone's own recordings.
    private func cacheAudio(recordingID: String) async throws -> URL {
        try requireSession()
        let recordingOwner = owner
        let audio = try await call("transcription_audio", ["id": .string(recordingID)], timeout: 60)
        guard let data = Data(base64Encoded: audio["content"].string) else {
            throw APIError(message: "This answer's audio is not available.")
        }
        try requireSession()
        let url = try RecordingStore.url(owner: recordingOwner, clientID: "server-" + recordingID.filter { $0.isLetter || $0.isNumber || $0 == "-" })
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Coaching

    func coach() async {
        guard !coaching, !recorder.isRecording, !recorder.isPaused, !draft.isBlank else { return }
        coaching = true; error = ""
        defer { coaching = false }
        var data = current["data"]
        data["answer"] = .string(draft); data["transcript"] = ""
        data["behavioral"]["local_id"] = .string(localClientID)
        data["behavioral"]["recording_id"] = recording["id"]
        var packet: JSON = ["key": .string(UUID().uuidString), "session_id": current["id"], "index": .number(Double(index)), "data": data]
        submitted = packet; dirty = true; remember()
        feedback = [:]; page = .processing
        liveActivity.setCoaching(question: question?.prompt ?? "")
        do {
            let result = try await sessionRequest { try await transport.coach(id: packet["session_id"].string, data: data) }
            packet["data"] = result["data"]; packet["revision"] = result["revision"]; packet["feedback"] = result["feedback"]
            do { try drafts.saveSubmission(owner: owner, submission: packet) } catch { fail(error) }
            if current["id"] == packet["session_id"], index == packet["index"].int {
                submitted = packet; feedback = packet["feedback"]
                page = draft == packet["data"]["answer"].string ? .coaching : .review
                liveActivity.setReady(); remember()
            }
            await persistCoaching(packet)
        } catch {
            fail(error)
            if current["id"] == packet["session_id"], index == packet["index"].int { page = .review }
            liveActivity.setFailed()
        }
    }

    var hasUnsavedCoaching: Bool { !submitted["feedback"].object.isEmpty && !submitted["saved"].bool }

    func retryCoachingSave() async { await persistCoaching(submitted) }

    private func persistCoaching(_ packet: JSON) async {
        do {
            let saved = try await sessionRequest { try await transport.saveCoaching(packet) }
            var stored = packet; stored["saved"] = true
            do { try drafts.saveSubmission(owner: owner, submission: stored) } catch { fail(error) }
            if current["id"] == packet["session_id"], index == packet["index"].int, submitted["key"] == packet["key"] {
                current = saved; submitted = stored; remember(); await reload()
            }
        } catch {
            fail(error)
            if !(error is CancellationError) { self.error = "Your answer and coaching remain available. " + error.localizedDescription }
        }
    }

    /// Poll only unfinished transcription. Coaching returns its result directly.
    func poll() async {
        guard !busy, !polling, store != nil else { return }
        polling = true
        let observed = epoch
        defer { polling = false }
        do {
            if !recording["id"].string.isEmpty, recording["status"].string != "completed" {
                let result = try await call("transcription_get", ["id": recording["id"]])
                let list = try await call("transcription_list")
                if observed == epoch {
                    runtime = list["runtime"]
                    recording = result
                    if result["status"].string == "completed", !dirty {
                        draft = result["transcript"].string
                        dirty = true
                        remember()
                    }
                }
            }
        } catch {
            if observed == epoch, !(error is CancellationError) { fail(error) }
        }
    }

    var needsPolling: Bool {
        !recording["id"].string.isEmpty && recording["status"].string != "completed"
    }

    func nextAnswer() async {
        guard !busy, !coaching else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let w = workflow
            let last = isLastQuestion
            var entries = w["history"].array.filter { $0["index"].int != w["index"].int }
            entries.append([
                "index": w["index"],
                "problem_id": current["data"]["problem_id"],
                "answer": submitted["data"]["answer"].isNull ? .string(draft) : submitted["data"]["answer"],
                "feedback": feedback,
                "local_id": .string(localClientID),
                "recording_id": recording["id"],
            ])
            let nextIndex = last ? w["index"].int : w["index"].int + 1
            var data = current["data"]
            data["problem_id"] = w["plan"][nextIndex]
            data["answer"] = last ? (submitted["data"]["answer"].isNull ? .string(draft) : submitted["data"]["answer"]) : ""
            data["transcript"] = ""
            var behavioral = w
            behavioral["index"] = .number(Double(nextIndex))
            behavioral["history"] = .array(entries)
            behavioral["complete"] = .bool(last)
            behavioral["local_id"] = .string(last ? localClientID : "")
            behavioral["recording_id"] = last ? recording["id"] : .string("")
            data["behavioral"] = behavioral
            try await save(data)
            if last { page = .complete }
            else { resetAnswer(); page = .question }
        } catch { fail(error) }
    }

    func tryAgain() {
        // A new attempt starts empty: the last transcript must not turn up in the box or the recording.
        resetAnswer()
        var data = current["data"]
        data["behavioral"]["complete"] = false
        current["data"] = data
        remember()
        page = .question
    }

    // MARK: Saved answers

    func viewSaved(_ answer: JSON) async {
        error = ""
        do {
            var url = RecordingStore.exists(owner: owner, clientID: answer["local_id"].string)
            let recordingID = answer["recording_id"].string
            if url == nil, !recordingID.isEmpty { url = try await cacheAudio(recordingID: recordingID) }
            archived = answer
            archivedURL = url
            page = .savedAnswer
        } catch { fail(error) }
    }

    private func fail(_ failure: Error) {
        if failure is CancellationError { return }
        error = failure.localizedDescription
    }
}

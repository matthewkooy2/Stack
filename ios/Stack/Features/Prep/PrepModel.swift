import Foundation
import Observation

enum PrepPage: String, StageKey {
    case home, type, focus, length, question, answer, recording, review, processing, coaching, complete
    case continueSession, past, history, savedAnswer

    var depth: Int {
        switch self {
        case .home: return 0
        case .type, .continueSession, .past: return 1
        case .focus: return 2
        case .length: return 3
        case .question: return 4
        case .answer, .recording: return 5
        case .review: return 6
        case .processing: return 7
        case .coaching: return 8
        case .complete, .history: return 9
        case .savedAnswer: return 10
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
    var idea = false

    // Server state
    var loaded = false
    var sessions: [JSON] = []
    var catalog: [PrepQuestion] = []
    var current: JSON = [:]
    var runtime: JSON = [:]
    var recording: JSON = [:]
    var run: JSON = [:]
    var feedback: JSON = [:]
    var archived: JSON = [:]
    var archivedURL: URL?

    // Answer in progress
    var draft = ""
    var localClientID = ""
    var localURL: URL?

    // Status
    var busy = false
    var saving = false
    var error = ""

    let recorder = AudioRecorder()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var boundGeneration: Int?
    @ObservationIgnored private var epoch = 0
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private var autosaveFailed = false
    @ObservationIgnored private var pendingCapture: (clientID: String, url: URL)?

    func bind(_ store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        boundGeneration = store.sessionGeneration
        recorder.onAutoStop = { [weak self] clientID, url in
            Task { @MainActor in await self?.captureStopped(clientID: clientID, url: url) }
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
    var recordingActive: Bool { recorder.isRecording || recorder.isPaused }
    var locked: Bool { busy || saving || recordingActive }
    var coachRun: AgentRun? { run["id"].string.isEmpty ? nil : AgentRun(run) }
    var transcribing: Bool {
        !recording.object.isEmpty && recording["status"].string != "completed"
    }
    var transcriptionUnavailable: Bool { runtime["status"].string == "unavailable" }
    var autosaveToken: String { "\(page.rawValue)|\(current["id"].string)|\(draft)" }

    var strengths: [JSON] { feedback["rubric"].array.filter { $0["score"].double >= 3 } }
    var improvements: [JSON] { feedback["rubric"].array.filter { $0["score"].double < 3 } }

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
        idea = false
        page = next
    }

    func begin(count: Int) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            var plan = (0..<count).map { i -> String in
                let bases = focus.bases
                return bases[i % bases.count] + (i >= bases.count ? "-\(i / bases.count + 1)" : "")
            }
            if idea {
                plan = ["disagreement-2"] + plan.filter { $0 != "disagreement-2" }
                plan = Array(plan.prefix(count))
            }
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
        } catch { fail(error) }
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
            let behavioral = current["data"]["behavioral"]
            localClientID = behavioral["local_id"].string
            localURL = RecordingStore.exists(owner: owner, clientID: localClientID)
            recording = [:]
            let recordingID = behavioral["recording_id"].string
            if !recordingID.isEmpty {
                recording = try await call("transcription_get", ["id": .string(recordingID)])
                if localURL == nil { localURL = try? await cacheAudio(recordingID: recordingID) }
            }
            let activity = try await call("agent_activity")
            run = activity["runs"].array.first {
                $0["target_id"].string == id && $0["kind"].string == "prep"
                    && $0["session_revision"].int == current["revision"].int
            } ?? [:]
            let state = run["status"].string
            if !feedback.object.isEmpty { page = .coaching }
            else if ["queued", "running", "needs_input", "blocked", "failed", "cancelled"].contains(state) { page = .processing }
            else if !draft.isEmpty || localURL != nil || !recording.object.isEmpty { page = .review }
            else { page = .question }
        } catch { fail(error) }
    }

    private func resetAnswer() {
        draft = ""
        dirty = false
        feedback = [:]
        run = [:]
        recording = [:]
        localClientID = ""
        localURL = nil
        autosaveFailed = false
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

    private func persistAnswer() async throws {
        var value = current["data"]
        value["answer"] = .string(draft)
        value["transcript"] = .string(recording.object.isEmpty ? "" : draft)
        value["behavioral"]["local_id"] = .string(localClientID)
        value["behavioral"]["recording_id"] = .string(recording["id"].string)
        if value != current["data"] { try await save(value) }
    }

    /// Debounced by the view: runs after typing pauses.
    func autoSave() async {
        guard !busy, !autosaveFailed, !current["id"].string.isEmpty, current["data"]["answer"].string != draft,
              [.answer, .review].contains(page) else { return }
        busy = true
        saving = true
        defer { busy = false; saving = false }
        do { try await persistAnswer() }
        catch is CancellationError { }
        catch {
            self.error = "Your answer is kept on screen. Save again when connected. " + error.localizedDescription
            autosaveFailed = true
        }
    }

    func edited(_ text: String) {
        draft = text
        dirty = true
        autosaveFailed = false
    }

    // MARK: Navigation

    func back() async {
        guard !locked else { return }
        error = ""
        epoch += 1
        switch page {
        case .type: page = .home
        case .focus: page = .type
        case .length: page = idea ? .home : .focus
        case .history: page = .coaching
        case .savedAnswer: page = .history
        case .answer, .review:
            busy = true
            do { try await persistAnswer(); page = .home } catch { fail(error) }
            busy = false
        default:
            page = .home
            await reload()
        }
    }

    // MARK: Recording

    /// Hidden tabs stay mounted, so leaving Prep must explicitly release the microphone.
    func suspendCapture() {
        epoch += 1
        let stopped = recorder.stop()
        let captured = stopped ?? pendingCapture
        pendingCapture = nil
        guard let saved = captured else { return }
        localClientID = saved.clientID
        localURL = saved.url
        recording = [:]
        page = .review
        let generation = store?.sessionGeneration
        Task { @MainActor [weak self] in
            guard let self, let store = self.store, store.phase == .ready,
                  store.sessionGeneration == generation else { return }
            do { try await self.persistAnswer() } catch { self.fail(error) }
        }
    }

    func recordAnswer() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer {
            busy = false
            if let pending = pendingCapture {
                pendingCapture = nil
                Task { @MainActor [weak self] in
                    await self?.captureStopped(clientID: pending.clientID, url: pending.url)
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
            dirty = false
            page = .recording
            try await persistAnswer()
        } catch { fail(error) }
    }

    func togglePause() {
        guard !busy else { return }
        error = ""
        do {
            if recorder.isPaused { try recorder.resume() } else { recorder.pause() }
        } catch { fail(error) }
    }

    func finishAnswer() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        guard let saved = recorder.stop() else {
            error = "No audio was saved. Record your answer again."
            return
        }
        await keepCapture(clientID: saved.clientID, url: saved.url)
    }

    private func captureStopped(clientID: String, url: URL) async {
        guard page == .recording, store?.phase == .ready, store?.sessionGeneration == boundGeneration else { return }
        if busy { pendingCapture = (clientID, url); return }
        busy = true
        defer { busy = false }
        await keepCapture(clientID: clientID, url: url)
    }

    private func keepCapture(clientID: String, url: URL) async {
        localClientID = clientID
        localURL = url
        draft = ""
        dirty = false
        recording = [:]
        do {
            try await persistAnswer()
            page = .review
            try await uploadAnswer()
        } catch {
            fail(error)
            page = .review
        }
    }

    private func uploadAnswer() async throws {
        guard let url = localURL else { throw APIError(message: "Recording file is unavailable.") }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { throw APIError(message: "This recording has no saved audio. Record another answer.") }
        guard data.count <= 10 * 1024 * 1024 else { throw APIError(message: "Recording must be 10 MB or less.") }
        recording = try await call(
            "transcription_upload",
            ["client_id": .string(localClientID), "content": .string(data.base64EncodedString())],
            timeout: 90
        )
        try await persistAnswer()
    }

    func retryUpload() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do { try await uploadAnswer() } catch { fail(error) }
    }

    func retryTranscription() async {
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
        guard !busy, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await persistAnswer()
            feedback = [:]
            run = try await call("agent_start", ["kind": "prep", "target_id": current["id"]])
            page = .processing
        } catch { fail(error) }
    }

    func retryCoach() async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            if run["status"].string == "needs_input" {
                try await call("agent_respond", ["id": run["id"], "values": [], "reuse": true])
            } else {
                try await call("agent_retry", ["id": run["id"]])
            }
        } catch { fail(error) }
    }

    /// Polled every two seconds by the view while a transcript or coaching is pending.
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
                    }
                }
            }
            if page == .processing {
                let result = try await sessionRequest { try await transport.get(current["id"].string) }
                guard observed == epoch else { return }
                let revision = current["revision"].int
                if let match = result["feedback"].array.last(where: { $0["revision"].int == revision }) {
                    current = result
                    feedback = match["data"]
                    page = .coaching
                    await reload()
                } else if !run["id"].string.isEmpty {
                    let latest = try await call("agent_run", ["id": run["id"]])
                    if observed == epoch { run = latest }
                }
            }
        } catch {
            if observed == epoch, !(error is CancellationError) { fail(error) }
        }
    }

    var needsPolling: Bool {
        page == .processing || (!recording["id"].string.isEmpty && recording["status"].string != "completed")
    }

    func nextAnswer() async {
        guard !busy else { return }
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
                "answer": .string(draft),
                "feedback": feedback,
                "local_id": .string(localClientID),
                "recording_id": recording["id"],
            ])
            let nextIndex = last ? w["index"].int : w["index"].int + 1
            var data = current["data"]
            data["problem_id"] = w["plan"][nextIndex]
            data["answer"] = .string(last ? draft : "")
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
        feedback = [:]
        var data = current["data"]
        data["behavioral"]["complete"] = false
        current["data"] = data
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

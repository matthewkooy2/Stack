import Foundation
import Observation

enum LibraryPage: String, StageKey {
    case loading, industry, track, slots, slot, attempts, attempt, interviewer, recording, review, scoring

    var depth: Int {
        switch self {
        case .loading: return 0
        case .industry: return 1
        case .track: return 2
        case .slots: return 3
        case .slot: return 4
        case .attempts, .interviewer: return 5
        case .attempt, .recording: return 6
        case .review: return 7
        case .scoring: return 8
        }
    }
}

/// The practice interview library: choose an industry and track, then practice question slots.
/// Each answer is a video kept on this phone, an uploaded audio copy for transcription, and a
/// scored attempt on the server. A slot opens on its highest-scoring attempt.
@MainActor
@Observable
final class LibraryModel {
    var page: LibraryPage = .loading
    var industries: [PracticeChoice] = []
    var tracks: [PracticeChoice] = []
    var industry = ""
    var slots: [PracticeSlot] = []
    var question: PracticeQuestion?
    var attempts: [PracticeAttempt] = []
    var attempt: PracticeAttempt?

    /// Read the question aloud before recording. Off shows the text only.
    var useInterviewer = true
    var autoRecord = true

    // The answer in progress.
    var videoID = ""
    var videoURL: URL?
    var duration: TimeInterval = 0
    var recording: JSON = [:]
    var runtime: JSON = [:]
    var draft = ""
    var draftEdited = false
    var attemptClientID = ""

    var busy = false
    var error = ""

    let recorder = VideoRecorder()
    let interviewer = InterviewerVoice()
    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var generation = 0

    func bind(_ store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        generation = store.sessionGeneration
        recorder.onAutoStop = { [weak self] result in
            Task { @MainActor in await self?.captured(result) }
        }
    }

    private var owner: String { store?.account.userID ?? "" }

    private func call(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        guard let store, store.sessionGeneration == generation else { throw CancellationError() }
        let result = try await store.call(name, args, timeout: timeout)
        guard store.sessionGeneration == generation else { throw CancellationError() }
        if !result["error"].string.isEmpty { throw APIError(message: result["error"].string) }
        return result
    }

    private func run(_ work: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do { try await work() } catch { fail(error) }
    }

    private func fail(_ failure: Error) {
        if failure is CancellationError { return }
        error = failure.localizedDescription
    }

    var transcribing: Bool { !recording.object.isEmpty && !["completed", "failed", "cancelled"].contains(recording["status"].string) }
    var transcriptionUnavailable: Bool { runtime["status"].string == "unavailable" }
    var needsPolling: Bool { (page == .review && transcribing) || (page == .scoring) }
    var industryLabel: String { industries.first { $0.id == industry }?.label ?? industry }
    var recordingActive: Bool { recorder.isRecording || recorder.phase == .finishing }

    // MARK: Loading and navigation

    func load() async {
        await run {
            let options = try await call("practice_options")
            industries = options["industries"].array.map(PracticeChoice.init)
            tracks = options["tracks"].array.map(PracticeChoice.init)
            industry = options["industry"].string
            page = industry.isEmpty ? .industry : .track
        }
        if page == .loading, !error.isEmpty { page = .industry }
    }

    func chooseIndustry(_ id: String) async {
        await run {
            let options = try await call("practice_profile", ["industry": .string(id)])
            industry = options["industry"].string
            await store?.refresh()
            page = .track
        }
    }

    func chooseTrack(_ track: PracticeChoice) async {
        guard track.available else { return }
        await run {
            try await reloadSlots()
            page = .slots
        }
    }

    private func reloadSlots() async throws {
        let result = try await call("practice_slots", ["track": "behavioral"])
        if result["needs_industry"].bool { page = .industry; return }
        slots = result["slots"].array.map(PracticeSlot.init)
    }

    func openSlot(_ slot: PracticeSlot) {
        question = slot.question
        attempt = slot.best
        attempts = []
        error = ""
        page = .slot
    }

    func showAttempts() async {
        guard let question else { return }
        await run {
            attempts = try await call("practice_attempts", ["question_id": .string(question.id)])["attempts"].array.map(PracticeAttempt.init)
            page = .attempts
        }
    }

    func view(_ chosen: PracticeAttempt) {
        attempt = chosen
        page = .attempt
    }

    func back() async {
        guard !busy, !recordingActive else { return }
        interviewer.stop()
        error = ""
        switch page {
        case .loading, .industry: break
        case .track: page = .industry
        case .slots: page = .track
        case .slot: await run { try await reloadSlots() }; page = .slots
        case .attempts: page = .slot
        case .interviewer, .recording: recorder.shutdown(); page = .slot
        case .attempt, .scoring: await run { try await refreshSlot() }; page = .slot
        case .review: await discardAnswer(); page = .slot
        }
    }

    /// Re-reads the slots so the open question shows its current best answer.
    private func refreshSlot() async throws {
        try await reloadSlots()
        guard let question, let slot = slots.first(where: { $0.id == question.id }) else { return }
        attempt = slot.best
        attempts = []
    }

    // MARK: Asking and recording

    func practice() async {
        guard let question else { return }
        error = ""
        page = .interviewer
        await recorder.prepare()
        if useInterviewer {
            interviewer.ask(question) { [weak self] in
                guard let self, self.page == .interviewer, self.autoRecord, self.recorder.phase == .ready else { return }
                Task { await self.startRecording() }
            }
        }
    }

    func replay() {
        guard let question else { return }
        interviewer.ask(question) {}
    }

    func skipInterviewer() {
        interviewer.stop()
        useInterviewer = false
    }

    func startRecording() async {
        interviewer.stop()
        guard !owner.isEmpty else { error = "Sign in before recording."; return }
        do {
            if recorder.phase == .idle { await recorder.prepare() }
            guard recorder.phase == .ready else { return }
            videoID = VideoLibraryStore.newVideoID()
            let url = try VideoLibraryStore.url(owner: owner, videoID: videoID)
            try recorder.start(to: url)
            page = .recording
        } catch { fail(error) }
    }

    func stopRecording() async {
        do { await captured(.success(try await recorder.stop())) }
        catch { await captured(.failure(error)) }
    }

    /// Recording finished, by Stop or on its own; save it and send its audio for transcription.
    private func captured(_ result: Result<URL, Error>) async {
        switch result {
        case .failure(let failure):
            recorder.shutdown()
            if !videoID.isEmpty { try? VideoLibraryStore.delete(owner: owner, videoID: videoID) }
            fail(failure)
            page = .slot
        case .success(let url):
            // Release the camera while the person reviews; the next answer prepares it again.
            recorder.shutdown()
            videoURL = url
            duration = recorder.elapsed
            draft = ""
            draftEdited = false
            recording = [:]
            attemptClientID = "attempt-" + UUID().uuidString.lowercased()
            page = .review
            await uploadAudio()
        }
    }

    func uploadAudio() async {
        guard let videoURL else { return }
        await run {
            let wav = try await AudioExtractor.wav(from: videoURL, to: try VideoLibraryStore.audioURL(owner: owner, videoID: videoID))
            let data = try Data(contentsOf: wav)
            let list = try await call("transcription_list")
            runtime = list["runtime"]
            recording = try await call("transcription_upload", ["client_id": .string(videoID), "content": .string(data.base64EncodedString())], timeout: 90)
            try? FileManager.default.removeItem(at: wav)
            adoptTranscript()
        }
    }

    private func adoptTranscript() {
        if recording["status"].string == "completed", !draftEdited { draft = recording["transcript"].string }
    }

    func edited(_ text: String) {
        draft = text
        draftEdited = true
    }

    /// Polled every two seconds while a transcript or score is pending.
    func poll() async {
        guard !busy else { return }
        do {
            if page == .review, transcribing {
                recording = try await call("transcription_get", ["id": recording["id"]])
                runtime = try await call("transcription_list")["runtime"]
                adoptTranscript()
            } else if page == .scoring, let current = attempt {
                let latest = PracticeAttempt(try await call("practice_attempt_get", ["id": .string(current.id)]))
                attempt = latest
                if !latest.isCoaching { page = .attempt }
            }
        } catch { fail(error) }
    }

    func retryTranscription() async {
        await run { recording = try await call("transcription_action", ["id": recording["id"], "action": "retry"]) }
    }

    // MARK: Scoring

    func score() async {
        guard let question, !draft.isBlank else { return }
        await run {
            let created = try await call("practice_attempt_create", [
                "question_id": .string(question.id), "client_id": .string(attemptClientID), "answer": .string(draft),
                "recording_id": recording["id"], "video_id": .string(videoID), "duration": .number(duration),
            ])
            attempt = PracticeAttempt(created)
            videoURL = nil
            recording = [:]
            page = attempt?.isCoaching == true ? .scoring : .attempt
        }
    }

    func retryScoring() async {
        guard let current = attempt, !current.runID.isEmpty else { return }
        await run {
            if current.status == "needs_input" {
                _ = try await call("agent_respond", ["id": .string(current.runID), "values": [], "reuse": true])
            } else {
                _ = try await call("agent_retry", ["id": .string(current.runID)])
            }
            attempt = PracticeAttempt(try await call("practice_attempt_get", ["id": .string(current.id)]))
            page = .scoring
        }
    }

    /// Leaving review without scoring removes the recording from the phone and the server.
    func discardAnswer() async {
        let id = recording["id"].string
        if !id.isEmpty { _ = try? await call("transcription_action", ["id": .string(id), "action": "delete"]) }
        if !videoID.isEmpty { try? VideoLibraryStore.delete(owner: owner, videoID: videoID) }
        videoURL = nil
        recording = [:]
        draft = ""
    }

    func delete(_ target: PracticeAttempt) async {
        await run {
            _ = try await call("practice_attempt_delete", ["id": .string(target.id)])
            try? VideoLibraryStore.delete(owner: owner, videoID: target.videoID)
            if let question {
                attempts = try await call("practice_attempts", ["question_id": .string(question.id)])["attempts"].array.map(PracticeAttempt.init)
            }
            try await reloadSlots()
            attempt = attempts.first
            page = attempts.isEmpty ? .slot : .attempts
        }
    }

    func localVideo(_ attempt: PracticeAttempt) -> URL? {
        VideoLibraryStore.existing(owner: owner, videoID: attempt.videoID)
    }

    func suspend() {
        interviewer.stop()
        recorder.shutdown()
    }
}

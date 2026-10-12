import AVFoundation
import Observation
import SwiftUI

struct PhoneTranscript: Codable, Equatable {
    let original: String
    var text: String
    var revision: Int
    var serverID: String? = nil
    var syncedText: String? = nil

    var hasPendingEdits: Bool { text != syncedText }
}

struct CapturedRecording {
    let clientID: String
    let url: URL
    let finalized: Task<Void, Never>
}

/// Durable, owner-isolated recordings on this phone. Files are 16 kHz mono 16-bit PCM WAV, which is the
/// format the transcription service accepts.
enum RecordingStore {
    static let maximumSeconds: TimeInterval = 300

    static func directory(owner: String) throws -> URL {
        let safe = owner.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe == owner, safe.count <= 80 else { throw APIError(message: "Sign in before recording.") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("Recordings", isDirectory: true).appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
        return directory
    }

    static func newClientID() -> String { "swift-" + UUID().uuidString.lowercased() }

    static func url(owner: String, clientID: String) throws -> URL {
        guard clientID.range(of: "^[a-zA-Z0-9_-]{12,80}$", options: .regularExpression) != nil else {
            throw APIError(message: "Invalid recording identifier.")
        }
        return try directory(owner: owner).appendingPathComponent(clientID + ".wav")
    }

    static func exists(owner: String, clientID: String) -> URL? {
        guard !clientID.isEmpty, let url = try? url(owner: owner, clientID: clientID),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              size > 44 else { return nil }
        return url
    }

    static func transcript(at url: URL) -> PhoneTranscript? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url.appendingPathExtension("json")) else { return nil }
        return try? JSONDecoder().decode(PhoneTranscript.self, from: data)
    }

    // Called on the main actor after finalization; never recreate files removed by sign-out.
    @MainActor static func saveTranscript(_ value: PhoneTranscript, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CancellationError() }
        guard !value.original.isBlank, value.original.count <= 30000, value.text.count <= 30000 else {
            throw APIError(message: "Transcript must be 30,000 characters or less.")
        }
        let path = url.appendingPathExtension("json")
        try JSONEncoder().encode(value).write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @MainActor static func editTranscript(_ text: String, at url: URL) throws {
        guard var value = transcript(at: url) else { return }
        guard value.text != text else { return }
        value.text = text; value.revision += 1
        try saveTranscript(value, at: url)
    }

    @MainActor static func markSynced(_ serverID: String, text: String? = nil, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path), !serverID.isEmpty else { throw CancellationError() }
        if var value = transcript(at: url) {
            value.serverID = serverID
            value.syncedText = text
            try saveTranscript(value, at: url)
        }
        // Raw fallback audio has no transcript sidecar, but also needs durable sync state.
        try JSONEncoder().encode(serverID).write(to: url.appendingPathExtension("synced"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    @MainActor static func pending(owner: String) -> [CapturedRecording] {
        guard let directory = try? directory(owner: owner),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return [] }
        return files.filter {
            $0.pathExtension == "wav" && $0.lastPathComponent.hasPrefix("swift-")
                && ((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) > 44
                && (transcript(at: $0).map { $0.serverID == nil || $0.hasPendingEdits }
                    ?? !FileManager.default.fileExists(atPath: $0.appendingPathExtension("synced").path))
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
            CapturedRecording(clientID: $0.deletingPathExtension().lastPathComponent, url: $0, finalized: Task {})
        }
    }

    @MainActor static func delete(owner: String, clientID: String) throws {
        let url = try url(owner: owner, clientID: clientID)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let sidecar = url.appendingPathExtension("json")
        if FileManager.default.fileExists(atPath: sidecar.path) { try FileManager.default.removeItem(at: sidecar) }
        let marker = url.appendingPathExtension("synced")
        if FileManager.default.fileExists(atPath: marker.path) { try FileManager.default.removeItem(at: marker) }
    }

    /// Everything this phone kept for every account; used on sign-out.
    static func removeAll() {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Recordings", isDirectory: true))
    }
}

/// Records one answer at a time with pause and resume. Both capture paths (on-device speech
/// and the PC-transcription fallback) tap the microphone PCM and feed one `PCMLevelMeter`.
@MainActor
@Observable
final class AudioRecorder {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    var error = ""
    /// A calm explanation of why capture ended without Stop (call, background, route change, limit).
    private(set) var stopNotice = ""
    /// Microphone access was refused; the view offers Settings and a retry.
    private(set) var permissionDenied = false
    private(set) var liveText = ""
    private(set) var onDevice = false
    private(set) var finalizing = false
    private(set) var engineMessage = ""
    /// Whether the live transcript is drawn. Visibility only: recognition and the saved
    /// transcript never depend on it, and it survives pause, resume and new captures.
    private(set) var showsLiveTranscript = false
    /// Level meter of the capture in progress (or the one that just ended; it reads idle).
    private(set) var meter: PCMLevelMeter?

    private var captureGeneration = 0
    private var starting = false
    private var speechCapture: AnyObject?
    private var fallbackCapture: (any AudioPCMCapture)?
    private let requestPermission: @MainActor () async -> Bool
    private let makeFallback: @MainActor () -> any AudioPCMCapture
    private let allowOnDevice: Bool

    // Synthetic tests inject permission and capture; the app uses the real microphone paths.
    init(requestPermission: @escaping @MainActor () async -> Bool = {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
    }, makeFallback: @escaping @MainActor () -> any AudioPCMCapture = { FallbackPCMCapture() }, allowOnDevice: Bool = true) {
        self.requestPermission = requestPermission
        self.makeFallback = makeFallback
        self.allowOnDevice = allowOnDevice
    }
    private(set) var clientID = ""
    private(set) var fileURL: URL?
    /// Called when the recording stopped on its own (time limit, phone call, route change).
    var onAutoStop: ((CapturedRecording) -> Void)?

    func setLiveTranscriptVisible(_ visible: Bool) { showsLiveTranscript = visible }

    #if DEBUG
    // Rendering fixture only. Synthetic capture never claims to run SpeechAnalyzer.
    // Release builds and ordinary Debug launches cannot enter this path.
    func showSyntheticTranscriptForUITest(_ text: String) {
        guard ProcessInfo.processInfo.arguments.contains("--microphone-ui-fixture") else { return }
        onDevice = true
        liveText = text
    }
    #endif

    func start(owner: String) async throws -> (clientID: String, url: URL) {
        guard !starting, !isRecording, !finalizing, speechCapture == nil, fallbackCapture == nil else { throw APIError(message: "Finish the current recording first.") }
        starting = true
        defer { starting = false }
        let generation = captureGeneration
        error = ""; stopNotice = ""; permissionDenied = false
        liveText = ""; onDevice = false
        engineMessage = "PC transcription will be used."
        let granted = await requestPermission()
        guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
        guard granted else {
            permissionDenied = true
            throw APIError(message: "Allow microphone access in iPhone Settings to record your answer, or type it instead.")
        }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), allowOnDevice {
            let capabilities = await StackSpeechSession.capabilities()
            guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
            engineMessage = capabilities["reason"] as? String ?? engineMessage
            if capabilities["available"] as? Bool == true {
                let id = RecordingStore.newClientID()
                let url = try RecordingStore.url(owner: owner, clientID: id)
                clientID = id; fileURL = url
                let capture = StackSpeechSession(id: id) { [weak self] event in
                    guard let self, generation == self.captureGeneration, id == self.clientID else { return }
                    if event["kind"] as? String == "progress" {
                        self.elapsed = (event["duration_ms"] as? Double ?? 0) / 1000
                        self.liveText = event["text"] as? String ?? ""
                    } else if event["kind"] as? String == "finished" {
                        self.elapsed = (event["duration_ms"] as? Double ?? 0) / 1000
                        self.stopNotice = event["message"] as? String ?? ""
                        if let saved = self.stop() { self.onAutoStop?(saved) }
                    }
                }
                speechCapture = capture
                meter = capture.meter
                do {
                    try await capture.start(uri: url.absoluteString)
                    guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
                    isRecording = true; isPaused = false; elapsed = 0; onDevice = true
                    return (id, url)
                } catch {
                    _ = await capture.stop(cancelled: true, reason: "On-device speech could not start.")
                    speechCapture = nil
                    guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
                    engineMessage = "On-device speech could not start. PC transcription will be used."
                    // Keep a partial file; fallback gets a new identity and never overwrites it.
                }
            }
        }
        #endif
        let id = RecordingStore.newClientID()
        let url = try RecordingStore.url(owner: owner, clientID: id)
        let capture = makeFallback()
        capture.onProgress = { [weak self] seconds in
            guard let self, generation == self.captureGeneration, id == self.clientID else { return }
            self.elapsed = seconds
        }
        capture.onEnded = { [weak self] reason in
            guard let self, generation == self.captureGeneration, id == self.clientID else { return }
            self.stopNotice = reason
            if let saved = self.stop() { self.onAutoStop?(saved) }
        }
        do { try capture.start(url: url) }
        catch { throw APIError(message: "The microphone could not start. Close other audio apps and try again.") }
        guard generation == captureGeneration, !Task.isCancelled else {
            capture.stop()
            throw CancellationError()
        }
        fallbackCapture = capture
        meter = capture.meter
        clientID = id
        fileURL = url
        isRecording = true
        isPaused = false
        elapsed = 0
        return (id, url)
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let capture = speechCapture as? StackSpeechSession {
            do { try capture.pause(); isPaused = true } catch { self.error = error.localizedDescription }
            return
        }
        #endif
        guard let capture = fallbackCapture else { return }
        do { try capture.pause(); isPaused = true } catch { self.error = error.localizedDescription }
    }

    func resume() throws {
        guard isRecording, isPaused else { return }
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let capture = speechCapture as? StackSpeechSession {
            try capture.resume(); isPaused = false; return
        }
        #endif
        guard let capture = fallbackCapture else { return }
        do { try capture.resume() } catch { throw APIError(message: "The recording could not resume.") }
        isPaused = false
    }

    /// Stops and returns the saved file, or nil when nothing is being recorded.
    @discardableResult
    func stop(cancelled: Bool = false, reason: String = "") -> CapturedRecording? {
        if isRecording, !reason.isEmpty { stopNotice = reason }
        captureGeneration += 1
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let capture = speechCapture as? StackSpeechSession, let url = fileURL {
            let id = clientID
            capture.halt()
            speechCapture = nil
            isRecording = false; isPaused = false; finalizing = true
            let task = Task { @MainActor [weak self] in
                let result = await capture.stop(cancelled: cancelled, reason: "")
                self?.elapsed = (result["duration_ms"] as? Double ?? 0) / 1000
                if let message = result["message"] as? String, !message.isEmpty { self?.stopNotice = message }
                if result["complete"] as? Bool == true, let original = result["text"] as? String, original.count <= 30000 {
                    do { try RecordingStore.saveTranscript(PhoneTranscript(original: original, text: original, revision: 1), at: url) }
                    catch is CancellationError { }
                    catch { self?.error = error.localizedDescription }
                } else if !cancelled {
                    self?.engineMessage = "On-device recognition could not finish. PC transcription will be used."
                }
                self?.finalizing = false
            }
            return CapturedRecording(clientID: id, url: url, finalized: task)
        }
        #endif
        guard let capture = fallbackCapture, let url = fileURL else { return nil }
        let result = capture.stop()
        fallbackCapture = nil
        elapsed = result.seconds
        isRecording = false
        isPaused = false
        if !result.error.isEmpty, stopNotice.isEmpty { stopNotice = result.error }
        return CapturedRecording(clientID: clientID, url: url, finalized: Task {})
    }
}

func recordingClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Plays a saved answer.
@MainActor
@Observable
final class AnswerPlayer: NSObject, AVAudioPlayerDelegate {
    private(set) var isPlaying = false
    private var player: AVAudioPlayer?

    func toggle(url: URL) {
        if isPlaying { stop(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let made = try AVAudioPlayer(contentsOf: url)
            made.delegate = self
            player = made
            isPlaying = made.play()
        } catch { isPlaying = false }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}

@MainActor
struct AnswerPlayback: View {
    let url: URL
    var isActive = true
    @State var player = AnswerPlayer()

    var body: some View {
        Button { player.toggle(url: url) } label: {
            HStack(spacing: 14) {
                GlyphView(name: player.isPlaying ? "pause" : "play", size: 20)
                Text(player.isPlaying ? "Pause your answer" : "Play your answer")
                    .font(Typeface.button).foregroundStyle(Palette.icon)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Palette.button, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        }
        .buttonStyle(.tap)
        .onDisappear { player.stop() }
        .onChange(of: isActive) { _, active in if !active { player.stop() } }
        .accessibilityLabel(player.isPlaying ? "Pause your answer" : "Play your answer")
    }
}

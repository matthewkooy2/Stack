import AVFoundation
import Observation
import SwiftUI

/// Durable, owner-isolated recordings on this phone. Files are 16 kHz mono 16-bit PCM WAV, which is the
/// format the transcription service accepts.
enum RecordingStore {
    static let maximumSeconds: TimeInterval = 300

    static func directory(owner: String) throws -> URL {
        let safe = owner.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe.count <= 80 else { throw APIError(message: "Sign in before recording.") }
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

    /// Everything this phone kept for every account; used on sign-out.
    static func removeAll() {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent("Recordings", isDirectory: true))
    }
}

/// Records one answer at a time with pause and resume.
@MainActor
@Observable
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var elapsed: TimeInterval = 0
    var error = ""

    private var recorder: AVAudioRecorder?
    private var ticker: Task<Void, Never>?
    private var interruption: NSObjectProtocol?
    private var captureGeneration = 0
    private(set) var clientID = ""
    private(set) var fileURL: URL?
    /// Called when the recording stopped on its own (time limit, phone call, route change).
    var onAutoStop: ((String, URL) -> Void)?

    func start(owner: String) async throws -> (clientID: String, url: URL) {
        let generation = captureGeneration
        error = ""
        let granted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
        }
        guard generation == captureGeneration, !Task.isCancelled else { throw CancellationError() }
        guard granted else {
            throw APIError(message: "Allow microphone access in iPhone Settings to record your answer, or type it instead.")
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)
        let id = RecordingStore.newClientID()
        let url = try RecordingStore.url(owner: owner, clientID: id)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let made = try AVAudioRecorder(url: url, settings: settings)
        made.delegate = self
        guard made.record(forDuration: RecordingStore.maximumSeconds) else {
            throw APIError(message: "The microphone could not start. Close other audio apps and try again.")
        }
        recorder = made
        clientID = id
        fileURL = url
        isRecording = true
        isPaused = false
        elapsed = 0
        observeInterruptions()
        startTicker()
        return (id, url)
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
    }

    func resume() throws {
        guard isRecording, isPaused else { return }
        guard recorder?.record() == true else { throw APIError(message: "The recording could not resume.") }
        isPaused = false
    }

    /// Stops and returns the saved file, or nil when nothing is being recorded.
    @discardableResult
    func stop() -> (clientID: String, url: URL)? {
        captureGeneration += 1
        guard let recorder, let url = fileURL else { return nil }
        elapsed = recorder.currentTime
        recorder.stop()
        finish()
        return (clientID, url)
    }

    private func finish() {
        ticker?.cancel()
        ticker = nil
        recorder = nil
        isRecording = false
        isPaused = false
        if let interruption { NotificationCenter.default.removeObserver(interruption) }
        interruption = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let recorder = self.recorder else { return }
                if self.isRecording { self.elapsed = recorder.currentTime }
            }
        }
    }

    /// A phone call or alarm stops the capture; the audio recorded so far is kept.
    private func observeInterruptions() {
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw == AVAudioSession.InterruptionType.began.rawValue else { return }
            guard let recording = self else { return }
            Task { @MainActor in
                guard let saved = recording.stop() else { return }
                recording.onAutoStop?(saved.clientID, saved.url)
            }
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            // Reaching the time limit stops the recorder itself.
            guard self.isRecording, self.recorder === recorder, let url = self.fileURL else { return }
            self.elapsed = RecordingStore.maximumSeconds
            let id = self.clientID
            self.finish()
            self.onAutoStop?(id, url)
        }
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

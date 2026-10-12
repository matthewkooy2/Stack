import AVFoundation
import UIKit

// Capture used when on-device speech is unavailable or fails to start. It records the same
// durable 16 kHz mono WAV the PC transcriber accepts, and measures the same PCM samples for
// the level meter, so the recording surface behaves identically on both paths.
// No speech recognition is performed here.

/// Converts tapped microphone buffers to the durable WAV. Called from the audio thread;
/// everything is serialized by `lock`.
final class PCMFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var file: FileHandle?
    private let converter: SpeechPCMConverter
    private let meter: PCMLevelMeter
    private var frames: AVAudioFramePosition = 0
    private var syncedFrames: AVAudioFramePosition = 0
    private var error = ""
    private var paused = false

    init(url: URL, natural: AVAudioFormat, meter: PCMLevelMeter) throws {
        let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
        converter = try SpeechPCMConverter(from: natural, to: pcm)
        self.meter = meter
        guard FileManager.default.createFile(atPath: url.path, contents: WAVHeader.data(bytes: 0),
                                             attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else {
            throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not create the durable audio file."])
        }
        file = try FileHandle(forUpdating: url)
        try file?.seek(toOffset: 44)
    }

    func append(_ source: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard file != nil, !paused, frames < 16000 * 300 else { return }
        meter.ingest(source)
        let output: AVAudioPCMBuffer
        do { guard let converted = try converter.convert(source) else { return }; output = converted }
        catch { self.error = "Audio conversion failed. Partial audio was kept."; return }
        write(output)
    }

    private func write(_ output: AVAudioPCMBuffer) {
        guard let file, frames < 16000 * 300 else { return }
        output.frameLength = min(output.frameLength, AVAudioFrameCount(16000 * 300 - frames))
        guard output.frameLength > 0 else { return }
        guard let samples = output.int16ChannelData?[0] else { error = "Microphone samples were unavailable."; return }
        let audio = Data(bytes: samples, count: Int(output.frameLength) * 2)
        do {
            try file.write(contentsOf: audio)
            // Keep the header current so a suspended app can recover every committed buffer.
            let count = frames + AVAudioFramePosition(output.frameLength)
            try file.seek(toOffset: 0); try file.write(contentsOf: WAVHeader.data(bytes: UInt32(count * 2)))
            try file.seek(toOffset: UInt64(44 + count * 2))
            if count - syncedFrames >= 16000 { try file.synchronize(); syncedFrames = count }
        } catch { self.error = "Saving audio failed. Keep this recording and check available phone storage."; return }
        frames += AVAudioFramePosition(output.frameLength)
    }

    func snapshot() -> (seconds: Double, error: String) {
        lock.lock(); defer { lock.unlock() }
        return (Double(frames) / 16000, error)
    }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
    }

    func close() -> (seconds: Double, error: String) {
        lock.lock(); defer { lock.unlock() }
        if file != nil {
            do { for buffer in try converter.finish() { write(buffer) } }
            catch { self.error = "Audio conversion could not finish. Your partial audio was kept." }
        }
        do { try file?.synchronize(); try file?.close() }
        catch { self.error = "Audio could not be fully flushed. Keep the partial recording and check phone storage." }
        file = nil
        return (Double(frames) / 16000, error)
    }
}

@MainActor
protocol AudioPCMCapture: AnyObject {
    var meter: PCMLevelMeter { get }
    var onProgress: ((Double) -> Void)? { get set }
    var onEnded: ((String) -> Void)? { get set }
    func start(url: URL) throws
    func pause() throws
    func resume() throws
    @discardableResult func stop() -> (seconds: Double, error: String)
}

@MainActor
final class FallbackPCMCapture: AudioPCMCapture {
    let meter = PCMLevelMeter()
    /// Seconds of audio saved so far, about every 200 ms.
    var onProgress: ((Double) -> Void)?
    /// The capture ended without a Stop (interruption, background, route reset, limit, error).
    /// The file is already closed when this is called.
    var onEnded: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var writer: PCMFileWriter?
    private var ticker: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var naturalFormat: AVAudioFormat?
    private var closed: (seconds: Double, error: String)?
    private(set) var isPaused = false

    func start(url: URL) throws {
        var tapInstalled = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
            let natural = engine.inputNode.outputFormat(forBus: 0)
            guard natural.sampleRate > 0, natural.channelCount > 0 else {
                throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone input is unavailable."])
            }
            let writer = try PCMFileWriter(url: url, natural: natural, meter: meter)
            self.writer = writer
            naturalFormat = natural
            engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: natural) { @Sendable buffer, _ in writer.append(buffer) }
            tapInstalled = true
            engine.prepare()
            try engine.start()
        } catch {
            // Nothing was recorded: release the tap, the session and the empty file so a
            // retry (or the PC fallback's new identity) starts from a clean state.
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            _ = writer?.close()
            writer = nil
            meter.finish()
            closed = (seconds: 0, error: "")
            try? FileManager.default.removeItem(at: url)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        observe()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, self.closed == nil, let writer = self.writer, !Task.isCancelled else { return }
                let snapshot = writer.snapshot()
                self.onProgress?(snapshot.seconds)
                if !snapshot.error.isEmpty { self.end(snapshot.error); return }
                if snapshot.seconds >= RecordingStore.maximumSeconds { self.end("Five-minute recording limit reached."); return }
            }
        }
    }

    func pause() throws {
        guard closed == nil, !isPaused else { throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording is no longer active."]) }
        writer?.setPaused(true)
        engine.pause()
        meter.pause()
        isPaused = true
    }

    func resume() throws {
        guard closed == nil, isPaused else { throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: "Recording is no longer active."]) }
        // A route change while paused is not reported (a paused engine is not running), and the
        // tap is still bound to the old format. Detect it here rather than record nothing.
        guard engine.inputNode.outputFormat(forBus: 0) == naturalFormat else {
            let message = "The microphone changed while paused. The partial answer was kept."
            end(message)
            throw NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        do { try engine.start() }
        catch {
            end("The microphone could not resume. The partial answer was kept.")
            throw error
        }
        meter.resume()
        writer?.setPaused(false)
        isPaused = false
    }

    /// Releases the microphone synchronously and closes the file. Safe to call repeatedly.
    @discardableResult
    func stop() -> (seconds: Double, error: String) {
        if let closed { return closed }
        ticker?.cancel(); ticker = nil
        engine.stop()
        if writer != nil { engine.inputNode.removeTap(onBus: 0) }
        // The tap is gone, so the writer sees no further buffers; the meter drops any in flight.
        meter.finish()
        let result = writer?.close() ?? (seconds: 0, error: "")
        writer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        closed = result
        return result
    }

    private func end(_ reason: String) {
        guard closed == nil else { return }
        stop()
        onEnded?(reason)
    }

    private func observe() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in self?.end("Microphone interrupted. The partial answer was kept.") }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.end("Recording stopped when Stack entered the background. Audio was kept.") }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.end("Audio service reset. The partial answer was kept.") }
            },
            // A route or format change stops the engine itself; without this the file would
            // silently stop growing while the timer froze. Paused engines are not running either.
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isPaused, !self.engine.isRunning else { return }
                    self.end("The microphone changed. The partial answer was kept.")
                }
            },
        ]
    }
}

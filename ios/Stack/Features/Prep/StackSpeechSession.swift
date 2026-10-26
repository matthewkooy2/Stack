import AVFoundation
import Speech
import UIKit

// Reused from the Expo StackSpeech module. Older SDK builds retain PC fallback.
#if compiler(>=6.2)

// Durable WAV stays 16 kHz; recognition uses Apple's negotiated PCM format.
// No SFSpeechRecognizer (which can use a server) or asset-download API is used.
@available(iOS 26.0, *) @MainActor final class StackSpeechSession {
  let id: String
  private let emit: ([String: Any]) -> Void
  private let engine = AVAudioEngine()
  private var writer: SpeechAudioWriter?
  private var analyzer: SpeechAnalyzer?
  private var input: AsyncStream<AnalyzerInput>.Continuation?
  private var results: Task<Void, Never>?
  private var ending: Task<[String: Any], Never>?
  private var ticker: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var segments = TranscriptSegments()
  private var recognitionError = ""
  private var uri = ""
  private var starting = true
  private var stopRequested = false
  private var stopped = false
  private var paused = false
  private var naturalFormat: AVAudioFormat?
  private var stoppedSnapshot: (seconds: Double, error: String)?
  private(set) var stoppedTranscript = ""
  private(set) var isActive = false
  /// Amplitude of the PCM this capture delivers. Owned by this capture alone, so a stale
  /// session can never move a newer recording's bars.
  let meter = PCMLevelMeter()
  var isBusy: Bool { starting || isActive || (stopRequested && !stopped) }
  init(id: String, emit: @escaping ([String: Any]) -> Void) { self.id = id; self.emit = emit }
  nonisolated static func failure(_ message: String) -> NSError { NSError(domain: "StackSpeech", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  static func capabilities() async -> [String: Any] {
    guard SpeechTranscriber.isAvailable else { return ["available": false, "reason": "On-device speech is unsupported on this iPhone. PC transcription will be used."] }
    guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { return ["available": false, "reason": "English on-device speech is unavailable. PC transcription will be used."] }
    let installed = await SpeechTranscriber.installedLocales
    guard installed.contains(where: { $0.identifier == locale.identifier }) else { return ["available": false, "reason": "The English speech model is not installed. PC transcription will be used."] }
    return ["available": true, "locale": locale.identifier, "reason": "On-device English transcription ready."]
  }
  func pause() throws {
    guard isActive, !stopRequested else { throw Self.failure("Recording is no longer active.") }
    writer?.setPaused(true)
    engine.pause()
    meter.pause(); paused = true
  }
  func resume() throws {
    guard isActive, !stopRequested else { throw Self.failure("Recording is no longer active.") }
    // A route change while paused is not reported (a paused engine is not running) and the
    // tap is still bound to the old format, so check before restarting.
    guard engine.inputNode.outputFormat(forBus: 0) == naturalFormat else {
      let message = "The microphone changed while paused. The partial answer was kept."
      Task { @MainActor in _ = await self.stop(cancelled: false, reason: message) }
      throw Self.failure(message)
    }
    do { try engine.start() }
    catch {
      Task { @MainActor in _ = await self.stop(cancelled: false, reason: "The microphone could not resume. The partial answer was kept.") }
      throw error
    }
    meter.resume(); writer?.setPaused(false); paused = false
  }
  func start(uri: String) async throws {
    defer { starting = false }
    guard (await Self.capabilities())["available"] as? Bool == true,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw Self.failure("On-device speech is unavailable. Use PC transcription.") }
    try checkStartup()
    guard AVAudioApplication.shared.recordPermission == .granted else { throw Self.failure("Microphone access is denied. Enable it for Stack in iPhone Settings.") }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].standardizedFileURL
    guard let url = URL(string: uri), url.isFileURL, url.standardizedFileURL.path.hasPrefix(base.path + "/Recordings/"),
          url.lastPathComponent == id + ".wav" else { throw Self.failure("Invalid durable recording path.") }
    self.uri = uri
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .measurement, options: [])
    try audioSession.setActive(true)
    let natural = engine.inputNode.outputFormat(forBus: 0)
    guard natural.sampleRate > 0, natural.channelCount > 0 else { throw Self.failure("Microphone input is unavailable.") }
    naturalFormat = natural
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    self.analyzer = analyzer
    let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    guard let speechFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: pcm),
          speechFormat.channelCount == 1,
          speechFormat.sampleRate > 0, speechFormat.sampleRate <= Double(Int32.max),
          speechFormat.sampleRate.rounded() == speechFormat.sampleRate else {
      throw Self.failure("A compatible on-device audio format is unavailable. Use PC transcription.")
    }
    try checkStartup()
    try await analyzer.prepareToAnalyze(in: speechFormat)
    try checkStartup()
    let stream = AsyncStream<AnalyzerInput>(bufferingPolicy: .bufferingNewest(64)) { self.input = $0 }
    results = Task { [weak self] in
      do {
        for try await result in transcriber.results {
          guard let self else { return }
          self.accept(start: CMTimeGetSeconds(result.range.start), end: CMTimeGetSeconds(CMTimeRangeGetEnd(result.range)), text: String(result.text.characters), final: result.isFinal)
        }
      } catch { self?.recognitionError = "On-device recognition stopped. Your saved audio can be transcribed on the PC." }
    }
    try await analyzer.start(inputSequence: stream)
    try checkStartup()
    guard let input else { throw Self.failure("Recording stopped before microphone startup completed.") }
    let writer = try SpeechAudioWriter(url: url, natural: natural, pcm: pcm, speechFormat: speechFormat, continuation: input, meter: meter)
    self.writer = writer
    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: natural) { @Sendable buffer, _ in writer.append(buffer) }
    engine.prepare()
    guard UIApplication.shared.applicationState == .active else { throw Self.failure("Stack moved to the background before recording started.") }
    try engine.start()
    isActive = true
    observers = [
      NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
        guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor [weak self] in _ = await self?.stop(cancelled: false, reason: "Microphone interrupted. The partial answer was kept.") }
      },
      NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in _ = await self?.stop(cancelled: false, reason: "Audio service reset. The partial answer was kept.") }
      },
      // A route or format change stops the engine itself, so no more samples arrive. A paused
      // engine is also not running, hence the flag.
      NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          guard let self, self.isActive, !self.paused, !self.engine.isRunning else { return }
          _ = await self.stop(cancelled: false, reason: "The microphone changed. The partial answer was kept.")
        }
      }
    ]
    ticker = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 200_000_000)
        guard let self, self.isActive, !Task.isCancelled else { return }
        let snapshot = writer.snapshot()
        self.emit(["id": self.id, "kind": "progress", "duration_ms": snapshot.seconds * 1000, "text": self.transcript(finalOnly: false)])
        if !snapshot.error.isEmpty || snapshot.seconds >= 300 {
          if !snapshot.error.isEmpty { self.recognitionError = snapshot.error }
          _ = await self.stop(cancelled: false, reason: snapshot.seconds >= 300 ? "Five-minute recording limit reached." : snapshot.error)
          return
        }
      }
    }
  }
  private func accept(start: Double, end: Double, text: String, final: Bool) {
    segments.update(start: start, end: end, text: text, final: final)
  }
  private func transcript(finalOnly: Bool) -> String { segments.text(finalOnly: finalOnly) }
  private func checkStartup() throws {
    guard !stopRequested else { throw Self.failure("Recording stopped before microphone startup completed.") }
  }

  // Release the microphone synchronously on navigation/account changes, before finalization awaits.
  func halt() {
    stopRequested = true
    guard stoppedSnapshot == nil else { return }
    engine.stop(); ticker?.cancel()
    meter.finish()
    if writer != nil { engine.inputNode.removeTap(onBus: 0) }
    stoppedSnapshot = writer?.close() ?? (seconds: 0, error: "")
    input?.finish()
    stoppedTranscript = transcript(finalOnly: false)
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers.removeAll()
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }

  func stop(cancelled: Bool, reason: String) async -> [String: Any] {
    if let ending { return await ending.value }
    // Set this before scheduling cleanup: startup may resume at any await.
    halt()
    let ending = Task { @MainActor () -> [String: Any] in
      let wasActive = self.isActive
      self.isActive = false
      let snapshot = self.stoppedSnapshot ?? (seconds: 0.0, error: "")
      if let analyzer = self.analyzer {
        if cancelled { await analyzer.cancelAndFinishNow(); self.results?.cancel() }
        else {
          let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            if !Task.isCancelled {
              self.recognitionError = "On-device finalization timed out. Audio is saved for PC transcription."
              await analyzer.cancelAndFinishNow(); self.results?.cancel()
            }
          }
          do { try await analyzer.finalizeAndFinishThroughEndOfInput(); await self.results?.value }
          catch { self.recognitionError = "On-device recognition could not finish. Audio is saved for PC transcription." }
          deadline.cancel()
        }
      }
      if !snapshot.error.isEmpty { self.recognitionError = snapshot.error }
      let text = self.transcript(finalOnly: true)
      let complete = !cancelled && self.recognitionError.isEmpty && !text.isEmpty
      let result: [String: Any] = ["id": self.id, "kind": "finished", "uri": self.uri,
        "duration_ms": snapshot.seconds * 1000, "text": text, "complete": complete, "cancelled": cancelled,
        "message": self.recognitionError.isEmpty ? reason : self.recognitionError]
      if wasActive { self.emit(result) }
      self.writer = nil; self.input = nil; self.analyzer = nil; self.results = nil
      self.stopped = true
      return result
    }
    self.ending = ending
    return await ending.value
  }
}

@available(iOS 26.0, *) final class SpeechAudioWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var file: FileHandle?
  private let converter: SpeechPCMConverter
  private let speechConverter: SpeechPCMConverter
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private var frames: AVAudioFramePosition = 0
  private var syncedFrames: AVAudioFramePosition = 0
  private var speechFrames: AVAudioFramePosition = 0
  private var error = ""
  private var paused = false
  private let meter: PCMLevelMeter
  init(url: URL, natural: AVAudioFormat, pcm: AVAudioFormat, speechFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation, meter: PCMLevelMeter) throws {
    self.meter = meter
    converter = try SpeechPCMConverter(from: natural, to: pcm)
    speechConverter = try SpeechPCMConverter(from: pcm, to: speechFormat)
    self.continuation = continuation
    guard FileManager.default.createFile(atPath: url.path, contents: WAVHeader.data(bytes: 0), attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw StackSpeechSession.failure("Could not create the durable audio file.") }
    file = try FileHandle(forUpdating: url)
    try file?.seek(toOffset: 44)
  }
  func append(_ source: AVAudioPCMBuffer) {
    lock.lock(); defer { lock.unlock() }
    guard file != nil, !paused, frames < 16000 * 300 else { return }
    // Measured from the tapped samples before conversion, under the same lock as the file.
    meter.ingest(source)
    let output: AVAudioPCMBuffer
    do { guard let converted = try converter.convert(source) else { return }; output = converted }
    catch { self.error = "Audio conversion failed. Partial audio was kept."; return }
    appendPCM(output)
  }
  private func appendPCM(_ output: AVAudioPCMBuffer) {
    guard let file, frames < 16000 * 300 else { return }
    output.frameLength = min(output.frameLength, AVAudioFrameCount(16000 * 300 - frames))
    guard output.frameLength > 0 else { return }
    guard let samples = output.int16ChannelData?[0] else { error = "Microphone samples were unavailable."; return }
    // iPhone PCM is little endian, matching the durable WAV header.
    let audio = Data(bytes: samples, count: Int(output.frameLength) * 2)
    do {
      try file.write(contentsOf: audio)
      // Update the header for every committed buffer so reopening after suspension
      // can recover all written frames without relying on a later Stop callback.
      let count = frames + AVAudioFramePosition(output.frameLength)
      try file.seek(toOffset: 0); try file.write(contentsOf: WAVHeader.data(bytes: UInt32(count * 2)))
      try file.seek(toOffset: UInt64(44 + count * 2))
      if count - syncedFrames >= 16000 { try file.synchronize(); syncedFrames = count }
    }
    catch { self.error = "Saving audio failed. Keep this recording and check available phone storage."; return }
    frames += AVAudioFramePosition(output.frameLength)
    do {
      guard let speechBuffer = try speechConverter.convert(output) else { return }
      submit(speechBuffer)
    } catch { self.error = "Recognition audio conversion failed. Audio is saved for PC transcription." }
  }
  private func submit(_ buffer: AVAudioPCMBuffer) {
    let start = CMTime(value: speechFrames, timescale: CMTimeScale(speechConverter.format.sampleRate))
    speechFrames += AVAudioFramePosition(buffer.frameLength)
    if case .dropped = continuation.yield(AnalyzerInput(buffer: buffer, bufferStartTime: start)) {
      error = "Live recognition could not keep up. Audio is saved for PC transcription."
    }
  }
  func snapshot() -> (seconds: Double, error: String) {
    lock.lock(); defer { lock.unlock() }; return (Double(frames) / 16000, error)
  }
  func setPaused(_ value: Bool) {
    lock.lock(); defer { lock.unlock() }; paused = value
  }
  func close() -> (seconds: Double, error: String) {
    lock.lock(); defer { lock.unlock() }
    if file != nil {
      do {
        for buffer in try converter.finish() { appendPCM(buffer) }
        for buffer in try speechConverter.finish() { submit(buffer) }
      } catch { self.error = "Audio conversion could not finish. Your partial audio was kept." }
    }
    do { try file?.synchronize(); try file?.close() } catch { self.error = "Audio could not be fully flushed. Keep the partial recording and check phone storage." }
    file = nil; return (Double(frames) / 16000, error)
  }
}
#endif

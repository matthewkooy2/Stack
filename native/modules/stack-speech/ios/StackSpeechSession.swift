import AVFoundation
import Speech
import UIKit

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
  private(set) var isActive = false
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
    engine.pause()
  }
  func resume() throws {
    guard isActive, !stopRequested else { throw Self.failure("Recording is no longer active.") }
    try engine.start()
  }
  func start(uri: String) async throws {
    defer { starting = false }
    guard (await Self.capabilities())["available"] as? Bool == true,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else { throw Self.failure("On-device speech is unavailable. Use PC transcription.") }
    try checkStartup()
    guard AVAudioApplication.shared.recordPermission == .granted else { throw Self.failure("Microphone access is denied. Enable it for Stack in iPhone Settings.") }
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].standardizedFileURL
    guard let url = URL(string: uri), url.isFileURL, url.standardizedFileURL.path.hasPrefix(documents.path + "/stack-recordings/"),
          url.lastPathComponent == id + ".wav" else { throw Self.failure("Invalid durable recording path.") }
    self.uri = uri
    let audioSession = AVAudioSession.sharedInstance()
    try audioSession.setCategory(.record, mode: .measurement, options: [])
    try audioSession.setActive(true)
    let natural = engine.inputNode.outputFormat(forBus: 0)
    guard natural.sampleRate > 0, natural.channelCount > 0 else { throw Self.failure("Microphone input is unavailable.") }
    let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .whileInUse))
    self.analyzer = analyzer
    let pcm = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)!
    guard let speechFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: pcm),
          speechFormat.commonFormat == .pcmFormatInt16, speechFormat.channelCount == 1,
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
    let writer = try SpeechAudioWriter(url: url, natural: natural, pcm: pcm, speechFormat: speechFormat, continuation: input)
    self.writer = writer
    engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: natural) { @Sendable buffer, _ in writer.append(buffer) }
    engine.prepare()
    guard UIApplication.shared.applicationState == .active else { throw Self.failure("Stack moved to the background before recording started.") }
    try engine.start()
    isActive = true
    observers = [
      NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
        guard notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue else { return }
        Task { @MainActor in _ = await self?.stop(cancelled: false, reason: "Microphone interrupted. The partial answer was kept.") }
      },
      NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in _ = await self?.stop(cancelled: false, reason: "Recording stopped when Stack entered the background. Audio was kept.") }
      },
      NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in _ = await self?.stop(cancelled: false, reason: "Audio service reset. The partial answer was kept.") }
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

  func stop(cancelled: Bool, reason: String) async -> [String: Any] {
    if let ending { return await ending.value }
    // Set this before scheduling cleanup: startup may resume at any await.
    stopRequested = true
    let ending = Task { @MainActor () -> [String: Any] in
      let wasActive = self.isActive
      self.isActive = false; self.ticker?.cancel()
      self.engine.stop()
      if self.writer != nil { self.engine.inputNode.removeTap(onBus: 0) }
      let snapshot = self.writer?.close() ?? (seconds: 0.0, error: "")
      self.input?.finish()
      for observer in self.observers { NotificationCenter.default.removeObserver(observer) }
      self.observers.removeAll()
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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

@available(iOS 26.0, *) private final class SpeechAudioWriter: @unchecked Sendable {
  private let lock = NSLock()
  private var file: FileHandle?
  private let converter: SpeechPCMConverter
  private let speechConverter: SpeechPCMConverter
  private let continuation: AsyncStream<AnalyzerInput>.Continuation
  private var frames: AVAudioFramePosition = 0
  private var syncedFrames: AVAudioFramePosition = 0
  private var speechFrames: AVAudioFramePosition = 0
  private var error = ""
  init(url: URL, natural: AVAudioFormat, pcm: AVAudioFormat, speechFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) throws {
    converter = try SpeechPCMConverter(from: natural, to: pcm)
    speechConverter = try SpeechPCMConverter(from: pcm, to: speechFormat)
    self.continuation = continuation
    guard FileManager.default.createFile(atPath: url.path, contents: Self.header(bytes: 0), attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]) else { throw StackSpeechSession.failure("Could not create the durable audio file.") }
    file = try FileHandle(forUpdating: url)
    try file?.seek(toOffset: 44)
  }
  private static func header(bytes: UInt32) -> Data {
    var data = Data("RIFF".utf8)
    func integer<T: FixedWidthInteger>(_ value: T) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
    integer(bytes + 36); data.append(Data("WAVEfmt ".utf8)); integer(UInt32(16)); integer(UInt16(1)); integer(UInt16(1))
    integer(UInt32(16000)); integer(UInt32(32000)); integer(UInt16(2)); integer(UInt16(16)); data.append(Data("data".utf8)); integer(bytes)
    return data
  }
  func append(_ source: AVAudioPCMBuffer) {
    lock.lock(); defer { lock.unlock() }
    guard file != nil, frames < 16000 * 300 else { return }
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
      try file.seek(toOffset: 0); try file.write(contentsOf: Self.header(bytes: UInt32(count * 2)))
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

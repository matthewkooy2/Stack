import AVFoundation
import Speech
import XCTest
@testable import Stack

final class MicrophonePCMTests: XCTestCase {
    private func buffer(_ kind: AVAudioCommonFormat = .pcmFormatFloat32, interleaved: Bool = false,
                        channels: AVAudioChannelCount = 2, frames: AVAudioFrameCount = 1600,
                        amplitude: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format: AVAudioFormat
        if channels > 2 {
            // The channel-count convenience initializer supports mono/stereo only.
            // Use an explicit discrete layout to exercise every later channel.
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
            format = try XCTUnwrap(AVAudioFormat(commonFormat: kind, sampleRate: 16000,
                                                interleaved: interleaved, channelLayout: layout))
        } else {
            format = try XCTUnwrap(AVAudioFormat(commonFormat: kind, sampleRate: 16000,
                                                channels: channels, interleaved: interleaved))
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(frames, 1)))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                // Only the last channel is audible: detects missed channels and wrong strides.
                let value = channel == Int(channels) - 1 ? amplitude : 0
                if kind == .pcmFormatFloat32 { buffer.floatChannelData![channel][frame * buffer.stride] = value }
                else { buffer.int16ChannelData![channel][frame * buffer.stride] = Int16(value * 32767) }
            }
        }
        return buffer
    }

    func testFloatAndInt16PlanarAndInterleavedAllChannels() throws {
        for kind in [AVAudioCommonFormat.pcmFormatFloat32, .pcmFormatInt16] {
            for interleaved in [false, true] {
                for channels in [AVAudioChannelCount(1), 2, 4] {
                    let measured = try XCTUnwrap(PCMAmplitude.measure(buffer(kind, interleaved: interleaved, channels: channels)))
                    XCTAssertEqual(measured.rms, 0.25, accuracy: 0.0001)
                    XCTAssertEqual(measured.peak, 0.25, accuracy: 0.0001)
                    XCTAssertEqual(measured.frames, 1600)
                    XCTAssertEqual(measured.clippedSamples, 0)
                }
            }
        }
    }

    func testSilenceInvalidFloatsAndNegativeFullScale() throws {
        let silence = try XCTUnwrap(PCMAmplitude.measure(buffer(amplitude: 0)))
        XCTAssertEqual(silence.rms, 0)
        let values: [Float] = [.nan, .infinity, -.infinity, 0]
        XCTAssertEqual(values.withUnsafeBufferPointer { PCMAmplitude.measure(floats: $0) }.rms, 0)
        let fullScale: [Int16] = [.min, .max]
        let clipping = fullScale.withUnsafeBufferPointer { PCMAmplitude.measure(int16: $0) }
        XCTAssertEqual(clipping.peak, 1)
        XCTAssertEqual(clipping.clippedSamples, 2)
        XCTAssertNil(PCMAmplitude.measure(try buffer(frames: 0)))
    }

    func testAmplitudeAttackReleaseQuietSilenceAndClipHold() {
        let loud = PCMMeasurement(rms: 0.3, peak: 0.5, clippedSamples: 0, frames: 1600)
        var tracker = PCMLevelTracker()
        tracker.ingest(loud, duration: 0.04)
        let attack = tracker.level
        XCTAssertGreaterThan(attack, 0.5)
        XCTAssertLessThan(attack, 1)
        tracker.ingest(.empty, duration: 0.04)
        XCTAssertGreaterThan(tracker.level, attack * 0.8)
        XCTAssertLessThan(tracker.level, attack)
        for _ in 0..<40 { tracker.ingest(.empty, duration: 0.1) }
        XCTAssertEqual(tracker.quality, .silent)
        XCTAssertEqual(tracker.level, 0)
        let quiet = PCMMeasurement(rms: 0.005, peak: 0.01, clippedSamples: 0, frames: 1600)
        for _ in 0..<41 { tracker.ingest(quiet, duration: 0.1) }
        XCTAssertEqual(tracker.quality, .quiet)
        tracker.ingest(PCMMeasurement(rms: 0.5, peak: 1, clippedSamples: 2, frames: 1600), duration: 0.1)
        XCTAssertEqual(tracker.quality, .clipping)
        tracker.ingest(loud, duration: 1.3)
        XCTAssertEqual(tracker.quality, .good)
        XCTAssertEqual(tracker.bars.count, 6)
        XCTAssertEqual(tracker.bars, Array(tracker.bars.reversed()))
        XCTAssertTrue(tracker.bars.allSatisfy { (0...1).contains($0) })
        XCTAssertLessThan(PCMLevelTracker.displayLevel(rms: 0.01), PCMLevelTracker.displayLevel(rms: 0.1))
    }

    func testPauseResetStallAndTerminalStaleBuffers() {
        let meter = PCMLevelMeter()
        let loud = PCMMeasurement(rms: 0.3, peak: 0.5, clippedSamples: 0, frames: 1600)
        meter.ingest(loud, duration: 0.1, uptime: 1)
        XCTAssertGreaterThan(meter.snapshot(uptime: 1).level, 0)
        XCTAssertEqual(meter.snapshot(uptime: 4).level, 0)
        XCTAssertEqual(meter.snapshot(uptime: 4).quality, .good) // Stall is not delivered silence.
        meter.ingest(.empty, duration: 0.1, uptime: 4.1)
        XCTAssertEqual(meter.snapshot(uptime: 4.1).level, 0) // Old loud history must not reappear.
        XCTAssertTrue(meter.snapshot(uptime: 4.1).bars.allSatisfy { $0 == 0 })
        meter.pause()
        meter.ingest(loud, duration: 0.1, uptime: 5)
        XCTAssertEqual(meter.snapshot(uptime: 5), .idle)
        meter.resume()
        meter.ingest(loud, duration: 0.1, uptime: 6)
        XCTAssertGreaterThan(meter.snapshot(uptime: 6).level, 0)
        meter.reset()
        XCTAssertEqual(meter.snapshot(uptime: 6), .idle)
        meter.finish(); meter.resume(); meter.reset()
        meter.ingest(loud, duration: 0.1, uptime: 7)
        XCTAssertEqual(meter.snapshot(uptime: 7), .idle)
    }

    func testSyntheticWriterPauseCloseAndWAVRecovery() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try buffer(.pcmFormatInt16, channels: 1)
        let writer = try PCMFileWriter(url: url, natural: source.format, meter: PCMLevelMeter())
        writer.append(source)
        XCTAssertEqual(writer.snapshot().seconds, 0.1, accuracy: 0.00001)
        let partial = try Data(contentsOf: url)
        XCTAssertEqual(partial.prefix(44), WAVHeader.data(bytes: 3200))
        XCTAssertEqual(partial.count, 3244)
        writer.setPaused(true); writer.append(source)
        XCTAssertEqual(writer.snapshot().seconds, 0.1, accuracy: 0.00001)
        writer.setPaused(false); writer.append(source)
        XCTAssertEqual(writer.close().seconds, 0.2, accuracy: 0.00001)
        writer.append(source)
        XCTAssertEqual(writer.close().seconds, 0.2, accuracy: 0.00001)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 3200)
        XCTAssertEqual(file.fileFormat.sampleRate, 16000)
        XCTAssertEqual(file.fileFormat.channelCount, 1)
    }

    func testWriterRejectsChangedInputFormatAndRetainsPriorAudio() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try buffer(.pcmFormatInt16, channels: 1)
        let writer = try PCMFileWriter(url: url, natural: source.format, meter: PCMLevelMeter())
        writer.append(source)
        writer.append(try buffer(.pcmFormatFloat32))
        XCTAssertFalse(writer.snapshot().error.isEmpty)
        XCTAssertEqual(writer.close().seconds, 0.1, accuracy: 0.00001)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 1600)
    }

    func testWAVWriterClampsAtFiveMinutes() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try buffer(.pcmFormatInt16, channels: 1, frames: 16000 * 301, amplitude: 0)
        let writer = try PCMFileWriter(url: url, natural: source.format, meter: PCMLevelMeter())
        writer.append(source)
        XCTAssertEqual(writer.close().seconds, RecordingStore.maximumSeconds)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16000 * 300)
        XCTAssertEqual(try Data(contentsOf: url).prefix(44), WAVHeader.data(bytes: 16000 * 300 * 2))
    }

    #if compiler(>=6.2)
    func testSpeechWriterUsesSyntheticPCMWhilePauseAndCloseRetainAudio() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try buffer(.pcmFormatInt16, channels: 1)
        // iOS 27 traps an AnalyzerInput whose samples are not 16-bit signed integers. The app submits the format
        // SpeechAnalyzer reports; Float32 conversion stays covered without Speech in SpeechRestorationTests.
        let speechFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                                      channels: 1, interleaved: false))
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let meter = PCMLevelMeter()
        let writer = try SpeechAudioWriter(url: url, natural: source.format, pcm: source.format,
                                          speechFormat: speechFormat, continuation: continuation, meter: meter)
        writer.append(source)
        XCTAssertGreaterThan(meter.snapshot().level, 0)
        writer.setPaused(true); writer.append(source)
        XCTAssertEqual(writer.snapshot().seconds, 0.1, accuracy: 0.00001)
        writer.setPaused(false); writer.append(source)
        XCTAssertEqual(writer.close().seconds, 0.2, accuracy: 0.00001)
        writer.append(source)
        XCTAssertEqual(writer.close().seconds, 0.2, accuracy: 0.00001)
        continuation.finish()
        var submitted = 0
        for await _ in stream { submitted += 1 }
        XCTAssertGreaterThan(submitted, 0)
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 3200)
        XCTAssertEqual(try Data(contentsOf: url).prefix(44), WAVHeader.data(bytes: 6400))
    }
    #endif
}

@MainActor
final class PhoneTranscriptTests: XCTestCase {
    private func recordingURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data(repeating: 0, count: 44).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
        }
        return url
    }

    func testPreviewBecomesFinalWithoutLosingTheRecordingOrEdits() throws {
        let url = try recordingURL()
        try RecordingStore.saveTranscript(
            PhoneTranscript(original: "live words", text: "live words", revision: 1, isFinal: false), at: url)
        XCTAssertEqual(RecordingStore.transcript(at: url)?.text, "live words")

        try RecordingStore.finalizeTranscript("complete words", at: url)
        let untouched = try XCTUnwrap(RecordingStore.transcript(at: url))
        XCTAssertEqual(untouched.original, "complete words")
        XCTAssertEqual(untouched.text, "complete words")
        XCTAssertTrue(untouched.isFinal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let editedURL = try recordingURL()
        try RecordingStore.saveTranscript(
            PhoneTranscript(original: "live words", text: "live words", revision: 1, isFinal: false), at: editedURL)
        try RecordingStore.editTranscript("my correction", at: editedURL)
        try RecordingStore.finalizeTranscript("complete words", at: editedURL)
        let edited = try XCTUnwrap(RecordingStore.transcript(at: editedURL))
        XCTAssertEqual(edited.original, "complete words")
        XCTAssertEqual(edited.text, "my correction")
        XCTAssertEqual(edited.revision, 3)
        XCTAssertTrue(edited.isFinal)
    }

    func testServerTranscriptPromotesAnUneditedPreviewAfterLocalTimeout() throws {
        let url = try recordingURL()
        try RecordingStore.saveTranscript(
            PhoneTranscript(original: "live words", text: "live words", revision: 1, isFinal: false), at: url)

        try RecordingStore.markSynced("server-1", text: "server words", at: url)
        let transcript = try XCTUnwrap(RecordingStore.transcript(at: url))
        XCTAssertEqual(transcript.original, "server words")
        XCTAssertEqual(transcript.text, "server words")
        XCTAssertEqual(transcript.serverID, "server-1")
        XCTAssertTrue(transcript.isFinal)

        let editedURL = try recordingURL()
        try RecordingStore.saveTranscript(
            PhoneTranscript(original: "live words", text: "live words", revision: 1, isFinal: false), at: editedURL)
        try RecordingStore.editTranscript("my correction", at: editedURL)
        try RecordingStore.markSynced("server-2", text: "server words", at: editedURL)
        let edited = try XCTUnwrap(RecordingStore.transcript(at: editedURL))
        XCTAssertEqual(edited.text, "my correction")
        XCTAssertEqual(edited.original, "live words")
        XCTAssertFalse(edited.isFinal)
        XCTAssertEqual(edited.serverID, "server-2")
    }

    func testOldTranscriptSidecarsDecodeAsFinal() throws {
        let legacy = Data(#"{"original":"saved","text":"saved","revision":1,"serverID":null,"syncedText":null}"#.utf8)
        let transcript = try JSONDecoder().decode(PhoneTranscript.self, from: legacy)
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(try JSONDecoder().decode(PhoneTranscript.self, from: JSONEncoder().encode(transcript)), transcript)
    }
}

@MainActor
final class MicrophoneRecorderTests: XCTestCase {
    private final class SyntheticCapture: AudioPCMCapture {
        let meter = PCMLevelMeter()
        var onProgress: ((Double) -> Void)?
        var onEnded: ((String) -> Void)?
        var seconds = 0.0
        var paused = false
        var stopped = false
        var failStartup = false
        func start(url: URL) throws {
            if failStartup { throw APIError(message: "Synthetic startup failure") }
            try (WAVHeader.data(bytes: 64) + Data(repeating: 0, count: 64)).write(to: url)
        }
        func deliver() {
            guard !stopped, !paused else { return }
            seconds += 0.1
            meter.ingest(PCMMeasurement(rms: 0.3, peak: 0.5, clippedSamples: 0, frames: 1600), duration: 0.1)
            onProgress?(seconds)
        }
        func pause() throws { paused = true; meter.pause() }
        func resume() throws { paused = false; meter.resume() }
        func stop() -> (seconds: Double, error: String) { stopped = true; meter.finish(); return (seconds, "") }
    }

    private func cleanup(_ url: URL) {
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    }

    func testVisibilityPreservesCaptureIdentityElapsedAndSavedTranscript() async throws {
        let capture = SyntheticCapture()
        let recorder = AudioRecorder(requestPermission: { true }, makeFallback: { capture }, allowOnDevice: false)
        let start = try await recorder.start(owner: "synthetic-mic-test")
        cleanup(start.url)
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Synthetic original", text: "Reviewed", revision: 2), at: start.url)
        capture.deliver()
        recorder.setLiveTranscriptVisible(true); recorder.setLiveTranscriptVisible(false)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(recorder.clientID, start.clientID)
        XCTAssertEqual(recorder.elapsed, 0.1)
        recorder.pause(); capture.deliver()
        XCTAssertEqual(recorder.elapsed, 0.1)
        XCTAssertTrue(recorder.isPaused)
        try recorder.resume(); capture.deliver()
        XCTAssertEqual(recorder.elapsed, 0.2)
        let saved = try XCTUnwrap(recorder.stop())
        await saved.finalized.value
        XCTAssertEqual(saved.url, start.url)
        XCTAssertEqual(RecordingStore.transcript(at: start.url)?.original, "Synthetic original")
        XCTAssertEqual(RecordingStore.transcript(at: start.url)?.text, "Reviewed")
        XCTAssertNil(recorder.stop())
        try? FileManager.default.removeItem(at: start.url.appendingPathExtension("json"))
    }

    func testPermissionRecoveryStartupRetryAndInterruptionDropsLateProgress() async throws {
        var granted = false
        var capture = SyntheticCapture()
        let recorder = AudioRecorder(requestPermission: { granted }, makeFallback: { capture }, allowOnDevice: false)
        do { _ = try await recorder.start(owner: "synthetic-mic-test"); XCTFail("Permission must fail") } catch { }
        XCTAssertTrue(recorder.permissionDenied)
        XCTAssertFalse(recorder.isRecording)
        granted = true; capture.failStartup = true
        do { _ = try await recorder.start(owner: "synthetic-mic-test"); XCTFail("Startup must fail") } catch { }
        capture = SyntheticCapture()
        let first = try await recorder.start(owner: "synthetic-mic-test")
        cleanup(first.url)
        XCTAssertFalse(recorder.permissionDenied)
        var saved: CapturedRecording?
        recorder.onAutoStop = { saved = $0 }
        capture.deliver()
        let old = capture
        old.onEnded?("Synthetic interruption: partial audio kept.")
        XCTAssertNotNil(saved)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertTrue(recorder.stopNotice.contains("interruption"))
        capture = SyntheticCapture()
        let second = try await recorder.start(owner: "synthetic-mic-test")
        cleanup(second.url)
        XCTAssertNotEqual(first.clientID, second.clientID)
        old.onProgress?(999); old.onEnded?("Late event")
        XCTAssertEqual(recorder.elapsed, 0)
        XCTAssertTrue(recorder.stopNotice.isEmpty)
        XCTAssertTrue(recorder.isRecording)
        _ = recorder.stop()
    }

    func testStopDuringPermissionWaitPreventsStartup() async throws {
        var permission: CheckedContinuation<Bool, Never>?
        let capture = SyntheticCapture()
        let recorder = AudioRecorder(requestPermission: { await withCheckedContinuation { permission = $0 } },
                                     makeFallback: { capture }, allowOnDevice: false)
        let pending = Task { try await recorder.start(owner: "synthetic-mic-test") }
        while permission == nil { await Task.yield() }
        do { _ = try await recorder.start(owner: "synthetic-mic-test"); XCTFail("Concurrent start must fail") } catch { }
        XCTAssertNil(recorder.stop())
        permission?.resume(returning: true)
        do { _ = try await pending.value; XCTFail("Stopped startup must cancel") } catch is CancellationError { }
        XCTAssertFalse(recorder.isRecording)
        XCTAssertNil(recorder.fileURL)
    }

    func testAccessibleQualityAndTimerDescriptions() {
        XCTAssertEqual(recordingSurfaceClock(24), "00:24")
        XCTAssertEqual(recordingSurfaceClock(-1), "00:00")
        XCTAssertEqual(RecordingLevelBars.spoken(.idle, running: false), "Not recording")
        XCTAssertTrue(RecordingLevelBars.caption(.quiet, running: true).contains("speak up"))
        XCTAssertEqual(RecordingLevelBars.barHeight(level: 0, minHeight: 14, maxHeight: 104), 14)
        XCTAssertEqual(RecordingLevelBars.barHeight(level: 1, minHeight: 14, maxHeight: 104), 104)
        XCTAssertEqual(RecordingLevelBars.barHeight(level: 7, minHeight: 14, maxHeight: 104), 104)
        XCTAssertEqual(RecordingLevelBars.barHeight(level: .nan, minHeight: 14, maxHeight: 104), 14)
        var smoother = LevelBarSmoother()
        let rising = smoother.advance(toward: [1, 0.5, 0, 0, 0.5, 1], elapsed: 1.0 / 60.0)
        XCTAssertTrue(rising[0] > 0 && rising[0] < 1 && rising[2] == 0)
        XCTAssertEqual(smoother.advance(toward: [1, 0.5, 0, 0, 0.5, 1], elapsed: 1).first, 1)
        XCTAssertEqual(smoother.advance(toward: [1, 1, 1, 1, 1, 1], elapsed: 0).first, 1)
        XCTAssertEqual(smoother.advance(toward: [0.3, .nan, 9, 0, 0, 0], elapsed: 0, smoothing: false), [0.3, 0, 1, 0, 0, 0])
        XCTAssertEqual(RecordingLevelBars.spoken(PCMLevelSnapshot(bars: [], level: 1, quality: .clipping), running: true), "Too loud")
    }
}

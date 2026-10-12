#if DEBUG
import AVFoundation
import SwiftUI

/// Offline renderer for the production surface. Generated PCM feeds the real writer/meter;
/// fictional transcript sidecars test visibility and retention. No engine, permissions,
/// recognizer, assets, sign-in or API call. Omitted from Release builds.
@MainActor
struct MicrophoneUITestScene: View {
    private static let owner = "synthetic-microphone-ui-fixture"
    @State private var feed: MicrophoneFixtureFeed
    @State private var recorder: AudioRecorder
    @State private var savedURLs: [URL] = []
    @State private var error = ""

    init() {
        let feed = MicrophoneFixtureFeed()
        _feed = State(initialValue: feed)
        _recorder = State(initialValue: AudioRecorder(requestPermission: { true },
                          makeFallback: { feed.makeCapture() }, allowOnDevice: false))
    }

    private var arguments: [String] { ProcessInfo.processInfo.arguments }
    private var supported: Bool { !arguments.contains("--microphone-no-live") }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.stack) {
                    RecordingSurface(recorder: recorder, questionNumber: 1, questionCount: 5,
                        prompt: "Tell me about a time you solved a difficult problem.",
                        onStop: { _ = recorder.stop() }, onTogglePause: {
                            do { if recorder.isPaused { try recorder.resume() } else { recorder.pause() } }
                            catch { self.error = error.localizedDescription }
                        })
                    Text("Offline synthetic audio fixture").font(Typeface.caption).foregroundStyle(Palette.muted)
                    if recorder.isRecording {
                        Button("Send synthetic silence") { feed.capture?.amplitude = 0 }
                        Button("Send synthetic sound") { feed.capture?.amplitude = 0.2 }
                    } else if let url = recorder.fileURL, let phone = RecordingStore.transcript(at: url) {
                        Text("Saved original: \(phone.original)")
                        Text("Saved answer: \(phone.text)")
                        Button("Retry synthetic recording") { Task { await start() } }
                    }
                    MessageLine(text: error).fadeSwitch(!error.isEmpty)
                }
                .padding(Spacing.page)
                .frame(minHeight: proxy.size.height, alignment: .topLeading)
            }
            .accessibilityIdentifier("microphone-fixture-scroll")
            .background(Palette.page.ignoresSafeArea())
        }
        .environment(\.dynamicTypeSize, arguments.contains("--microphone-large-type") ? .accessibility5 : .large)
        .environment(\.accessibilityReduceMotion, arguments.contains("--microphone-reduce-motion"))
        .task { await start() }
        .onDisappear {
            _ = recorder.stop()
            for url in savedURLs {
                try? RecordingStore.delete(owner: Self.owner, clientID: url.deletingPathExtension().lastPathComponent)
            }
        }
    }

    private func start() async {
        do {
            let saved = try await recorder.start(owner: Self.owner)
            savedURLs.append(saved.url)
            if supported { recorder.showSyntheticTranscriptForUITest("Synthetic live transcript") }
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor
private final class MicrophoneFixtureFeed {
    var capture: MicrophoneFixtureCapture?
    func makeCapture() -> any AudioPCMCapture {
        let value = MicrophoneFixtureCapture()
        capture = value
        return value
    }
}

@MainActor
private final class MicrophoneFixtureCapture: AudioPCMCapture {
    let meter = PCMLevelMeter()
    var onProgress: ((Double) -> Void)?
    var onEnded: ((String) -> Void)?
    var amplitude: Float = 0.2
    private var writer: PCMFileWriter?
    private var ticker: Task<Void, Never>?
    private var paused = false
    private var result: (seconds: Double, error: String)?

    func start(url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let writer = try PCMFileWriter(url: url, natural: format, meter: meter)
        self.writer = writer
        try RecordingStore.saveTranscript(PhoneTranscript(original: "Synthetic recognized answer",
            text: "Reviewed synthetic answer", revision: 2), at: url)
        ticker = Task { @MainActor [weak self] in
            var phase = 0.0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard let self, self.result == nil, !Task.isCancelled else { return }
                if self.paused { continue }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 800) else { return }
                buffer.frameLength = 800
                for index in 0..<800 {
                    buffer.floatChannelData![0][index] = self.amplitude * Float(sin(phase))
                    phase += 2 * .pi * 220 / 16000
                }
                writer.append(buffer)
                self.onProgress?(writer.snapshot().seconds)
            }
        }
    }

    func pause() throws { paused = true; writer?.setPaused(true); meter.pause() }
    func resume() throws { writer?.setPaused(false); meter.resume(); paused = false }
    func stop() -> (seconds: Double, error: String) {
        if let result { return result }
        ticker?.cancel(); ticker = nil; meter.finish()
        let value = writer?.close() ?? (seconds: 0, error: "")
        writer = nil; result = value
        return value
    }
}
#endif

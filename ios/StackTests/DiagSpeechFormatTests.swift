import AVFoundation
import Speech
import XCTest
@testable import Stack

// Diagnostic branch only. Never merged.
#if compiler(>=6.2)
final class DiagSpeechFormatTests: XCTestCase {
    private func report(_ name: String, _ text: String) {
        print("DIAG-SPEECH \(name): \(text)")
        let attachment = XCTAttachment(string: text)
        attachment.name = "diag-speech-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDiagReportAnalyzerFormat() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        let pcm = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false))
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: pcm)
        report("best-format", "considering=\(pcm); best=\(String(describing: best)); "
            + "commonFormat=\(String(describing: best?.commonFormat.rawValue)); equalsPCM=\(best == pcm)")
    }

    func testDiagInt16AnalyzerInput() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        try construct(.pcmFormatInt16)
    }

    func testDiagOriginalFloat32AnalyzerInput() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("SpeechAnalyzer requires iOS 26") }
        try construct(.pcmFormatFloat32)
    }

    @available(iOS 26.0, *)
    private func construct(_ kind: AVAudioCommonFormat) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: kind, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        print("DIAG-SPEECH input-\(kind.rawValue): before AnalyzerInput")
        _ = AnalyzerInput(buffer: buffer, bufferStartTime: .zero)
        report("input-\(kind.rawValue)", "constructed AnalyzerInput for \(format)")
    }
}
#endif

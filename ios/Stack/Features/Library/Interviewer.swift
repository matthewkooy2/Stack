import AVFoundation
import Observation
import SwiftUI

/// What presents a question. v1 is the on-device voice below; a pre-rendered talking-head clip
/// per question (for example Kokoro or Piper speech lip-synced with LivePortrait or MuseTalk) can
/// conform later without changing the library flow.
@MainActor
protocol InterviewerClip: AnyObject {
    var isSpeaking: Bool { get }
    func ask(_ question: PracticeQuestion, onFinish: @escaping @MainActor () -> Void)
    func stop()
}

/// Reads each question aloud with the system voice. Free, offline and private: nothing leaves the phone.
@MainActor
@Observable
final class InterviewerVoice: NSObject, InterviewerClip, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var onFinish: (@MainActor () -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func ask(_ question: PracticeQuestion, onFinish: @escaping @MainActor () -> Void) {
        stop()
        self.onFinish = onFinish
        // The recorder normally owns the route; set a loudspeaker route only if nothing has yet.
        let audio = AVAudioSession.sharedInstance()
        if audio.category != .playAndRecord {
            try? audio.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetooth])
        }
        try? audio.setActive(true)
        let utterance = AVSpeechUtterance(string: question.prompt)
        // Questions are written in English; prefer the person's English accent when they have one.
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        utterance.voice = AVSpeechSynthesisVoice(language: current.hasPrefix("en") ? current : "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.95
        utterance.preUtteranceDelay = 0.3
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stop() {
        onFinish = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }

    private func finished() {
        isSpeaking = false
        let callback = onFinish
        onFinish = nil
        callback?()
    }
}

/// The interviewer's face: a calm avatar that pulses while speaking and breathes while listening.
struct InterviewerCard: View {
    let speaking: Bool
    let listening: Bool

    var body: some View {
        VStack(spacing: 14) {
            Halo(active: speaking, size: 108) {
                ZStack {
                    Circle().fill(Palette.dark).frame(width: 84, height: 84)
                    Image(systemName: speaking ? "waveform" : "person.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Palette.onDark)
                        .symbolEffect(.variableColor.iterative, isActive: speaking)
                }
            }
            Text(speaking ? "Interviewer is asking…" : listening ? "Listening" : "Your interviewer")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
                .breathe(listening)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(speaking ? "Interviewer is asking the question" : "Interviewer")
    }
}

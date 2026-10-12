import SwiftUI
import UIKit

// The recording surface: question and progress above, six measured level bars, status and
// timer, a live-transcript visibility button, and one wide Stop button. Styling comes from
// Palette, Typeface and Spacing; the bars are driven only by PCMLevelMeter.

@MainActor
enum AppSettings {
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// Six rounded bars whose heights are the measured microphone amplitude. There is no
/// decorative loop: while nothing is recording the schedule is paused and the bars rest at
/// their minimum. Reduce Motion samples the meter less often and applies no animation.
@MainActor
struct RecordingLevelBars: View {
    let meter: PCMLevelMeter?
    /// Recording and not paused.
    let running: Bool
    var maxHeight: CGFloat = 104
    var showsQuality = true

    @Environment(\.stackReduceMotion) private var reduceMotion

    private let width: CGFloat = 18
    private let gap: CGFloat = 12
    private var minHeight: CGFloat { max(14, maxHeight * 0.14) }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 30.0, paused: !running)) { _ in
            let snapshot = running ? (meter?.snapshot() ?? .idle) : .idle
            VStack(spacing: 14) {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<PCMLevelTracker.barCount, id: \.self) { index in
                        let value = CGFloat(min(max(snapshot.bars[index], 0), 1))
                        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                            .fill(snapshot.quality == .clipping ? Palette.danger : Palette.ink)
                            .frame(width: width, height: minHeight + (maxHeight - minHeight) * value)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: maxHeight)
                if showsQuality {
                    Text(Self.caption(snapshot.quality, running: running))
                        .font(Typeface.caption)
                        .foregroundStyle(snapshot.quality == .clipping ? Palette.danger : Palette.muted)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 20)
                }
            }
            .onChange(of: snapshot.quality) { _, quality in
                // Only states that need action are announced; each needs seconds of audio to trigger.
                guard running, [.quiet, .silent, .clipping].contains(quality) else { return }
                AccessibilityNotification.Announcement(Self.caption(quality, running: true)).post()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Microphone level")
            .accessibilityValue(Self.spoken(snapshot, running: running))
        }
    }

    static func caption(_ quality: PCMInputQuality, running: Bool) -> String {
        guard running else { return "" }
        switch quality {
        case .waiting, .good: return "Listening"
        case .quiet: return "Input is quiet. Move closer or speak up."
        case .silent: return "No sound detected. Check that the microphone is not covered."
        case .clipping: return "Too loud. Move back a little."
        }
    }

    static func spoken(_ snapshot: PCMLevelSnapshot, running: Bool) -> String {
        guard running else { return "Not recording" }
        switch snapshot.quality {
        case .quiet: return "Quiet"
        case .silent: return "No sound"
        case .clipping: return "Too loud"
        case .waiting, .good:
            switch snapshot.level {
            case ..<0.1: return "Silent"
            case ..<0.4: return "Low"
            case ..<0.75: return "Medium"
            default: return "High"
            }
        }
    }
}

/// The on/off button for showing live text. It changes visibility only: the capture, the
/// recognizer and the finalized transcript are untouched either way.
@MainActor
struct LiveTranscriptControl: View {
    let recorder: AudioRecorder

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if recorder.onDevice { supported } else { unavailable }
        }
    }

    private var supported: some View {
        let shown = recorder.showsLiveTranscript
        return VStack(alignment: .leading, spacing: 10) {
            Button { recorder.setLiveTranscriptVisible(!shown) } label: {
                HStack(spacing: 10) {
                    GlyphView(name: "chat", size: 18)
                    Text(shown ? "Live transcription: on" : "Live transcription: off")
                        .font(Typeface.caption).foregroundStyle(Palette.icon)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.oat, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.tap(scale: 0.98))
            .accessibilityLabel("Live transcription")
            .accessibilityValue(shown ? "On" : "Off")
            .accessibilityHint("Only changes whether the text is shown. Recording and transcription continue.")
            if shown {
                ScrollView {
                    Text(recorder.liveText.isEmpty ? "Listening for speech…" : recorder.liveText)
                        .font(Typeface.body).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: 160)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
                .accessibilityLabel("Live transcript")
                .transition(.opacity)
            } else {
                Text("Transcribing on this iPhone. Hiding the text does not stop it.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
        .fadeSwitch(true)
    }

    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {} label: {
                Text("Live transcription unavailable")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(Palette.oat.opacity(0.6), in: Capsule())
            }
            .disabled(true)
            .accessibilityLabel("Live transcription unavailable")
            .accessibilityHint(recorder.engineMessage)
            Text("\(recorder.engineMessage) Live text cannot be shown, but your audio is still recorded and saved.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
    }
}

/// `00:24`-style clock used on the recording surface.
func recordingSurfaceClock(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}

@MainActor
struct RecordingSurface: View {
    let recorder: AudioRecorder
    var title = "Mock interview"
    let questionNumber: Int
    let questionCount: Int
    let prompt: String
    var busy = false
    let onStop: () -> Void
    let onTogglePause: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
    @Environment(\.stackReduceMotion) private var reduceMotion

    private var compact: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }
    private var fraction: CGFloat {
        guard questionCount > 0 else { return 0 }
        return CGFloat(min(max(questionNumber, 0), questionCount)) / CGFloat(questionCount)
    }
    private var live: Bool { recorder.isRecording || recorder.isPaused }
    private var status: String {
        if recorder.isPaused { return "Paused" }
        if recorder.isRecording { return "Recording" }
        return recorder.finalizing ? "Saving your answer" : "Recording stopped"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).font(Typeface.button.weight(.semibold)).foregroundStyle(Palette.ink)
                    Spacer(minLength: 12)
                    brand
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Typeface.button.weight(.semibold)).foregroundStyle(Palette.ink)
                    brand
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.halo)
                    GeometryReader { proxy in
                        Capsule().fill(Palette.muted).frame(width: proxy.size.width * fraction)
                    }
                }
                .frame(height: 4)
                Text("Question \(questionNumber) of \(questionCount)")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Question \(questionNumber) of \(questionCount)")

            Text(prompt).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: compact ? 8 : 24)

            VStack(spacing: 18) {
                RecordingLevelBars(meter: recorder.meter, running: recorder.isRecording && !recorder.isPaused,
                                   maxHeight: compact ? 64 : 104)
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        Circle().fill(recorder.isRecording && !recorder.isPaused ? Palette.icon : Color.clear)
                            .overlay(Circle().stroke(Palette.icon, lineWidth: 1.5))
                            .frame(width: 10, height: 10)
                        Text(status).font(Typeface.body).foregroundStyle(Palette.muted)
                    }
                    Text(recordingSurfaceClock(recorder.elapsed))
                        .font(.system(.largeTitle, design: .monospaced).weight(.medium))
                        .foregroundStyle(Palette.ink)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue("\(Int(recorder.elapsed) / 60) minutes \(Int(recorder.elapsed) % 60) seconds")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Recording status and elapsed time")
                .accessibilityValue("\(status), \(Int(recorder.elapsed) / 60) minutes \(Int(recorder.elapsed) % 60) seconds")
                .accessibilityIdentifier("recording-status-clock")
            }
            .frame(maxWidth: .infinity)

            if live || recorder.finalizing { LiveTranscriptControl(recorder: recorder) }
            MessageLine(text: recorder.stopNotice, isError: false).fadeSwitch(!recorder.stopNotice.isEmpty)

            Spacer(minLength: compact ? 8 : 24)

            VStack(spacing: Spacing.option) {
                Button(action: onStop) {
                    HStack(spacing: 14) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Palette.icon).frame(width: 18, height: 18)
                        Text("Stop recording").font(Typeface.button).foregroundStyle(Palette.icon)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Palette.button, in: Capsule())
                    .overlay(Capsule().stroke(Palette.dark.opacity(0.4), lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.tap)
                .disabled(busy || !live)
                .accessibilityLabel("Stop recording")
                .accessibilityHint("Saves your answer and moves to review.")
                StackButton(label: recorder.isPaused ? "Resume" : "Pause", kind: .secondary,
                            disabled: busy || !live, action: onTogglePause)
                Text("Take your time. Up to five minutes. A phone call or locking your phone stops and keeps the recording.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var brand: some View {
        Text("STACK").font(.system(.footnote).weight(.semibold)).tracking(3).foregroundStyle(Palette.ink)
            .accessibilityHidden(true)
    }
}

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

/// Display-side easing between measured bar levels. It only moves each bar toward the latest
/// measured value (fast on the way up, a little slower on the way down), so capture buffers
/// that arrive about every 100 ms read as continuous. It adds no activity of its own: with a
/// constant target it settles on that target; every transition stays between the previous
/// displayed level and the measured target.
struct LevelBarSmoother: Equatable {
    static let rise = 0.025
    static let fall = 0.07

    private(set) var values: [Float]

    init(count: Int = PCMLevelTracker.barCount) { values = Array(repeating: 0, count: count) }

    mutating func reset() { values = Array(repeating: 0, count: values.count) }

    /// `elapsed` is the time since the previous frame. Zero or non-finite elapsed holds the values.
    mutating func advance(toward targets: [Float], elapsed: TimeInterval, smoothing: Bool = true) -> [Float] {
        for index in values.indices {
            let target = index < targets.count && targets[index].isFinite ? min(max(targets[index], 0), 1) : 0
            if !smoothing { values[index] = target; continue }
            guard elapsed > 0, elapsed.isFinite else { continue }
            let tau = target > values[index] ? Self.rise : Self.fall
            values[index] += (target - values[index]) * Float(1 - exp(-elapsed / tau))
            if abs(target - values[index]) < 0.004 { values[index] = target }
        }
        return values
    }
}

/// Reference box so the frame-to-frame display state survives view updates without publishing.
@MainActor
private final class LevelBarDisplay {
    var smoother = LevelBarSmoother()
    var lastFrame: Date?
}

/// Six slim rounded bars whose heights are the measured microphone amplitude. There is no
/// decorative loop: while nothing is recording the schedule is paused and the bars rest as
/// small dots in a quiet tone. Sampled at 60 Hz with a brief display-side ease toward each
/// measured level; Reduce Motion samples less often and shows measured values directly.
@MainActor
struct RecordingLevelBars: View {
    let meter: PCMLevelMeter?
    /// Recording and not paused.
    let running: Bool
    var maxHeight: CGFloat = 104
    var showsQuality = true

    @Environment(\.stackReduceMotion) private var reduceMotion

    @State private var display = LevelBarDisplay()

    private let width: CGFloat = 8
    private let gap: CGFloat = 14
    /// At rest each bar is a round dot.
    private var minHeight: CGFloat { width }

    /// Bar height for a 0...1 measured level; out-of-range values are clamped.
    static func barHeight(level: Float, minHeight: CGFloat, maxHeight: CGFloat) -> CGFloat {
        let value = CGFloat(min(max(level.isFinite ? level : 0, 0), 1))
        return minHeight + (maxHeight - minHeight) * value
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 60.0, paused: !running)) { context in
            let snapshot = running ? (meter?.snapshot() ?? .idle) : .idle
            let bars = shownBars(snapshot, at: context.date)
            VStack(spacing: 16) {
                HStack(alignment: .center, spacing: gap) {
                    ForEach(0..<PCMLevelTracker.barCount, id: \.self) { index in
                        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
                            .fill(running ? (snapshot.quality == .clipping ? Palette.danger : Palette.dark) : Palette.ring)
                            .frame(width: width, height: Self.barHeight(level: bars[index], minHeight: minHeight, maxHeight: maxHeight))
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

    /// Heights to draw this frame. A stopped or paused meter shows rest immediately.
    private func shownBars(_ snapshot: PCMLevelSnapshot, at date: Date) -> [Float] {
        guard running else {
            display.smoother.reset(); display.lastFrame = nil
            return snapshot.bars
        }
        let elapsed = display.lastFrame.map { date.timeIntervalSince($0) } ?? 0.1
        display.lastFrame = date
        return display.smoother.advance(toward: snapshot.bars, elapsed: min(max(elapsed, 0), 0.1), smoothing: !reduceMotion)
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
    /// Height of the text well; the surface shortens it on compact screens.
    var textHeight: CGFloat = 160

    @Environment(\.stackReduceMotion) private var reduceMotion

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
                    Text("Live transcription")
                        .font(Typeface.caption).foregroundStyle(Palette.icon)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Text(shown ? "On" : "Off")
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(shown ? Palette.onDark : Palette.muted)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(shown ? Palette.dark : Palette.halo, in: Capsule())
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(Palette.oat, in: Capsule())
                .contentShape(Capsule())
                .animation(reduceMotion ? nil : Motion.fadeAnimation, value: shown)
            }
            .buttonStyle(.tap(scale: 0.98))
            .accessibilityLabel("Live transcription")
            .accessibilityValue(shown ? "On" : "Off")
            .accessibilityHint("Only changes whether the text is shown. Recording and transcription continue.")
            if shown {
                LiveTranscriptText(text: recorder.liveText, height: textHeight)
            } else {
                Text("Transcribing on this iPhone. Hiding the text does not stop it.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            }
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: shown)
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

/// The scrolling live text. It opens on the latest words and follows new text while the reader
/// is at the end; once they scroll up it stays put until they return to the end. Following
/// uses an immediate scroll, so it needs no animation and respects Reduce Motion.
@MainActor
private struct LiveTranscriptText: View {
    let text: String
    let height: CGFloat

    @State private var following = true
    @State private var lastContent: CGFloat = 0

    private static let space = "live-transcript-scroll"
    private static let end = "live-transcript-end"
    /// Within this many points of the end counts as at the end.
    private static let tolerance: CGFloat = 24

    fileprivate struct Metrics: Equatable { var offset: CGFloat; var content: CGFloat }
    fileprivate struct MetricsKey: PreferenceKey {
        static let defaultValue = Metrics(offset: 0, content: 0)
        static func reduce(value: inout Metrics, nextValue: () -> Metrics) { value = nextValue() }
    }

    var body: some View {
        let empty = text.isEmpty
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Text(empty ? "Listening for speech…" : text)
                        .font(Typeface.body)
                        .foregroundStyle(empty ? Palette.muted : Palette.text)
                        .lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .accessibilityAddTraits(.updatesFrequently)
                    Color.clear.frame(height: 1).id(Self.end)
                }
                .background(GeometryReader { geometry in
                    let frame = geometry.frame(in: .named(Self.space))
                    Color.clear.preference(key: MetricsKey.self, value: Metrics(offset: -frame.minY, content: frame.height))
                })
            }
            .coordinateSpace(name: Self.space)
            .scrollIndicators(.hidden)
            .onPreferenceChange(MetricsKey.self) { metrics in
                if metrics.content != lastContent {
                    // First layout or new text: keep the reader's place unless they are following.
                    lastContent = metrics.content
                    if following { proxy.scrollTo(Self.end, anchor: .bottom) }
                } else {
                    following = metrics.offset + height >= metrics.content - Self.tolerance
                }
            }
        }
        .frame(height: height)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous).stroke(Palette.rule.opacity(0.6), lineWidth: 1))
        .accessibilityLabel("Live transcript")
        // Insert softly; remove at once so hidden text is never left on screen or readable.
        .transition(.asymmetric(insertion: .opacity, removal: .identity))
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
                .animation(reduceMotion ? nil : Motion.stageAnimation, value: fraction)
                Text("Question \(questionNumber) of \(questionCount)")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Question \(questionNumber) of \(questionCount)")

            Text(prompt).font(Typeface.display).tracking(-1.8).foregroundStyle(Palette.ink)
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
                            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: recorder.isPaused)
                            .accessibilityHidden(true)
                        Text(status).font(Typeface.body).foregroundStyle(Palette.muted)
                    }
                    Text(recordingSurfaceClock(recorder.elapsed))
                        .font(Font.system(.largeTitle, design: .default).weight(.medium).monospacedDigit())
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

            if live || recorder.finalizing { LiveTranscriptControl(recorder: recorder, textHeight: compact ? 112 : 160) }
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

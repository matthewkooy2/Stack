import SwiftUI

// The Prep screens in the Stack look: one thing to read and one thing to tap. They are plain views fed by
// closures, so the Motion Lab can show them without a session or a microphone.

/// A quiet text link under the main button.
struct ScreenLink: Identifiable {
    let title: String
    let action: () -> Void
    var id: String { title }
    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }
}

/// The first sentence of a prompt and whatever follows it, so the first can be large and the rest quiet.
func splitPrompt(_ prompt: String) -> (lead: String, rest: String) {
    var index = prompt.startIndex
    while index < prompt.endIndex {
        if ".?!".contains(prompt[index]) {
            let next = prompt.index(after: index)
            if next < prompt.endIndex, prompt[next] == " " {
                return (String(prompt[..<next]), String(prompt[prompt.index(after: next)...]))
            }
        }
        index = prompt.index(after: index)
    }
    return (prompt, "")
}

/// A big blue pill, the same as the login screen's main button.
private struct PrimaryPill: View {
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let icon { Image(systemName: icon).font(.system(size: 19, weight: .semibold)) }
                Text(title).font(.system(.headline).weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(Brand.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98))
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

private struct QuietLinks: View {
    let links: [ScreenLink]
    var body: some View {
        HStack(spacing: 24) {
            ForEach(links) { link in
                Button(action: link.action) {
                    Text(link.title).font(Typeface.caption).foregroundStyle(Brand.muted)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.97))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A question, large, with one action. It is Prep's home, and every later question in a session.
@MainActor
struct PrepQuestionScreen: View {
    var topic: String?
    var progress: String?
    var context: String?
    let prompt: String
    var primary = "Answer"
    var busy = false
    var message = ""
    var links: [ScreenLink] = []
    var onTopic: (() -> Void)?
    var onHistory: (() -> Void)?
    let onPrimary: () -> Void

    var body: some View {
        let parts = splitPrompt(prompt)
        VStack(alignment: .leading, spacing: 0) {
            topBar.reveal(0)
            Spacer(minLength: 24)
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 14) {
                    if let context { Text(context).font(Typeface.caption).foregroundStyle(Brand.muted) }
                    Text(parts.lead)
                        .font(.system(size: 36, weight: .heavy))
                        .tracking(-1.8)
                        .foregroundStyle(Brand.ink)
                        .minimumScaleFactor(0.6)
                    if !parts.rest.isEmpty {
                        Text(parts.rest).font(.system(.title3)).foregroundStyle(Brand.muted)
                    }
                }
                .id(prompt)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
            .animation(Motion.ease(0.4), value: prompt)
            .reveal(1)
            Spacer(minLength: 24)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            PrimaryPill(title: primary, icon: primary == "Answer" ? "mic.fill" : nil, disabled: busy, action: onPrimary)
                .reveal(2)
            QuietLinks(links: links).padding(.top, 6).reveal(3)
        }
    }

    private var topBar: some View {
        HStack {
            if let onTopic, let topic {
                Button(action: onTopic) {
                    HStack(spacing: 5) {
                        Text(topic).font(.system(.subheadline).weight(.semibold))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    }
                    .foregroundStyle(Brand.ink)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.97))
                .accessibilityLabel("Topic: \(topic)")
            } else if let progress {
                Text(progress).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.muted)
            }
            Spacer()
            if let onHistory {
                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath").font(.system(size: 20)).foregroundStyle(Brand.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.92, dim: 1))
                .accessibilityLabel("Past sessions")
            }
        }
        .frame(minHeight: 44)
    }
}

/// Recording: a timer, one circle that pauses, and Done. Level, status and quality hints live in the circle and
/// one quiet line. The microphone stays the recorder's business; this only reads it.
@MainActor
struct PrepRecordingScreen: View {
    let recorder: AudioRecorder
    let progress: String
    var busy = false
    var message = ""
    let onDone: () -> Void
    let onTogglePause: () -> Void
    let onCancel: () -> Void

    @Environment(\.stackReduceMotion) private var reduceMotion

    private var live: Bool { recorder.isRecording || recorder.isPaused }
    private var running: Bool { recorder.isRecording && !recorder.isPaused }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(progress).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.muted)
                Spacer()
            }
            .frame(minHeight: 44)
            .reveal(0)
            Spacer()
            VStack(spacing: 34) {
                Button(action: onTogglePause) { orb }
                    .buttonStyle(.tap(scale: 0.97, dim: 1))
                    .disabled(busy || !live)
                    .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
                VStack(spacing: 8) {
                    Text(clock)
                        .font(.system(size: 64, weight: .heavy).monospacedDigit())
                        .tracking(-2)
                        .foregroundStyle(Brand.ink)
                        .contentTransition(reduceMotion ? .identity : .numericText())
                        .accessibilityLabel("Elapsed time")
                        .accessibilityValue("\(Int(recorder.elapsed) / 60) minutes \(Int(recorder.elapsed) % 60) seconds")
                    caption
                }
            }
            .frame(maxWidth: .infinity)
            .reveal(1)
            Spacer()
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            PrimaryPill(title: "Done", disabled: busy || !live, action: onDone)
                .accessibilityHint("Saves your answer.")
                .reveal(2)
            QuietLinks(links: [ScreenLink("Cancel", action: onCancel)]).padding(.top, 6).reveal(3)
        }
    }

    private var clock: String {
        let total = max(0, Int(recorder.elapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The circle swells with the measured microphone level while recording.
    private var orb: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 0.25 : 1.0 / 60.0, paused: !running)) { _ in
            let level = running ? CGFloat(recorder.meter?.snapshot().level ?? 0) : 0
            let swell = reduceMotion ? 0 : min(max(level, 0), 1)
            ZStack {
                Circle().fill(Brand.accent.opacity(0.14)).frame(width: 190, height: 190).scaleEffect(1 + swell * 0.16)
                Circle().stroke(Brand.accent, lineWidth: 3).frame(width: 150, height: 150)
                Circle().fill(Brand.accent).frame(width: 118, height: 118).scaleEffect(1 + swell * 0.05)
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: swell)
        }
        .frame(width: 200, height: 200)
    }

    @ViewBuilder private var caption: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            let quality = running ? (recorder.meter?.snapshot().quality ?? .waiting) : .waiting
            let warn = [.quiet, .silent, .clipping].contains(quality)
            Text(recorder.isPaused ? "Paused. Tap the circle to continue."
                 : warn ? RecordingLevelBars.caption(quality, running: true)
                 : live ? "Tap the circle to pause" : (recorder.finalizing ? "Saving your answer" : ""))
                .font(Typeface.caption)
                .foregroundStyle(quality == .clipping ? Palette.danger : Brand.muted)
                .multilineTextAlignment(.center)
                .frame(minHeight: 20)
        }
    }
}

/// Choose what to practice: a focus, or another kind of practice. One sheet instead of the old setup pages.
@MainActor
struct PrepTopicSheet: View {
    let selected: PrepFocus
    let onFocus: (PrepFocus) -> Void
    let onTool: (PrepTool) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PrepFocus.allCases, id: \.self) { focus in
                row(focus.shortName, checked: focus == selected) { onFocus(focus); dismiss() }
            }
            Rectangle().fill(Brand.rule).frame(height: 1).padding(.vertical, 6)
            row("Technical") { dismiss(); onTool(.practice) }
            row("Mock interview") { dismiss(); onTool(.interview) }
            row("More tools", muted: true) { dismiss(); onTool(.tools) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.page)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Brand.page.ignoresSafeArea())
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }

    private func row(_ title: String, checked: Bool = false, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: muted ? 17 : 22, weight: .semibold))
                    .tracking(-0.5)
                    .foregroundStyle(muted ? Brand.muted : Brand.ink)
                Spacer()
                if checked { Image(systemName: "checkmark").font(.system(size: 17, weight: .bold)).foregroundStyle(Brand.accent) }
            }
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.99))
        .accessibilityLabel(title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

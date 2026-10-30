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
struct PrimaryPill: View {
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

struct QuietLinks: View {
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

/// Choose what to practice: a focus, or a mock interview for a saved role.
@MainActor
struct PrepTopicSheet: View {
    let selected: PrepFocus
    let onFocus: (PrepFocus) -> Void
    let onInterview: () -> Void
    /// Opens the practice-interview library (industry question slots with recorded, scored answers).
    var onPractice: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(PrepFocus.allCases, id: \.self) { focus in
                row(focus.shortName, checked: focus == selected) { onFocus(focus); dismiss() }
            }
            Rectangle().fill(Brand.rule).frame(height: 1).padding(.vertical, 6)
            row("Mock interview") { dismiss(); onInterview() }
            if let onPractice { row("Practice interview") { dismiss(); onPractice() } }
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

/// While the answer is read and the coaching written: the coin mark breathing, one line, nothing to decide.
/// When it stalls, the same screen offers the one next step.
@MainActor
struct PrepWorkingScreen: View {
    let progress: String
    var message = "Reading your answer…"
    var detail = ""
    var stalled = false
    var primary: String?
    var busy = false
    var onPrimary: (() -> Void)?
    var links: [ScreenLink] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(progress).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.muted)
                Spacer()
            }
            .frame(minHeight: 44)
            .reveal(0)
            Spacer()
            VStack(spacing: 22) {
                StackMark(size: 170).compositingGroup().breathe(!stalled, minimum: 0.55)
                Text(message)
                    .font(.system(size: 24, weight: .bold)).tracking(-0.7)
                    .foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                if !detail.isEmpty {
                    Text(detail).font(Typeface.caption).foregroundStyle(Brand.muted).multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .reveal(1)
            Spacer()
            if let primary, let onPrimary {
                PrimaryPill(title: primary, disabled: busy, action: onPrimary).reveal(2)
            }
            QuietLinks(links: links).padding(.top, 6).reveal(3)
        }
        .accessibilityElement(children: .contain)
    }
}

/// One scored part of the coaching, with the reason for its score.
struct CoachCriterion: Identifiable, Equatable {
    let name: String
    let score: Int          // 0 to 4
    let why: String
    var id: String { name }
}

/// Coaching as a scorecard: a one-line verdict, four scores readable at a glance, and one thing to work on.
/// Each row opens to say why it got its score. When the coaching has no scores it shows its two key points instead.
@MainActor
struct PrepCoachingScreen: View {
    let progress: String
    let verdict: String
    let criteria: [CoachCriterion]
    let focus: String
    var worked = ""
    let primary: String
    var busy = false
    var message = ""
    let onAnswer: () -> Void
    let onPrimary: () -> Void
    let onAgain: () -> Void
    /// The quiet link under the button; nil hides it.
    var secondary: String? = "Try this answer again"

    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var open: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(progress).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.muted)
                Spacer()
                Button(action: onAnswer) {
                    Text("Your answer").font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.ink)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.97))
            }
            .frame(minHeight: 44)
            .reveal(0)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verdict)
                        .font(.system(size: 30, weight: .heavy)).tracking(-1.4)
                        .foregroundStyle(Brand.ink)
                        .minimumScaleFactor(0.7)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 18)
                        .reveal(1)
                    if criteria.isEmpty {
                        if !worked.isBlank { block("Worked", worked).padding(.top, 28).reveal(2) }
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(criteria.enumerated()), id: \.element.id) { index, item in
                                row(item, index: index)
                            }
                        }
                        .padding(.top, 22)
                        .reveal(2)
                    }
                    if !focus.isBlank { block("Work on", focus).padding(.top, 28).reveal(3) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            PrimaryPill(title: primary, disabled: busy, action: onPrimary).reveal(4)
            QuietLinks(links: secondary.map { [ScreenLink($0, action: onAgain)] } ?? []).padding(.top, 6).reveal(5)
        }
    }

    private func row(_ item: CoachCriterion, index: Int) -> some View {
        let isOpen = open == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.ease(0.32)) { open = isOpen ? nil : item.id }
            } label: {
                HStack(spacing: 12) {
                    Text(item.name).font(.system(size: 19, weight: .semibold)).tracking(-0.4).foregroundStyle(Brand.ink)
                    Spacer(minLength: 8)
                    Text("\(item.score)/4")
                        .font(.system(.subheadline).weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.score == 0 ? Palette.danger : Brand.muted)
                    dots(item.score, delay: 0.35 + Double(index) * 0.08)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold)).foregroundStyle(Brand.muted)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.99, dim: 1))
            .accessibilityLabel("\(item.name), \(item.score) of 4")
            .accessibilityHint(isOpen ? "Hides why" : "Shows why")
            if isOpen && !item.why.isBlank {
                Text(item.why)
                    .font(Typeface.body).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            Rectangle().fill(Brand.rule).frame(height: 1)
        }
    }

    /// Four dots, filled to the score. They fill in one after another when the screen appears.
    private func dots(_ score: Int, delay: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < score ? Brand.accent : Brand.rule)
                    .frame(width: 11, height: 11)
                    .pop(delay: delay + Double(i) * 0.05)
            }
        }
        .accessibilityHidden(true)
    }

    private func block(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
            Text(text)
                .font(.system(size: 22, weight: .bold)).tracking(-0.6)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A round white back button, the same as on the sign-in forms.
struct BrandBackButton: View {
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Brand.ink)
                .frame(width: 44, height: 44)
                .background(Color.white, in: Circle())
                .overlay(Circle().stroke(Brand.rule, lineWidth: 1))
        }
        .buttonStyle(.tap(scale: 0.92, dim: 1))
        .disabled(disabled)
        .accessibilityLabel("Back")
    }
}

/// The end of a session: the mark lands, one line, nothing to decide.
@MainActor
struct PrepDoneScreen: View {
    let answers: Int
    let streak: Int
    let onDone: () -> Void
    let onAgain: () -> Void

    private var detail: String {
        let count = "\(answers) \(answers == 1 ? "answer" : "answers")"
        return streak > 0 ? "\(count) · \(streak) day streak" : count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                StackMark(size: 200)
                Text("Nice work.").font(.system(size: 46, weight: .heavy)).tracking(-2.2).foregroundStyle(Brand.ink)
                    .reveal(0, delay: 0.9)
                Text(detail).font(.system(.title3)).foregroundStyle(Brand.muted).reveal(1, delay: 0.9)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            PrimaryPill(title: "Done", action: onDone).reveal(2, delay: 0.9)
            QuietLinks(links: [ScreenLink("Practice again", action: onAgain)]).padding(.top, 6).reveal(3, delay: 0.9)
        }
    }
}

struct HistoryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

/// A plain list: a big title, then rows with a hairline between them.
@MainActor
struct PrepListScreen: View {
    let title: String
    let items: [HistoryItem]
    var empty = ""
    let onBack: () -> Void
    let onSelect: (HistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { BrandBackButton(action: onBack); Spacer() }.reveal(0)
            Text(title).font(.system(size: 36, weight: .heavy)).tracking(-1.8).foregroundStyle(Brand.ink)
                .padding(.top, 18).padding(.bottom, 8).reveal(1)
            if items.isEmpty {
                Text(empty).font(Typeface.body).foregroundStyle(Brand.muted).padding(.top, 16)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 20, weight: .semibold)).tracking(-0.5).foregroundStyle(Brand.ink)
                                .lineLimit(2).multilineTextAlignment(.leading)
                            if !item.detail.isEmpty {
                                Text(item.detail).font(Typeface.caption).foregroundStyle(Brand.muted).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Brand.muted)
                    }
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.99, dim: 1))
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
                .reveal(index + 2)
            }
        }
    }
}

/// One saved answer: the question, the audio, what was said, and the coaching it got, with every reason showing.
@MainActor
struct PrepSavedAnswerScreen<Playback: View>: View {
    let heading: String
    let prompt: String
    let answer: String
    let verdict: String
    let criteria: [CoachCriterion]
    let focus: String
    let onBack: () -> Void
    @ViewBuilder var playback: () -> Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { BrandBackButton(action: onBack); Spacer() }.reveal(0)
            Text(heading).font(.system(size: 36, weight: .heavy)).tracking(-1.8).foregroundStyle(Brand.ink)
                .padding(.top, 18).reveal(1)
            if !prompt.isEmpty { Text(prompt).font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 6) }
            playback().padding(.top, 18)
            if !answer.isBlank {
                label("What you said").padding(.top, 26)
                Text(answer).font(Typeface.body).foregroundStyle(Brand.ink).padding(.top, 6)
            }
            if !verdict.isBlank {
                label("Coaching").padding(.top, 26)
                Text(verdict).font(.system(size: 24, weight: .bold)).tracking(-0.8).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            ForEach(criteria) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.system(size: 18, weight: .semibold)).foregroundStyle(Brand.ink)
                        Spacer()
                        Text("\(item.score)/4").font(.system(.subheadline).weight(.semibold).monospacedDigit())
                            .foregroundStyle(item.score == 0 ? Palette.danger : Brand.muted)
                    }
                    if !item.why.isBlank { Text(item.why).font(Typeface.body).foregroundStyle(Brand.muted) }
                }
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
            }
            if !focus.isBlank {
                label("Work on").padding(.top, 22)
                Text(focus).font(.system(size: 20, weight: .bold)).tracking(-0.5).foregroundStyle(Brand.ink).padding(.top, 6)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
    }
}

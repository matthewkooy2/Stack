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

/// Primary action with an optional SF Symbol.
struct PrimaryPill: View {
    let title: String
    var icon: String?
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).accessibilityHidden(true) }
                Text(title)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.button, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .disabled(disabled)
        .accessibilityLabel(title)
    }
}

struct QuietLinks: View {
    let links: [ScreenLink]
    var body: some View {
        if !links.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { buttons }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(spacing: 0) { buttons }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var buttons: some View {
        ForEach(links) { link in
            Button(action: link.action) {
                Text(link.title).font(.subheadline.weight(.medium)).foregroundStyle(Brand.accent)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.98))
        }
    }
}

/// A question with optional role context and a direct recording action.
@MainActor
struct PrepQuestionScreen: View {
    var topic: String?
    var progress: String?
    var context: String?
    let prompt: String
    var primary = "Record answer"
    var busy = false
    var message = ""
    var links: [ScreenLink] = []
    var onTopic: (() -> Void)?
    var onHistory: (() -> Void)?
    let onPrimary: () -> Void
    @Environment(\.stackReduceMotion) private var reduceMotion

    var body: some View {
        let parts = splitPrompt(prompt)
        VStack(alignment: .leading, spacing: 0) {
            topBar.reveal(0)
            Spacer(minLength: 24)
            ZStack(alignment: .leading) {
                VStack(alignment: .leading, spacing: 14) {
                    if let context { Text(context).font(Typeface.caption).foregroundStyle(Brand.muted) }
                    Text(parts.lead)
                        .font(Typeface.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Brand.ink)
                    if !parts.rest.isEmpty {
                        Text(parts.rest).font(.system(.title3)).foregroundStyle(Brand.muted)
                    }
                }
                .id(prompt)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 14)), removal: .opacity))
            }
            .animation(reduceMotion ? nil : Motion.fadeAnimation, value: prompt)
            .reveal(1)
            Spacer(minLength: 24)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            PrimaryPill(title: primary, icon: primary == "Record answer" ? "mic.fill" : nil, disabled: busy, action: onPrimary)
                .reveal(2)
            QuietLinks(links: links).disabled(busy).padding(.top, 6).reveal(3)
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

/// The question stays in view while the microphone meter and timer report the live take.
@MainActor
struct PrepRecordingScreen: View {
    let recorder: AudioRecorder
    let progress: String
    var prompt = ""
    var busy = false
    var message = ""
    let onDone: () -> Void
    let onTogglePause: () -> Void
    let onCancel: () -> Void
    @Environment(\.stackReduceMotion) private var reduceMotion

    private var live: Bool { recorder.isRecording || recorder.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(progress).font(Typeface.caption).foregroundStyle(Brand.muted)
            if !prompt.isEmpty {
                Text(prompt).font(Typeface.title).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            VStack(spacing: 12) {
                Text(recordingSurfaceClock(recorder.elapsed))
                    .font(.system(.largeTitle, design: .rounded).weight(.medium).monospacedDigit())
                    .foregroundStyle(Brand.ink)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue("\(Int(recorder.elapsed) / 60) minutes \(Int(recorder.elapsed) % 60) seconds")
                RecordingLevelBars(meter: recorder.meter, running: recorder.isRecording && !recorder.isPaused, maxHeight: 64)
                Button(action: onTogglePause) {
                    Label(recorder.isPaused ? "Resume recording" : "Pause recording",
                          systemImage: recorder.isPaused ? "play.fill" : "pause.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
                        .padding(.horizontal, 16).frame(minHeight: 44)
                        .background(Palette.halo, in: Capsule())
                }
                .buttonStyle(.tap(scale: 0.98))
                .disabled(busy || !live)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
            Spacer(minLength: 8)
            if !message.isEmpty { MessageLine(text: message) }
            PrimaryPill(title: busy ? "Saving…" : "Done", disabled: busy || !live, action: onDone)
                .accessibilityHint("Saves your answer.")
            QuietLinks(links: [ScreenLink("Cancel", action: onCancel)])
                .disabled(busy)
        }
    }
}

@MainActor
struct PrepTopicSheet: View {
    let selected: PrepFocus
    let onFocus: (PrepFocus) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetPage(title: "Question topic") {
            VStack(spacing: 0) {
                ForEach(PrepFocus.allCases, id: \.self) { focus in
                    Button {
                        onFocus(focus)
                        dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            GlyphView(name: focus.icon, size: 19, color: Brand.accent)
                            Text(focus.rawValue).font(Typeface.body).foregroundStyle(Brand.ink)
                            Spacer()
                            if focus == selected {
                                Image(systemName: "checkmark").foregroundStyle(Brand.accent)
                            }
                        }
                        .padding(.vertical, 8).frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.tap(scale: 0.99))
                    .accessibilityAddTraits(focus == selected ? .isSelected : [])
                    if focus != PrepFocus.allCases.last { Divider() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Displays progress while a request runs.
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
    var spinner = false

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
                if stalled {
                    Image(systemName: "info.circle").font(.largeTitle).foregroundStyle(Brand.muted)
                        .accessibilityHidden(true)
                } else {
                    ProgressView().controlSize(spinner ? .large : .regular).tint(Brand.accent)
                }
                Text(message).font(Typeface.title).foregroundStyle(Brand.ink)
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
    var fullText = ""
    let primary: String
    var busy = false
    var message = ""
    let onAnswer: () -> Void
    let onPrimary: () -> Void
    let onAgain: () -> Void
    /// The quiet link under the button; nil hides it.
    var secondary: String? = "Try this answer again"

    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSize
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
                feedbackContent
                if scrollsActions { actions }
            }
            .frame(maxHeight: .infinity)
            if !scrollsActions { actions }
        }
    }

    private var scrollsActions: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }

    private var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verdict)
                .font(Typeface.title)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
                .reveal(1)
            if criteria.isEmpty {
                if !worked.isBlank { block("Worked", worked).padding(.top, 28).reveal(2) }
            } else {
                VStack(spacing: 0) {
                    ForEach(criteria) { item in
                        row(item)
                    }
                }
                .padding(.top, 22)
                .reveal(2)
            }
            if !focus.isBlank { block("Work on", focus).padding(.top, 28).reveal(3) }
            if !fullText.isBlank {
                DisclosureSection("Full coaching") {
                    Text(fullText).font(Typeface.body).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 0) {
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            PrimaryPill(title: primary, disabled: busy, action: onPrimary).reveal(4)
            QuietLinks(links: secondary.map { [ScreenLink($0, action: onAgain)] } ?? []).padding(.top, 6).reveal(5)
        }
    }

    private func row(_ item: CoachCriterion) -> some View {
        let isOpen = open == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { open = isOpen ? nil : item.id }
            } label: {
                HStack(spacing: 12) {
                    Text(item.name).font(.headline).foregroundStyle(Brand.ink)
                    Spacer(minLength: 8)
                    Text("\(item.score)/4")
                        .font(.system(.subheadline).weight(.semibold).monospacedDigit())
                        .foregroundStyle(item.score == 0 ? Palette.danger : Brand.muted)
                    if !typeSize.isAccessibilitySize { dots(item.score) }
                    if !item.why.isBlank {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.99, dim: 1))
            .accessibilityLabel("\(item.name), \(item.score) of 4")
            .disabled(item.why.isBlank)
            .accessibilityValue(item.why.isBlank ? "" : (isOpen ? "Expanded" : "Collapsed"))
            .accessibilityHint(item.why.isBlank ? "" : (isOpen ? "Hides why" : "Shows why"))
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

    /// A compact visual counterpart to the spoken score.
    private func dots(_ score: Int) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < score ? Brand.accent : Brand.rule)
                    .frame(width: 7, height: 7)
            }
        }
        .accessibilityHidden(true)
    }

    private func block(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
            Text(text)
                .font(Typeface.section)
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
        BackButton(disabled: disabled, action: action)
    }
}

/// A session receipt with the answer count and the current streak.
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
                Image(systemName: "checkmark.circle.fill").font(.system(size: 50)).foregroundStyle(Palette.success)
                    .accessibilityHidden(true)
                Text("Session complete").font(Typeface.display).foregroundStyle(Brand.ink)
                    .reveal(0)
                Text(detail).font(.system(.title3)).foregroundStyle(Brand.muted).reveal(1)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            PrimaryPill(title: "Done", action: onDone).reveal(2)
            QuietLinks(links: [ScreenLink("Practice again", action: onAgain)]).padding(.top, 6).reveal(3)
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
            Text(title).font(Typeface.display).foregroundStyle(Brand.ink)
                .padding(.top, 18).padding(.bottom, 8).reveal(1)
            if items.isEmpty {
                EmptyNote(icon: "clock", title: empty)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { onSelect(item) } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.headline).foregroundStyle(Brand.ink)
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
    var fullText = ""
    let onBack: () -> Void
    @ViewBuilder var playback: () -> Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { BrandBackButton(action: onBack); Spacer() }.reveal(0)
            Text(heading).font(Typeface.display).foregroundStyle(Brand.ink)
                .padding(.top, 18).reveal(1)
            if !prompt.isEmpty { Text(prompt).font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 6) }
            playback().padding(.top, 18)
            if !answer.isBlank {
                label("What you said").padding(.top, 26)
                Text(answer).font(Typeface.body).foregroundStyle(Brand.ink).padding(.top, 6)
            }
            if !verdict.isBlank {
                label("Coaching").padding(.top, 26)
                Text(verdict).font(Typeface.title).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
            ForEach(criteria) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).font(.headline).foregroundStyle(Brand.ink)
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
                Text(focus).font(Typeface.section).foregroundStyle(Brand.ink).padding(.top, 6)
            }
            if !fullText.isBlank {
                label("Full coaching").padding(.top, 22)
                Text(fullText).font(Typeface.body).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
    }
}

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

// MARK: - Shared pieces

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

/// A round back control with a title, the header of the Prep lists and saved answers.
@MainActor
private struct PrepSubheader: View {
    let title: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            BackButton(action: onBack)
            Text(title).font(Typeface.title).foregroundStyle(Brand.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.leading, -6)
    }
}

// MARK: - Question

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
                    if let context { StatusPill(text: context, tone: .accent, prominent: true, symbol: "briefcase.fill") }
                    Text(parts.lead)
                        .font(Typeface.display)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(Brand.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !parts.rest.isEmpty {
                        Text(parts.rest).font(.title3).foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .id(prompt)
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)), removal: .opacity))
            }
            .animation(reduceMotion ? nil : Motion.smooth, value: prompt)
            .reveal(1)
            Spacer(minLength: 24)
            if !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.danger).padding(.bottom, 10)
            }
            StackButton(label: primary, icon: primary == "Record answer" ? "mic.fill" : "", disabled: busy,
                        pulse: primary == "Record answer", action: onPrimary)
                .reveal(2)
            QuietLinks(links: links).disabled(busy).padding(.top, 6).reveal(3)
        }
    }

    private var topBar: some View {
        HStack {
            if let onTopic, let topic {
                Button(action: onTopic) {
                    HStack(spacing: 6) {
                        Text(topic).font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(Brand.accent)
                    .padding(.horizontal, 12).frame(minHeight: 36)
                    .background(Palette.halo, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.97))
                .accessibilityLabel("Topic: \(topic)")
            } else if let progress {
                StatusPill(text: progress, tone: .accent, prominent: true)
            }
            Spacer()
            if let onHistory {
                Button(action: onHistory) {
                    Image(systemName: "clock.arrow.circlepath").font(.title3).foregroundStyle(Brand.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.tap(scale: 0.92, dim: 1))
                .accessibilityLabel("History")
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Recording

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
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var clockSize: CGFloat = 64

    private var live: Bool { recorder.isRecording || recorder.isPaused }
    private var running: Bool { recorder.isRecording && !recorder.isPaused }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                StatusPill(text: progress, tone: .accent, prominent: true)
                Spacer()
                statePill
            }
            .frame(minHeight: 44)
            if !prompt.isEmpty {
                Text(prompt).font(Typeface.title).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 8)
            VStack(spacing: 20) {
                Text(recordingSurfaceClock(recorder.elapsed))
                    .font(.system(size: clockSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Brand.ink)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue("\(Int(recorder.elapsed) / 60) minutes \(Int(recorder.elapsed) % 60) seconds")
                RecordingLevelBars(meter: recorder.meter, running: running, maxHeight: 72)
            }
            .frame(maxWidth: .infinity)
            Spacer(minLength: 8)
            if !message.isEmpty { MessageLine(text: message) }
            controls
            QuietLinks(links: [ScreenLink("Cancel", action: onCancel)])
                .disabled(busy)
        }
    }

    private var statePill: some View {
        HStack(spacing: 7) {
            Circle().fill(running ? Palette.danger : Palette.muted).frame(width: 8, height: 8)
                .breathe(running, minimum: 0.35)
            Text(recorder.isPaused ? "Paused" : (running ? "Recording" : "Ready"))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 12).frame(minHeight: 32)
        .background(Palette.surface, in: Capsule())
        .animation(reduceMotion ? nil : Motion.snappy, value: recorder.isPaused)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var controls: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Button(action: onTogglePause) {
                Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.semibold)).foregroundStyle(Brand.accent)
                    .frame(width: typeSize.isAccessibilitySize ? nil : 54, height: 54)
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : 54)
                    .background(Palette.halo, in: RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.tap(scale: 0.95, dim: 0.5))
            .disabled(busy || !live)
            .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")
            StackButton(label: busy ? "Saving…" : "Done", icon: busy ? "" : "stop.fill", disabled: busy || !live, action: onDone)
                .accessibilityHint("Saves your answer")
        }
    }
}

// MARK: - Working

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
                if !progress.isEmpty { StatusPill(text: progress, tone: .accent, prominent: true) }
                Spacer()
            }
            .frame(minHeight: 44)
            .reveal(0)
            Spacer()
            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(Palette.halo).frame(width: 88, height: 88)
                    if stalled {
                        Image(systemName: "exclamationmark.circle").font(.title).foregroundStyle(Palette.muted)
                            .accessibilityHidden(true)
                    } else {
                        ProgressView().controlSize(spinner ? .large : .regular).tint(Brand.accent)
                    }
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
            Spacer()
            if let primary, let onPrimary {
                StackButton(label: primary, disabled: busy, action: onPrimary).reveal(2)
            }
            QuietLinks(links: links).padding(.top, 6).reveal(3)
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Feedback

/// One scored part of the feedback, with the reason for its score.
struct CoachCriterion: Identifiable, Equatable {
    let name: String
    let score: Int          // 0 to 4
    let why: String
    var id: String { name }
}

/// Feedback as a scorecard: a one-line verdict, four scores readable at a glance, and one thing to work on.
/// Each row opens to say why it got its score. When the feedback has no scores it shows its two key points instead.
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
                StatusPill(text: progress, tone: .accent, prominent: true)
                Spacer()
                Button(action: onAnswer) {
                    HStack(spacing: 6) {
                        Image(systemName: "text.quote").font(.footnote.weight(.semibold))
                        Text("Your answer").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Brand.ink)
                    .padding(.horizontal, 12).frame(minHeight: 32)
                    .background(Palette.surface, in: Capsule())
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
            .scrollIndicators(.hidden)
            .frame(maxHeight: .infinity)
            if !scrollsActions { actions }
        }
    }

    private var scrollsActions: Bool { typeSize.isAccessibilitySize || verticalSize == .compact }

    private var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verdict)
                .font(Typeface.title)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .reveal(1)
            if criteria.isEmpty {
                if !worked.isBlank {
                    noteCard(pill: "Strength", tone: .success, text: worked).reveal(2)
                }
            } else {
                Card(spacing: 0) {
                    ForEach(Array(criteria.enumerated()), id: \.element.id) { index, item in
                        row(item, last: index == criteria.count - 1)
                    }
                }
                .reveal(2)
            }
            if !focus.isBlank { noteCard(pill: "To improve", tone: .warning, text: focus).reveal(3) }
            if !fullText.isBlank {
                DisclosureSection("Full feedback") {
                    Text(fullText).font(Typeface.body).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            StackButton(label: primary, disabled: busy, action: onPrimary).reveal(4)
            QuietLinks(links: secondary.map { [ScreenLink($0, action: onAgain)] } ?? []).padding(.top, 6).reveal(5)
        }
    }

    private func row(_ item: CoachCriterion, last: Bool) -> some View {
        let isOpen = open == item.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : Motion.snappy) { open = isOpen ? nil : item.id }
            } label: {
                HStack(spacing: 12) {
                    Text(item.name).font(.headline).foregroundStyle(Brand.ink)
                    Spacer(minLength: 8)
                    if !typeSize.isAccessibilitySize { dots(item.score) }
                    ScoreChip(score: item.score)
                    if !item.why.isBlank {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .frame(minHeight: 52)
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
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            if !last { Divider() }
        }
    }

    /// A compact visual counterpart to the spoken score.
    private func dots(_ score: Int) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { i in
                Circle()
                    .fill(i < score ? Brand.accent : Brand.rule)
                    .frame(width: 6, height: 6)
            }
        }
        .accessibilityHidden(true)
    }

    private func noteCard(pill: String, tone: StatusPill.Tone, text: String) -> some View {
        Card(spacing: 10) {
            StatusPill(text: pill, tone: tone)
            Text(text)
                .font(Typeface.section)
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Done

/// A session receipt with the answer count and the current streak.
@MainActor
struct PrepDoneScreen: View {
    let answers: Int
    let streak: Int
    let onDone: () -> Void
    let onAgain: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 24) {
                Image(systemName: "checkmark").font(.system(size: 34, weight: .bold)).foregroundStyle(Palette.success)
                    .frame(width: 88, height: 88)
                    .background(Palette.success.opacity(0.13), in: Circle())
                    .pop()
                    .accessibilityHidden(true)
                Text("Session complete").font(Typeface.display).foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.center)
                    .reveal(0)
                HStack(spacing: 12) {
                    tile(symbol: "text.bubble.fill", tint: 0, value: answers, label: answers == 1 ? "answer" : "answers")
                    if streak > 0 { tile(symbol: "flame.fill", tint: 3, value: streak, label: "day streak") }
                }
                .reveal(1)
            }
            .frame(maxWidth: .infinity)
            Spacer()
            Spacer()
            StackButton(label: "Done", action: onDone).reveal(2)
            QuietLinks(links: [ScreenLink("Practice again", action: onAgain)]).padding(.top, 6).reveal(3)
        }
    }

    private func tile(symbol: String, tint: Int, value: Int, label: String) -> some View {
        Card(spacing: 10) {
            SymbolDisc(systemName: symbol, size: 36, tint: tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(Typeface.title.monospacedDigit()).foregroundStyle(Brand.ink)
                    .contentTransition(.numericText())
                Text(label).font(Typeface.caption).foregroundStyle(Brand.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Lists

struct HistoryItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
}

/// A title with a back control, then one grouped list of rows.
@MainActor
struct PrepListScreen: View {
    let title: String
    let items: [HistoryItem]
    var empty = ""
    let onBack: () -> Void
    let onSelect: (HistoryItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            PrepSubheader(title: title, onBack: onBack).reveal(0)
            if items.isEmpty {
                EmptyNote(icon: "clock", title: empty).reveal(1)
            } else {
                GroupedList {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        GroupRow(symbol: "text.bubble", tint: index, title: item.title, detail: item.detail,
                                 divider: index < items.count - 1) { onSelect(item) }
                    }
                }
                .reveal(1)
            }
        }
    }
}

/// One saved answer: the question, the audio, what was said, and the feedback it got, with every reason showing.
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
        VStack(alignment: .leading, spacing: Spacing.group) {
            PrepSubheader(title: heading, onBack: onBack).reveal(0)
            if !prompt.isEmpty { Text(prompt).font(Typeface.section).foregroundStyle(Brand.ink).reveal(1) }
            playback()
            if !answer.isBlank {
                Card(spacing: 8) {
                    StatusPill(text: "What you said", tone: .neutral)
                    Text(answer).font(Typeface.body).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !verdict.isBlank {
                Text(verdict).font(Typeface.title).foregroundStyle(Brand.ink)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if !criteria.isEmpty {
                Card(spacing: 0) {
                    ForEach(Array(criteria.enumerated()), id: \.element.id) { index, item in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(item.name).font(.headline).foregroundStyle(Brand.ink)
                                Spacer()
                                ScoreChip(score: item.score)
                            }
                            if !item.why.isBlank { Text(item.why).font(Typeface.caption).foregroundStyle(Brand.muted) }
                        }
                        .padding(.vertical, 12)
                        .accessibilityElement(children: .combine)
                        .overlay(alignment: .bottom) { if index < criteria.count - 1 { Divider() } }
                    }
                }
            }
            if !focus.isBlank {
                Card(spacing: 10) {
                    StatusPill(text: "To improve", tone: .warning)
                    Text(focus).font(Typeface.section).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !fullText.isBlank {
                DisclosureSection("Full feedback") {
                    Text(fullText).font(Typeface.body).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A topic chooser sheet. The Prep home uses an inline menu; this stays available for other entry points.
@MainActor
struct PrepTopicSheet: View {
    let selected: PrepFocus
    let onFocus: (PrepFocus) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetPage(title: "Topic") {
            GroupedList {
                ForEach(Array(PrepFocus.allCases.enumerated()), id: \.element) { index, focus in
                    GroupRow(symbol: "text.bubble", tint: index, title: focus.rawValue,
                             divider: index < PrepFocus.allCases.count - 1) {
                        onFocus(focus)
                        dismiss()
                    } trailing: {
                        if focus == selected { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                    }
                    .accessibilityAddTraits(focus == selected ? .isSelected : [])
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

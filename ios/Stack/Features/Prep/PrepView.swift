import SwiftUI

@MainActor
struct PrepView: View {
    var isActive = true
    var onProfile: (() -> Void)?
    @Environment(AppStore.self) private var store
    @State var model = PrepModel()
    @State private var tool: PrepTool?
    @Environment(\.stackReduceMotion) private var reduceMotion

    /// These pages display their own navigation and status.
    private var fillsScreen: Bool { [.home, .question, .recording, .processing, .coaching, .complete].contains(model.page) }

    /// Pages that draw their own back button.
    private var ownsBack: Bool { [.past, .history, .savedAnswer].contains(model.page) }

    private var screenMessage: String { model.error.isEmpty ? model.recorder.error : model.error }

    var body: some View {
        GeometryReader { proxy in
            Stage(key: model.page, step: model.index) {
                if model.page == .coaching {
                    coaching
                        .padding(.horizontal, Spacing.page)
                        .padding(.vertical, 8)
                } else {
                    ScrollView {
                        scrollingPage
                            .padding(.horizontal, Spacing.page)
                            .padding(.top, model.page == .home ? Spacing.page : 8)
                            .padding(.bottom, 16)
                            .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
        }
        .background(Brand.page.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: model.page) { _, new in new == .coaching || new == .complete }
        .task {
            model.bind(store)
            await model.load()
        }
        .onChange(of: isActive) { _, active in
            if !active { model.suspendCapture() }
        }
        .fullScreenCover(item: $tool) { value in
            switch value {
            case .interview: MockInterviewFlow().environment(store)
            case .library: LibraryView().environment(store)
            }
        }
        .onDisappear { model.suspendCapture() }
        .task(id: model.needsPolling) {
            guard model.needsPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.page == .processing ? 0.8 : 2))
                if Task.isCancelled { break }
                await model.poll()
            }
        }
    }

    private var scrollingPage: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            if !fillsScreen && !ownsBack {
                BrandBackButton(disabled: model.locked) { Task { await model.back() } }
            }
            if [.answer, .review].contains(model.page) {
                Text("Question \(model.index + 1) of \(model.plan.count)")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            pageContent
            if !fillsScreen {
                MessageLine(text: screenMessage)
                    .fadeSwitch(!screenMessage.isEmpty)
                MessageLine(text: model.recorder.stopNotice, isError: false)
                    .fadeSwitch(!model.recorder.stopNotice.isEmpty)
                if model.recorder.permissionDenied {
                    StackButton(label: "Open microphone settings", kind: .secondary) { AppSettings.open() }
                    Text("Allow the microphone, or type instead")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                Text("Saving…").font(Typeface.caption).foregroundStyle(Palette.muted)
                    .fadeSwitch(model.busy || model.coaching)
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .home: home
        case .question: questionPage
        case .answer: typedAnswer
        case .recording: recordingPage
        case .review: review
        case .processing: processing
        case .coaching: coaching
        case .complete: complete
        case .past: sessionList
        case .history: savedAnswers
        case .savedAnswer: savedAnswer
        }
    }

    // MARK: Home and questions

    private var micLinks: [ScreenLink] {
        model.recorder.permissionDenied ? [ScreenLink("Open microphone settings") { AppSettings.open() }] : []
    }

    /// A session with no answers and no end is just a question someone opened and left; it says nothing.
    private var finishedSessions: [JSON] {
        model.sessions.filter { $0["data"]["behavioral"]["complete"].bool || !$0["data"]["behavioral"]["history"].array.isEmpty }
    }

    /// The saved job at the interview stage, if any.
    private var interviewRole: Application? {
        store.account.applications.first { !$0.isDemo && $0.status.lowercased().contains("interview") }
    }

    private var home: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            ScreenHeader(title: StackTab.prep.rawValue, onProfile: onProfile) { EmptyView() }
                .reveal(0)
            hero.reveal(1)
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Keep going")
                progressCard
                toolsList
            }
            .reveal(2)
        }
    }

    /// Today's question: topic menu, the question, one primary action and two quieter ones.
    private var hero: some View {
        Card(tint: Palette.surface, spacing: 18) {
            if let session = model.continuing {
                ProgressPill(text: "Continue · \(session.label)", symbol: "arrow.uturn.forward")
                prompt(session.prompt)
                PrimaryPill(title: "Continue", disabled: model.busy) {
                    Task { await model.openSession(session.id) }
                }
                SoftAction(title: "Start something new", icon: "plus", disabled: model.busy) { model.startedFresh = true }
            } else {
                topicMenu
                if let offered = model.offered {
                    prompt(offered.prompt)
                        .id(offered.id)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
                    VStack(spacing: 12) {
                        PrimaryPill(title: "Record answer", icon: "mic.fill", disabled: model.busy, pulse: true) {
                            Task { await model.answerOffered() }
                        }
                        HStack(spacing: 10) {
                            SoftAction(title: "Type instead", icon: "keyboard", disabled: model.busy) {
                                Task { await model.answerOffered(typing: true) }
                            }
                            SoftAction(title: "Another question", icon: "arrow.triangle.2.circlepath", disabled: model.busy) {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(Motion.animation(Motion.smooth, reduce: reduceMotion)) { model.another() }
                            }
                        }
                        QuietLinks(links: micLinks)
                    }
                } else if model.loaded {
                    EmptyNote(icon: "question-file", title: "No questions available")
                    StackButton(label: model.loadingCatalog ? "Loading…" : "Reload questions", kind: .secondary, disabled: model.loadingCatalog) {
                        Task { await model.load(retry: true) }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        SkeletonBlock(height: 26, radius: 8)
                        SkeletonBlock(height: 26, radius: 8)
                        SkeletonBlock(width: 200, height: 16)
                        SkeletonBlock(height: 54, radius: Radius.button).padding(.top, 10)
                    }
                    .accessibilityLabel("Loading questions")
                }
            }
            if !screenMessage.isEmpty { MessageLine(text: screenMessage) }
        }
        .animation(Motion.animation(Motion.smooth, reduce: reduceMotion), value: model.offered?.id)
    }

    private var topicMenu: some View {
        Menu {
            ForEach(PrepFocus.allCases, id: \.self) { focus in
                Button {
                    UISelectionFeedbackGenerator().selectionChanged()
                    withAnimation(Motion.animation(Motion.smooth, reduce: reduceMotion)) { model.choose(focus) }
                } label: {
                    if focus == model.focus { Label(focus.rawValue, systemImage: "checkmark") } else { Text(focus.rawValue) }
                }
            }
        } label: {
            HStack(spacing: 7) {
                GlyphView(name: model.focus.icon, size: 14, color: Brand.accent)
                Text(model.focus.rawValue).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(Palette.halo, in: Capsule())
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.97))
        .disabled(model.busy)
        .padding(.vertical, -6)
        .accessibilityLabel("Topic: \(model.focus.shortName)")
    }

    /// Streak and this week, from the saved sessions.
    @ViewBuilder
    private var progressCard: some View {
        if model.loaded {
            let week = model.week
            let days = week.filter { $0.practiced }.count
            Card(spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    stat(symbol: "flame.fill", tint: 3, value: model.streak, label: "day streak")
                    Divider().frame(height: 44)
                    stat(symbol: "calendar", tint: 0, value: days, label: "this week")
                }
                if !week.isEmpty {
                    HStack(spacing: 0) {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            VStack(spacing: 6) {
                                Image(systemName: day.practiced ? "checkmark" : "circle.fill")
                                    .font(.system(size: day.practiced ? 12 : 6, weight: .bold))
                                    .foregroundStyle(day.practiced ? Color.white : Palette.rule)
                                    .frame(width: 28, height: 28)
                                    .background(day.practiced ? Palette.button : Palette.page, in: Circle())
                                Text(day.label).font(.caption2.weight(.medium)).foregroundStyle(Palette.muted)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Practiced \(days) of 7 days this week")
                }
            }
            .animation(Motion.animation(Motion.smooth, reduce: reduceMotion), value: days)
        }
    }

    private func stat(symbol: String, tint: Int, value: Int, label: String) -> some View {
        HStack(spacing: 12) {
            TintDisc(systemName: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)").font(Typeface.title.monospacedDigit()).foregroundStyle(Brand.ink)
                    .contentTransition(.numericText())
                Text(label).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var toolsList: some View {
        GroupedList {
            GroupRow(symbol: "bubble.left.and.text.bubble.right.fill", tint: 0, title: "Mock interview",
                     detail: interviewRole.map { "\($0.job.title) · \($0.job.company)" } ?? "Practice for a saved job",
                     disabled: model.busy, action: { tool = .interview }) {
                HStack(spacing: 8) {
                    if interviewRole != nil { StatusPill(text: "Next up", tone: .accent) }
                    RowChevron()
                }
            }
            GroupRow(symbol: "rectangle.stack.fill", tint: 1, title: "Question library", detail: "Practice by industry",
                     disabled: model.busy) { tool = .library }
            GroupRow(symbol: "clock.fill", tint: 5, title: "History", detail: finishedSessions.isEmpty ? "Your sessions appear here"
                         : "\(finishedSessions.count) \(finishedSessions.count == 1 ? "session" : "sessions")",
                     divider: false, disabled: model.busy) { model.go(.past) }
        }
    }

    private func prompt(_ text: String) -> some View {
        let parts = splitPrompt(text)
        return VStack(alignment: .leading, spacing: 10) {
            Text(parts.lead).font(.title.weight(.bold)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if !parts.rest.isEmpty { Text(parts.rest).font(.body).foregroundStyle(Palette.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var questionPage: some View {
        PrepQuestionScreen(progress: "\(model.index + 1) of \(model.plan.count)", prompt: model.question?.prompt ?? "",
                           busy: model.busy, message: screenMessage,
                           links: [ScreenLink("Type instead") { model.go(.answer) },
                                   ScreenLink("Stop for now") { Task { await model.back() } }] + micLinks,
                           onPrimary: { Task { await model.recordAnswer() } })
    }

    // MARK: Answering

    private var typedAnswer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.question?.prompt ?? "").font(Typeface.title).foregroundStyle(Palette.ink).reveal(0)
            AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                         placeholder: "Your answer", label: "Your answer", disabled: model.busy)
            PrimaryPill(title: "Get feedback", disabled: model.busy || model.coaching || model.draft.isBlank) {
                Task { await model.coach() }
            }
        }
    }

    private var recordingPage: some View {
        PrepRecordingScreen(recorder: model.recorder, progress: "\(model.index + 1) of \(model.plan.count)",
                            prompt: model.question?.prompt ?? "", busy: model.finishing, message: screenMessage,
                            onDone: { Task { await model.finishAnswer() } },
                            onTogglePause: { model.togglePause() },
                            onCancel: { model.cancelRecording() })
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your answer").font(Typeface.display).foregroundStyle(Brand.ink)
            Text(model.question?.prompt ?? "").font(Typeface.section).foregroundStyle(Brand.muted)
            if let url = model.localURL, FileManager.default.fileExists(atPath: url.path) {
                AnswerPlayback(url: url, isActive: isActive)
            }
            if model.transcribing {
                Card {
                    Text(model.transcriptionUnavailable ? "Transcript unavailable" : "Reading your answer…")
                        .font(Typeface.body).foregroundStyle(Palette.text)
                        .breathe(!["failed", "cancelled"].contains(model.recording["status"].string) && !model.transcriptionUnavailable)
                    Text(transcriptionNote).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if ["failed", "cancelled"].contains(model.recording["status"].string) {
                        StackButton(label: "Try again") { Task { await model.retryTranscription() } }
                    }
                }
                .reveal()
            }
            if model.localURL != nil, model.recording.object.isEmpty {
                StackButton(label: "Upload answer", disabled: model.busy) { Task { await model.retryUpload() } }.reveal()
            }
            if !model.feedback.object.isEmpty {
                Text(model.submitted["data"]["answer"].string).font(Typeface.body).foregroundStyle(Brand.ink)
                coachingDetails
                if model.hasUnsavedCoaching {
                    StackButton(label: "Save feedback", disabled: model.coaching) { Task { await model.retryCoachingSave() } }
                }
                QuietLinks(links: [ScreenLink("Back to feedback") { model.go(.coaching) }])
            } else {
                AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                             placeholder: "Type or edit your answer", label: "Your answer",
                             disabled: model.coaching || (model.busy && !model.canReviewPhoneText))
                VStack(spacing: 6) {
                    PrimaryPill(title: "Get feedback", disabled: model.busy || model.coaching || model.draft.isBlank) { Task { await model.coach() } }
                    if !model.coaching {
                        QuietLinks(links: [ScreenLink("Record again") { Task { await model.recordAnswer() } }])
                    }
                }
            }
        }
    }

    /// All of the coaching text, for people who want more than the two sentences.
    private var coachingDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Full feedback").font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
            let raw = model.feedback["text"].string.isBlank ? model.feedback["summary"].string : model.feedback["text"].string
            if model.feedback["rubric"].array.isEmpty {
                ForEach(Array(CoachingText.paragraphs(raw).enumerated()), id: \.offset) { _, paragraph in
                    Text(paragraph).font(Typeface.body).foregroundStyle(Brand.ink)
                }
            } else if !raw.isEmpty {
                Text(model.feedback["summary"].string).font(Typeface.body).foregroundStyle(Brand.ink)
            }
            ForEach(Array(model.feedback["rubric"].array.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item["criterion"].string.capitalized).font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                    Text(item["feedback"].string).font(Typeface.body).foregroundStyle(Brand.ink)
                }
            }
            ForEach(Array(model.feedback["next_exercises"].strings.enumerated()), id: \.offset) { _, value in
                Text(value).font(Typeface.body).foregroundStyle(Brand.ink)
            }
            if let quote = model.feedback["evidence"].array.first?["quote"].string, !quote.isEmpty {
                Text("“\(quote)”").font(Typeface.caption).foregroundStyle(Brand.muted)
                    .padding(.leading, 15)
                    .overlay(alignment: .leading) { Rectangle().fill(Brand.rule).frame(width: 3) }
            }
        }
    }

    private var transcriptionNote: String {
        let message = model.recording["error"].string
        if !message.isEmpty { return message }
        let runtime = model.runtime["message"].string
        return runtime.isEmpty ? "Audio saved. You can type your answer below" : runtime
    }

    // MARK: Coaching

    @ViewBuilder
    private var processing: some View {
        let progress = "\(model.index + 1) of \(model.plan.count)"
        PrepWorkingScreen(progress: progress, links: [ScreenLink("Your answer") { model.go(.review) }])
    }

    private var coaching: some View {
        let shown = CoachingPresentation.make(from: model.feedback)
        return PrepCoachingScreen(progress: "\(model.index + 1) of \(model.plan.count)",
                                  verdict: shown.verdict.isBlank ? "Here’s how that went" : shown.verdict,
                                  criteria: shown.criteria, focus: shown.focus,
                                  worked: model.worked,
                                  fullText: CoachingPresentation.fullText(from: model.feedback),
                                  primary: model.isLastQuestion ? "Finish" : "Next question",
                                  busy: model.busy || model.coaching || model.workflow["complete"].bool, message: screenMessage,
                                  onAnswer: { model.go(.review) },
                                  onPrimary: { Task { await model.nextAnswer() } },
                                  onAgain: {}, secondary: nil)
    }

    private var complete: some View {
        PrepDoneScreen(answers: model.history.count, streak: model.streak,
                       onDone: { model.go(.home) },
                       onAgain: { model.another(); model.go(.home) })
    }

    // MARK: Lists

    private var sessionList: some View {
        let rows = finishedSessions
            .sorted { $0["updated_at"].double > $1["updated_at"].double }
        let items = rows.map { row -> HistoryItem in
            let work = row["data"]["behavioral"]
            let answers = work["history"].array.count
            let first = model.catalog.first { $0.id == work["plan"].strings.first }?.prompt ?? ""
            let when = shortDate(row["updated_at"].double)
            let count = "\(answers) \(answers == 1 ? "answer" : "answers")"
            return HistoryItem(id: row["id"].string, title: first.isEmpty ? "Practice session" : splitPrompt(first).lead,
                               detail: [when, count, work["complete"].bool ? "" : "In progress"].filter { !$0.isEmpty }.joined(separator: " · "))
        }
        return PrepListScreen(title: "History", items: items, empty: "No sessions yet",
                              onBack: { Task { await model.back() } },
                              onSelect: { item in Task { await model.openSession(item.id) } })
    }

    private var savedAnswers: some View {
        let focus = PrepFocus(rawValue: model.workflow["focus"].string)?.shortName ?? "Session"
        let items = model.history.map { entry -> HistoryItem in
            let prompt = model.catalog.first { $0.id == entry["problem_id"].string }?.prompt ?? ""
            return HistoryItem(id: String(entry["index"].int), title: "Question \(entry["index"].int + 1)",
                               detail: splitPrompt(prompt).lead)
        }
        return PrepListScreen(title: focus, items: items, empty: "No saved answers",
                              onBack: { Task { await model.back() } },
                              onSelect: { item in
                                  if let entry = model.history.first(where: { String($0["index"].int) == item.id }) {
                                      Task { await model.viewSaved(entry) }
                                  }
                              })
    }

    private var savedAnswer: some View {
        let shown = CoachingPresentation.make(from: model.archived["feedback"])
        let prompt = model.catalog.first { $0.id == model.archived["problem_id"].string }?.prompt ?? ""
        return PrepSavedAnswerScreen(heading: "Question \(model.archived["index"].int + 1)", prompt: prompt,
                                     answer: model.archived["answer"].string, verdict: shown.verdict,
                                     criteria: shown.criteria, focus: shown.focus,
                                     fullText: CoachingPresentation.fullText(from: model.archived["feedback"]),
                                     onBack: { Task { await model.back() } }) {
            if let url = model.archivedURL { AnswerPlayback(url: url, isActive: isActive) }
        }
    }
}

/// The multi-line answer field.
@MainActor
struct AnswerEditor: View {
    @Binding var text: String
    let placeholder: String
    let label: String
    var disabled = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .focused($focused)
            .keyboardDismissControl()
            .lineLimit(6...)
            .font(Typeface.body)
            .foregroundStyle(Brand.ink)
            .tint(Brand.accent)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .stroke(focused ? Brand.accent.opacity(0.7) : Brand.rule, lineWidth: focused ? 1.5 : 1))
            .animation(Motion.fadeAnimation, value: focused)
            .disabled(disabled)
            .accessibilityLabel(label)
    }
}

enum PrepTool: String, Identifiable {
    case interview, library
    var id: String { rawValue }
}

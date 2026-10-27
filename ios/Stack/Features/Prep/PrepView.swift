import SwiftUI

@MainActor
struct PrepView: View {
    var isActive = true
    @Environment(AppStore.self) private var store
    @State var model = PrepModel()
    @State private var tool: PrepTool?
    @State private var showTopics = false
    @State private var pendingTool: PrepTool?

    /// Pages that fill the screen and draw their own top bar, in the new look.
    private var fillsScreen: Bool { [.home, .question, .recording, .processing, .coaching, .complete].contains(model.page) }

    /// Pages that draw their own back button.
    private var ownsBack: Bool { [.past, .history, .savedAnswer].contains(model.page) }

    private var screenMessage: String { model.error.isEmpty ? model.recorder.error : model.error }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Stage(key: model.page, step: model.index) {
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
                                Text("Allow microphone access, then return and choose Record answer again. You can also type instead.")
                                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                            }
                            Text("Saving…").font(Typeface.caption).foregroundStyle(Palette.muted)
                                .fadeSwitch(model.busy || model.saving)
                        }
                    }
                    .padding(.horizontal, Spacing.page)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height - 8,
                           maxHeight: fillsScreen ? proxy.size.height - 8 : nil, alignment: .topLeading)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
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
        .sheet(isPresented: $showTopics, onDismiss: {
            if let next = pendingTool { pendingTool = nil; tool = next }
        }) {
            PrepTopicSheet(selected: model.focus, onFocus: { model.choose($0) }, onInterview: { pendingTool = .interview })
        }
        .fullScreenCover(item: $tool) { _ in MockInterviewFlow().environment(store) }
        .onDisappear { model.suspendCapture() }
        .task(id: model.autosaveToken) {
            guard [.answer, .review].contains(model.page) else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { await model.autoSave() }
        }
        .task(id: model.needsPolling) {
            guard model.needsPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(model.page == .processing ? 0.8 : 2))
                if Task.isCancelled { break }
                await model.poll()
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

    /// "Interview at <company>" when a saved role is at the interview stage.
    private var interviewContext: String? {
        let role = store.account.applications.first { !$0.isDemo && $0.status.lowercased().contains("interview") }
        return role.map { "Interview at \($0.job.company)" }
    }

    @ViewBuilder
    private var home: some View {
        if let resume = model.continuing {
            PrepQuestionScreen(progress: "Continue · \(resume.label)", prompt: resume.prompt, primary: "Continue",
                               busy: model.busy, message: screenMessage,
                               links: [ScreenLink("Start something new") { withAnimation(Motion.ease(0.4)) { model.startedFresh = true } }],
                               onHistory: { model.go(.past) },
                               onPrimary: { Task { await model.openSession(resume.id) } })
        } else if let offered = model.offered {
            PrepQuestionScreen(topic: model.focus.shortName, context: interviewContext, prompt: offered.prompt,
                               busy: model.busy, message: screenMessage,
                               links: [ScreenLink("Another question") { withAnimation(Motion.ease(0.4)) { model.another() } },
                                       ScreenLink("Type instead") { Task { await model.answerOffered(typing: true) } }] + micLinks,
                               onTopic: { showTopics = true },
                               onHistory: { model.go(.past) },
                               onPrimary: { Task { await model.answerOffered() } })
        } else {
            Color.clear
        }
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
            Text(model.question?.prompt ?? "").font(Typeface.display).tracking(-1.8).foregroundStyle(Palette.ink).reveal(0)
            AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                         placeholder: "Your answer…", label: "Your answer", disabled: model.busy)
            PrimaryPill(title: "Get coaching", disabled: model.busy || model.saving || model.draft.isBlank) {
                Task { await model.coach() }
            }
        }
    }

    private var recordingPage: some View {
        PrepRecordingScreen(recorder: model.recorder, progress: "\(model.index + 1) of \(model.plan.count)",
                            busy: model.finishing, message: screenMessage,
                            onDone: { Task { await model.finishAnswer() } },
                            onTogglePause: { model.togglePause() },
                            onCancel: { model.cancelRecording() })
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Your answer").font(.system(size: 36, weight: .heavy)).tracking(-1.8).foregroundStyle(Brand.ink)
            Text(model.question?.prompt ?? "").font(Typeface.caption).foregroundStyle(Brand.muted)
            if let url = model.localURL, FileManager.default.fileExists(atPath: url.path) {
                AnswerPlayback(url: url, isActive: isActive)
            }
            if model.transcribing {
                Card {
                    Text(model.transcriptionUnavailable ? "Transcription unavailable" : "Reading your answer…")
                        .font(Typeface.body).foregroundStyle(Palette.text)
                        .breathe(!["failed", "cancelled"].contains(model.recording["status"].string) && !model.transcriptionUnavailable)
                    Text(transcriptionNote).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if ["failed", "cancelled"].contains(model.recording["status"].string) {
                        StackButton(label: "Try reading it again") { Task { await model.retryTranscription() } }
                    }
                }
                .reveal()
            }
            if model.localURL != nil, model.recording.object.isEmpty {
                StackButton(label: "Upload saved answer", disabled: model.busy) { Task { await model.retryUpload() } }.reveal()
            }
            AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                         placeholder: "Type or fix your answer before coaching", label: "Your answer",
                         disabled: model.busy && !model.canReviewPhoneText)
            if !model.feedback.object.isEmpty { coachingDetails }
            VStack(spacing: 6) {
                PrimaryPill(title: model.feedback.object.isEmpty ? "Get coaching" : "Update coaching",
                            disabled: model.busy || model.saving || model.draft.isBlank) { Task { await model.coach() } }
                QuietLinks(links: [ScreenLink("Record again") { Task { await model.recordAnswer() } }]
                           + (model.feedback.object.isEmpty ? [] : [ScreenLink("Back to coaching") { model.go(.coaching) }]))
            }
        }
    }

    /// All of the coaching text, for people who want more than the two sentences.
    private var coachingDetails: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Full coaching").font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.accent)
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
        return runtime.isEmpty ? "Your audio is saved. Waiting for the transcription worker. You can type your answer below." : runtime
    }

    // MARK: Coaching

    @ViewBuilder
    private var processing: some View {
        let progress = "\(model.index + 1) of \(model.plan.count)"
        let state = model.run["status"].string
        let stalled = ["needs_input", "blocked", "failed", "cancelled"].contains(state)
        let unreadable = model.run.object.isEmpty && model.draft.isBlank
            && (["failed", "cancelled"].contains(model.recording["status"].string) || model.transcriptionUnavailable)
        if stalled {
            PrepWorkingScreen(progress: progress, message: "We couldn’t finish your coaching.",
                              detail: model.run["message"].string, stalled: true,
                              primary: "Try again", busy: model.busy, onPrimary: { Task { await model.retryCoach() } },
                              links: [ScreenLink("Your answer") { model.go(.review) }])
        } else if unreadable {
            PrepWorkingScreen(progress: progress, message: "We couldn’t read your recording.",
                              detail: "Your audio is saved. You can type your answer instead.", stalled: true,
                              primary: "Type your answer", onPrimary: { model.go(.review) },
                              links: [ScreenLink("Try reading it again") { Task { await model.retryTranscription() } }])
        } else {
            PrepWorkingScreen(progress: progress, links: [ScreenLink("Your answer") { model.go(.review) }])
        }
    }

    private var coaching: some View {
        let shown = CoachingPresentation.make(from: model.feedback)
        return PrepCoachingScreen(progress: "\(model.index + 1) of \(model.plan.count)",
                                  verdict: shown.verdict.isBlank ? "Here’s how that went." : shown.verdict,
                                  criteria: shown.criteria, focus: shown.focus,
                                  worked: model.strengths.first?["feedback"].string ?? "",
                                  primary: model.isLastQuestion ? "Finish" : "Next question",
                                  busy: model.busy || model.workflow["complete"].bool, message: screenMessage,
                                  onAnswer: { model.go(.review) },
                                  onPrimary: { Task { await model.nextAnswer() } },
                                  onAgain: { model.tryAgain() })
    }

    private var complete: some View {
        PrepDoneScreen(answers: model.history.count, streak: model.streak,
                       onDone: { model.go(.home) },
                       onAgain: { model.another(); model.go(.home) })
    }

    // MARK: Lists

    private var sessionList: some View {
        // A session with no answers and no end is just a question someone opened and left; it says nothing.
        let rows = model.sessions
            .filter { $0["data"]["behavioral"]["complete"].bool || !$0["data"]["behavioral"]["history"].array.isEmpty }
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
        return PrepListScreen(title: "History", items: items, empty: "Your sessions will show up here.",
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
        return PrepListScreen(title: focus, items: items, empty: "No answers saved in this session.",
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

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(6...16)
            .font(Typeface.body)
            .foregroundStyle(Brand.ink)
            .tint(Brand.accent)
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Brand.rule, lineWidth: 1))
            .disabled(disabled)
            .accessibilityLabel(label)
    }
}

enum PrepTool: String, Identifiable {
    case interview
    var id: String { rawValue }
}

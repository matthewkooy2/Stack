import SwiftUI

@MainActor
struct PrepView: View {
    var isActive = true
    @Environment(AppStore.self) private var store
    @State var model = PrepModel()
    @State private var tool: PrepTool?

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                Stage(key: model.page, step: model.index) {
                    VStack(alignment: .leading, spacing: Spacing.stack) {
                        if model.page != .home {
                            BackButton(label: "Back to Prep", disabled: model.locked) { Task { await model.back() } }
                        }
                        if [.question, .answer, .recording, .review, .processing, .coaching].contains(model.page) {
                            Text("Question \(model.index + 1) of \(model.plan.count)")
                                .font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                        pageContent
                        MessageLine(text: model.error.isEmpty ? model.recorder.error : model.error)
                            .fadeSwitch(!(model.error.isEmpty && model.recorder.error.isEmpty))
                        Text("Saving…").font(Typeface.caption).foregroundStyle(Palette.muted)
                            .fadeSwitch(model.busy || model.saving)
                    }
                    .padding(.horizontal, Spacing.page)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height - 8, alignment: .topLeading)
                }
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
        }
        .sensoryFeedback(.success, trigger: model.page) { _, new in new == .coaching || new == .complete }
        .task {
            model.bind(store)
            await model.load()
        }
        .onChange(of: isActive) { _, active in
            if !active { model.suspendCapture() }
        }
        .sheet(item: $tool) { value in
            switch value {
            case .tools: PrepToolsSheet().environment(store)
            case .practice: PracticeView().environment(store)
            case .interview: InterviewView().environment(store)
            }
        }
        .onDisappear { model.suspendCapture() }
        .task(id: model.autosaveToken) {
            guard [.answer, .review].contains(model.page) else { return }
            try? await Task.sleep(for: .milliseconds(900))
            if !Task.isCancelled { await model.autoSave() }
        }
        .task(id: model.needsPolling) {
            guard model.needsPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await model.poll()
            }
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch model.page {
        case .home: home
        case .type: chooseType
        case .focus: chooseFocus
        case .length: chooseLength
        case .question: questionPage
        case .answer: typedAnswer
        case .recording: recordingPage
        case .review: review
        case .processing: processing
        case .coaching: coaching
        case .complete: complete
        case .continueSession, .past: sessionList
        case .history: savedAnswers
        case .savedAnswer: savedAnswer
        }
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Prep").font(.system(size: 40, weight: .bold)).tracking(-1).foregroundStyle(Palette.ink)
                .padding(.bottom, 12)
            ListRow(label: "New session", icon: "add-session") { model.focus = .mixed; model.go(.type) }.reveal(0)
            ListRow(label: "Continue session", icon: "continue-session") { model.go(.continueSession) }.reveal(1)
            ListRow(label: "Past sessions", icon: "clock") { model.go(.past) }.reveal(2)

            Card(tint: Palette.surfaceRaised) {
                Text("Session idea").font(Typeface.caption).foregroundStyle(Palette.muted)
                Text("Tell me about a time you changed your mind.")
                    .font(.system(.title2)).foregroundStyle(Palette.text)
                StackButton(label: "Start session", kind: .dark) {
                    model.focus = .teamwork
                    model.go(.length)
                    model.idea = true
                }
            }
            .padding(.top, 28)
            .reveal(3)

            weekTracker.padding(.top, 28).reveal(4).fadeSwitch(model.loaded, keep: true)
            StackButton(label: "More practice tools", kind: .secondary) { tool = .tools }.reveal(5)
        }
    }

    private var weekTracker: some View {
        let week = model.week
        let count = week.filter(\.practiced).count
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                GlyphView(name: "sparkles", size: 20, color: Palette.muted)
                Text("\(count) practice \(count == 1 ? "day" : "days") this week")
                    .font(Typeface.body).foregroundStyle(Palette.text)
            }
            HStack {
                ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                    VStack(spacing: 10) {
                        Text(day.label).font(Typeface.caption).foregroundStyle(Palette.muted)
                        ZStack {
                            Circle().stroke(Palette.outline, lineWidth: 1).frame(width: 30, height: 30)
                            if day.practiced {
                                Circle().fill(Palette.ring).frame(width: 30, height: 30)
                                GlyphView(name: "check", size: 14).pop(delay: 0.25 + Double(index) * 0.07)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(day.practiced ? "Practiced" : "No practice")
                }
            }
        }
    }

    // MARK: Setup

    private var chooseType: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Choose your session type").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Spacer(minLength: 110)
            VStack(spacing: Spacing.option) {
                OptionRow(label: "Behavioral", icon: "chat") { model.go(.focus) }.reveal(0)
                OptionRow(label: "Technical", icon: "code", oat: true) { tool = .practice }
                    .reveal(1)
            }
        }
    }

    private var chooseFocus: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Choose your focus").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Spacer(minLength: 110)
            VStack(spacing: Spacing.option) {
                ForEach(Array(PrepFocus.allCases.enumerated()), id: \.element) { index, choice in
                    OptionRow(label: choice.rawValue, icon: choice.icon, oat: index % 2 == 1) {
                        model.focus = choice
                        model.go(.length)
                    }
                    .reveal(index)
                }
            }
        }
    }

    private var chooseLength: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Choose your session length").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Spacer(minLength: 110)
            VStack(spacing: Spacing.option) {
                ForEach(Array([1, 3, 5].enumerated()), id: \.element) { index, count in
                    OptionRow(label: "\(count) \(count == 1 ? "question" : "questions")", icon: "question-file",
                              oat: count == 3, disabled: model.busy || model.catalog.isEmpty) {
                        Task { await model.begin(count: count) }
                    }
                    .reveal(index)
                }
            }
        }
    }

    // MARK: Answering

    private var questionPage: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text(model.question?.prompt ?? "").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink).reveal(0)
            Spacer(minLength: 100)
            VStack(spacing: Spacing.option) {
                StackButton(label: "Record answer", icon: "mic", disabled: model.busy) { Task { await model.recordAnswer() } }
                StackButton(label: "Type instead", kind: .secondary) { model.go(.answer) }
            }
            .reveal(2)
        }
    }

    private var typedAnswer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.question?.prompt ?? "").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink).reveal(0)
            AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                         placeholder: "Your answer…", label: "Your answer", disabled: model.busy)
            StackButton(label: "Review your answer", disabled: model.busy || model.saving || model.draft.isBlank) {
                model.go(.review)
            }
        }
    }

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Record your answer").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Text(model.question?.prompt ?? "").font(Typeface.body).foregroundStyle(Palette.text)
            Card {
                VStack(spacing: 14) {
                    Halo(active: model.recorder.isRecording && !model.recorder.isPaused, size: 76) {
                        GlyphView(name: "mic", size: 38)
                    }
                    Text(model.recorder.isPaused ? "Paused" : (model.recorder.isRecording ? "Recording" : "Recording stopped"))
                        .font(Typeface.body).foregroundStyle(Palette.text)
                    Text(recordingClock(model.recorder.elapsed))
                        .font(.system(.largeTitle, design: .default).weight(.bold).monospacedDigit())
                        .foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            }
            Text("Up to five minutes. A phone call or locking your phone stops and keeps the recording.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            Spacer(minLength: 24)
            VStack(spacing: Spacing.option) {
                StackButton(label: "Finish answer", disabled: model.busy) { Task { await model.finishAnswer() } }
                StackButton(label: model.recorder.isPaused ? "Resume" : "Pause", kind: .secondary,
                            disabled: model.busy || !model.recordingActive) { model.togglePause() }
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Review your answer").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Text(model.question?.title ?? "").font(Typeface.caption).foregroundStyle(Palette.muted)
            if let url = model.localURL, FileManager.default.fileExists(atPath: url.path) {
                AnswerPlayback(url: url, isActive: isActive)
            }
            if model.transcribing {
                Card {
                    Text(model.transcriptionUnavailable ? "Transcription unavailable" : "Transcribing your answer…")
                        .font(Typeface.body).foregroundStyle(Palette.text)
                        .breathe(!["failed", "cancelled"].contains(model.recording["status"].string) && !model.transcriptionUnavailable)
                    Text(transcriptionNote).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if ["failed", "cancelled"].contains(model.recording["status"].string) {
                        StackButton(label: "Retry transcription") { Task { await model.retryTranscription() } }
                    }
                }
                .reveal()
            }
            if model.localURL != nil, model.recording.object.isEmpty {
                StackButton(label: "Upload saved answer", disabled: model.busy) { Task { await model.retryUpload() } }.reveal()
            }
            AnswerEditor(text: Binding(get: { model.draft }, set: { model.edited($0) }),
                         placeholder: "Type or review your answer before coaching", label: "Review transcript", disabled: model.busy)
            VStack(spacing: Spacing.option) {
                StackButton(label: "Get coaching", disabled: model.busy || model.saving || model.draft.isBlank) { Task { await model.coach() } }
                StackButton(label: "Record again", kind: .secondary, disabled: model.busy) { Task { await model.recordAnswer() } }
                if !model.feedback.object.isEmpty {
                    StackButton(label: "Return to coaching", kind: .secondary) { model.go(.coaching) }
                }
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

    private var processing: some View {
        let state = model.run["status"].string
        let stalled = ["needs_input", "blocked", "failed", "cancelled"].contains(state)
        let labels = ["queued": "Waiting to start", "running": "Writing your coaching", "needs_input": "Needs your input",
                      "blocked": "Blocked", "failed": "Couldn’t finish", "cancelled": "Cancelled"]
        return VStack(alignment: .leading, spacing: 22) {
            Text("Preparing your coaching").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Halo(active: !stalled, size: 76) { GlyphView(name: "sparkles", size: 32) }
            let message = model.run["message"].string
            Text(message.isEmpty ? "Your answer is saved. Coaching will appear here when ready." : message)
                .font(Typeface.body).foregroundStyle(Palette.text)
            Text(labels[state] ?? state.replacingOccurrences(of: "_", with: " "))
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if stalled {
                StackButton(label: "Retry coaching", disabled: model.busy) { Task { await model.retryCoach() } }
            }
            StackButton(label: "View your answer", kind: .secondary) { model.go(.review) }
        }
    }

    private var coaching: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your coaching").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Text(model.question?.title ?? "").font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "View your answer", kind: .secondary) { model.go(.review) }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    GlyphView(name: "done", size: 26)
                    Text("What worked").font(Typeface.title).foregroundStyle(Palette.ink)
                }
                Text(model.strengths.first?["feedback"].string ?? model.feedback["summary"].string)
                    .font(Typeface.body).foregroundStyle(Palette.text)
                if let quote = model.feedback["evidence"].array.first?["quote"].string, !quote.isEmpty {
                    Text("“\(quote)”").font(Typeface.caption).foregroundStyle(Palette.muted)
                        .padding(.leading, 15)
                        .overlay(alignment: .leading) { Rectangle().fill(Palette.halo).frame(width: 3) }
                }
            }
            .reveal(1)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    GlyphView(name: "sprout", size: 26)
                    Text("Try next").font(Typeface.title).foregroundStyle(Palette.ink)
                }
                ForEach(Array(model.feedback["next_exercises"].strings.enumerated()), id: \.offset) { _, value in
                    Text(value).font(Typeface.body).foregroundStyle(Palette.text)
                }
                if let improvement = model.improvements.first?["feedback"].string, !improvement.isEmpty {
                    Text(improvement).font(Typeface.body).foregroundStyle(Palette.text)
                }
            }
            .reveal(2)

            Card {
                Text("A stronger ending").font(Typeface.caption).foregroundStyle(Palette.muted)
                Text("The result was… and next time I would…").font(Typeface.body).foregroundStyle(Palette.text)
            }
            .reveal(3)

            VStack(spacing: Spacing.group) {
                if !model.history.isEmpty {
                    StackButton(label: "Saved answers", kind: .secondary) { model.go(.history) }
                }
                StackButton(label: model.isLastQuestion ? "Finish session" : "Next question", icon: "next",
                            disabled: model.busy || model.workflow["complete"].bool) { Task { await model.nextAnswer() } }
                StackButton(label: "Try this answer again", kind: .secondary) { model.tryAgain() }
            }
            .reveal(4)
        }
    }

    private var complete: some View {
        VStack(alignment: .leading, spacing: 22) {
            Halo(size: 76) { GlyphView(name: "done", size: 34) }.pop()
            Text("Session complete").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            Text("\(model.plan.count) \(model.plan.count == 1 ? "question" : "questions") practiced. Your answers and coaching are saved.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            StackButton(label: "Back to Prep") { model.go(.home) }
            StackButton(label: "New session", kind: .secondary) { model.go(.type) }
        }
    }

    // MARK: Lists

    private var sessionList: some View {
        let continuing = model.page == .continueSession
        let rows = continuing ? model.activeSessions : model.sessions
        return VStack(alignment: .leading, spacing: Spacing.group) {
            Text(continuing ? "Continue session" : "Past sessions").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                let w = row["data"]["behavioral"]
                OptionRow(label: "\(w["focus"].string) · \(w["index"].int + 1) of \(w["plan"].array.count)", icon: "chat",
                          oat: index % 2 == 1, disabled: model.busy) {
                    Task { await model.openSession(row["id"].string) }
                }
                .reveal(index)
            }
            if rows.isEmpty {
                Text("No sessions yet. Start with New session.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var savedAnswers: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            Text("Saved answers").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            ForEach(Array(model.history.enumerated()), id: \.offset) { index, entry in
                OptionRow(label: "Question \(entry["index"].int + 1)", icon: "play", oat: index % 2 == 1) {
                    Task { await model.viewSaved(entry) }
                }
                .reveal(index)
            }
            StackButton(label: "Return to session", kind: .secondary) { model.go(.coaching) }
        }
    }

    private var savedAnswer: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Answer \(model.archived["index"].int + 1)").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            if let prompt = model.catalog.first(where: { $0.id == model.archived["problem_id"].string })?.prompt {
                Text(prompt).font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if let url = model.archivedURL { AnswerPlayback(url: url, isActive: isActive) }
            Text(model.archived["answer"].string).font(Typeface.body).foregroundStyle(Palette.text)
            Text("Your coaching").font(Typeface.title).foregroundStyle(Palette.ink)
            Text(model.archived["feedback"]["summary"].string).font(Typeface.body).foregroundStyle(Palette.text)
            StackButton(label: "Saved answers", kind: .secondary) { model.go(.history) }
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
            .foregroundStyle(Palette.text)
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
            .disabled(disabled)
            .accessibilityLabel(label)
    }
}

enum PrepTool: String, Identifiable {
    case tools, practice, interview
    var id: String { rawValue }
}

/// Practice beyond the behavioral workflow: job-specific mock interviews, technical exercises and
/// recording with transcription.
@MainActor
struct PrepToolsSheet: View {
    @State private var showInterview = false
    @State private var showPractice = false
    @State private var showRecording = false

    var body: some View {
        SheetPage(title: "Practice tools") {
            OptionRow(label: "Mock interview", icon: "chat", detail: "For a role you saved") { showInterview = true }.reveal(0)
            OptionRow(label: "Technical practice", icon: "code", detail: "Exercises, tests and coaching", oat: true) { showPractice = true }.reveal(1)
            OptionRow(label: "Record and transcribe", icon: "mic", detail: "Review spoken answers as text") { showRecording = true }.reveal(2)
        }
        .sheet(isPresented: $showInterview) { InterviewSheetHost() }
        .sheet(isPresented: $showPractice) { PracticeSheetHost() }
        .sheet(isPresented: $showRecording) { RecordingSheetHost() }
    }
}

private struct InterviewSheetHost: View {
    @Environment(AppStore.self) private var store
    var body: some View { InterviewView().environment(store) }
}

private struct PracticeSheetHost: View {
    @Environment(AppStore.self) private var store
    var body: some View { PracticeView().environment(store) }
}

private struct RecordingSheetHost: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        SheetPage(title: "Record and transcribe") { TranscriptionPanel() }.environment(store)
    }
}

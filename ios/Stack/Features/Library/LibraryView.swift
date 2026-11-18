import AVKit
import SwiftUI

/// Practice interview library: industry, track, question slots, the AI interviewer, a recorded
/// video answer, and scored coaching. Each slot opens on its highest-scoring answer.
@MainActor
struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var model = LibraryModel()
    @State private var confirmDelete: PracticeAttempt?
    private enum ReviewExit { case close, back }
    @State private var reviewExit: ReviewExit?

    var body: some View {
        SheetPage(title: title, subtitle: subtitle, closeDisabled: model.recordingActive || (model.page == .review && model.busy), onClose: close) {
            Stage(key: model.page) {
                VStack(alignment: .leading, spacing: Spacing.stack) {
                    if ![.loading, .industry].contains(model.page) {
                        BackButton(label: "Back", disabled: model.busy || model.recordingActive) {
                            if model.page == .review { reviewExit = .back }
                            else { Task { await model.back() } }
                        }
                    }
                    content
                    MessageLine(text: model.error.isEmpty ? model.recorder.error : model.error)
                        .fadeSwitch(!(model.error.isEmpty && model.recorder.error.isEmpty))
                    MessageLine(text: model.recorder.stopNotice, isError: false).fadeSwitch(!model.recorder.stopNotice.isEmpty)
                    Text("Working…").font(Typeface.caption).foregroundStyle(Palette.muted).fadeSwitch(model.busy)
                }
            }
        }
        .task {
            model.bind(store)
            await model.load()
        }
        .task(id: model.needsPolling) {
            guard model.needsPolling else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await model.poll()
            }
        }
        .onDisappear { model.suspend() }
        .confirmationDialog("Discard this recording?", isPresented: Binding(get: { reviewExit != nil },
                            set: { if !$0 { reviewExit = nil } }), titleVisibility: .visible, presenting: reviewExit) { exit in
            Button("Discard recording", role: .destructive) {
                Task {
                    if exit == .back { await model.back() }
                    else { await model.discardAnswer(); dismiss() }
                }
            }
            Button("Keep reviewing", role: .cancel) {}
        } message: { _ in
            Text("This removes the recording and its draft transcript.")
        }
        .confirmationDialog("Delete this answer?", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { target in
            Button("Delete video and score", role: .destructive) { Task { await model.delete(target) } }
        } message: { _ in
            Text("This removes the video from this phone and the transcript and score from your account.")
        }
    }

    private var title: String {
        switch model.page {
        case .loading, .industry: return "Practice interview"
        case .track: return "Choose a track"
        case .slots: return "Questions"
        case .slot: return model.question?.title ?? "Question"
        case .attempts: return "All answers"
        case .attempt: return "Your answer"
        case .interviewer: return "Get ready"
        case .recording: return "Recording"
        case .review: return "Review your answer"
        case .scoring: return "Answer feedback"
        }
    }

    private var subtitle: String {
        switch model.page {
        case .industry: return "Choose an industry for your practice questions."
        case .track: return model.industryLabel
        case .slots: return "\(model.industryLabel) · Behavioral"
        case .attempts: return model.question?.title ?? ""
        default: return ""
        }
    }

    private func close() {
        guard !model.recordingActive else { return }
        if model.page == .review { reviewExit = .close; return }
        model.suspend()
        dismiss()
    }

    @ViewBuilder
    private var content: some View {
        switch model.page {
        case .loading: ProgressView("Loading questions…").frame(maxWidth: .infinity)
        case .industry: industryPicker
        case .track: trackPicker
        case .slots: slotList
        case .slot: slotDetail
        case .attempts: attemptList
        case .attempt: attemptDetail
        case .interviewer: interviewerPage
        case .recording: recordingPage
        case .review: reviewPage
        case .scoring: scoringPage
        }
    }

    // MARK: Setup

    private var industryPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.option) {
            if model.industries.isEmpty && !model.busy {
                EmptyNote(icon: "library", title: "No industries available")
                StackButton(label: "Reload industries", kind: .secondary) { Task { await model.load() } }
            }
            ForEach(Array(model.industries.enumerated()), id: \.element.id) { index, choice in
                OptionRow(label: choice.label, icon: "industry", oat: choice.id == model.industry, disabled: model.busy) {
                    Task { await model.chooseIndustry(choice.id) }
                }
                .reveal(index)
            }
        }
    }

    private var trackPicker: some View {
        VStack(alignment: .leading, spacing: Spacing.option) {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { index, track in
                OptionRow(label: track.label, icon: track.id == "technical" ? "code" : "chat",
                          detail: track.available ? "Questions every interviewer asks" : "Coming soon",
                          disabled: model.busy || !track.available) {
                    Task { await model.chooseTrack(track) }
                }
                .reveal(index)
            }
            Button("Change industry (\(model.industryLabel))") { model.page = .industry }
                .font(.subheadline.weight(.medium)).foregroundStyle(Brand.accent).frame(minHeight: 44)
        }
    }

    private var slotList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.slots.isEmpty {
                EmptyNote(icon: "question-file", title: "No questions in this track")
            }
            ForEach(Array(model.slots.enumerated()), id: \.element.id) { index, slot in
                ListRow(label: slot.question.title, detail: slotDetailText(slot), action: { model.openSlot(slot) }) {
                    ScoreBadge(attempt: slot.best)
                }
                .reveal(min(index, 8))
            }
        }
    }

    private func slotDetailText(_ slot: PracticeSlot) -> String {
        let count = slot.attemptCount
        return count == 0 ? slot.question.topic : "\(count) \(count == 1 ? "answer" : "answers")"
    }

    // MARK: Slot

    private var slotDetail: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let question = model.question { QuestionHeader(question: question) }
            if let best = model.attempt {
                SectionLabel(text: "Your best answer")
                Button { model.view(best) } label: {
                    AttemptSummary(attempt: best, video: model.localVideo(best))
                }
                .buttonStyle(.tap(scale: 0.99))
                .accessibilityHint("Opens your best answer.")
                StackButton(label: "All answers", icon: "clock", kind: .secondary, disabled: model.busy) { Task { await model.showAttempts() } }
            }
            Toggle("Have the interviewer ask the question", isOn: $model.useInterviewer)
                .font(Typeface.body).tint(Brand.accent)
            StackButton(label: model.attempt == nil ? "Practice this question" : "Record a new answer", icon: "video",
                        disabled: model.busy) { Task { await model.practice() } }
        }
    }

    private var attemptList: some View {
        VStack(alignment: .leading, spacing: Spacing.option) {
            Text(model.attempts.isEmpty ? "No saved answers yet." : "Highest score first")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(model.attempts.enumerated()), id: \.element.id) { index, attempt in
                Button { model.view(attempt) } label: {
                    AttemptSummary(attempt: attempt, video: model.localVideo(attempt), rank: index + 1)
                }
                .buttonStyle(.tap(scale: 0.98))
                .reveal(min(index, 8))
            }
        }
    }

    private var attemptDetail: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let attempt = model.attempt {
                if let url = model.localVideo(attempt) {
                    AnswerVideoPlayer(url: url)
                } else {
                    Card(tint: Palette.oat, spacing: 6) {
                        Text("Video not on this phone").font(Typeface.option).foregroundStyle(Palette.icon)
                        Text("Videos stay on the phone that recorded them. Your transcript and score are still here.")
                            .font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
                ScoreCard(attempt: attempt)
                if attempt.isStalled || attempt.status == "unscored" {
                    StackButton(label: "Score again", icon: "refresh", kind: .secondary, disabled: model.busy || attempt.runID.isEmpty) {
                        Task { await model.retryScoring() }
                    }
                }
                DisclosureSection("Your answer transcript") {
                    Text(attempt.transcript).font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
                }
                StackButton(label: "Record a new answer", icon: "video", disabled: model.busy) { Task { await model.practice() } }
                Button(role: .destructive) { confirmDelete = attempt } label: {
                    Label("Delete this answer", systemImage: "trash").font(Typeface.body)
                }
                .foregroundStyle(Palette.danger)
                .disabled(model.busy)
            }
        }
    }

    // MARK: Interviewer and recording

    private var interviewerPage: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if model.useInterviewer {
                InterviewerCard(speaking: model.interviewer.isSpeaking)
            }
            if let question = model.question {
                Text(question.prompt).font(Typeface.section).foregroundStyle(Palette.ink).reveal(1)
                if !question.hints.isEmpty {
                    Text(question.hints.joined(separator: " ")).font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            preview
            if model.useInterviewer {
                HStack(spacing: 12) {
                    StackButton(label: "Replay", icon: "speaker", kind: .secondary, disabled: model.interviewer.isSpeaking) { model.replay() }
                    StackButton(label: "Skip interviewer", kind: .secondary) { model.skipInterviewer() }
                }
                Toggle("Start recording when the question ends", isOn: $model.autoRecord).font(Typeface.caption).tint(Brand.accent)
            }
            StackButton(label: "Record answer", icon: "video", disabled: model.recorder.phase != .ready) {
                Task { await model.startRecording() }
            }
            permissionNotes
        }
    }

    @ViewBuilder
    private var preview: some View {
        if model.recorder.hasVideo, [.ready, .recording, .finishing].contains(model.recorder.phase) {
            CameraPreview(session: model.recorder.session)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if model.recorder.isRecording {
                        Label(timer(model.recorder.elapsed), systemImage: "record.circle")
                            .font(Typeface.caption.monospacedDigit()).foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.black.opacity(0.75), in: Capsule()).padding(12)
                    }
                }
        } else if model.recorder.phase == .preparing {
            ProgressView("Starting camera…").frame(maxWidth: .infinity, minHeight: 120)
        }
    }

    @ViewBuilder
    private var permissionNotes: some View {
        if !model.recorder.cameraFound, !model.recorder.cameraDenied {
            Text("No camera is available, so this answer records audio only.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
        if model.recorder.cameraDenied, !model.recorder.microphoneDenied {
            Text("Camera access is off, so this answer records audio only. You can allow the camera in Settings.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
        if model.recorder.cameraDenied || model.recorder.microphoneDenied {
            StackButton(label: "Open Settings", kind: .secondary) { AppSettings.open() }
        }
    }

    private var recordingPage: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let question = model.question { Text(question.prompt).font(Typeface.body).foregroundStyle(Palette.text) }
            preview
            if !model.recorder.hasVideo {
                Halo(active: true, size: 96) { GlyphView(name: "mic", size: 30) }.frame(maxWidth: .infinity)
                Text(timer(model.recorder.elapsed)).font(Typeface.title.monospacedDigit()).frame(maxWidth: .infinity)
            }
            Text("Up to \(Int(VideoLibraryStore.maximumSeconds / 60)) minutes. Aim for about two.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Stop and review", icon: "check", disabled: model.recorder.phase != .recording) {
                Task { await model.stopRecording() }
            }
        }
    }

    // MARK: Review and scoring

    private var reviewPage: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if let url = model.videoURL { AnswerVideoPlayer(url: url) }
            SectionLabel(text: "Review your transcript")
            if model.transcribing {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(model.recording["status"].string == "processing" ? "Transcribing your answer…" : "Waiting for transcription…")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            } else if model.recording["status"].string == "failed" {
                Text("Transcription failed. Retry, or type your answer below.").font(Typeface.caption).foregroundStyle(Palette.danger)
                StackButton(label: "Retry transcription", icon: "refresh", kind: .secondary, disabled: model.busy) { Task { await model.retryTranscription() } }
            } else if model.recording.object.isEmpty, !model.busy {
                StackButton(label: "Retry upload", icon: "upload", kind: .secondary) { Task { await model.uploadAudio() } }
            }
            if model.transcriptionUnavailable {
                Text("Automatic transcription is unavailable right now. Type what you said to get a score.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            StackField(label: "Transcript", text: Binding(get: { model.draft }, set: { model.edited($0) }), multiline: true)
            Text("Coaching uses the edited transcript. Your video stays on this phone.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Get score and feedback", icon: "sparkles", disabled: model.busy || model.draft.isBlank) {
                Task { await model.score() }
            }
            StackButton(label: "Discard and record again", kind: .secondary, disabled: model.busy) {
                Task { await model.discardAnswer(); await model.practice() }
            }
        }
    }

    private var scoringPage: some View {
        VStack(alignment: .leading, spacing: Spacing.group) {
            if model.attempt?.isStalled == true {
                Label("Scoring paused", systemImage: "pause.circle").font(Typeface.title).foregroundStyle(Palette.ink)
            } else {
                HStack(spacing: 12) {
                    ProgressView().tint(Brand.accent)
                    Text("Scoring your answer…").font(Typeface.section).foregroundStyle(Palette.ink)
                }
            }
            if let message = model.attempt?.runMessage, !message.isEmpty {
                Text(message).font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if let attempt = model.attempt, attempt.isStalled {
                StackButton(label: "Retry scoring", icon: "refresh", disabled: model.busy) { Task { await model.retryScoring() } }
            }
            StackButton(label: "Back to question", kind: .secondary) { Task { await model.back() } }
        }
    }

    private func timer(_ seconds: TimeInterval) -> String {
        String(format: "%d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}

// MARK: - Components

private struct QuestionHeader: View {
    let question: PracticeQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.topic).font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            Text(question.prompt).font(Typeface.section).foregroundStyle(Palette.ink)
        }
    }
}

struct ScoreBadge: View {
    let attempt: PracticeAttempt?

    var body: some View {
        let scored = attempt?.score != nil
        Text(PracticeScore.label(attempt))
            .font(scored ? Typeface.button.monospacedDigit().weight(.semibold) : Typeface.caption)
            .foregroundStyle(scored ? Brand.accent : Palette.muted)
            .padding(.horizontal, scored ? 12 : 0)
            .padding(.vertical, scored ? 6 : 0)
            .background(scored ? Palette.halo : .clear, in: Capsule())
            .accessibilityLabel(scored ? "Score \(attempt?.score ?? 0) of 100" : PracticeScore.label(attempt))
    }
}

private struct AttemptSummary: View {
    let attempt: PracticeAttempt
    let video: URL?
    var rank = 0

    var body: some View {
        Card(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(rank > 0 ? "#\(rank) · \(dateTime(attempt.createdAt))" : dateTime(attempt.createdAt))
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    Text(video == nil ? "Transcript only on this phone" : "Video · \(Int(attempt.duration))s")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                Spacer()
                ScoreBadge(attempt: attempt)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
            }
            Text(attempt.transcript).font(Typeface.body).foregroundStyle(Palette.text).lineLimit(3).multilineTextAlignment(.leading)
        }
    }
}

private struct ScoreCard: View {
    let attempt: PracticeAttempt

    var body: some View {
        Card(tint: Palette.surfaceRaised, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(attempt.score.map(String.init) ?? "–").font(.largeTitle.weight(.bold).monospacedDigit()).foregroundStyle(Palette.ink)
                Text("/ 100").font(Typeface.caption).foregroundStyle(Palette.muted)
                Spacer()
                Text(attempt.status == "unscored" ? "Feedback only" : "Score").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(PracticeAttempt.criteria, id: \.self) { name in
                if let value = attempt.rubric[name] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(PracticeScore.criterion(name)).font(Typeface.caption).foregroundStyle(Palette.text)
                            Spacer()
                            Text("\(Int(value))/4").font(Typeface.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                        }
                        ProgressView(value: value, total: 4).tint(Brand.accent)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !attempt.feedback.isEmpty {
                Text(attempt.feedback).font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
            }
            Text("Scores are your coach's judgment of this answer, not a certification.")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
    }
}

/// Plays a locally saved answer.
struct AnswerVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: Spacing.cardRadius, style: .continuous))
            .onAppear { if player == nil { player = AVPlayer(url: url) } }
            .onDisappear { player?.pause() }
            .accessibilityLabel("Your recorded answer")
    }
}

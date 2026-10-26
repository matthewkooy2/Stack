import SwiftUI

/// Record an answer, send it to the transcription worker, review and correct the transcript.
/// Used by mock interviews; `onUse` hands a reviewed transcript back to the caller.
@MainActor
struct TranscriptionPanel: View {
    var onUse: ((String, String) -> Void)?
    var disabled = false
    var questionNumber = 1
    var questionCount = 1
    var prompt = "Record your answer."

    @Environment(AppStore.self) private var store

    @State private var recorder = AudioRecorder()
    @State private var recordings: [JSON] = []
    @State private var phoneRecordings: [CapturedRecording] = []
    @State private var runtime: JSON = [:]
    @State private var supportsClientTranscripts: Bool?
    @State private var current: JSON = [:]
    @State private var text = ""
    @State private var dirty = false
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @State private var pendingUpload: CapturedRecording?
    @State private var showRecordingSurface = false
    @State private var deleting = false
    @State private var boundGeneration: Int?
    @State private var recordingOwner = ""

    private var owner: String { store.account.userID }
    private var status: String { current["status"].string }
    private var transcribing: Bool { ["queued", "decoding", "loading", "transcribing"].contains(status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(tint: Palette.oat, spacing: 12) {
                Text("Record an answer").font(Typeface.option).foregroundStyle(Palette.icon)
                Text("Speak in English for up to five minutes. Review and correct the transcript before using it.")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
                Text(runtime["status"].string == "ready" ? "Transcription ready." :
                        (runtime["message"].string.isEmpty ? "Checking transcription…" : runtime["message"].string))
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                if runtime["status"].string == "unavailable" {
                    StackButton(label: "Retry setup", kind: .secondary) { Task { await retrySetup() } }
                }
                if recorder.isRecording {
                    StackButton(label: "Return to recording", icon: "mic") { showRecordingSurface = true }
                } else {
                    StackButton(label: "Record", icon: "mic", disabled: busy || dirty || disabled || recorder.finalizing || pendingUpload != nil) { Task { await record() } }
                }
                Text("Your recording stays on this phone until you delete it. Leaving this screen or locking your phone stops recording.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            MessageLine(text: error.isEmpty ? recorder.error : error).fadeSwitch(!(error.isEmpty && recorder.error.isEmpty))
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: recorder.stopNotice, isError: false).fadeSwitch(!recorder.stopNotice.isEmpty)
            if recorder.permissionDenied {
                StackButton(label: "Open microphone settings", kind: .secondary) { AppSettings.open() }
                Text("After allowing microphone access, return and tap Record. You can also type your answer.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if let pending = pendingUpload {
                StackButton(label: "Sync saved recording", disabled: busy) { Task { await upload(pending) } }
            }
            if !recordings.isEmpty {
                SectionLabel(text: "Saved recordings")
                ForEach(Array(recordings.enumerated()), id: \.offset) { _, row in
                    Chip(label: "\(row["status"].string.capitalized) · \(Int(row["duration_seconds"].double.rounded())) seconds") {
                        Task { await open(row["id"].string) }
                    }
                }
            }
            if !phoneRecordings.isEmpty {
                SectionLabel(text: "Saved on this phone")
                ForEach(phoneRecordings, id: \.clientID) { saved in
                    Chip(label: RecordingStore.transcript(at: saved.url) == nil ? "Saved audio" : "Phone transcript") {
                        guard !busy, !dirty, !recorder.isRecording else { return }
                        recordingOwner = owner; pendingUpload = saved
                        if let phone = RecordingStore.transcript(at: saved.url) {
                            current = ["id": .string(saved.clientID), "phone_only": true, "status": "completed",
                                       "original_transcript": .string(phone.original), "transcript": .string(phone.text), "revision": .number(Double(phone.revision))]
                            text = phone.text
                        } else {
                            current = ["id": .string(saved.clientID), "phone_only": true, "status": "saved"]
                            text = ""
                        }
                    }
                }
            }
            if !current.object.isEmpty { detail }
        }
        .task { await refresh() }
        .task(id: current["id"].string + status) {
            while !Task.isCancelled, transcribing {
                try? await Task.sleep(for: .seconds(2.5))
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .onDisappear { if !showRecordingSurface { suspendRecording() } }
        .fullScreenCover(isPresented: $showRecordingSurface) {
            GeometryReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.stack) {
                        RecordingSurface(recorder: recorder, questionNumber: questionNumber,
                                         questionCount: questionCount, prompt: prompt, busy: busy,
                                         onStop: { Task { await stop(cancelled: false) } },
                                         onTogglePause: { togglePause() })
                        MessageLine(text: recorder.error).fadeSwitch(!recorder.error.isEmpty)
                    }
                    .padding(Spacing.page)
                    .frame(minHeight: proxy.size.height, alignment: .topLeading)
                }
                .scrollIndicators(.hidden)
                .background(Palette.page.ignoresSafeArea())
            }
            .interactiveDismissDisabled()
            .onDisappear { if recorder.isRecording { suspendRecording() } }
        }
        .onAppear {
            if boundGeneration == nil { boundGeneration = store.sessionGeneration }
            recorder.onAutoStop = { saved in
                showRecordingSurface = false
                pendingUpload = saved
                Task { @MainActor in await upload(saved) }
            }
        }
        .confirmationDialog("Delete this recording and transcript?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await change("delete") } }
        }
    }

    // MARK: Detail

    private var detail: some View {
        Card(spacing: 10) {
            let percent = current["percent"]
            Text((current["phone_finalizing"].bool ? "Finishing your transcript" : status.capitalized)
                 + (percent.isNull ? "" : " · \(Int(percent.double.rounded()))%"))
                .font(Typeface.option).foregroundStyle(Palette.icon)
            if current["phone_finalizing"].bool {
                Text("Your recording and live transcript are saved on this phone while on-device recognition finishes.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            } else if current["phone_preview"].bool {
                Text("On-device recognition did not finish. Your audio and transcript preview are saved on this phone.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if transcribing {
                Text("Working on your transcript…").font(Typeface.caption).foregroundStyle(Palette.muted).breathe(true)
            }
            if !current["error"].string.isEmpty { MessageLine(text: current["error"].string) }
            if status == "completed" {
                StackField(label: "Transcript", text: Binding(get: { text }, set: {
                    text = $0; dirty = true
                    if let saved = pendingUpload {
                        do { try RecordingStore.editTranscript(text, at: saved.url) }
                        catch { self.error = error.localizedDescription }
                    }
                }), multiline: true)
                StackButton(label: dirty ? "Save transcript" : "Transcript saved", kind: .secondary, disabled: busy || !dirty) {
                    Task { await change("save") }
                }
                if let onUse {
                    StackButton(label: "Use this transcript", icon: "check", disabled: busy || dirty || disabled || text.isBlank || current["phone_only"].bool) {
                        onUse(text, current["id"].string)
                    }
                }
                Text("Original: \(current["original_transcript"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if ["failed", "cancelled"].contains(status) {
                StackButton(label: "Retry transcription", kind: .secondary, disabled: busy) { Task { await change("retry") } }
            }
            if transcribing {
                StackButton(label: "Cancel transcription", kind: .secondary, disabled: busy) { Task { await change("cancel") } }
            }
            Chip(label: "Delete recording and transcript") { deleting = true }
        }
    }

    // MARK: Actions

    private func refresh(afterRecordingSync: Bool = false) async {
        if boundGeneration == nil { boundGeneration = store.sessionGeneration }
        do {
            try requireSession()
            phoneRecordings = RecordingStore.pending(owner: owner)
            let list = try await sessionCall("transcription_list")
            recordings = list["recordings"].array
            runtime = list["runtime"]
            supportsClientTranscripts = list["client_transcripts"].bool
            let id = current["id"].string
            if !id.isEmpty, !busy, !current["phone_only"].bool {
                let latest = try await sessionCall("transcription_get", ["id": .string(id)])
                guard id == current["id"].string else { return }
                current = latest
                if !dirty { text = latest["transcript"].string }
            }
        } catch {
            guard !(error is CancellationError) else { return }
            if afterRecordingSync {
                self.error = "Recording synced, but refreshing its status failed (\(failureCategory(error))).\(failureDetail(error))"
            } else {
                self.error = error.localizedDescription
            }
        }
    }

    private func retrySetup() async {
        do { runtime = try await sessionCall("transcription_retry_setup"); error = "" }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func record() async {
        guard !busy, boundGeneration == store.sessionGeneration else { return }
        recordingOwner = owner
        busy = true
        error = ""
        notice = ""
        defer { busy = false }
        do {
            _ = try await recorder.start(owner: recordingOwner)
            guard boundGeneration == store.sessionGeneration, recordingOwner == owner else {
                _ = recorder.stop(cancelled: true); throw CancellationError()
            }
            showRecordingSurface = true
        }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func stop(cancelled: Bool) async {
        guard !busy, let saved = recorder.stop(cancelled: cancelled) else { return }
        showRecordingSurface = false
        if cancelled {
            await saved.finalized.value
            guard boundGeneration == store.sessionGeneration else { return }
            phoneRecordings = RecordingStore.pending(owner: owner)
            notice = "Recording cancelled. The partial audio stays on this phone."
            return
        }
        pendingUpload = saved
        showPhoneTranscript(saved)
        await upload(saved)
    }

    private func suspendRecording() {
        // Stop synchronously even while microphone permission is pending.
        guard let saved = recorder.stop(reason: "Recording stopped when you left the recording screen or locked your phone. Audio was kept.") else { return }
        showRecordingSurface = false
        pendingUpload = saved
        if !busy { Task { await upload(saved) } }
    }

    private func togglePause() {
        guard !busy else { return }
        if recorder.isPaused {
            do { try recorder.resume() }
            catch { recorder.error = error.localizedDescription }
        } else { recorder.pause() }
    }

    private func upload(_ saved: CapturedRecording) async {
        guard !busy, boundGeneration == store.sessionGeneration, recordingOwner == owner, !owner.isEmpty else { return }
        busy = true
        error = ""
        defer { busy = false }
        var stage = "finishing the on-device transcript"
        var uploadConfirmed = false
        do {
            await saved.finalized.value
            try requireSession()
            pendingUpload = saved
            let phone = RecordingStore.transcript(at: saved.url)
            if let phone { showPhoneTranscript(saved, phone: phone) }
            stage = "reading the saved audio"
            let data = try Data(contentsOf: saved.url)
            guard !data.isEmpty else {
                throw APIError(message: "This recording has no saved audio. Record another answer.",
                               failureCategory: "local audio validation")
            }
            guard data.count <= 10 * 1024 * 1024 else {
                throw APIError(message: "Recording must be 10 MB or less.", failureCategory: "local audio validation")
            }
            var args: JSON = ["client_id": .string(saved.clientID), "content": .string(data.base64EncodedString())]
            if let phone, phone.isFinal {
                let supported: Bool
                if let cached = supportsClientTranscripts {
                    supported = cached
                } else {
                    stage = "checking transcript sync support"
                    let capability = try await sessionCall("transcription_list")
                    supported = capability["client_transcripts"].bool
                    supportsClientTranscripts = supported
                }
                guard supported else {
                    throw APIError(message: "Transcript saved on this phone. Server sync needs the transcription update.",
                                   failureCategory: "server capability")
                }
                args["local_transcript"] = .string(phone.original)
            }
            stage = "uploading audio"
            var result = try await sessionCall("transcription_upload", args, timeout: 90)
            uploadConfirmed = true
            if phone?.isFinal == true, result["status"].string == "completed", result["transcript"].string != text {
                if let prior = phone?.syncedText, prior != result["transcript"].string {
                    current = result; dirty = true
                    stage = "reconciling transcript edits"
                    throw APIError(message: "The server transcript changed. Your phone edits are retained. Review them before saving.",
                                   failureCategory: "transcript conflict")
                }
                stage = "saving transcript edits on Stack"
                result = try await sessionCall("transcription_action", ["id": result["id"], "action": "save", "text": .string(text), "revision": result["revision"]])
            }
            stage = "saving sync status on this phone"
            try RecordingStore.markSynced(result["id"].string, text: result["transcript"].string, at: saved.url)
            // Save edits made while network requests were in flight to the phone as well.
            if phone != nil {
                stage = "saving transcript edits on this phone"
                try RecordingStore.editTranscript(text, at: saved.url)
            }
            pendingUpload = nil
            current = result
            if !dirty { text = result["transcript"].string }
            dirty = text != result["transcript"].string
            notice = phone?.isFinal == true ? "Audio and on-device transcript saved." : "Audio saved. Transcription continues if you close Stack."
            await refresh(afterRecordingSync: true)
        } catch {
            guard boundGeneration == store.sessionGeneration else { return }
            pendingUpload = saved
            guard !(error is CancellationError) else { return }
            let category = failureCategory(error)
            let detail = failureDetail(error)
            if category == "transcript conflict" {
                self.error = detail.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            if uploadConfirmed {
                self.error = "Audio is uploaded, but \(stage) failed (\(category)). The phone copy is retained; retry sync to reconcile.\(detail)"
            } else if stage == "uploading audio", (error as? APIError)?.failureCategory != nil {
                self.error = "Stack did not confirm the audio upload (\(category)). The recording remains saved on this phone; retry sync is safe."
            } else {
                self.error = "Could not complete sync while \(stage) (\(category)). The recording remains saved on this phone; retry sync.\(detail)"
            }
        }
    }

    private func failureCategory(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return "local operation" }
        if let category = apiError.failureCategory { return category }
        if apiError.status > 0 { return "HTTP \(apiError.status)" }
        return "Stack API error"
    }

    private func failureDetail(_ error: Error) -> String {
        guard let apiError = error as? APIError else { return "" }
        if apiError.failureCategory?.hasPrefix("network ") == true
            || apiError.failureCategory == "offline"
            || apiError.failureCategory == "host lookup failure"
            || apiError.failureCategory == "host connection failure"
            || apiError.failureCategory == "connection lost"
            || apiError.failureCategory == "TLS failure" {
            return ""
        }
        return " \(apiError.message)"
    }

    private func showPhoneTranscript(_ saved: CapturedRecording, phone: PhoneTranscript? = nil) {
        guard let phone = phone ?? RecordingStore.transcript(at: saved.url) else { return }
        let sameRecording = current["id"].string == saved.clientID
        let isEditing = sameRecording && dirty
        current = ["id": .string(saved.clientID), "phone_only": true, "status": "completed",
                   "phone_finalizing": .bool(!phone.isFinal && recorder.finalizing),
                   "phone_preview": .bool(!phone.isFinal),
                   "original_transcript": .string(phone.original), "transcript": .string(phone.text),
                   "revision": .number(Double(phone.revision))]
        if !isEditing { text = phone.text; dirty = false }
    }

    private func open(_ id: String) async {
        guard !busy, pendingUpload == nil else { return }
        guard !dirty else {
            error = "Save your transcript changes before opening another recording."
            return
        }
        do {
            current = try await sessionCall("transcription_get", ["id": .string(id)])
            text = current["transcript"].string
            error = ""
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func change(_ action: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        let id = current["id"].string
        do {
            if current["phone_only"].bool, action == "delete", let saved = pendingUpload {
                try requireSession()
                try RecordingStore.delete(owner: owner, clientID: saved.clientID)
                pendingUpload = nil; current = [:]; text = ""; dirty = false
                await refresh(); return
            }
            if current["phone_only"].bool, action == "save", let saved = pendingUpload {
                try requireSession()
                try RecordingStore.editTranscript(text, at: saved.url)
                current["transcript"] = .string(text); dirty = false
                notice = "Transcript saved on this phone. Sync when connected."
                return
            }
            let submitted = text
            let result = try await sessionCall("transcription_action", [
                "id": .string(id), "action": .string(action), "text": .string(text), "revision": current["revision"],
            ])
            if action == "delete" {
                let localID = current["client_id"].string
                if !localID.isEmpty { try RecordingStore.delete(owner: owner, clientID: localID) }
                current = [:]
                text = ""
                dirty = false
            } else {
                current = result
                if action == "save" {
                    if let url = RecordingStore.exists(owner: owner, clientID: current["client_id"].string) {
                        try RecordingStore.editTranscript(text, at: url)
                        try RecordingStore.markSynced(current["id"].string, text: result["transcript"].string, at: url)
                    }
                    if text == submitted { text = result["transcript"].string; dirty = false }
                    if !dirty { pendingUpload = nil }
                    notice = "Transcript saved. The original transcription is retained."
                }
            }
            await refresh()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func requireSession() throws {
        guard boundGeneration == store.sessionGeneration, store.phase == .ready else { throw CancellationError() }
    }

    private func sessionCall(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25) async throws -> JSON {
        try requireSession()
        let result = try await store.call(name, args, timeout: timeout)
        try requireSession()
        return result
    }
}

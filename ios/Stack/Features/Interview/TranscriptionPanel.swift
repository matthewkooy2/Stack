import SwiftUI

/// Record an answer, send it to the transcription worker, review and correct the transcript.
/// Used by mock interviews; `onUse` hands a reviewed transcript back to the caller.
@MainActor
struct TranscriptionPanel: View {
    var onUse: ((String, String) -> Void)?
    var disabled = false

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var recorder = AudioRecorder()
    @State private var recordings: [JSON] = []
    @State private var runtime: JSON = [:]
    @State private var current: JSON = [:]
    @State private var text = ""
    @State private var dirty = false
    @State private var busy = false
    @State private var error = ""
    @State private var notice = ""
    @State private var pendingUpload: (clientID: String, url: URL)?
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
                HStack(spacing: 14) {
                    Halo(active: recorder.isRecording && !recorder.isPaused, size: 56) { GlyphView(name: "mic", size: 24) }
                    Text(recordingClock(recorder.elapsed))
                        .font(.system(.title2).weight(.bold).monospacedDigit()).foregroundStyle(Palette.ink)
                }
                if recorder.isRecording {
                    StackButton(label: "Stop and transcribe", disabled: busy) { Task { await stop(cancelled: false) } }
                    StackButton(label: "Cancel recording", kind: .secondary, disabled: busy) { Task { await stop(cancelled: true) } }
                } else {
                    StackButton(label: "Record", icon: "mic", disabled: busy || dirty || disabled) { Task { await record() } }
                }
                Text("Your recording stays on this phone until you delete it. Leaving this screen or locking your phone stops recording.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            MessageLine(text: error.isEmpty ? recorder.error : error).fadeSwitch(!(error.isEmpty && recorder.error.isEmpty))
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            if let pending = pendingUpload {
                StackButton(label: "Upload saved recording", disabled: busy) { Task { await upload(pending.clientID, pending.url) } }
            }
            if !recordings.isEmpty {
                SectionLabel(text: "Saved recordings")
                ForEach(Array(recordings.enumerated()), id: \.offset) { _, row in
                    Chip(label: "\(row["status"].string.capitalized) · \(Int(row["duration_seconds"].double.rounded())) seconds") {
                        Task { await open(row["id"].string) }
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
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { suspendRecording() }
        }
        .onDisappear { suspendRecording() }
        .onAppear {
            if boundGeneration == nil { boundGeneration = store.sessionGeneration }
            recorder.onAutoStop = { clientID, url in
                Task { @MainActor in await upload(clientID, url) }
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
            Text(status.capitalized + (percent.isNull ? "" : " · \(Int(percent.double.rounded()))%"))
                .font(Typeface.option).foregroundStyle(Palette.icon)
            if transcribing {
                Text("Working on your transcript…").font(Typeface.caption).foregroundStyle(Palette.muted).breathe(true)
            }
            if !current["error"].string.isEmpty { MessageLine(text: current["error"].string) }
            if status == "completed" {
                StackField(label: "Transcript", text: Binding(get: { text }, set: { text = $0; dirty = true }), multiline: true)
                StackButton(label: dirty ? "Save transcript" : "Transcript saved", kind: .secondary, disabled: busy || !dirty) {
                    Task { await change("save") }
                }
                if let onUse {
                    StackButton(label: "Use this transcript", icon: "check", disabled: busy || dirty || disabled || text.isBlank) {
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

    private func refresh() async {
        do {
            let list = try await store.call("transcription_list")
            recordings = list["recordings"].array
            runtime = list["runtime"]
            let id = current["id"].string
            if !id.isEmpty, !busy {
                let latest = try await store.call("transcription_get", ["id": .string(id)])
                current = latest
                if !dirty { text = latest["transcript"].string }
            }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func retrySetup() async {
        do { runtime = try await store.call("transcription_retry_setup"); error = "" }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func record() async {
        guard !busy, boundGeneration == store.sessionGeneration else { return }
        recordingOwner = owner
        busy = true
        error = ""
        notice = ""
        defer { busy = false }
        do { _ = try await recorder.start(owner: recordingOwner) }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func stop(cancelled: Bool) async {
        guard let saved = recorder.stop() else { return }
        if cancelled {
            notice = "Recording cancelled. The partial audio stays on this phone."
            return
        }
        await upload(saved.clientID, saved.url)
    }

    private func suspendRecording() {
        // Stop synchronously even while microphone permission is pending.
        guard let saved = recorder.stop() else { return }
        pendingUpload = (saved.clientID, saved.url)
        if !busy { Task { await upload(saved.clientID, saved.url) } }
    }

    private func upload(_ clientID: String, _ url: URL) async {
        guard boundGeneration == store.sessionGeneration, recordingOwner == owner, !owner.isEmpty else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let data = try Data(contentsOf: url)
            guard !data.isEmpty else { throw APIError(message: "This recording has no saved audio. Record another answer.") }
            guard data.count <= 10 * 1024 * 1024 else { throw APIError(message: "Recording must be 10 MB or less.") }
            let result = try await store.call("transcription_upload",
                                              ["client_id": .string(clientID), "content": .string(data.base64EncodedString())],
                                              timeout: 90)
            pendingUpload = nil
            current = result
            text = result["transcript"].string
            dirty = false
            notice = "Audio saved. Transcription continues if you close Stack."
            await refresh()
        } catch {
            guard boundGeneration == store.sessionGeneration else { return }
            pendingUpload = (clientID, url)
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func open(_ id: String) async {
        guard !dirty else {
            error = "Save your transcript changes before opening another recording."
            return
        }
        do {
            current = try await store.call("transcription_get", ["id": .string(id)])
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
            let result = try await store.call("transcription_action", [
                "id": .string(id), "action": .string(action), "text": .string(text), "revision": current["revision"],
            ])
            if action == "delete" {
                current = [:]
                text = ""
                dirty = false
            } else {
                current = result
                if action == "save" {
                    text = result["transcript"].string
                    dirty = false
                    notice = "Transcript saved. The original transcription is retained."
                }
            }
            await refresh()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

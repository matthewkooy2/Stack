import SwiftUI

/// LinkedIn profile review from the PDF a member saves from their own profile. Stack never opens,
/// signs in to or reads LinkedIn; the upload is reviewed by Stack's configured model in one request.
@MainActor
struct LinkedInFlow: View {
    enum Step: Int, StageKey { case upload, reviewing, results; var depth: Int { rawValue } }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(AppStore.self) private var store
    @State private var step: Step = .upload
    @State private var role = ""
    @State private var importing = false
    @State private var uploader = ResumeUploader(read: { url in
        try await readPickedFileInBackground(url, limit: ResumeFiles.limit, tooLarge: LinkedInPDF.tooLarge)
    }, accepts: LinkedInPDF.isPDF, wrongType: LinkedInPDF.wrongType)
    @State private var generation = -1
    /// A review that failed after the PDF was read; Try again reruns it without another upload.
    @State private var failedRun = ""
    @State private var retrying = false
    @State private var error = ""
    @State private var run: JSON = .null

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(label: step == .results ? "Close" : "Back") { back() }
                Spacer()
            }
            .padding(.horizontal, Spacing.page).padding(.top, 8).padding(.bottom, 8)
            Stage(key: step) { content }
                .frame(maxHeight: .infinity)
        }
        .background(Brand.page.ignoresSafeArea())
        .tint(Brand.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            guard store.phase == .ready, generation == store.sessionGeneration, uploader.picked(result) else { return }
            upload()
        }
        .onChange(of: importing) { _, open in if !open { uploader.pickerClosed() } }
        .onChange(of: store.sessionGeneration) { _, _ in dismiss() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .upload:
            LinkedInPDFUploadScreen(
                role: $role,
                busy: uploader.isBusy || retrying,
                progress: retrying ? "Reviewing your profile…" : uploader.progress,
                error: error.isEmpty ? uploader.message : error,
                onChoose: choose,
                onRetry: failedRun.isEmpty ? (uploader.canRetry ? retryUpload : nil) : retryReview)
        case .reviewing:
            PrepWorkingScreen(progress: "LinkedIn", message: "Reviewing your profile…",
                              detail: "This can take up to a minute.", spinner: true)
                .padding(.horizontal, Spacing.page)
        case .results:
            LinkedInReviewScreen(content: LinkedInReviewContent(run["artifacts"]["linkedin_review"]),
                                 role: run["context"]["target_role"].string, taskID: run["id"].string,
                                 onDone: { dismiss() }, onAnother: reset)
        }
    }

    private func choose() {
        error = ""
        failedRun = ""
        generation = store.sessionGeneration
        importing = uploader.begin()
    }

    private func retryUpload() {
        error = ""
        if uploader.retry() { upload() }
    }

    /// Reading the PDF happens before the screen changes; the review wait gets its own screen.
    private func upload() {
        let session = generation
        let target = role.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let finished = await uploader.run { file in
                guard session == store.sessionGeneration, store.phase == .ready else { throw CancellationError() }
                go(.reviewing)
                let result = try await store.call("linkedin_pdf_review", [
                    "name": .string(file.name), "content": .string(file.content), "target_role": .string(target),
                ], timeout: 180)
                try settle(result)
            }
            if !finished, step == .reviewing { go(.upload) }
        }
    }

    private func retryReview() {
        guard !retrying, !failedRun.isEmpty else { return }
        retrying = true
        error = ""
        let id = failedRun
        Task {
            defer { retrying = false }
            do {
                go(.reviewing)
                try settle(try await store.call("agent_retry", ["id": .string(id)], timeout: 180))
            } catch is CancellationError {
                go(.upload)
            } catch {
                self.error = error.localizedDescription
                go(.upload)
            }
        }
    }

    /// A completed review opens the result; a failed one keeps its run so Try again needs no new upload.
    private func settle(_ result: JSON) throws {
        if result["status"].string == "completed" {
            run = result
            failedRun = ""
            go(.results)
            Task { await store.refresh() }
            return
        }
        failedRun = result["id"].string
        let message = result["message"].string
        throw APIError(message: message.isBlank ? "The review did not finish. Try again." : message)
    }

    private func reset() {
        run = .null
        failedRun = ""
        error = ""
        uploader.reset()
        go(.upload)
    }

    private func back() {
        switch step {
        case .upload, .results: dismiss()
        case .reviewing: break
        }
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : Motion.stageAnimation) { step = next }
    }
}

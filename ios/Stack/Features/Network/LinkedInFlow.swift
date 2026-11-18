import SwiftUI

/// LinkedIn profile review from the PDF a member saves from their own profile. Stack never opens,
/// signs in to or reads LinkedIn; the upload is reviewed by the shared model worker.
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
    @State private var reviewID = ""
    @State private var reviewTask: Task<Void, Never>?
    @State private var error = ""
    @State private var run: JSON = .null

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(label: step == .upload ? "Back" : "Close") { dismiss() }
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
        .onDisappear { reviewTask?.cancel() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .upload:
            LinkedInPDFUploadScreen(
                role: $role,
                busy: uploader.isBusy || reviewTask != nil,
                progress: uploader.progress,
                error: error.isEmpty ? uploader.message : error,
                onChoose: choose,
                onRetry: reviewID.isEmpty ? (uploader.canRetry ? retryUpload : nil) : retryReview)
        case .reviewing:
            PrepWorkingScreen(progress: "LinkedIn", message: "Reviewing your profile…",
                              detail: reviewID.isEmpty ? "Sending your PDF…" : "You can leave. Find it in Activity.", spinner: true)
                .padding(.horizontal, Spacing.page)
        case .results:
            LinkedInReviewScreen(content: LinkedInReviewContent(run["artifacts"]["linkedin_review"]),
                                 role: run["context"]["target_role"].string, taskID: run["id"].string,
                                 onDone: { dismiss() }, onAnother: reset)
        }
    }

    private func choose() {
        error = ""
        generation = store.sessionGeneration
        importing = uploader.begin()
    }

    private func retryUpload() {
        error = ""
        if uploader.retry() { upload() }
    }

    private func upload() {
        guard reviewTask == nil else { return }
        reviewID = ""
        let session = generation
        let target = role.trimmingCharacters(in: .whitespacesAndNewlines)
        reviewTask = Task {
            defer { reviewTask = nil }
            var queued: JSON = .null
            let accepted = await uploader.run { file in
                try Task.checkCancellation()
                guard session == store.sessionGeneration, store.phase == .ready else { throw CancellationError() }
                go(.reviewing)
                queued = try await store.call("linkedin_pdf_review", [
                    "name": .string(file.name), "content": .string(file.content), "target_role": .string(target),
                ], timeout: 180)
                try Task.checkCancellation()
                guard !queued["id"].string.isEmpty else {
                    throw APIError(message: "Couldn’t start the review. Check Activity before trying again.")
                }
            }
            guard !Task.isCancelled else { return }
            if accepted {
                reviewID = queued["id"].string
                await showReview { queued }
            } else if step == .reviewing {
                go(.upload)
            }
        }
    }

    private func retryReview() {
        guard reviewTask == nil, !reviewID.isEmpty else { return }
        let args: JSON = ["id": .string(reviewID)]
        reviewTask = Task {
            defer { reviewTask = nil }
            await showReview {
                let latest = try await store.call("agent_run", args, timeout: 10)
                if ["failed", "blocked"].contains(latest["status"].string) {
                    return try await store.call("agent_retry", args, timeout: 10)
                }
                return latest
            }
        }
    }

    private func showReview(_ fetch: () async throws -> JSON) async {
        error = ""
        go(.reviewing)
        do {
            var result = try await fetch()
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(180)
            while ["queued", "running"].contains(result["status"].string) {
                try await clock.sleep(until: min(clock.now + .seconds(2), deadline))
                guard clock.now < deadline else {
                    throw APIError(message: "Still reviewing. Try again, or check Activity.")
                }
                result = try await store.call("agent_run", ["id": .string(reviewID)], timeout: 10)
            }
            try Task.checkCancellation()
            guard result["status"].string == "completed" else {
                if result["status"].string == "cancelled" { reviewID = "" }
                let message = result["message"].string
                throw APIError(message: message.isBlank ? "Couldn’t finish the review." : message)
            }
            run = result
            reviewID = ""
            go(.results)
            Task { await store.refresh() }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
            go(.upload)
        }
    }

    private func reset() {
        run = .null
        reviewID = ""
        error = ""
        uploader.reset()
        go(.upload)
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : Motion.stageAnimation) { step = next }
    }
}

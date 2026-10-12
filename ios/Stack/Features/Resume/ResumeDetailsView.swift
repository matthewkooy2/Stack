import SwiftUI

extension ResumeReviewController.Backend {
    /// The signed-in account's calls. Responses for an ended session are dropped by `AppStore.call`.
    @MainActor
    static func live(_ store: AppStore) -> ResumeReviewController.Backend {
        ResumeReviewController.Backend(
            read: { id in try await store.call("agent_extract_resume", ["id": .string(id)], timeout: 45) },
            retry: { id in
                _ = try await store.callAccount("retry_resume_processing", ["id": .string(id), "kind": .string(ResumeLane.structured)])
            },
            save: { id, revision, values, confirm in
                try await store.call("resume_save_details", [
                    "id": .string(id), "revision": revision, "values": .object(values.mapValues { .string($0) }),
                    "confirm": .bool(confirm),
                ])
            },
            saveRecords: { id, revision, records, confirm, template in
                try await store.call("resume_save_records", [
                    "id": .string(id), "revision": revision, "records": .array(records), "confirm": .bool(confirm),
                    "template": template.string.isEmpty ? "classic" : template,
                ])
            },
            refreshAccount: { _ = try? await store.callAccount("bootstrap") })
    }
}

/// Review of what Stack read from a resume. Every extracted field is editable, grouped into focused
/// sections; edits are written to a local draft (a failure is shown and the edits stay editable) until
/// saved. Original uploads stay unchanged, and the original extraction has its own read-only screen.
///
/// The screen is rebuilt for each signed-in account, so another account's draft is never rendered.
@MainActor
struct ResumeDetailsView: View {
    let resume: ResumeItem
    var onConfirmed: (() async -> Void)?

    @Environment(AppStore.self) private var store

    var body: some View {
        ResumeReviewScreen(resume: resume, userID: store.account.userID, onConfirmed: onConfirmed)
            .id(store.account.userID)
    }
}

@MainActor
private struct ResumeReviewScreen: View {
    let resume: ResumeItem
    let userID: String
    var onConfirmed: (() async -> Void)?

    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: ResumeReviewController?
    @State private var selection: String?
    @State private var showSource = false
    @State private var lastReadTicket: JSON = .null

    /// A retry changes the account's ticket before the editor's next read completes.
    private var activeProcessing: JSON {
        let ticket = store.account.processing(of: resume.id)[ResumeLane.structured]
        // A cached account snapshot may predate the screen read. Prefer that read until
        // the account ticket changes (for example immediately after retrying).
        if !ticket.isNull, ticket != lastReadTicket { return ticket }
        return controller?.processing ?? ticket
    }

    var body: some View {
        SheetPage(title: "Resume details", subtitle: resume.name) {
            if let controller {
                ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.kind(of: activeProcessing),
                                     processing: activeProcessing)
                content(controller)
            } else if userID.isEmpty {
                MessageLine(text: "Sign in to review resume details.")
            } else {
                ProgressView().tint(Palette.muted).accessibilityLabel("Reading resume")
            }
        }
        .task {
            guard controller == nil, !userID.isEmpty else { return }
            let made = ResumeReviewController(
                resumeID: resume.id, userID: userID, backend: .live(store), drafts: FileResumeDraftStore.shared,
                currentUserID: { [store] in store.account.userID }, onConfirmed: onConfirmed)
            controller = made
            let ticket = store.account.processing(of: resume.id)[ResumeLane.structured]
            await made.load()
            lastReadTicket = ticket
        }
        .onDisappear { controller?.flush() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller?.flush() } }
        .pollsWhileProcessing(["queued", "parsing"].contains(activeProcessing["status"].string))
        .onChange(of: store.account.processing(of: resume.id)[ResumeLane.structured]["status"].string) { _, status in
            if ["completed", "failed"].contains(status) {
                let ticket = store.account.processing(of: resume.id)[ResumeLane.structured]
                Task {
                    await controller?.load(quiet: true)
                    if store.account.processing(of: resume.id)[ResumeLane.structured] == ticket { lastReadTicket = ticket }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ controller: ResumeReviewController) -> some View {
        if controller.initialLoading {
            ProgressView().tint(Palette.muted).accessibilityLabel("Reading resume")
        }
        MessageLine(text: controller.error).fadeSwitch(!controller.error.isEmpty)
        if !controller.loaded, !controller.error.isEmpty {
            StackButton(label: "Retry parsing", icon: "refresh", kind: .secondary, disabled: controller.initialLoading) {
                Task { await controller.load(retry: true) }
            }
        }
        if controller.loaded {
            statusBlock(controller)
            if controller.recordMode {
                ResumeRecordsEditor(controller: controller)
            } else if selection == ResumeReviewController.originalSectionID {
                ResumeOriginalScreen(controller: controller) { withAnimation(Motion.fadeAnimation) { selection = nil } }
            } else if let key = selection {
                ResumeSectionEditor(controller: controller, sectionKey: key) { withAnimation(Motion.fadeAnimation) { selection = nil } }
            } else {
                overview(controller)
            }
            actions(controller)
        }
    }

    private func statusBlock(_ controller: ResumeReviewController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.statusLabel)
                .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                .accessibilityIdentifier("resume-review-state")
                .accessibilityValue(controller.statusID)
            if controller.hasConflict {
                Card(tint: Palette.oat, spacing: 12) {
                    Text("This resume changed since you started editing. Your edits are kept on this device and cannot be saved over the newer version.")
                        .font(Typeface.caption).foregroundStyle(Palette.text)
                    StackButton(label: "Discard my edits and reload", kind: .secondary, disabled: controller.saving) {
                        controller.discardEditsAndReload()
                        selection = nil
                    }
                    .accessibilityIdentifier("resume-review-discard")
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("resume-review-conflict")
            } else if controller.restoredDraft {
                Text("Restored your unsaved edits from this device.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("resume-review-restored")
            }
            if !controller.draftError.isEmpty {
                Text(controller.draftError).font(Typeface.caption).foregroundStyle(Palette.danger)
                    .accessibilityIdentifier("resume-review-draft-error")
            }
            Text("Check every extracted line. Original uploads stay unchanged. Saving a draft withdraws confirmation.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(controller.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(Typeface.caption).foregroundStyle(Palette.text)
            }
        }
    }

    private func overview(_ controller: ResumeReviewController) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(controller.sectionSummaries()) { summary in
                Button {
                    withAnimation(Motion.fadeAnimation) { selection = summary.id }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title).font(Typeface.option).foregroundStyle(Palette.icon)
                            Text(summary.detail).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(1)
                        }
                        Spacer()
                        if summary.changed { Text("Edited").font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark) }
                        GlyphView(name: "chevron", size: 14, color: Palette.muted)
                    }
                    .padding(.vertical, 12)
                    .frame(minHeight: 56)
                    .overlay(alignment: .bottom) { Rectangle().fill(Palette.rule).frame(height: 1) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(summary.title), \(summary.detail)\(summary.changed ? ", edited" : "")")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("resume-review-section-\(summary.id)")
            }
            Button {
                withAnimation(Motion.fadeAnimation) { selection = ResumeReviewController.originalSectionID }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Original extraction").font(Typeface.option).foregroundStyle(Palette.icon)
                        Text("Read-only, in original order").font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer()
                    GlyphView(name: "chevron", size: 14, color: Palette.muted)
                }
                .padding(.vertical, 12)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Original extraction, read-only, in original order")
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("resume-review-section-original")
        }
    }

    private func actions(_ controller: ResumeReviewController) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            StackButton(label: showSource ? "Hide extracted text" : "View extracted text", kind: .secondary) {
                withAnimation(Motion.fadeAnimation) { showSource.toggle() }
            }
            if showSource {
                Text(controller.sourceText).font(Typeface.caption).foregroundStyle(Palette.text).textSelection(.enabled)
            }
            StackButton(label: onConfirmed != nil ? "Confirm and continue tailoring" : "Confirm resume details", icon: "check",
                        disabled: controller.saving || controller.hasConflict
                            || (controller.confirmed && !controller.dirty && onConfirmed == nil)) {
                Task { await controller.save(confirm: true) }
            }
            .accessibilityIdentifier("resume-review-confirm")
            StackButton(label: "Save draft", kind: .secondary, disabled: controller.saving || controller.hasConflict || !controller.dirty) {
                Task { await controller.save(confirm: false) }
            }
            .accessibilityIdentifier("resume-review-save")
            MessageLine(text: controller.message, isError: false).fadeSwitch(!controller.message.isEmpty)
                .accessibilityIdentifier("resume-review-message")
        }
    }
}

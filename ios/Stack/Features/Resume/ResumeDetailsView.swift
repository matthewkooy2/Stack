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
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stackReduceMotion) private var reduceMotion
    @State private var controller: ResumeReviewController?
    @State private var selection: String? = "profile"
    @State private var editing: String?
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
        ZStack {
            Brand.page.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        BackButton(label: "Close") { dismiss() }
                        Spacer()
                        if controller?.loaded == true {
                            Menu {
                                Button("Original extraction", systemImage: "doc.text") {
                                    withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { selection = ResumeReviewController.originalSectionID; editing = nil }
                                }.accessibilityIdentifier("resume-review-section-original")
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Brand.ink).frame(width: 44, height: 44)
                                    .background(.white, in: Circle())
                            }
                            .accessibilityLabel("More options")
                        }
                    }.padding(.bottom, 32)
                    Text("Review details").font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink)
                    Text("Check the information we extracted from your resume and make any corrections.")
                        .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 10)
                    VStack(alignment: .leading, spacing: 12) {
                        if let controller {
                            ProcessingStatusView(resumeID: resume.id, kind: ResumeLane.kind(of: activeProcessing), processing: activeProcessing)
                            content(controller)
                        } else if userID.isEmpty {
                            MessageLine(text: "Sign in to review resume details.")
                        } else {
                            ProgressView().tint(Palette.muted).accessibilityLabel("Reading resume")
                        }
                    }.padding(.top, 28)
                }
                .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 24)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let controller, controller.loaded, selection != ResumeReviewController.originalSectionID {
                    actions(controller)
                        .padding(.horizontal, Spacing.page).padding(.top, 12).padding(.bottom, 8)
                        .background(Brand.page)
                }
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
        MessageLine(text: controller.detailsError).fadeSwitch(!controller.detailsError.isEmpty)
            .accessibilityIdentifier("resume-review-details-error")
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
            } else {
                overview(controller)
            }
        }
    }

    private func statusBlock(_ controller: ResumeReviewController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(controller.statusLabel)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
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
            ForEach(Array(controller.warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning).font(Typeface.caption).foregroundStyle(Palette.text)
            }
        }
    }

    private func overview(_ controller: ResumeReviewController) -> some View {
        let summaries = controller.sectionSummaries().sorted { left, right in
            let order = ["profile", "workExperiences", "educations", "projects", "skills", "additional"]
            return (order.firstIndex(of: left.id) ?? order.count) < (order.firstIndex(of: right.id) ?? order.count)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(summaries) { summary in
                VStack(alignment: .leading, spacing: 0) {
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                            selection = selection == summary.id ? nil : summary.id
                            editing = nil
                        }
                    } label: {
                        HStack(alignment: .center, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(summary.title == "Work experience" ? "Experience" : summary.title)
                                    .font(.system(size: 21, weight: .semibold)).tracking(-0.5).foregroundStyle(Brand.ink)
                                if selection != summary.id {
                                    Text(sectionPreview(controller.document, key: summary.id))
                                        .font(Typeface.caption).foregroundStyle(Brand.muted).lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: selection == summary.id ? "chevron.up" : "chevron.down")
                                .font(.system(size: 15, weight: .medium)).foregroundStyle(Brand.ink)
                        }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("resume-review-section-\(summary.id)")
                    if selection == summary.id {
                        HStack {
                            Spacer()
                            Button(editing == summary.id ? "Done" : "Edit") {
                                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) {
                                    editing = editing == summary.id ? nil : summary.id
                                }
                            }.font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        if editing == summary.id {
                            ResumeSectionEditor(controller: controller, sectionKey: summary.id, inline: true) {
                                withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { editing = nil }
                            }
                        } else {
                            sectionDetails(controller.document, key: summary.id)
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.bottom, selection == summary.id ? 14 : 0)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
            }
        }
    }

    private func sectionPreview(_ document: ResumeDocument, key: String) -> String {
        let values: [String]
        if let entry = document.entries(of: key).first {
            let names = ResumeSchema.spec(key)?.fields.map(\.name) ?? entry.values.keys.sorted()
            values = names.filter { $0 != "descriptions" }.compactMap { entry.values[$0] }.filter { !$0.isEmpty }
        } else if key == ResumeReviewController.otherSectionID {
            values = document.strayKeys.map { document.single($0) }.filter { !$0.isEmpty }
        } else {
            values = (ResumeSchema.spec(key)?.fields.map { document.single("\(key).\($0.name)") } ?? [])
                .filter { !$0.isEmpty }.map { $0.replacingOccurrences(of: "\n", with: ", ") }
        }
        return values.prefix(2).joined(separator: " · ").isEmpty ? "Nothing found" : values.prefix(2).joined(separator: " · ")
    }

    @ViewBuilder
    private func sectionDetails(_ document: ResumeDocument, key: String) -> some View {
        let spec = ResumeSchema.spec(key)
        if spec?.repeated == true || !document.entries(of: key).isEmpty {
            let entries = document.entries(of: key)
            if entries.isEmpty {
                Text("Nothing found").font(Typeface.caption).foregroundStyle(Brand.muted)
            }
            ForEach(entries) { entry in
                let known = spec?.fields.map(\.name) ?? []
                let names = known + entry.values.keys.filter { !known.contains($0) }.sorted()
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(names, id: \.self) { name in
                        if let value = entry.values[name], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            detailValue(value, label: document.label(section: key, field: name), bullets: name == "descriptions")
                        }
                    }
                }.padding(.bottom, 8)
            }
        } else {
            let keys: [String] = key == ResumeReviewController.otherSectionID ? document.strayKeys :
                (spec?.fields.map { "\(key).\($0.name)" } ?? []) + document.extraKeys(in: key)
            let populated = keys.filter { !document.single($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            if populated.isEmpty { Text("Nothing found").font(Typeface.caption).foregroundStyle(Brand.muted) }
            ForEach(populated, id: \.self) { field in
                detailValue(document.single(field), label: document.label(forKey: field), bullets: field.hasSuffix(".descriptions"))
            }
        }
    }

    private func detailValue(_ value: String, label: String, bullets: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(Typeface.caption).foregroundStyle(Brand.muted).frame(width: 76, alignment: .leading)
            if bullets {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(ResumeBullets.split(value).enumerated()), id: \.offset) { _, item in
                        Text("•  " + item).font(Typeface.caption).foregroundStyle(Brand.ink)
                    }
                }
            } else {
                Text(value).font(Typeface.caption).foregroundStyle(Brand.ink).textSelection(.enabled)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }

    private func actions(_ controller: ResumeReviewController) -> some View {
        VStack(spacing: 2) {
            StackButton(label: onConfirmed != nil ? "Confirm and continue tailoring" : "Confirm details",
                        disabled: controller.saving || controller.hasConflict) {
                Task { await controller.save(confirm: true) }
            }.accessibilityIdentifier("resume-review-confirm")
            Button("Save draft") { Task { await controller.save(confirm: false) } }
                .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                .frame(maxWidth: .infinity, minHeight: 44)
                .disabled(controller.saving || controller.hasConflict || !controller.dirty)
                .accessibilityIdentifier("resume-review-save")
            MessageLine(text: controller.message, isError: false).fadeSwitch(!controller.message.isEmpty)
                .accessibilityIdentifier("resume-review-message")
        }
    }
}

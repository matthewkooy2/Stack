import SwiftUI
import UniformTypeIdentifiers

/// Optional matching preferences, then a resume upload while the Jobs tab prepares behind this screen.
@MainActor
struct JobOnboardingView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    var onPrepared: () -> Void = {}
    let onDone: () -> Void
    @State private var role = ""
    @State private var location = ""
    @State private var stage = ""
    @State private var picker = ""
    @State private var finished = false
    @State private var working = false
    @State private var importing = false
    @State private var uploader = ResumeUploader()
    @State private var uploadGeneration = -1
    @State private var error = ""

    var body: some View {
        ZStack {
            Brand.page.ignoresSafeArea()
            if picker == "role" {
                RoleChoiceView(current: role, onSelect: { role = $0; picker = "" }, onBack: { picker = "" })
            } else if picker == "location" {
                LocationChoiceView(onSelect: { location = $0; picker = "" }, onBack: { picker = "" })
            } else if picker == "stage" {
                SheetPage(title: "Career stage", onClose: { picker = "" }) {
                    VStack(spacing: 0) {
                        ForEach(PreferenceForm.careerStages, id: \.self) { value in
                            Button { stage = value; picker = "" } label: {
                                HStack {
                                    Text(value).foregroundStyle(Brand.ink)
                                    Spacer()
                                    if stage == value { Image(systemName: "checkmark").foregroundStyle(Brand.accent) }
                                }
                                .font(Typeface.body).frame(minHeight: 56).contentShape(Rectangle())
                                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }
                            }.buttonStyle(.plain)
                        }
                    }
                    Button("Skip for now") { stage = ""; picker = "" }
                        .font(Typeface.caption).foregroundStyle(Brand.muted).frame(minHeight: 44)
                }
            } else if finished {
                ResumeUploadScreen(uploading: uploader.isBusy, fileName: uploader.fileName, disabled: store.busy,
                                   error: uploader.phase == .failed ? uploader.message : error,
                                   progress: uploader.progress, onUpload: chooseResume,
                                   onRetry: uploader.canRetry ? { retryUpload() } : nil)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Button("Skip for now", action: onDone)
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(uploader.isBusy)
                            .padding(.horizontal, Spacing.page).padding(.bottom, 16)
                            .background(Brand.page)
                    }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("A little about\nyour search.")
                                .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                            Text("This helps us get started.")
                                .font(Typeface.body).foregroundStyle(Brand.muted).padding(.top, 12).reveal(1)
                            VStack(alignment: .leading, spacing: 24) {
                                selection("Role or job title", value: role.isEmpty ? "Choose a role" : role) { picker = "role" }
                                selection("City or state", value: location.isEmpty ? "Choose a location" : location) { picker = "location" }
                                selection("Career stage", value: stage.isEmpty ? "Choose your stage" : stage) { picker = "stage" }
                            }.padding(.top, 36).reveal(2)
                        }
                        .padding(.horizontal, Spacing.page).padding(.top, 40).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden)
                    VStack(spacing: 4) {
                        MessageLine(text: error).fadeSwitch(!error.isEmpty)
                        StackButton(label: working ? "Saving…" : "Continue", disabled: working) {
                            Task { await save() }
                        }
                        Button("Skip for now", action: showResume)
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(working)
                    }
                    .padding(.horizontal, Spacing.page).padding(.bottom, 16)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ResumeFiles.allowedTypes) { result in
            guard uploadGeneration == store.sessionGeneration, store.phase == .ready, uploader.picked(result) else { return }
            Task { await upload() }
        }
        .onChange(of: importing) { _, open in if !open { uploader.pickerClosed() } }
        .onChange(of: store.sessionGeneration) { _, _ in importing = false; uploader.reset() }
        .replayable()
    }

    private func selection(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text(label).fontWeight(.semibold) + Text(" (optional)").foregroundColor(Brand.muted))
                .font(Typeface.caption).foregroundStyle(Brand.ink)
            Button(action: action) {
                HStack { Text(value).foregroundStyle(Brand.muted); Spacer(); Image(systemName: "chevron.down").foregroundStyle(Brand.muted) }
                    .padding(.horizontal, 16).frame(height: 54).background(.white, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
    }

    private func showResume() {
        onPrepared()
        withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { finished = true }
    }

    private func save() async {
        guard !working else { return }; working = true; error = ""; defer { working = false }
        guard !role.isEmpty || !location.isEmpty || !stage.isEmpty else { showResume(); return }
        let account = store.account
        var preferences = PreferenceForm(account.preferences)
        if !stage.isEmpty { preferences.stage = stage }
        do {
            // Fresh profiles have no display name yet; keep the actual signed-in handle until one is supplied.
            let name = account.name.isBlank ? store.googleInfo["username"].string : account.name
            try await store.callAccount("save_profile", [
                "name": .string(name),
                "role": .string(role.isEmpty ? account.role : role),
                "location": .string(location.isEmpty ? account.location : location),
                "mode": .string(account.mode),
                "notifications": .bool(account.notificationsOn),
                "preferences": preferences.json,
            ])
            showResume()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func chooseResume() {
        guard uploader.begin() else { return }
        uploadGeneration = store.sessionGeneration
        error = ""
        importing = true
    }

    private func retryUpload() {
        guard uploader.retry() else { return }
        Task { await upload() }
    }

    private func upload() async {
        let generation = uploadGeneration
        let uploaded = await uploader.run { file in
            guard generation == store.sessionGeneration, store.phase == .ready else { throw CancellationError() }
            _ = try await store.callAccount("upload_resume", ["name": .string(file.name), "content": .string(file.content)], timeout: 90)
        }
        if uploaded { onDone() }
    }
}

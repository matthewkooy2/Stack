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
    @State private var uploadName = ""
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
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(finished ? "Add your\nresume." : "A little about\nyour search.")
                                .font(Typeface.display).tracking(-1.8).foregroundStyle(Brand.ink).reveal(0)
                            Text(finished ? "We’re finding jobs for you. Add your resume while we look." : "This helps us get started.")
                                .font(Typeface.body).foregroundStyle(Brand.muted).padding(.top, 12).reveal(1)
                            if finished {
                                ResumeStackMark().frame(maxWidth: .infinity).padding(.top, 28)
                                Text("We’ll start reading it as soon as it uploads.")
                                    .font(Typeface.caption).foregroundStyle(Brand.muted).padding(.top, 12)
                                Text(uploadName.isEmpty ? "PDF · Up to 10 MB" : uploadName)
                                    .font(Typeface.caption).foregroundStyle(Brand.muted)
                                    .lineLimit(1).truncationMode(.middle).padding(.top, 8)
                            } else {
                                VStack(alignment: .leading, spacing: 24) {
                                    selection("Role or job title", value: role.isEmpty ? "Choose a role" : role) { picker = "role" }
                                    selection("City or state", value: location.isEmpty ? "Choose a location" : location) { picker = "location" }
                                    selection("Career stage", value: stage.isEmpty ? "Choose your stage" : stage) { picker = "stage" }
                                }.padding(.top, 36).reveal(2)
                            }
                        }
                        .padding(.horizontal, Spacing.page).padding(.top, 40).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.scrollIndicators(.hidden)
                    VStack(spacing: 4) {
                        MessageLine(text: error).fadeSwitch(!error.isEmpty)
                        StackButton(label: working ? (finished ? "Uploading…" : "Saving…") : (finished ? "Upload resume" : "Continue"), disabled: working) {
                            if finished { importing = true } else { Task { await save() } }
                        }
                        Button("Skip for now") { if finished { onDone() } else { showResume() } }
                            .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity, minHeight: 44).disabled(working)
                    }
                    .padding(.horizontal, Spacing.page).padding(.bottom, 16)
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                working = true; error = ""; uploadName = url.lastPathComponent
                Task { await upload(url) }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
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
            try await store.callAccount("save_profile", [
                "name": .string(account.name),
                "role": .string(role.isEmpty ? account.role : role),
                "location": .string(location.isEmpty ? account.location : location),
                "mode": .string(account.mode),
                "notifications": .bool(account.notificationsOn),
                "preferences": preferences.json,
            ])
            showResume()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func upload(_ url: URL) async {
        let generation = store.sessionGeneration
        defer { working = false; uploadName = "" }
        do {
            let file = try await readPickedFileInBackground(url, limit: 10 * 1024 * 1024, tooLarge: "PDF must be 10 MB or smaller.")
            guard generation == store.sessionGeneration else { return }
            try await store.callAccount("upload_resume", ["name": .string(file.name), "content": .string(file.content)], timeout: 90)
            onDone()
        } catch { if generation == store.sessionGeneration, !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

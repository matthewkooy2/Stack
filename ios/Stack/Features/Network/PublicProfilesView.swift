import SwiftUI

/// Local drafts match the existing public-profile editor. Nothing is published to a provider.
@MainActor
struct PublicProfilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var platform = "LinkedIn"
    @State private var field: ProfileDraftField?
    @State private var draft = ""
    @State private var generation = -1

    private var fields: [ProfileDraftField] { ProfileDraftField.fields(for: platform) }
    private func key(_ field: ProfileDraftField) -> String { platform + ":" + field.id }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            Page {
                BackButton(label: "Close") { dismiss() }
                Text("Public profiles").font(Typeface.display).foregroundStyle(Palette.ink).reveal(0)
                Text("Draft your professional story. These drafts stay in this signed-in session; your public profiles stay unchanged.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted).reveal(1)
                HStack {
                    ForEach(["LinkedIn", "GitHub", "Portfolio"], id: \.self) { name in
                        Chip(label: name, selected: platform == name) { platform = name }
                    }
                }
                ForEach(fields) { item in
                    ListRow(label: item.label, icon: "edit", detail: store.profileDrafts[key(item)] ?? "Add a draft") {
                        draft = store.profileDrafts[key(item)] ?? ""
                        field = item
                    }
                }
            }
        }
        .onAppear { generation = store.sessionGeneration }
        .onChange(of: store.sessionGeneration) { _, _ in dismiss() }
        .sheet(item: $field) { item in
            ZStack {
                Palette.page.ignoresSafeArea()
                Page {
                    BackButton(label: "Cancel") { field = nil }
                    Text(item.label).font(Typeface.title).foregroundStyle(Palette.ink)
                    StackField(label: "Draft", text: $draft, multiline: true)
                    StackButton(label: "Save draft") {
                        guard generation == store.sessionGeneration, store.phase == .ready else { return }
                        store.profileDrafts[key(item)] = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        field = nil
                    }
                    Text("Saved locally for this session. Signing out clears these drafts.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            .interactiveDismissDisabled(!draft.isEmpty)
        }
    }
}

struct ProfileDraftField: Identifiable {
    let id: String
    let label: String
    static func fields(for platform: String) -> [Self] {
        let rows: [(String, String)]
        switch platform {
        case "LinkedIn": rows = [("url", "Profile URL"), ("headline", "Headline"), ("location", "Location"),
            ("about", "About"), ("skills", "Top skills"), ("role", "Current or recent role"),
            ("experience", "Experience highlights"), ("school", "School"), ("degree", "Degree and field of study"),
            ("activities", "Activities and achievements"), ("featured", "Projects and links"), ("credentials", "Certifications")]
        case "GitHub": rows = [("url", "Profile URL"), ("bio", "Bio"), ("website", "Website"),
            ("readme", "README introduction"), ("stack", "Tools and technologies"), ("focus", "Current focus"),
            ("projects", "Pinned repositories"), ("demos", "Live demos"), ("contributions", "Contributions")]
        default: rows = [("url", "Website URL"), ("intro", "Headline"), ("about", "About"),
            ("work", "Featured projects"), ("role", "Your contribution"), ("outcomes", "Outcomes"),
            ("email", "Contact email"), ("links", "Social links"), ("resume", "Resume link")]
        }
        return rows.map { Self(id: $0.0, label: $0.1) }
    }
}

import SwiftUI

/// Local drafts match the existing public-profile editor. Nothing is published to a provider.
@MainActor
struct PublicProfilesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let canSwitchPlatform: Bool
    @State private var platform: String
    @State private var field: ProfileDraftField?
    @State private var draft = ""
    @State private var generation = -1

    init(initialPlatform: String? = nil) {
        canSwitchPlatform = initialPlatform == nil
        _platform = State(initialValue: initialPlatform ?? "LinkedIn")
    }

    private var fields: [ProfileDraftField] { ProfileDraftField.fields(for: platform) }
    private func key(_ field: ProfileDraftField) -> String { platform + ":" + field.id }

    var body: some View {
        SheetPage(title: canSwitchPlatform ? "Public profiles" : platform, subtitle: "Drafts stay in this signed-in session.") {
            if canSwitchPlatform {
                FlowLayout(spacing: 6) {
                    ForEach(["LinkedIn", "GitHub", "Portfolio"], id: \.self) { name in
                        Chip(label: name, selected: platform == name) { platform = name }
                    }
                }
            }
            VStack(spacing: 0) {
                ForEach(fields) { item in
                    ListRow(label: item.label, detail: store.profileDrafts[key(item)] ?? "") {
                        draft = store.profileDrafts[key(item)] ?? ""
                        field = item
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .onAppear { generation = store.sessionGeneration }
        .onChange(of: store.sessionGeneration) { _, _ in dismiss() }
        .sheet(item: $field) { item in
            SheetPage(title: item.label, closeLabel: "Cancel", onClose: { field = nil }) {
                StackField(label: "Draft", text: $draft, multiline: true)
                StackButton(label: "Save draft") {
                    guard generation == store.sessionGeneration, store.phase == .ready else { return }
                    store.profileDrafts[key(item)] = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    field = nil
                }
                Text("Signing out clears your saved drafts.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
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

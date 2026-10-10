import SwiftUI

/// Account sheet: profile and matching preferences, sign-in, agents, follow-ups and sign-out.
@MainActor
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State var name = ""
    @State var role = ""
    @State var location = ""
    @State var graduation = ""
    @State var availableFrom = ""
    @State var notifications = true
    @State var preferences = PreferenceForm()
    @State var seeded = false
    @State var showAgents = false
    @State var showReminders = false
    @State var showBank = false
    @State private var modelSettings: JSON = .null
    @State private var modelBusy = false
    @State private var modelError = ""

    private var changed: Bool {
        let a = store.account
        return name != a.name || role != a.role || location != a.location || notifications != a.notificationsOn
            || graduation != a.graduationMonth || availableFrom != a.availableFrom
            || preferences != PreferenceForm(a.preferences)
    }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            Page {
                HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                HStack(spacing: 16) {
                    Avatar(initials: String(store.account.name.prefix(1)).uppercased(), size: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.account.name.isEmpty ? "Your profile" : store.account.name).font(Typeface.title).foregroundStyle(Palette.ink)
                        Text(store.account.role).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
                .reveal(0)

                VStack(spacing: Spacing.option) {
                    ListRow(label: "Agents", icon: "sparkles",
                            detail: agentSummary) { showAgents = true }
                    ListRow(label: "Follow-up reminders", icon: "bell",
                            detail: reminderSummary) { showReminders = true }
                    ListRow(label: "Experience bank", icon: "resume",
                            detail: "Facts you confirm can be reused when tailoring") { showBank = true }
                }
                .reveal(1)

                VStack(spacing: 18) {
                    StackField(label: "Your name", text: $name)
                    StackField(label: "Target role", text: $role, placeholder: "Separate several roles with commas")
                    StackField(label: "Location", text: $location)
                    StackField(label: "Expected graduation (YYYY-MM)", text: $graduation, placeholder: "2027-05", keyboard: .numbersAndPunctuation)
                    StackField(label: "Available full-time from (YYYY-MM)", text: $availableFrom, placeholder: "Optional", keyboard: .numbersAndPunctuation)
                    MatchInputsView(form: $preferences)
                    ToggleRow(label: "Reminder notifications", isOn: $notifications)
                }
                .reveal(2)

                StackButton(label: "Save profile", disabled: store.busy || !changed || name.isBlank) {
                    Task { await save() }
                }

                Card(tint: Palette.surfaceRaised, spacing: 10) {
                    Text("Agent model").font(Typeface.section).foregroundStyle(Palette.ink)
                    Text("Applies to new agent tasks across Prep, resumes, jobs, applications and network. Live voice uses its separate connection.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    if !modelSettings.isNull && modelSettings["model_selection"].string.isEmpty {
                        Text("Current provider: \(store.account.modelProviderName)")
                            .font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                    ForEach(["codex-cli", "local"], id: \.self) { choice in
                        let option = modelSettings["model_options"].array.first { $0["selection"].string == choice } ?? .null
                        Button {
                            Task { await selectModel(choice) }
                        } label: {
                            HStack {
                                Image(systemName: modelSettings["model_selection"].string == choice ? "checkmark.circle.fill" : "circle")
                                Text(choice == "codex-cli" ? "Codex CLI" : "Local model")
                                Spacer()
                            }
                        }
                        .disabled(modelBusy || modelSettings.isNull)
                        Text(option["message"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                    if !modelError.isEmpty {
                        Text(modelError).font(Typeface.caption).foregroundStyle(Palette.text)
                    }
                }

                StoreMessages()

                GoogleAccountCard()
                if AppleSignIn.enabled || store.apple.hasAppleSession { AppleAccountCard() }

                Card(tint: Palette.surfaceRaised, spacing: 10) {
                    HStack(spacing: 10) {
                        GlyphView(name: "shield", size: 20)
                        Text("Your space stays yours").font(Typeface.section).foregroundStyle(Palette.ink)
                    }
                    Text("Your resumes, applications, contacts and practice are saved to your Stack account. Nothing is sent to an employer, a contact or a model provider unless you approve it.")
                        .font(Typeface.caption).foregroundStyle(Palette.text)
                    if !store.account.modelProviderName.isEmpty {
                        Text("Model provider: \(store.account.modelProviderName)").font(Typeface.caption).foregroundStyle(Palette.text)
                    }
                    if !store.account.modelProviderMessage.isEmpty {
                        Text(store.account.modelProviderMessage).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }

                VStack(spacing: Spacing.option) {
                    StackButton(label: "iPhone notification settings", icon: "bell", kind: .secondary) {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    StackButton(label: "Sign out", icon: "logout", kind: .secondary, disabled: store.busy) {
                        Task { await store.signOut(); dismiss() }
                    }
                }
                Text("Stack 0.2").font(Typeface.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
            }
        }
        .onAppear(perform: seed)
        .task { await loadModel() }
        .sheet(isPresented: $showAgents) { AgentHubView().environment(store) }
        .sheet(isPresented: $showReminders) { RemindersView().environment(store) }
        .sheet(isPresented: $showBank) { ExperienceBankView().environment(store) }
    }

    private var agentSummary: String {
        let active = store.account.activeRunCount
        let attention = store.account.attentionRunCount
        if active == 0, attention == 0 { return "Nothing running" }
        return "\(active) in progress · \(attention) need you"
    }

    private var reminderSummary: String {
        let open = store.account.reminders.filter { !$0.done }.count
        return open == 0 ? "No open reminders" : "\(open) open"
    }

    private func seed() {
        guard !seeded else { return }
        let a = store.account
        name = a.name; role = a.role; location = a.location
        graduation = a.graduationMonth; availableFrom = a.availableFrom
        notifications = a.notificationsOn
        preferences = PreferenceForm(a.preferences)
        seeded = true
    }

    private func loadModel() async {
        do { modelSettings = try await store.call("agent_settings") }
        catch { modelError = error.localizedDescription }
    }

    private func selectModel(_ selection: String) async {
        modelBusy = true
        modelError = ""
        defer { modelBusy = false }
        do {
            modelSettings = try await store.call("agent_save_model", ["selection": .string(selection)])
            await store.refresh()
        } catch { modelError = error.localizedDescription }
    }

    private func save() async {
        let chosen = preferences.modes
        let ok = await store.mutate("save_profile", [
            "name": .string(name), "role": .string(role), "location": .string(location),
            "mode": .string(chosen.count == 1 ? chosen[0] : "Any"),
            "notifications": .bool(notifications),
            "graduation_month": .string(graduation),
            "available_from": .string(availableFrom),
            "preferences": preferences.json,
        ])
        if ok {
            // The job deck re-reads saved defaults the next time it loads.
            NotificationCenter.default.post(name: .stackProfileSaved, object: nil)
        }
    }
}

extension Notification.Name {
    static let stackProfileSaved = Notification.Name("stack.profile.saved")
}

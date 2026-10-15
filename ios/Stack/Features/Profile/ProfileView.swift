import SwiftUI

/// Account sheet: a short hub that opens one focused section at a time. Edits are held here, so moving
/// between sections never loses a draft.
@MainActor
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum Pane: Int, StageKey {
        case hub, details, matching, account
        var depth: Int { self == .hub ? 0 : 1 }
    }

    @State private var section: Pane = .hub
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
            Stage(key: section) {
                Page {
                    HStack {
                        BackButton(label: section == .hub ? "Close" : "Back") {
                            if section == .hub { dismiss() } else { go(.hub) }
                        }
                        Spacer()
                    }
                    switch section {
                    case .hub: hub
                    case .details: details
                    case .matching: matching
                    case .account: account
                    }
                }
            }
        }
        .onAppear(perform: seed)
        .task { await loadModel() }
        .sheet(isPresented: $showAgents) { AgentHubView().environment(store) }
        .sheet(isPresented: $showReminders) { RemindersView().environment(store) }
        .sheet(isPresented: $showBank) { ExperienceBankView().environment(store) }
    }

    private func go(_ next: Pane) {
        withAnimation(Motion.stageAnimation) { section = next }
    }

    // MARK: Hub

    private var hub: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            HStack(spacing: 16) {
                Avatar(initials: String(store.account.name.prefix(1)).uppercased(), size: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.account.name.isEmpty ? "Your profile" : store.account.name).font(Typeface.title).foregroundStyle(Palette.ink)
                    if !store.account.role.isEmpty {
                        Text(store.account.role).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
            .reveal(0)

            VStack(spacing: 0) {
                ListRow(label: "Your details", icon: "profile", detail: "Name, role, location, timeline") { go(.details) }.reveal(1)
                ListRow(label: "Job matching", icon: "jobs", detail: "Level, pay, work style, exclusions") { go(.matching) }.reveal(2)
                ListRow(label: "Agents", icon: "sparkles", detail: agentSummary) { showAgents = true }.reveal(3)
                ListRow(label: "Follow-up reminders", icon: "bell", detail: reminderSummary) { showReminders = true }.reveal(4)
                ListRow(label: "Experience bank", icon: "resume", detail: "Confirmed facts for tailoring") { showBank = true }.reveal(5)
                ListRow(label: "Account", icon: "shield", detail: "Sign-in, model, notifications") { go(.account) }.reveal(6)
            }

            StoreMessages()
            if changed {
                StackButton(label: "Save changes", disabled: store.busy || name.isBlank) { Task { _ = await save() } }
            }
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Your details").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            VStack(spacing: 18) {
                StackField(label: "Your name", text: $name)
                StackField(label: "Target role", text: $role, placeholder: "Separate several roles with commas")
                StackField(label: "Location", text: $location)
                StackField(label: "Expected graduation (YYYY-MM)", text: $graduation, placeholder: "2027-05", keyboard: .numbersAndPunctuation)
                StackField(label: "Available full-time from (YYYY-MM)", text: $availableFrom, placeholder: "Optional", keyboard: .numbersAndPunctuation)
            }
            StoreMessages()
            saveButton
        }
    }

    // MARK: Matching

    private var matching: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Job matching").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            MatchInputsView(form: $preferences)
            StoreMessages()
            saveButton
        }
    }

    private var saveButton: some View {
        StackButton(label: "Save", disabled: store.busy || !changed || name.isBlank) {
            Task { if await save() { go(.hub) } }
        }
    }

    // MARK: Account

    private var account: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            Text("Account").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
            GoogleAccountCard()
            if store.apple.hasAppleSession { AppleAccountCard() }
            ToggleRow(label: "Reminder notifications", isOn: $notifications)
            DisclosureSection("Agent model", detail: modelSummary) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Applies to new agent tasks. Live voice uses its own connection.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    if !store.account.modelProviderMessage.isEmpty {
                        Text(store.account.modelProviderMessage).font(Typeface.caption).foregroundStyle(Palette.muted)
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
                            .font(Typeface.body).foregroundStyle(Palette.text)
                        }
                        .disabled(modelBusy || modelSettings.isNull)
                        if !option["message"].string.isEmpty {
                            Text(option["message"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
            // Outside the disclosure: a load or select can fail after it is collapsed.
            if !modelError.isEmpty {
                MessageLine(text: modelError)
            }
            Text("Nothing is sent to an employer, a contact or a model provider unless you approve it.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StoreMessages()
            VStack(spacing: Spacing.option) {
                if changed {
                    StackButton(label: "Save changes", disabled: store.busy || name.isBlank) { Task { _ = await save() } }
                }
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

    private var modelSummary: String {
        switch modelSettings["model_selection"].string {
        case "codex-cli": return "Codex CLI"
        case "local": return "Local model"
        default: return store.account.modelProviderName
        }
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

    @discardableResult
    private func save() async -> Bool {
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
        return ok
    }
}

extension Notification.Name {
    static let stackProfileSaved = Notification.Name("stack.profile.saved")
}

import SwiftUI

/// Account sheet: a short hub that opens one focused section at a time. Edits are held here, so moving
/// between sections never loses a draft.
@MainActor
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.stackReduceMotion) private var reduceMotion

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
    @State private var modelToSwitch = ""
    @State private var confirmStopModelTasks = false
    @State private var nudges = NudgeSettings()
    @State private var nudgeNote = ""
    @State private var confirmDelete = false

    private var changed: Bool {
        let a = store.account
        return name != a.name || role != a.role || location != a.location || notifications != a.notificationsOn
            || graduation != a.graduationMonth || availableFrom != a.availableFrom
            || preferences != PreferenceForm(a.preferences)
    }

    var body: some View {
        Stage(key: section) {
            SheetPage(title: paneTitle, closeLabel: section == .hub ? "Close" : "Back", onClose: {
                if section == .hub { dismiss() } else { go(.hub) }
            }) {
                switch section {
                case .hub: hub
                case .details: details
                case .matching: matching
                case .account: account
                }
            }
        }
        .onAppear(perform: seed)
        .task(id: section) { if section == .account { await loadModel() } }
        .sheet(isPresented: $showAgents) { AgentHubView().environment(store) }
        .sheet(isPresented: $showReminders) { RemindersView().environment(store) }
        .fullScreenCover(isPresented: $showBank) { MemoryBankView().environment(store) }
        .confirmationDialog("Switch AI model?", isPresented: $confirmStopModelTasks, titleVisibility: .visible) {
            Button("Stop tasks and switch", role: .destructive) {
                let selection = modelToSwitch
                Task { await selectModel(selection, stopTasks: true) }
            }
        } message: {
            Text("Running tasks will stop")
        }
        .alert("Delete your account?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete account", role: .destructive) {
                Task { if await store.deleteAccount() { dismiss() } }
            }
        } message: {
            Text("This permanently deletes your account and data.")
        }
    }

    private var paneTitle: String {
        switch section {
        case .hub: return "Profile"
        case .details: return "Your details"
        case .matching: return "Job preferences"
        case .account: return "Account"
        }
    }

    private func go(_ next: Pane) {
        withAnimation(reduceMotion ? nil : Motion.stageAnimation) { section = next }
    }

    // MARK: Hub

    private var hub: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            identity.reveal(0)
            settingsGroup("You") {
                SettingsRow(symbol: "person.crop.circle", tint: 0, title: "Your details") { go(.details) }
                SettingsRow(symbol: "slider.horizontal.3", tint: 1, title: "Job preferences") { go(.matching) }
                SettingsRow(symbol: "square.stack", tint: 2, title: "Experience", last: true) { showBank = true }
            }
            .reveal(1)
            settingsGroup("Settings") {
                SettingsRow(symbol: "sparkles", tint: 5, title: "Activity", value: agentSummary) { showAgents = true }
                SettingsRow(symbol: "bell", tint: 3, title: "Reminders", value: reminderSummary) { showReminders = true }
                SettingsRow(symbol: "lock.shield", tint: 4, title: "Account", last: true) { go(.account) }
            }
            .reveal(2)
            StoreMessages()
            if changed {
                StackButton(label: "Save", disabled: store.busy || name.isBlank) { Task { _ = await save() } }
                    .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .animation(reduceMotion ? nil : Motion.snappy, value: changed)
    }

    private var identity: some View {
        let account = store.account
        let line = [account.role, account.location].filter { !$0.isBlank }.joined(separator: " · ")
        return VStack(spacing: 12) {
            if account.name.isBlank {
                SymbolDisc(systemName: "person.fill", size: 84)
            } else {
                UserAvatar(name: account.name, size: 84)
            }
            VStack(spacing: 4) {
                Text(account.name.isBlank ? "Your account" : account.name)
                    .font(.title2.weight(.bold)).foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.center)
                if !line.isEmpty {
                    Text(line).font(Typeface.caption).foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center).lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: title)
            Card(spacing: 0, content: content)
        }
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
            VStack(spacing: 16) {
                StackField(label: "Name", text: $name)
                StackField(label: "Target role", text: $role, placeholder: "Roles, separated by commas")
                StackField(label: "Location", text: $location)
            }
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Dates")
                StackField(label: "Graduation", text: $graduation, placeholder: "YYYY-MM", keyboard: .numbersAndPunctuation)
                StackField(label: "Available from", text: $availableFrom, placeholder: "YYYY-MM", keyboard: .numbersAndPunctuation)
            }
            StoreMessages()
            saveButton
        }
    }

    // MARK: Matching

    private var matching: some View {
        VStack(alignment: .leading, spacing: Spacing.stack) {
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
            GoogleAccountCard()
            VStack(spacing: 0) {
                ToggleRow(label: "Notifications", isOn: $notifications)
                    .padding(.vertical, 14)
                    .frame(minHeight: 56)
                    .overlay(alignment: .bottom) { Divider() }
                nudgeSection
                modelSection
            }
            // Outside the disclosure: a load or select can fail after it is collapsed.
            if !modelError.isEmpty {
                MessageLine(text: modelError)
            }
            StoreMessages()
            VStack(spacing: Spacing.option) {
                if changed {
                    StackButton(label: "Save", disabled: store.busy || name.isBlank) { Task { _ = await save() } }
                }
                StackButton(label: "Notification settings", icon: "bell", kind: .secondary) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                StackButton(label: "Sign out", icon: "logout", kind: .secondary, disabled: store.busy) {
                    Task { await store.signOut(); dismiss() }
                }
            }
            VStack(spacing: 4) {
                HStack(spacing: 20) {
                    Link("Privacy policy", destination: URL(string: "https://stackmvp.top/privacy")!)
                    Link("Support", destination: URL(string: "https://stackmvp.top/support")!)
                }
                .font(Typeface.caption)
                .tint(Palette.muted)
                .frame(minHeight: 44)
                Button("Delete account", role: .destructive) { confirmDelete = true }
                    .font(Typeface.caption)
                    .frame(minHeight: 44)
                    .disabled(store.busy)
                if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                    Text("Stack \(version)").font(.footnote).foregroundStyle(Palette.muted)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var modelSection: some View {
        DisclosureSection("AI model", detail: modelSummary) {
            VStack(alignment: .leading, spacing: 10) {
                if modelSettings["active_model_tasks"].int > 0 {
                    Text("Tasks are running. Stop them to switch")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                if !store.account.modelProviderMessage.isEmpty {
                    Text(store.account.modelProviderMessage).font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                ForEach(modelSettings["model_options"].array.map { $0["selection"].string }, id: \.self) { choice in
                    let option = modelSettings["model_options"].array.first { $0["selection"].string == choice } ?? .null
                    Button {
                        if modelSettings["active_model_tasks"].int > 0 {
                            modelToSwitch = choice
                            confirmStopModelTasks = true
                        } else {
                            Task { await selectModel(choice) }
                        }
                    } label: {
                        HStack {
                            Image(systemName: modelSettings["model_selection"].string == choice ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(modelSettings["model_selection"].string == choice ? Brand.accent : Palette.muted)
                            Text(choice == "codex-cli" ? "Codex CLI" : "Local model")
                            Spacer()
                        }
                        .font(Typeface.body).foregroundStyle(Palette.text)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .disabled(modelBusy || modelSettings.isNull || modelSettings["model_selection"].string == choice)
                    if !option["message"].string.isEmpty {
                        Text(option["message"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
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
        if active == 0, attention == 0 { return "Idle" }
        return attention > 0 ? "\(attention) need you" : "\(active) running"
    }

    // MARK: Accountability reminders

    private var nudgeSummary: String {
        guard nudges.enabled else { return "Off" }
        return "\(nudges.hours.count) a day, \(Self.hourLabel(nudges.startHour))–\(Self.hourLabel(nudges.endHour))"
    }

    nonisolated static func hourLabel(_ hour: Int) -> String {
        let suffix = hour < 12 ? "am" : "pm"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve)\(suffix)"
    }

    private var nudgeSection: some View {
        DisclosureSection("Daily reminders", detail: nudgeSummary) {
            VStack(alignment: .leading, spacing: 12) {
                ToggleRow(label: "Remind me", isOn: nudgeBinding(\.enabled))
                if nudges.enabled {
                    Text("How often").font(.system(.subheadline).weight(.semibold)).foregroundStyle(Brand.muted)
                    FlowLayout(spacing: 8) {
                        ForEach(NudgeSettings.frequencies, id: \.self) { hours in
                            Chip(label: "Every \(hours)h", selected: nudges.everyHours == hours) { update { $0.everyHours = hours } }
                        }
                    }
                    Stepper("From \(Self.hourLabel(nudges.startHour))", value: nudgeBinding(\.startHour), in: 5...(nudges.endHour))
                        .font(Typeface.body).foregroundStyle(Brand.ink)
                    Stepper("Until \(Self.hourLabel(nudges.endHour))", value: nudgeBinding(\.endHour), in: (nudges.startHour)...23)
                        .font(Typeface.body).foregroundStyle(Brand.ink)
                }
                if !nudgeNote.isEmpty {
                    Text(nudgeNote).font(Typeface.caption).foregroundStyle(Brand.muted)
                }
                if nudgeNote == Self.deniedNote {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                    }
                    .font(Typeface.caption.weight(.semibold)).foregroundStyle(Brand.accent)
                }
            }
        }
    }

    static let deniedNote = "Notifications are off. Turn them on in Settings"

    private func nudgeBinding<Value>(_ path: WritableKeyPath<NudgeSettings, Value>) -> Binding<Value> {
        Binding(get: { nudges[keyPath: path] }, set: { value in update { $0[keyPath: path] = value } })
    }

    /// Reminders are local to this phone, so a change applies at once instead of waiting for Save.
    private func update(_ change: (inout NudgeSettings) -> Void) {
        change(&nudges)
        nudges.save(for: store.account.userID)
        Task {
            switch await store.reconcileNudges(ask: true) {
            case .scheduled(let count): nudgeNote = "\(count) a day from \(Self.hourLabel(nudges.hours.first ?? nudges.startHour))"
            case .denied: nudgeNote = Self.deniedNote
            case .off: nudgeNote = ""
            }
        }
    }

    private var reminderSummary: String {
        let open = store.account.reminders.filter { !$0.done }.count
        return open == 0 ? "None" : "\(open) open"
    }

    private func seed() {
        guard !seeded else { return }
        let a = store.account
        name = a.name; role = a.role; location = a.location
        graduation = a.graduationMonth; availableFrom = a.availableFrom
        notifications = a.notificationsOn
        nudges = NudgeSettings.load(for: a.userID)
        preferences = PreferenceForm(a.preferences)
        seeded = true
    }

    private func loadModel() async {
        do { modelSettings = try await store.call("agent_settings") }
        catch { modelError = error.localizedDescription }
    }

    private func selectModel(_ selection: String, stopTasks: Bool = false) async {
        modelBusy = true
        modelError = ""
        defer { modelBusy = false }
        do {
            modelSettings = try await store.call("agent_save_model", ["selection": .string(selection), "stop_tasks": .bool(stopTasks)])
            await store.refresh()
        } catch {
            if let latest = try? await store.call("agent_settings") { modelSettings = latest }
            modelError = error.localizedDescription
        }
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

/// A Settings-style row: a tinted symbol tile, a title, an optional value and a chevron.
@MainActor
private struct SettingsRow: View {
    let symbol: String
    let tint: Int
    let title: String
    var value = ""
    var last = false
    let action: () -> Void

    var body: some View {
        let tone = Palette.tints[tint % Palette.tints.count]
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tone.ink)
                    .frame(width: 32, height: 32)
                    .background(tone.fill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text(title).font(.body.weight(.medium)).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !value.isEmpty {
                    Text(value).font(Typeface.caption).foregroundStyle(Palette.muted).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted.opacity(0.7))
            }
            .padding(.vertical, 10)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { if !last { Divider().padding(.leading, 44) } }
        }
        .buttonStyle(.tap(scale: 0.985, dim: 1))
        .accessibilityLabel(value.isEmpty ? title : "\(title), \(value)")
    }
}

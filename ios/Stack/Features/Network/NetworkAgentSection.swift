import Observation
import SwiftUI

/// Unfinished Network edits. Owned above the tool sheets so closing one never discards typed work;
/// the owner clears it when the account or session changes.
@Observable
@MainActor
final class NetworkDrafts {
    var adding = false
    var name = ""
    var email = ""
    var company = ""
    var relationship = ""
    var sourceURL = ""
    var importText = ""
    var followupLimit = "0"
    var followupDays = "7"
    var policyLoaded = false
    var linkedInURL = ""
    var linkedInRole = ""
    var linkedInSavedURL = ""
    var linkedInSavedRole = ""
    var linkedInLoaded = false

    func reset() {
        adding = false
        name = ""; email = ""; company = ""; relationship = ""; sourceURL = ""; importText = ""
        followupLimit = "0"; followupDays = "7"; policyLoaded = false
        linkedInURL = ""; linkedInRole = ""; linkedInSavedURL = ""; linkedInSavedRole = ""; linkedInLoaded = false
    }
}

/// Your real contacts. Saving never sends; outreach starts only on request and waits for review.
@MainActor
struct NetworkAgentSection: View {
    @Bindable var drafts: NetworkDrafts
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store

    @State private var contacts: [JSON] = []
    @State private var loaded = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""

    private var feature: AgentFeature? { store.account.feature("networking") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Saving a contact never contacts them. Drafts wait for your review.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if let feature { FeatureCardView(feature: feature, onAction: onNavigate, compact: true) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            ForEach(Array(contacts.enumerated()), id: \.offset) { _, contact in contactCard(contact) }
            if loaded, contacts.isEmpty, !drafts.adding { Text("No contacts yet.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            if drafts.adding { form } else {
                StackButton(label: "Add a contact", icon: "add-session", kind: .secondary) { drafts.adding = true }
            }
            DisclosureSection("Follow-up timing",
                              detail: drafts.policyLoaded ? "Up to \(drafts.followupLimit) every \(drafts.followupDays) days" : "") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Sets how many follow-ups may be drafted. Sending still follows your review and standing permissions.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    StackField(label: "Follow-ups per contact (0–3)", text: $drafts.followupLimit, keyboard: .numberPad)
                    StackField(label: "Days between follow-ups", text: $drafts.followupDays, keyboard: .numberPad)
                    StackButton(label: "Save follow-up timing", kind: .secondary, disabled: working || !drafts.policyLoaded) {
                        Task { await saveFollowupPolicy() }
                    }
                }
            }
        }
        .task { await load() }
    }

    private func contactCard(_ contact: JSON) -> some View {
        let id = contact["id"].string
        let stopped = contact["stopped"].bool
        let selected = contact["selected"].bool
        return Card(spacing: 10) {
            HStack(alignment: .top) {
                Text(contact["name"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusPill(label: stopped ? "Outreach stopped" : (selected ? "Selected" : "Not selected"), tone: selected && !stopped ? .active : .quiet)
            }
            Text(contact["email"].string + (contact["company"].string.isEmpty ? "" : " · \(contact["company"].string)"))
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            if !contact["relationship"].string.isEmpty {
                Text(contact["relationship"].string).font(Typeface.caption).foregroundStyle(Palette.text)
            }
            if contact["followups"].int > 0 || contact["next_at"].double > 0 {
                Text("Follow-ups sent: \(contact["followups"].int)" + (contact["next_at"].double > 0 ? " · next draft \(dateTime(contact["next_at"].double))" : ""))
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(Array(store.account.runViews.filter { $0["target_id"].string == id && $0["kind"].string == "network" }.prefix(2).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { onOpenTask(run["id"].string) }
            }
            if !selected, !stopped {
                StackButton(label: "Select for outreach", kind: .secondary, disabled: working) {
                    var next = contact
                    next["selected"] = true
                    let selectedContact = next
                    Task { await perform("agent_save_contact", ["id": .string(id), "data": selectedContact], done: "Selected. Nothing was sent.") }
                }
            }
            if selected, !stopped {
                StackButton(label: "Draft outreach for my review", disabled: working || feature?.state == "unavailable") {
                    Task { await perform("agent_start", ["kind": "network", "target_id": .string(id)], done: "Drafting. You will review the email before anything is sent.") }
                }
            }
            if !stopped {
                StackButton(label: "Stop outreach and follow-ups", kind: .secondary, disabled: working) {
                    Task { await perform("agent_stop_contact", ["id": .string(id)], done: "Outreach stopped for this contact.") }
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            StackField(label: "Contact name", text: $drafts.name)
            StackField(label: "Verified email", text: $drafts.email, keyboard: .emailAddress, autocapitalization: .never)
            StackField(label: "Company", text: $drafts.company)
            StackField(label: "How you know them", text: $drafts.relationship, multiline: true)
            StackField(label: "Public research source (optional)", text: $drafts.sourceURL, placeholder: "https://company.com/team",
                       keyboard: .URL, autocapitalization: .never)
            StackButton(label: "Save contact", icon: "save", disabled: working || drafts.name.isBlank) { Task { await save() } }
            DisclosureSection("Import from CSV", open: !drafts.importText.isBlank) {
                VStack(alignment: .leading, spacing: 12) {
                    StackField(label: "Paste rows (name,email,relationship)", text: $drafts.importText, multiline: true, autocapitalization: .never)
                    StackButton(label: "Import contacts", kind: .secondary, disabled: working || drafts.importText.isBlank) {
                        Task {
                            if await perform("agent_import_contacts", ["content": .string(drafts.importText)],
                                             done: "Imported. Imported contacts stay unselected until you choose them.") { drafts.importText = "" }
                        }
                    }
                }
            }
            // Closing the form keeps what was typed; it is cleared only by saving or by a new session.
            StackButton(label: "Hide form", kind: .secondary) { drafts.adding = false }
        }
    }

    private func load() async {
        do {
            contacts = try await store.call("agent_contacts")["contacts"].array
            if !drafts.policyLoaded {
                let policy = try await store.call("agent_settings")["policy"]
                drafts.followupLimit = String(policy["followup_limit"].int)
                drafts.followupDays = policy["followup_days"].isNull ? "7" : String(policy["followup_days"].int)
                drafts.policyLoaded = true
            }
        }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loaded = true
    }

    private func saveFollowupPolicy() async {
        guard !working else { return }
        guard let limit = Int(drafts.followupLimit), (0...3).contains(limit), let days = Int(drafts.followupDays), (3...30).contains(days) else {
            error = "Use 0–3 follow-ups and 3–30 days between them."
            return
        }
        let generation = store.sessionGeneration
        working = true
        defer { working = false }
        do {
            var policy = try await store.call("agent_settings")["policy"]
            guard generation == store.sessionGeneration else { throw CancellationError() }
            policy["followup_limit"] = .number(Double(limit))
            policy["followup_days"] = .number(Double(days))
            try await store.call("agent_save_policy", ["policy": policy])
            error = ""
            notice = "Follow-up timing saved."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    @discardableResult
    private func perform(_ endpoint: String, _ args: JSON, done: String) async -> Bool {
        guard !working else { return false }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        do {
            let result = try await store.call(endpoint, args)
            notice = done
            if endpoint == "agent_start" { await load() } else { contacts = result["contacts"].array }
            return true
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
            return false
        }
    }

    private func save() async {
        let data: JSON = [
            "name": .string(drafts.name), "email": .string(drafts.email), "company": .string(drafts.company),
            "relationship": .string(drafts.relationship), "source": "User supplied", "source_url": .string(drafts.sourceURL), "selected": true,
        ]
        let ok = await perform("agent_save_contact", ["data": data],
                               done: "Contact saved. Nothing was sent. Tap Draft outreach when you are ready.")
        if ok {
            drafts.name = ""; drafts.email = ""; drafts.company = ""; drafts.relationship = ""; drafts.sourceURL = ""
            drafts.adding = false
        }
    }
}

/// LinkedIn profile review: save the URL and target role, then start a review task.
@MainActor
struct LinkedInProfileCard: View {
    @Bindable var drafts: NetworkDrafts
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var loading = true
    @State private var working = false
    @State private var error = ""
    @State private var settingsError = ""
    @State private var notice = ""
    /// The `agent_settings` result: saved model choice and standing permissions. Null until loaded.
    @State private var settings: JSON = .null

    private var feature: AgentFeature? { store.account.feature("linkedin") }
    private var steps: [LinkedInSetup.Step] {
        LinkedInSetup.steps(feature: feature, settings: settings, now: Date().timeIntervalSince1970)
    }
    private var step: LinkedInSetup.Step { steps.first ?? .profile }

    /// One unmet requirement at a time; requirements the account already meets are never listed.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepView
            if steps.count > 1 {
                Text("Then: " + steps.dropFirst().map(\.title).joined(separator: " · "))
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            if !settingsError.isEmpty {
                MessageLine(text: "Couldn’t check your setup: \(settingsError)")
                StackButton(label: "Retry setup check", icon: "refresh", kind: .secondary, disabled: working) {
                    Task { await recheck() }
                }
            }
            ForEach(Array(store.account.runViews.filter { $0["target_id"].string == "self" && $0["kind"].string == "linkedin" }.prefix(3).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { onOpenTask(run["id"].string) }
            }
        }
        .task {
            await loadProfile()
            await loadSettings()
        }
        // A permission or model change made elsewhere (Rules, Account) arrives through the readiness checks.
        .onChange(of: feature) { _, _ in Task { await loadSettings() } }
        .onChange(of: store.sessionGeneration) { _, _ in
            settings = .null
            settingsError = ""
            error = ""
            notice = ""
            Task { await loadSettings() }
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepView: some View {
        switch step {
        case .switchModel(let selection, let name, let reason):
            screen("Use \(name) for reviews",
                   "The model saved for this account isn’t available\(reason.isEmpty ? "." : ": \(reason)") \(name) is configured on this server. Sign-in and service availability are checked when a review starts.",
                   note: "Captured profile text goes to \(name). Change this any time in Account → Agent model.") {
                StackButton(label: "Use \(name)", disabled: working) { Task { await useModel(selection) } }
            }
        case .allowModel:
            allowModelStep
        case .modelUnavailable(let message):
            screen("A model isn’t connected yet", message,
                   note: "Only whoever runs this Stack server can connect one.") { operatorHelp }
        case .browserUnavailable(let message):
            screen("The browser worker isn’t available", message,
                   note: "LinkedIn review reads your profile in an isolated browser. Only whoever runs this Stack server can turn it on.") {
                operatorHelp
            }
        case .profile:
            profileStep
        }
    }

    @ViewBuilder
    private var allowModelStep: some View {
        let rearmed = LinkedInSetup.rearmedActions(settings["policy"], now: Date().timeIntervalSince1970)
        if rearmed.isEmpty {
            screen("Allow Model permission",
                   "LinkedIn review sends the text Stack captures from your profile to your model. Review your current choices in Rules, turn on Model, and save when you’re ready.",
                   note: "Rules shows the standing-permission expiry and keeps each permission under your control.") {
                StackButton(label: "Open Rules") { onNavigate("rules") }
            }
        } else {
            screen("Review your saved permissions",
                   "Turning standing permissions on would also re-enable: \(rearmed.joined(separator: ", ")). Choose what to allow in Rules, then come back.",
                   note: "Your saved permission choices are not changed here.") {
                StackButton(label: "Open Rules") { onNavigate("rules") }
            }
        }
    }

    @ViewBuilder
    private var operatorHelp: some View {
        if !settings["account_id"].string.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your account ID, for whoever sets this up").font(Typeface.caption).foregroundStyle(Palette.muted)
                Text(settings["account_id"].string).font(Typeface.caption).foregroundStyle(Palette.text).textSelection(.enabled)
            }
        }
        StackButton(label: "Check again", icon: "refresh", disabled: working) { Task { await recheck() } }
        if let alternative = feature?.alternative, !alternative.isEmpty {
            Text("Meanwhile: \(alternative)").font(Typeface.caption).foregroundStyle(Palette.text)
            StackButton(label: "Open Resume", kind: .secondary) { onNavigate("resume") }
        }
    }

    @ViewBuilder
    private var profileStep: some View {
        let model = LinkedInSetup.modelName(settings["model_selection"].string)
        VStack(alignment: .leading, spacing: 16) {
            Text("See what a recruiter learns from your profile, with prioritized fixes and rewrites.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            if loading {
                Text("Loading your saved profile…").font(Typeface.caption).foregroundStyle(Palette.muted)
            } else if !drafts.linkedInLoaded {
                // Fields stay hidden until the saved profile has loaded, so a retry can never overwrite typing.
                StackButton(label: "Retry loading profile", icon: "refresh", kind: .secondary) { Task { await loadProfile() } }
            } else {
                StackField(label: "Your LinkedIn profile URL", text: $drafts.linkedInURL, placeholder: "https://www.linkedin.com/in/your-name/",
                           keyboard: .URL, autocapitalization: .never)
                StackField(label: "Target role (optional)", text: $drafts.linkedInRole, placeholder: "e.g. Product designer")
            }
            Text("You sign in to LinkedIn in the agent browser and watch it read your profile. Captured profile text goes to your \(model.isEmpty ? "configured model" : model); login details stay in that temporary session. You choose which edits to apply.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Review my LinkedIn profile", disabled: loading || working || !drafts.linkedInLoaded || drafts.linkedInURL.isBlank) {
                Task { await start() }
            }
            if !loading, drafts.linkedInLoaded, !drafts.linkedInURL.isBlank,
               drafts.linkedInURL != drafts.linkedInSavedURL || drafts.linkedInRole != drafts.linkedInSavedRole {
                StackButton(label: "Save profile details", kind: .secondary, disabled: working) { Task { await save() } }
            }
            if let facts = feature?.checks.first(where: { $0.key == "facts" && !$0.ok }) {
                // Optional, so it follows the action instead of gating it.
                HStack {
                    Text("Optional: \(facts.fix)").font(Typeface.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Chip(label: "Open facts") { onNavigate("facts") }
                }
            }
        }
    }

    private func screen<Actions: View>(_ title: String, _ detail: String, note: String = "",
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(Typeface.title).foregroundStyle(Palette.ink)
            Text(detail).font(Typeface.body).foregroundStyle(Palette.text)
            if !note.isEmpty { Text(note).font(Typeface.caption).foregroundStyle(Palette.muted) }
            actions()
        }
    }

    // MARK: Data

    /// On failure the readiness checks in the account snapshot still decide the step.
    private func loadSettings() async {
        do {
            let latest = try await store.call("agent_settings")
            if !latest["error"].string.isEmpty {
                settings = .null
                settingsError = latest["error"].string
                return
            }
            settings = latest
            settingsError = ""
        } catch {
            guard !(error is CancellationError) else { return }
            settings = .null
            settingsError = error.localizedDescription
        }
    }

    private func recheck() async {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        await store.refresh()
        await loadSettings()
    }

    private func useModel(_ selection: String) async {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        let generation = store.sessionGeneration
        do {
            let latest = try await store.call("agent_save_model", ["selection": .string(selection)])
            guard generation == store.sessionGeneration else { return }
            if !latest["error"].string.isEmpty {
                error = latest["error"].string
                await loadSettings()
                return
            }
            settings = latest
            notice = "Using \(LinkedInSetup.modelName(selection))."
            await store.refresh()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    /// Reopening keeps unsaved edits: the saved profile is read only until it has loaded once, and the
    /// fields are not editable before then, so there is never a draft for a retry to overwrite.
    private func loadProfile() async {
        guard !drafts.linkedInLoaded else { loading = false; return }
        loading = true
        error = ""
        defer { loading = false }
        do {
            let result = try await store.call("agent_linkedin_profile")
            drafts.linkedInSavedURL = result["url"].string
            drafts.linkedInURL = drafts.linkedInSavedURL
            drafts.linkedInRole = result["target_role"].string
            drafts.linkedInSavedRole = drafts.linkedInRole
            drafts.linkedInLoaded = true
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func save() async {
        guard !working else { return }
        guard let url = LinkedInSetup.profileURL(drafts.linkedInURL) else {
            error = LinkedInSetup.profileURLMessage
            return
        }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        do {
            let result = try await store.call("agent_linkedin_profile",
                                              ["url": .string(url), "target_role": .string(drafts.linkedInRole)])
            drafts.linkedInURL = result["url"].string
            drafts.linkedInSavedURL = drafts.linkedInURL
            drafts.linkedInSavedRole = drafts.linkedInRole
            notice = "Saved to your Stack account."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func start() async {
        guard !working else { return }
        guard let url = LinkedInSetup.profileURL(drafts.linkedInURL) else {
            error = LinkedInSetup.profileURLMessage
            return
        }
        working = true
        error = ""
        defer { working = false }
        do {
            let result = try await store.call("agent_linkedin_start", ["url": .string(url), "target_role": .string(drafts.linkedInRole)])
            onOpenTask(result["id"].string)
        } catch {
            guard !(error is CancellationError) else { return }
            // The server's reason stays on screen; the step above it updates if a requirement changed.
            self.error = error.localizedDescription
            await store.refresh()
            await loadSettings()
        }
    }
}

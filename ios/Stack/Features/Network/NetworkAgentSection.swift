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
    @State private var error = ""
    @State private var notice = ""
    /// Model choice returned with the saved profile.
    @State private var settings: JSON = .null

    /// LinkedIn goes directly to profile entry; the selected model is used when analysis runs.
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            profileStep
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            ForEach(Array(store.account.runViews.filter { $0["target_id"].string == "self" && $0["kind"].string == "linkedin" }.prefix(3).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { onOpenTask(run["id"].string) }
            }
        }
        .task {
            await loadProfile()
        }
        .onChange(of: store.sessionGeneration) { _, _ in
            settings = .null
            error = ""
            notice = ""
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
            }
            StackField(label: "Your LinkedIn profile URL", text: $drafts.linkedInURL, placeholder: "https://www.linkedin.com/in/your-name/",
                           keyboard: .URL, autocapitalization: .never)
            StackField(label: "Target role (optional)", text: $drafts.linkedInRole, placeholder: "e.g. Product designer")
            Text("You sign in to LinkedIn in the agent browser and watch it read your profile. Captured profile text goes to your \(model.isEmpty ? "configured model" : model); login details stay in that temporary session. You choose which edits to apply.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Review my LinkedIn profile", disabled: false) {
                Task { await start() }
            }
            if !loading, drafts.linkedInLoaded, !drafts.linkedInURL.isBlank,
               drafts.linkedInURL != drafts.linkedInSavedURL || drafts.linkedInRole != drafts.linkedInSavedRole {
                StackButton(label: "Save profile details", kind: .secondary, disabled: false) { Task { await save() } }
            }

        }
    }

    private func loadProfile() async {
        loading = true
        error = ""
        defer { loading = false }
        do {
            let result = try await store.call("agent_linkedin_profile")
            settings = ["model_selection": result["model_selection"]]
            drafts.linkedInSavedURL = result["url"].string
            drafts.linkedInSavedRole = result["target_role"].string
            drafts.linkedInLoaded = true
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func save() async {
        let url = LinkedInSetup.profileURL(drafts.linkedInURL)
        error = ""
        notice = ""
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
        let url = LinkedInSetup.profileURL(drafts.linkedInURL)
        error = ""
        do {
            let result = try await store.call("agent_linkedin_start", ["url": .string(url), "target_role": .string(drafts.linkedInRole)])
            onOpenTask(result["id"].string)
        } catch {
            guard !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }
}

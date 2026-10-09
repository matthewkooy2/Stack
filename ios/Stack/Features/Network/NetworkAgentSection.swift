import SwiftUI

/// Your real contacts. Saving never sends; outreach starts only on request and waits for review.
@MainActor
struct NetworkAgentSection: View {
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store

    @State private var contacts: [JSON] = []
    @State private var loaded = false
    @State private var adding = false
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""

    @State private var name = ""
    @State private var email = ""
    @State private var company = ""
    @State private var relationship = ""
    @State private var sourceURL = ""
    @State private var importText = ""
    @State private var followupLimit = "0"
    @State private var followupDays = "7"
    @State private var policyLoaded = false

    private var feature: AgentFeature? { store.account.feature("networking") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LinkedInProfileCard(onOpenTask: onOpenTask, onNavigate: onNavigate)
            HStack(spacing: 10) {
                GlyphView(name: "network", size: 20)
                Text("Your contacts").font(Typeface.title).foregroundStyle(Palette.ink)
            }
            Text("Add people you know or have researched. Saving a contact never contacts them. When you ask, Stack drafts a short email from your confirmed facts and waits for you to review, edit and approve it.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            if let feature { FeatureCardView(feature: feature, onAction: onNavigate, compact: true) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            ForEach(Array(contacts.enumerated()), id: \.offset) { _, contact in contactCard(contact) }
            if loaded, contacts.isEmpty { Text("No contacts yet.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            if adding { form } else {
                StackButton(label: "Add a contact", icon: "add-session", kind: .secondary) { adding = true }
            }
            Card(spacing: 10) {
                Text("Follow-up timing").font(Typeface.option).foregroundStyle(Palette.icon)
                Text("Set how many follow-ups may be drafted and the days between them. Sending still follows your review and standing permissions.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                StackField(label: "Follow-ups per contact (0–3)", text: $followupLimit, keyboard: .numberPad)
                StackField(label: "Days between follow-ups", text: $followupDays, keyboard: .numberPad)
                StackButton(label: "Save follow-up timing", kind: .secondary, disabled: working || !policyLoaded) {
                    Task { await saveFollowupPolicy() }
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
            StackField(label: "Contact name", text: $name)
            StackField(label: "Verified email", text: $email, keyboard: .emailAddress, autocapitalization: .never)
            StackField(label: "Company", text: $company)
            StackField(label: "How you know them", text: $relationship, multiline: true)
            StackField(label: "Public research source (optional)", text: $sourceURL, placeholder: "https://company.com/team",
                       keyboard: .URL, autocapitalization: .never)
            StackButton(label: "Save contact", icon: "save", disabled: working || name.isBlank) { Task { await save() } }
            StackField(label: "Or paste CSV rows (name,email,relationship)", text: $importText, multiline: true, autocapitalization: .never)
            StackButton(label: "Import contacts", kind: .secondary, disabled: working || importText.isBlank) {
                Task {
                    if await perform("agent_import_contacts", ["content": .string(importText)],
                                     done: "Imported. Imported contacts stay unselected until you choose them.") { importText = "" }
                }
            }
            StackButton(label: "Close contact form", kind: .secondary) { adding = false }
        }
    }

    private func load() async {
        do {
            contacts = try await store.call("agent_contacts")["contacts"].array
            if !policyLoaded {
                let policy = try await store.call("agent_settings")["policy"]
                followupLimit = String(policy["followup_limit"].int)
                followupDays = policy["followup_days"].isNull ? "7" : String(policy["followup_days"].int)
                policyLoaded = true
            }
        }
        catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loaded = true
    }

    private func saveFollowupPolicy() async {
        guard !working else { return }
        guard let limit = Int(followupLimit), (0...3).contains(limit), let days = Int(followupDays), (3...30).contains(days) else {
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
            "name": .string(name), "email": .string(email), "company": .string(company),
            "relationship": .string(relationship), "source": "User supplied", "source_url": .string(sourceURL), "selected": true,
        ]
        let ok = await perform("agent_save_contact", ["data": data],
                               done: "Contact saved. Nothing was sent. Tap Draft outreach when you are ready.")
        if ok {
            name = ""; email = ""; company = ""; relationship = ""; sourceURL = ""
            adding = false
        }
    }
}

/// LinkedIn profile review: save the URL and target role, then start a review task.
@MainActor
struct LinkedInProfileCard: View {
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store
    @State private var url = ""
    @State private var role = ""
    @State private var savedURL = ""
    @State private var savedRole = ""
    @State private var loading = true
    @State private var working = false
    @State private var error = ""
    @State private var notice = ""

    private var feature: AgentFeature? { store.account.feature("linkedin") }

    var body: some View {
        Card(spacing: 12) {
            Text("Strengthen your LinkedIn profile").font(Typeface.title).foregroundStyle(Palette.ink)
            Text("See what a recruiter can learn from your headline, About, experience and skills. Get prioritized fixes and suggested rewrites grounded in your profile and confirmed facts.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            if let feature { FeatureCardView(feature: feature, onAction: onNavigate, compact: true) }
            if loading {
                Text("Loading your saved profile…").font(Typeface.caption).foregroundStyle(Palette.muted)
            } else {
                StackField(label: "Your LinkedIn profile URL", text: $url, placeholder: "https://www.linkedin.com/in/your-name/",
                           keyboard: .URL, autocapitalization: .never)
            }
            Text("Your profile URL and target role are saved to your Stack account for future reviews.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Save profile details", kind: .secondary,
                        disabled: loading || working || url.isBlank || (url == savedURL && role == savedRole)) { Task { await save() } }
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            StackField(label: "Target role (optional)", text: $role, placeholder: "e.g. Product designer")
            Text("Sign in to LinkedIn inside the agent browser, then confirm the profile is yours. You can watch the agent read it. Captured profile text goes to your configured model; login details stay in the temporary browser session. You choose which edits to apply.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            StackButton(label: "Review my LinkedIn profile", disabled: loading || working || url.isBlank || feature?.state == "unavailable") {
                Task { await start() }
            }
            ForEach(Array(store.account.runViews.filter { $0["target_id"].string == "self" && $0["kind"].string == "linkedin" }.prefix(3).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { onOpenTask(run["id"].string) }
            }
        }
        .task {
            do {
                let result = try await store.call("agent_linkedin_profile")
                savedURL = result["url"].string
                url = savedURL
                role = result["target_role"].string
                savedRole = role
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            loading = false
        }
    }

    private func save() async {
        guard !working else { return }
        working = true
        error = ""
        notice = ""
        defer { working = false }
        do {
            let result = try await store.call("agent_linkedin_profile", ["url": .string(url), "target_role": .string(role)])
            url = result["url"].string
            savedURL = url
            savedRole = role
            notice = "Saved to your Stack account."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func start() async {
        guard !working else { return }
        working = true
        error = ""
        defer { working = false }
        do {
            let result = try await store.call("agent_linkedin_start", ["url": .string(url), "target_role": .string(role)])
            onOpenTask(result["id"].string)
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

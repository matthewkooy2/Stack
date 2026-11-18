import Observation
import SwiftUI

/// Unfinished Network edits. Owned above the tool sheets so closing one never discards typed work;
/// the owner clears it when the account or session changes.
@Observable
@MainActor
final class NetworkDrafts {
    var name = ""
    var email = ""
    var company = ""
    var relationship = ""
    var sourceURL = ""
    var importText = ""
    var followupLimit = "0"
    var followupDays = "7"
    var policyLoaded = false

    func reset() {
        name = ""; email = ""; company = ""; relationship = ""; sourceURL = ""; importText = ""
        followupLimit = "0"; followupDays = "7"; policyLoaded = false
    }
}

/// Your real contacts. Saving never sends; outreach starts only on request and waits for review.
@MainActor
struct NetworkAgentSection: View {
    @Bindable var drafts: NetworkDrafts
    @Binding var working: Bool
    let destination: NetworkSheet
    let onOpenTask: (String) -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var contacts: [JSON] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var error = ""
    @State private var notice = ""

    private var feature: AgentFeature? { store.account.feature("networking") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !error.isEmpty { MessageLine(text: error) }
            if !notice.isEmpty { MessageLine(text: notice, isError: false) }
            switch destination {
            case .add: form.disabled(working)
            case .csv: importForm.disabled(working)
            case .settings: settings
            case .contact(let item):
                if let contact = contacts.first(where: { $0["id"].string == item.id }) {
                    contactCard(contact)
                    if let feature, feature.state != "ready" {
                        DisclosureSection("Outreach setup", open: true) {
                            FeatureCardView(feature: feature, onAction: onNavigate, compact: true)
                        }
                    }
                } else if loaded && error.isEmpty {
                    Text("This contact is no longer available.").font(Typeface.body).foregroundStyle(Brand.muted)
                }
            case .discovery: EmptyView()
            }
            if loading && !loaded { ProgressView().tint(Brand.accent) }
            if !loaded && !loading && !error.isEmpty {
                switch destination {
                case .settings, .contact:
                    Button("Try again") { Task { await load() } }.frame(minHeight: 44)
                default: EmptyView()
                }
            }
        }
        .task { await load() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel(text: "Follow-up timing")
            Text("Choose how often Stack can draft a follow-up for your review.")
                .font(.subheadline).foregroundStyle(Brand.muted)
            StackField(label: "Follow-ups per contact (0–3)", text: $drafts.followupLimit, keyboard: .numberPad)
            StackField(label: "Days between follow-ups", text: $drafts.followupDays, keyboard: .numberPad)
            StackButton(label: "Save follow-up timing", disabled: working || !drafts.policyLoaded) {
                Task { await saveFollowupPolicy() }
            }
            if let feature {
                DisclosureSection("Outreach setup", open: feature.state != "ready") {
                    FeatureCardView(feature: feature, onAction: onNavigate, compact: true)
                }
            }
        }
    }

    private func contactCard(_ contact: JSON) -> some View {
        let id = contact["id"].string
        let stopped = contact["stopped"].bool
        let selected = contact["selected"].bool
        return VStack(alignment: .leading, spacing: 12) {
            let info = NetworkContact(contact)
            HStack(spacing: 12) {
                Avatar(initials: info.initials, size: 48)
                VStack(alignment: .leading, spacing: 4) {
                    if !info.detail.isEmpty {
                        Text(info.detail).font(.headline).foregroundStyle(Brand.ink)
                    }
                    if !info.email.isEmpty && info.detail != info.email {
                        Text(info.email).font(.subheadline).foregroundStyle(Brand.muted).textSelection(.enabled)
                    }
                }
            }
            if stopped {
                StatusPill(label: "Outreach stopped")
            }
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
        }
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            StackField(label: "Paste rows (name,email,relationship)", text: $drafts.importText,
                       multiline: true, autocapitalization: .never)
            StackButton(label: "Import contacts", disabled: working || drafts.importText.isBlank) {
                Task {
                    if await perform("agent_import_contacts", ["content": .string(drafts.importText)], done: "") {
                        drafts.importText = ""
                        dismiss()
                    }
                }
            }
        }
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        error = ""
        defer { loading = false }
        do {
            switch destination {
            case .contact:
                contacts = try await store.call("agent_contacts")["contacts"].array
            case .settings where !drafts.policyLoaded:
                let policy = try await store.call("agent_settings")["policy"]
                drafts.followupLimit = String(policy["followup_limit"].int)
                drafts.followupDays = policy["followup_days"].isNull ? "7" : String(policy["followup_days"].int)
                drafts.policyLoaded = true
            default: break
            }
            loaded = true
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
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
            dismiss()
        }
    }
}

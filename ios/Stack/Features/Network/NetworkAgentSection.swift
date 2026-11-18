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
                        DisclosureSection("Setup", open: true) {
                            FeatureCardView(feature: feature, onAction: onNavigate, compact: true)
                        }
                    }
                } else if loaded && error.isEmpty {
                    EmptyNote(icon: "network", title: "Contact unavailable")
                }
            case .discovery: EmptyView()
            }
            if loading && !loaded { SkeletonRow() }
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
        VStack(alignment: .leading, spacing: 16) {
            Card {
                StackField(label: "Follow-ups per contact", text: $drafts.followupLimit, keyboard: .numberPad)
                StackField(label: "Days between follow-ups", text: $drafts.followupDays, keyboard: .numberPad)
            }
            StackButton(label: "Save", disabled: working || !drafts.policyLoaded) {
                Task { await saveFollowupPolicy() }
            }
            if let feature {
                DisclosureSection("Setup", open: feature.state != "ready") {
                    FeatureCardView(feature: feature, onAction: onNavigate, compact: true)
                }
            }
        }
    }

    private func contactCard(_ contact: JSON) -> some View {
        let id = contact["id"].string
        let info = NetworkContact(contact)
        let stopped = info.stopped
        let selected = contact["selected"].bool
        let followups = contact["followups"].int
        let runs = Array(store.account.runViews.filter { $0["target_id"].string == id && $0["kind"].string == "network" }.prefix(2).enumerated())
        return VStack(alignment: .leading, spacing: 20) {
            hero(info, stopped: stopped)
            HStack(alignment: .top, spacing: 24) {
                if let url = URL(string: "mailto:" + info.email), !info.email.isEmpty {
                    Link(destination: url) { roundAction("envelope.fill", "Email") }
                        .buttonStyle(.tap(scale: 0.92))
                        .accessibilityLabel("Email \(info.name)")
                }
                if !stopped {
                    if selected {
                        Button {
                            Task { await perform("agent_start", ["kind": "network", "target_id": .string(id)], done: "Drafting. Nothing sends without your review") }
                        } label: { roundAction("square.and.pencil", "Draft", prominent: true) }
                            .buttonStyle(.tap(scale: 0.92))
                            .disabled(working || feature?.state == "unavailable")
                            .accessibilityLabel("Draft outreach")
                    } else {
                        Button {
                            var next = contact
                            next["selected"] = true
                            let selectedContact = next
                            Task { await perform("agent_save_contact", ["id": .string(id), "data": selectedContact], done: "Selected") }
                        } label: { roundAction("checkmark.circle", "Select", prominent: true) }
                            .buttonStyle(.tap(scale: 0.92))
                            .disabled(working)
                            .accessibilityLabel("Select for outreach")
                    }
                    Button {
                        Task { await perform("agent_stop_contact", ["id": .string(id)], done: "Outreach stopped") }
                    } label: { roundAction("hand.raised.fill", "Stop", danger: true) }
                        .buttonStyle(.tap(scale: 0.92))
                        .disabled(working)
                        .accessibilityLabel("Stop outreach")
                }
            }
            .frame(maxWidth: .infinity)
            .sensoryFeedback(.success, trigger: notice) { _, new in !new.isEmpty }

            if !info.email.isEmpty || !info.relationship.isEmpty || followups > 0 || info.nextFollowup > 0 {
                Card {
                    VStack(alignment: .leading, spacing: 0) {
                        let rows = detailRows(info, followups: followups)
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.0).font(.footnote).foregroundStyle(Brand.muted)
                                Text(row.1).font(Typeface.body).foregroundStyle(Brand.ink).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .overlay(alignment: .bottom) {
                                if index < rows.count - 1 { Rectangle().fill(Palette.rule.opacity(0.7)).frame(height: 0.5) }
                            }
                        }
                    }
                    .padding(.vertical, -12)
                }
            }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    SectionHeader(title: "Activity")
                    ForEach(runs, id: \.offset) { _, run in
                        TaskRow(run: run) { onOpenTask(run["id"].string) }
                    }
                }
            }
        }
    }

    private func hero(_ info: NetworkContact, stopped: Bool) -> some View {
        VStack(spacing: 6) {
            Avatar(name: info.name, size: 96).padding(.bottom, 8)
            Text(info.name).font(.title.weight(.bold)).foregroundStyle(Brand.ink).multilineTextAlignment(.center)
            if !info.role.isEmpty {
                Text(info.role).font(.body.weight(.medium)).foregroundStyle(Brand.ink.opacity(0.85))
            }
            if !info.company.isEmpty {
                Text(info.company).font(.subheadline).foregroundStyle(Brand.muted)
            }
            if stopped {
                StatusPill(text: "Outreach stopped", tone: .neutral).padding(.top, 4)
            } else if info.followupDue() {
                StatusPill(text: "Follow up", tone: .warning).padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
    }

    private func roundAction(_ symbol: String, _ title: String, prominent: Bool = false, danger: Bool = false) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : (danger ? Palette.danger : Brand.accent))
                .frame(width: 56, height: 56)
                .background(prominent ? Palette.button : (danger ? Palette.danger.opacity(0.11) : Palette.halo), in: Circle())
            Text(title).font(.caption.weight(.medium)).foregroundStyle(Brand.muted)
        }
        .frame(minWidth: 64)
        .contentShape(Rectangle())
    }

    private func detailRows(_ info: NetworkContact, followups: Int) -> [(String, String)] {
        var rows: [(String, String)] = []
        if !info.email.isEmpty { rows.append(("Email", info.email)) }
        if !info.relationship.isEmpty { rows.append(("How you know them", info.relationship)) }
        if followups > 0 { rows.append(("Follow-ups", "\(followups) sent")) }
        if info.nextFollowup > 0 && !info.stopped { rows.append(("Next draft", dateTime(info.nextFollowup))) }
        return rows
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                StackField(label: "Contact name", text: $drafts.name)
                StackField(label: "Email", text: $drafts.email, keyboard: .emailAddress, autocapitalization: .never)
                StackField(label: "Company", text: $drafts.company)
                StackField(label: "How you know them", text: $drafts.relationship, multiline: true)
                StackField(label: "Source link (optional)", text: $drafts.sourceURL, placeholder: "https://company.com/team",
                           keyboard: .URL, autocapitalization: .never)
            }
            StackButton(label: "Save contact", disabled: working || drafts.name.isBlank) { Task { await save() } }
        }
    }

    private var importForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            StackField(label: "Paste contacts", text: $drafts.importText, placeholder: "Name, email, relationship",
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
            error = "Use 0–3 follow-ups, 3–30 days apart"
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
            notice = "Saved"
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
                               done: "Contact saved")
        if ok {
            drafts.name = ""; drafts.email = ""; drafts.company = ""; drafts.relationship = ""; drafts.sourceURL = ""
            dismiss()
        }
    }
}

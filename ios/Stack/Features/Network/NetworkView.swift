import SwiftUI

/// Both surfaces live inside the existing Network destination. Ordinary bottom-tab navigation
/// preserves the selected surface; explicit contact destinations open the roster instead.
@MainActor
struct NetworkView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    var onProfile: () -> Void

    @State private var section: NetworkSection = .presence
    @State private var roster = NetworkRoster()
    @State private var selected: NetworkContact?
    @State private var showContacts = false
    @State private var linkedIn = false
    @State private var secondary: NetworkSecondaryTool?
    @State private var presenceRefresh = 0
    /// Held above sheets so closing a tool never discards unfinished edits.
    @State private var drafts = NetworkDrafts()

    var body: some View {
        ZStack(alignment: .top) {
            // Keep both scroll positions and in-progress edits when switching sections.
            Page {
                header
                PresenceView(refreshID: presenceRefresh)
            }
            .opacity(section == .presence ? 1 : 0)
            .allowsHitTesting(section == .presence)
            .accessibilityHidden(section != .presence)
            Page {
                header
                networkContent
            }
            .opacity(section == .network ? 1 : 0)
            .allowsHitTesting(section == .network)
            .accessibilityHidden(section != .network)
            .refreshable { await roster.load(store: store) }
        }
        .background(Brand.page.ignoresSafeArea())
        .tint(Brand.accent)
        .task { openPendingContact(); await roster.load(store: store); openPendingContact() }
        .onChange(of: store.pendingOpen) { _, _ in openPendingContact() }
        .onChange(of: roster.loading) { _, loading in if !loading { openPendingContact() } }
        .onChange(of: roster.contacts) { _, _ in openPendingContact() }
        .onChange(of: store.sessionGeneration) { _, _ in reset() }
        .onChange(of: store.phase) { _, phase in if phase != .ready { reset() } }
        .sheet(item: $selected, onDismiss: refreshContacts) { contact in
            NetworkToolSheet(title: contact.name, contactID: contact.id, drafts: drafts).environment(store)
        }
        .sheet(isPresented: $showContacts, onDismiss: refreshContacts) {
            NetworkToolSheet(title: "Your contacts", drafts: drafts).environment(store)
        }
        .sheet(item: $secondary) { tool in
            switch tool {
            case .profiles: PublicProfilesView().environment(store)
            case .discovery(let id): DiscoveryCatalogView(initialRecordID: id).environment(store)
            }
        }
        .fullScreenCover(isPresented: $linkedIn, onDismiss: {
            presenceRefresh += 1
            Task { await store.refresh() }
        }) { LinkedInFlow().environment(store) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScreenHeader(title: "Network", onProfile: onProfile)
            HStack(alignment: .center, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 2) { sectionButton(.presence); sectionButton(.network) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) { sectionButton(.presence); sectionButton(.network) }
                }
                .padding(3)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                Spacer(minLength: 0)
                Menu {
                    Button("LinkedIn review", systemImage: "sparkles") { linkedIn = true }
                    Button("Public profile drafts", systemImage: "person.crop.rectangle") { secondary = .profiles }
                    Button("Discovery catalog", systemImage: "person.text.rectangle") { secondary = .discovery(nil) }
                    Button("Refresh contacts", systemImage: "arrow.clockwise") { refreshContacts() }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Brand.ink)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Network options")
                .accessibilityIdentifier("network-options")
            }
        }
    }

    private func sectionButton(_ value: NetworkSection) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { section = value }
        } label: {
            Text(value.rawValue)
                .font(.subheadline.weight(section == value ? .semibold : .regular))
                .foregroundStyle(section == value ? Brand.accent : Brand.muted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(section == value ? Palette.halo : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.tap(scale: 0.98))
        .accessibilityIdentifier(value == .presence ? "network-presence-tab" : "network-roster-tab")
        .accessibilityAddTraits(section == value ? .isSelected : [])
    }

    @ViewBuilder
    private var networkContent: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Contacts").font(Typeface.section).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button { showContacts = true } label: {
                Label("Manage", systemImage: "person.2")
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            }
            .foregroundStyle(Brand.accent)
            .accessibilityLabel("Your contacts")
            .accessibilityHint("Add, import or manage contacts")
            .accessibilityIdentifier("network-your-contacts")
        }
        if roster.loading && !roster.loaded {
            ProgressView("Loading contacts…")
                .frame(maxWidth: .infinity).padding(.vertical, 24)
                .foregroundStyle(Brand.muted)
        }
        if !roster.error.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(roster.error).font(.subheadline).foregroundStyle(Brand.muted)
                Button("Retry loading contacts") { refreshContacts() }
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(roster.loading)
            }
            .accessibilityIdentifier("network-load-error")
        }
        if roster.loaded && roster.contacts.isEmpty && roster.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("No contacts yet").font(Typeface.section).foregroundStyle(Brand.ink)
                    .accessibilityIdentifier("network-empty")
                Text("Add someone you know or import a contact list.")
                    .font(Typeface.body).foregroundStyle(Brand.muted)
                StackButton(label: "Add a contact", icon: "add-session") {
                    drafts.adding = true
                    showContacts = true
                }
                .padding(.top, 8)
            }
            .padding(20)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        if !roster.contacts.isEmpty {
            VStack(spacing: 0) {
                ForEach(roster.contacts) { contact in
                    contactRow(contact)
                    if contact.id != roster.contacts.last?.id { Divider() }
                }
            }
            .padding(.horizontal, 16)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func contactRow(_ contact: NetworkContact) -> some View {
        Button { selected = contact } label: {
            HStack(spacing: 14) {
                Text(contact.initials)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Brand.accent)
                    .frame(width: 42, height: 42)
                    .background(Palette.halo, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.name).font(.headline).foregroundStyle(Brand.ink)
                    let detail = [contact.role, contact.company].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(Brand.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold)).foregroundStyle(Brand.muted).accessibilityHidden(true)
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.99))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Open contact and outreach drafts")
        .accessibilityIdentifier("network-contact-\(contact.id)")
    }

    private func refreshContacts() { Task { await roster.load(store: store) } }

    private func openPendingContact() {
        if store.pendingOpen["network_section"] == "network" {
            section = .network
            store.pendingOpen.removeValue(forKey: "network_section")
        }
        guard store.pendingOpen["target_type"] == "contact", let id = store.pendingOpen["target_id"] else { return }
        section = .network
        // Catalog reminders can resolve from the cached account even if the real-contact read fails.
        if let record = store.account.contacts.first(where: { $0.id == id }), store.account.person(for: record) != nil {
            secondary = .discovery(id)
            store.pendingOpen = [:]
            return
        }
        // Missing or deleted real contacts never open a blank detail sheet.
        guard roster.loaded, !roster.loading else { return }
        if let contact = roster.contacts.first(where: { $0.id == id }) { selected = contact }
        else { showContacts = true }
        store.pendingOpen = [:]
    }

    private func reset() {
        roster.reset(); drafts.reset(); selected = nil; showContacts = false; linkedIn = false
        section = .presence
        secondary = nil
    }
}

private enum NetworkSecondaryTool: Identifiable {
    case profiles
    case discovery(String?)
    var id: String {
        switch self {
        case .profiles: return "profiles"
        case .discovery(let id): return "discovery:" + (id ?? "")
        }
    }
}

enum NetworkSection: String, CaseIterable {
    case presence = "Your Presence"
    case network = "Your Network"
}

/// Outreach gets its own screen, with agent tasks opening from here.
@MainActor
private struct NetworkToolSheet: View {
    let title: String
    var contactID: String? = nil
    let drafts: NetworkDrafts
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskTarget?
    @State private var hubPage: AgentPage?
    @State private var hubAction = ""

    var body: some View {
        SheetPage(title: title) {
            NetworkAgentSection(drafts: drafts, contactID: contactID, onOpenTask: { task = TaskTarget(id: $0) }, onNavigate: navigate)
        }
        .sheet(item: $task) { target in AgentTaskSheet(taskID: target.id).environment(store) }
        .sheet(item: $hubPage) { page in AgentHubView(initialPage: page, initialAction: hubAction).environment(store) }
    }

    /// Rules, facts and Google connection live in the Agents hub, which tab navigation cannot reach, so they open
    /// over this sheet and closing them returns here. Only tab destinations leave the sheet.
    private func navigate(_ action: String) {
        switch action {
        case "rules", "facts", "features":
            hubAction = ""
            hubPage = action == "facts" ? .facts : (action == "features" ? .features : .email)
        case _ where action.hasPrefix("connect:"):
            hubAction = action
            hubPage = .email
        default:
            dismiss()
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
        }
    }
}

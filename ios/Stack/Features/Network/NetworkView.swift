import SwiftUI

/// Both surfaces live inside the existing Network destination. Ordinary bottom-tab navigation
/// preserves the selected surface; explicit contact destinations open the roster instead.
@MainActor
struct NetworkView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    var onProfile: () -> Void

    @State private var section: NetworkSection = .network
    @State private var roster = NetworkRoster()
    @State private var sheet: NetworkSheet?
    @State private var drafts = NetworkDrafts()
    @State private var query = ""
    @State private var presenceReload = 0
    @State private var unavailableContact = false
    @ScaledMetric(relativeTo: .largeTitle) private var portraitSize: CGFloat = 80
    @FocusState private var searching: Bool

    private var sortedContacts: [NetworkContact] {
        roster.contacts.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        CollectionPage(title: "Network", onProfile: onProfile) {
            if section == .network && (!roster.contacts.isEmpty || !roster.error.isEmpty) {
                Button { sheet = .add } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Add a contact")
                .accessibilityIdentifier("network-your-contacts")
            }
            if section == .network { options }
        } content: { height in
            VStack(alignment: .leading, spacing: 16) {
                selector
                if section == .network {
                    networkContent(height: height)
                } else {
                    PresenceView(reload: $presenceReload)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: min(roster.contacts.count, 5))
        .refreshable {
            if section == .network { await roster.load(store: store) }
            else {
                await store.refresh()
                presenceReload += 1
            }
        }
        .alert("Contact unavailable", isPresented: $unavailableContact) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("This contact is no longer available.")
        }
        .tint(Brand.accent)
        .task { openPendingContact(); await roster.load(store: store); openPendingContact() }
        .onChange(of: store.pendingOpen) { _, _ in openPendingContact() }
        .onChange(of: roster.loading) { _, loading in if !loading { openPendingContact() } }
        .onChange(of: roster.contacts) { _, _ in openPendingContact() }
        .onChange(of: store.sessionGeneration) { _, _ in reset() }
        .onChange(of: store.phase) { _, phase in if phase != .ready { reset() } }
        .sheet(item: $sheet, onDismiss: refreshContacts) { destination in
            switch destination {
            case .discovery(let id):
                DiscoveryCatalogView(initialRecordID: id).environment(store)
            default:
                NetworkToolSheet(destination: destination, drafts: drafts).environment(store)
            }
        }
    }

    private var selector: some View {
        HStack(spacing: 20) {
            sectionButton(.network)
            sectionButton(.presence)
            Spacer()
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func sectionButton(_ value: NetworkSection) -> some View {
        Button {
            searching = false
            withAnimation(reduceMotion ? nil : Motion.fadeAnimation) { section = value }
        } label: {
            Text(value.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(section == value ? Brand.ink : Brand.muted)
                .frame(minHeight: 44)
                .overlay(alignment: .bottom) {
                    if section == value { Capsule().fill(Brand.accent).frame(height: 3) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(value == .presence ? "network-presence-tab" : "network-roster-tab")
        .accessibilityAddTraits(section == value ? .isSelected : [])
    }

    private var options: some View {
        Menu {
            Button("Import contacts", systemImage: "square.and.arrow.down") { sheet = .csv }
            Button("Outreach settings", systemImage: "slider.horizontal.3") { sheet = .settings }
            Button("Discovery catalog", systemImage: "person.text.rectangle") { sheet = .discovery(nil) }
        } label: {
            Image(systemName: "ellipsis").font(.headline).foregroundStyle(Brand.ink)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Network options")
        .accessibilityIdentifier("network-options")
    }

    @ViewBuilder
    private func networkContent(height: CGFloat) -> some View {
        if !roster.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MessageLine(text: roster.error)
                Button("Retry loading contacts", action: refreshContacts)
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(roster.loading)
            }
            .accessibilityIdentifier("network-load-error")
        }
        if roster.contacts.isEmpty {
            if !roster.loaded && roster.error.isEmpty {
                ProgressView("Loading contacts…").frame(maxWidth: .infinity, minHeight: max(44, height - 80))
            } else if roster.error.isEmpty {
                CollectionEmptyState(symbol: "person.2", title: "No contacts yet", actionTitle: "Add a contact",
                                     titleIdentifier: "network-empty", actionIdentifier: "network-your-contacts") {
                    sheet = .add
                }
                .frame(minHeight: max(0, height - 72))
            }
        } else if roster.contacts.count == 1, let contact = roster.contacts.first {
            singleContact(contact)
                .frame(maxWidth: .infinity, minHeight: max(0, (height - 60) * 0.86))
        } else if roster.contacts.count <= 4 {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: typeSize.isAccessibilitySize ? 1 : 2)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(sortedContacts) { contact in personCard(contact) }
            }
        } else {
            searchField
            directory
        }
    }

    private func singleContact(_ contact: NetworkContact) -> some View {
        Button { sheet = .contact(contact) } label: {
            VStack(spacing: 16) {
                avatar(contact, size: portraitSize)
                VStack(spacing: 5) {
                    Text(contact.name).font(.title.weight(.semibold)).foregroundStyle(Brand.ink)
                    if !contact.detail.isEmpty {
                        Text(contact.detail).font(.body).foregroundStyle(Brand.muted)
                    }
                    if !contact.email.isEmpty && contact.email != contact.detail {
                        Text(contact.email).font(.subheadline).foregroundStyle(Brand.muted)
                    }
                }
                if !contact.relationship.isEmpty {
                    Text(contact.relationship).font(.subheadline).foregroundStyle(Brand.ink).lineLimit(3)
                }
                HStack(spacing: 6) {
                    Text("View contact")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Palette.halo, in: Capsule())
            }
            .padding(.horizontal, 12).padding(.vertical, 16)
            .multilineTextAlignment(.center).contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityHint("Open contact and outreach")
        .accessibilityIdentifier("network-contact-\(contact.id)")
    }

    private func personCard(_ contact: NetworkContact) -> some View {
        Button { sheet = .contact(contact) } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    avatar(contact, size: 44)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Brand.muted)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(contact.name).font(.headline).foregroundStyle(Brand.ink)
                    if !contact.detail.isEmpty {
                        Text(contact.detail).font(.subheadline).foregroundStyle(Brand.muted)
                    }
                }
                if !contact.relationship.isEmpty {
                    Divider()
                    Text(contact.relationship).font(.subheadline).foregroundStyle(Brand.ink)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityHint("Open contact and outreach")
        .accessibilityIdentifier("network-contact-\(contact.id)")
    }

    private func avatar(_ contact: NetworkContact, size: CGFloat) -> some View {
        Text(contact.initials).font(.system(size: size * 0.35, weight: .semibold))
            .foregroundStyle(Brand.accent)
            .frame(width: size, height: size)
            .background(Palette.halo, in: Circle())
            .accessibilityHidden(true)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).accessibilityHidden(true)
            TextField("Search contacts", text: $query)
                .focused($searching)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searching = false }
                .accessibilityIdentifier("network-search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private var directory: some View {
        let groups = Dictionary(grouping: sortedContacts.filter { $0.matches(query) }, by: \.directoryLetter)
        let letters = groups.keys.sorted {
            if $0 == "#" || $1 == "#" { return $0 != "#" && $1 == "#" }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return LazyVStack(alignment: .leading, spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title.weight(.light)).foregroundStyle(Brand.muted)
                        .accessibilityHidden(true)
                    Text("No matching contacts").font(.headline).foregroundStyle(Brand.ink)
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        query = ""
                        searching = false
                    } label: {
                        Text("Clear search").frame(minHeight: 44)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            ForEach(letters, id: \.self) { letter in
                Text(letter).font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    .padding(.top, 12).accessibilityAddTraits(.isHeader)
                ForEach(groups[letter] ?? []) { contact in
                    Button { sheet = .contact(contact) } label: {
                        HStack(spacing: 12) {
                            avatar(contact, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(contact.name).font(.headline).foregroundStyle(Brand.ink)
                                if !contact.detail.isEmpty {
                                    Text(contact.detail).font(.subheadline).foregroundStyle(Brand.muted)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Brand.muted)
                        }
                        .multilineTextAlignment(.leading)
                        .padding(.vertical, 9).frame(minHeight: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Open contact and outreach")
                    .accessibilityIdentifier("network-contact-\(contact.id)")
                    Divider()
                }
            }
        }
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
            sheet = .discovery(id)
            store.pendingOpen = [:]
            return
        }
        // Missing or deleted real contacts never open a blank detail sheet.
        guard roster.loaded, !roster.loading else { return }
        if let contact = roster.contacts.first(where: { $0.id == id }) {
            unavailableContact = false
            sheet = .contact(contact)
        } else { unavailableContact = true }
        store.pendingOpen = [:]
    }

    private func reset() {
        roster.reset()
        drafts.reset()
        sheet = nil
        section = .network
        query = ""
        unavailableContact = false
    }
}

enum NetworkSheet: Identifiable {
    case add, csv, settings, contact(NetworkContact), discovery(String?)
    var id: String {
        switch self {
        case .add: return "add"
        case .csv: return "import"
        case .settings: return "settings"
        case .contact(let contact): return "contact:" + contact.id
        case .discovery(let id): return "discovery:" + (id ?? "")
        }
    }

    var title: String {
        switch self {
        case .add: return "New contact"
        case .csv: return "Import contacts"
        case .settings: return "Outreach settings"
        case .contact(let contact): return contact.name
        case .discovery: return "Discovery catalog"
        }
    }
}

enum NetworkSection: String {
    case network = "People", presence = "Presence"
}

/// Outreach gets its own screen, with agent tasks opening from here.
@MainActor
private struct NetworkToolSheet: View {
    let destination: NetworkSheet
    let drafts: NetworkDrafts
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var task: TaskTarget?
    @State private var hubPage: AgentPage?
    @State private var hubAction = ""

    var body: some View {
        SheetPage(title: destination.title, closeDisabled: working) {
            NetworkAgentSection(drafts: drafts, working: $working, destination: destination, onOpenTask: { task = TaskTarget(id: $0) }, onNavigate: navigate)
        }
        .interactiveDismissDisabled(working)
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

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
    @Namespace private var selectorSpace

    private var sortedContacts: [NetworkContact] {
        roster.contacts.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    var body: some View {
        CollectionPage(title: "Network", onProfile: onProfile) {
            if section == .network && (!roster.contacts.isEmpty || !roster.error.isEmpty) {
                HeaderIconButton(systemName: "plus", label: "Add a contact") { sheet = .add }
                    .accessibilityIdentifier("network-your-contacts")
            }
            if section == .network { options }
        } content: { height in
            VStack(alignment: .leading, spacing: 16) {
                selector
                if section == .network {
                    networkContent(height: height)
                        .transition(.opacity)
                } else {
                    PresenceView(reload: $presenceReload)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .animation(Motion.animation(Motion.smooth, reduce: reduceMotion), value: min(roster.contacts.count, 5))
        .replayable()
        .refreshable {
            if section == .network { await roster.load(store: store) }
            else {
                await store.refresh()
                presenceReload += 1
            }
        }
        .alert("Contact unavailable", isPresented: $unavailableContact) {
            Button("OK", role: .cancel) {}
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

    // MARK: Switcher

    /// A sliding capsule inside a quiet track. Selection moves with a spring and a light tick.
    private var selector: some View {
        HStack(spacing: 0) {
            sectionButton(.network)
            sectionButton(.presence)
        }
        .padding(3)
        .background(Palette.muted.opacity(0.12), in: Capsule())
        .sensoryFeedback(.selection, trigger: section)
    }

    private func sectionButton(_ value: NetworkSection) -> some View {
        let selected = section == value
        return Button {
            guard !selected else { return }
            searching = false
            withAnimation(Motion.animation(Motion.snappy, reduce: reduceMotion)) { section = value }
        } label: {
            Text(value.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Brand.ink : Brand.muted)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background {
                    if selected {
                        Capsule().fill(Palette.surfaceRaised)
                            .overlay(Capsule().strokeBorder(Palette.rule.opacity(0.6), lineWidth: 0.5))
                            .stackElevation()
                            .matchedGeometryEffect(id: "network-section", in: selectorSpace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(value == .presence ? "network-presence-tab" : "network-roster-tab")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var options: some View {
        HeaderMenu("ellipsis", label: "Network options") {
            Button("Import contacts", systemImage: "square.and.arrow.down") { sheet = .csv }
            Button("Outreach", systemImage: "slider.horizontal.3") { sheet = .settings }
            Button("Discover", systemImage: "person.text.rectangle") { sheet = .discovery(nil) }
        }
        .accessibilityIdentifier("network-options")
    }

    // MARK: People

    @ViewBuilder
    private func networkContent(height: CGFloat) -> some View {
        if !roster.error.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                MessageLine(text: roster.error)
                Button("Try again", action: refreshContacts)
                    .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    .disabled(roster.loading)
            }
            .accessibilityIdentifier("network-load-error")
        }
        if roster.contacts.isEmpty {
            if !roster.loaded && roster.error.isEmpty {
                VStack(spacing: 0) {
                    ForEach(0..<5, id: \.self) { _ in SkeletonRow() }
                }
                .padding(.horizontal, 16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .accessibilityLabel("Loading contacts")
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
                addTile
            }
            profilesSuggestion
        } else {
            searchField
            directory
        }
    }

    private func singleContact(_ contact: NetworkContact) -> some View {
        Button { sheet = .contact(contact) } label: {
            VStack(spacing: 20) {
                Avatar(name: contact.name, size: portraitSize)
                VStack(spacing: 6) {
                    Text(contact.name).font(.title2.weight(.bold)).foregroundStyle(Brand.ink)
                    if !contact.role.isEmpty {
                        Text(contact.role).font(.body.weight(.medium)).foregroundStyle(Brand.ink.opacity(0.85))
                    }
                    if !contact.company.isEmpty {
                        Text(contact.company).font(.subheadline).foregroundStyle(Brand.muted)
                    } else if contact.role.isEmpty && !contact.email.isEmpty {
                        Text(contact.email).font(.subheadline).foregroundStyle(Brand.muted)
                    }
                    if let pill = statusPill(contact) { pill.padding(.top, 4) }
                }
                if !contact.relationship.isEmpty {
                    Text(contact.relationship)
                        .font(.subheadline).foregroundStyle(Brand.ink).lineLimit(4)
                        .padding(14).frame(maxWidth: .infinity)
                        .background(Brand.page, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
                HStack(spacing: 6) {
                    Text("View contact")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
                .padding(.horizontal, 18).frame(minHeight: 44)
                .background(Palette.halo, in: Capsule())
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, 20).padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .contextMenu { contactActions(contact) }
        .accessibilityIdentifier("network-contact-\(contact.id)")
    }

    private func personCard(_ contact: NetworkContact) -> some View {
        Button { sheet = .contact(contact) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    Avatar(name: contact.name, size: 48)
                    Spacer(minLength: 4)
                    if let pill = statusPill(contact) { pill }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(contact.name).font(.headline).foregroundStyle(Brand.ink)
                    if !contact.role.isEmpty {
                        Text(contact.role).font(.subheadline).foregroundStyle(Brand.ink.opacity(0.85)).lineLimit(2)
                    }
                    if !contact.company.isEmpty {
                        Text(contact.company).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                    } else if contact.role.isEmpty && !contact.email.isEmpty {
                        Text(contact.email).font(.footnote).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if !contact.relationship.isEmpty {
                    Text(contact.relationship).font(.footnote).foregroundStyle(Brand.muted).lineLimit(3)
                        .padding(.top, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .top) { Rectangle().fill(Palette.rule.opacity(0.7)).frame(height: 0.5) }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.97))
        .contextMenu { contactActions(contact) }
        .accessibilityIdentifier("network-contact-\(contact.id)")
    }

    private var addTile: some View {
        Button { sheet = .add } label: {
            VStack(spacing: 10) {
                Image(systemName: "plus").font(.system(size: 20, weight: .semibold)).foregroundStyle(Brand.accent)
                    .frame(width: 48, height: 48).background(Palette.halo, in: Circle())
                Text("Add contact").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 190, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Brand.muted.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.97))
        .accessibilityIdentifier("network-add-tile")
    }

    private var profilesSuggestion: some View {
        Button {
            searching = false
            withAnimation(Motion.animation(Motion.snappy, reduce: reduceMotion)) { section = .presence }
        } label: {
            HStack(spacing: 12) {
                SymbolTile(systemName: "person.crop.rectangle.fill", weight: .semibold)
                Text("Review your LinkedIn").font(.headline).foregroundStyle(Brand.ink)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.muted.opacity(0.6)).accessibilityHidden(true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .stackElevation()
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityIdentifier("network-profiles-suggestion")
    }

    /// A trailing hint only when it changes what the person does next.
    private func statusPill(_ contact: NetworkContact) -> StatusPill? {
        if contact.stopped { return StatusPill(text: "Stopped", tone: .neutral) }
        if contact.followupDue() { return StatusPill(text: "Follow up", tone: .warning) }
        return nil
    }

    @ViewBuilder
    private func contactActions(_ contact: NetworkContact) -> some View {
        if !contact.email.isEmpty {
            if let url = URL(string: "mailto:" + contact.email) {
                Link(destination: url) { Label("Email", systemImage: "envelope") }
            }
            Button("Copy email", systemImage: "doc.on.doc") { UIPasteboard.general.string = contact.email }
        }
        Button("Open", systemImage: "person.crop.circle") { sheet = .contact(contact) }
    }

    // MARK: Search and directory

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.muted).accessibilityHidden(true)
            TextField("Search", text: $query)
                .focused($searching)
                .font(Typeface.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { searching = false }
                .accessibilityIdentifier("network-search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.tap(scale: 0.9))
                .accessibilityLabel("Clear search")
                .transition(.opacity)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, query.isEmpty ? 16 : 2)
        .frame(minHeight: 48)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .strokeBorder(searching ? Brand.accent : Palette.rule, lineWidth: searching ? 1.5 : 1))
        .animation(Motion.animation(Motion.snappy, reduce: reduceMotion), value: query.isEmpty)
    }

    private var directory: some View {
        let groups = Dictionary(grouping: sortedContacts.filter { $0.matches(query) }, by: \.directoryLetter)
        let letters = groups.keys.sorted {
            if $0 == "#" || $1 == "#" { return $0 != "#" && $1 == "#" }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return LazyVStack(alignment: .leading, spacing: 8) {
            if groups.isEmpty {
                VStack(spacing: 8) {
                    SymbolDisc(systemName: "magnifyingglass", size: 64)
                    Text("No matches").font(.headline).foregroundStyle(Brand.ink)
                        .accessibilityAddTraits(.isHeader)
                    Button {
                        query = ""
                        searching = false
                    } label: {
                        Text("Clear").font(.subheadline.weight(.semibold)).frame(minHeight: 44)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            ForEach(letters, id: \.self) { letter in
                let members = groups[letter] ?? []
                SectionHeader(title: letter).padding(.leading, 4).padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(members) { contact in
                        directoryRow(contact, last: contact.id == members.last?.id)
                    }
                }
                .padding(.horizontal, 16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .stackElevation()
            }
        }
    }

    private func directoryRow(_ contact: NetworkContact, last: Bool) -> some View {
        Button { sheet = .contact(contact) } label: {
            HStack(spacing: 12) {
                Avatar(name: contact.name, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(contact.name).font(.headline).foregroundStyle(Brand.ink)
                    if !contact.detail.isEmpty {
                        Text(contact.detail).font(.subheadline).foregroundStyle(Brand.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let pill = statusPill(contact) {
                    pill
                } else {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.muted.opacity(0.6)).accessibilityHidden(true)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 10).frame(minHeight: 60)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Palette.rule.opacity(0.7)).frame(height: 0.5).padding(.leading, 52) }
            }
        }
        .buttonStyle(.tap(scale: 0.985))
        .contextMenu { contactActions(contact) }
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
        case .settings: return "Outreach"
        case .contact: return "Contact"
        case .discovery: return "Discover"
        }
    }
}

enum NetworkSection: String {
    case network = "Contacts", presence = "Profiles"
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

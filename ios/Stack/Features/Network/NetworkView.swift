import SwiftUI

private struct Connection: Identifiable, Hashable {
    let record: ContactRecord
    let person: Person
    var id: String { record.id }
}

@MainActor
struct NetworkView: View {
    @Environment(AppStore.self) private var store
    var onProfile: () -> Void

    @State private var showSavedOnly = false
    @State private var selected: Connection?
    @State private var tool: NetworkTool?
    @State private var linkedIn = false
    /// Held here, not in the sheets, so closing a tool never discards unfinished edits.
    @State private var drafts = NetworkDrafts()

    private var connections: [Connection] {
        store.account.contacts.compactMap { record in
            store.account.person(for: record).map { Connection(record: record, person: $0) }
        }
    }

    private var shown: [Connection] { showSavedOnly ? connections.filter(\.record.saved) : connections }

    var body: some View {
        Page {
            ScreenHeader(title: "Network", onProfile: onProfile).reveal(0)
            HStack(spacing: 8) {
                Chip(label: "Discover", selected: !showSavedOnly) { withAnimation(Motion.fadeAnimation) { showSavedOnly = false } }
                Chip(label: "Saved", selected: showSavedOnly) { withAnimation(Motion.fadeAnimation) { showSavedOnly = true } }
            }
            .reveal(1)
            if shown.isEmpty {
                EmptyNote(icon: "network", title: showSavedOnly ? "No saved contacts" : "No suggestions yet",
                          message: "Saved contacts keep your draft and notes together.")
            } else {
                VStack(spacing: Spacing.option) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, connection in
                        Button { selected = connection } label: {
                            HStack(spacing: 16) {
                                Avatar(initials: connection.person.initials, tint: Color(cssHex: connection.person.colorHex))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.person.name).font(Typeface.option).foregroundStyle(Palette.icon)
                                    Text("\(connection.person.role) · \(connection.person.company)")
                                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                                    Text(connection.person.signal).font(Typeface.caption).foregroundStyle(Palette.text)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                if connection.record.saved { GlyphView(name: "star", size: 16, color: Palette.muted) }
                            }
                            .padding(18)
                            .background(index.isMultiple(of: 2) ? Palette.surface : Palette.oat,
                                        in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
                        }
                        .buttonStyle(.tap(scale: 0.98))
                        .reveal(index + 2)
                    }
                }
            }
            VStack(spacing: 0) {
                ListRow(label: "Your contacts", icon: "network", detail: "Add people and draft outreach for review") { tool = .contacts }
                ListRow(label: "LinkedIn review", icon: "sparkles", detail: "Fixes and rewrites for your profile") { linkedIn = true }
                ListRow(label: "Public profiles", icon: "profile", detail: "LinkedIn, GitHub and portfolio drafts") { tool = .profiles }
            }
            .reveal(shown.count + 2)
        }
        .refreshable { await store.refresh() }
        .task(id: store.pendingOpen) {
            guard store.pendingOpen["target_type"] == "contact", let id = store.pendingOpen["target_id"],
                  let record = store.account.contacts.first(where: { $0.id == id }),
                  let person = store.account.person(for: record) else { return }
            store.pendingOpen = [:]
            selected = Connection(record: record, person: person)
        }
        .sheet(item: $selected) { connection in
            ContactDetailView(recordID: connection.record.id).environment(store)
        }
        .onChange(of: store.sessionGeneration) { _, _ in drafts.reset() }
        .onChange(of: store.phase) { _, phase in if phase != .ready { drafts.reset() } }
        .fullScreenCover(isPresented: $linkedIn) { LinkedInFlow().environment(store) }
        .sheet(item: $tool) { value in
            switch value {
            case .contacts: NetworkToolSheet(title: "Your contacts", tool: .contacts, drafts: drafts).environment(store)
            case .profiles: PublicProfilesView().environment(store)
            }
        }
    }
}

enum NetworkTool: String, Identifiable {
    case contacts, profiles
    var id: String { rawValue }
}

/// Outreach gets its own screen, with agent tasks opening from here.
@MainActor
private struct NetworkToolSheet: View {
    let title: String
    let tool: NetworkTool
    let drafts: NetworkDrafts
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var task: TaskTarget?
    @State private var hubPage: AgentPage?
    @State private var hubAction = ""

    var body: some View {
        SheetPage(title: title) {
            NetworkAgentSection(drafts: drafts, onOpenTask: { task = TaskTarget(id: $0) }, onNavigate: navigate)
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
            hubPage = action == "facts" ? .facts : (action == "features" ? .features : .rules)
        case _ where action.hasPrefix("connect:"):
            hubAction = action
            hubPage = .rules
        default:
            dismiss()
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
        }
    }
}

@MainActor
private struct ContactDetailView: View {
    let recordID: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var draft = ""
    @State private var notes = ""
    @State private var seeded = false
    @State private var showReminder = false
    @State private var reminderTitle = "Reach out"
    @State private var reminderDate = Date().addingTimeInterval(86_400)

    private var record: ContactRecord? { store.account.contacts.first { $0.id == recordID } }
    private var person: Person? { record.flatMap { store.account.person(for: $0) } }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            if let record, let person {
                Page {
                    HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                    HStack(spacing: 16) {
                        Avatar(initials: person.initials, tint: Color(cssHex: person.colorHex), size: 72)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(person.name).font(Typeface.title).foregroundStyle(Palette.ink)
                            Text("\(person.role) · \(person.company)").font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    .reveal(0)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.bio).font(Typeface.body).foregroundStyle(Palette.text)
                        if !person.reason.isEmpty {
                            Text("Why connect: \(person.reason)").font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                    }
                    .reveal(1)
                    StackField(label: "Outreach draft", text: $draft, multiline: true).reveal(3)
                    Text("Saved here. Nothing is sent.").font(Typeface.caption).foregroundStyle(Palette.muted)
                    DisclosureSection("Private notes", open: !notes.isBlank) {
                        StackField(label: "Private notes", text: $notes, multiline: true)
                    }
                    StackButton(label: "Save draft and notes", disabled: store.busy) { save(record.saved) }
                    StackButton(label: record.saved ? "Remove from saved" : "Save contact", icon: "star", kind: .secondary, disabled: store.busy) {
                        save(!record.saved)
                    }
                    StackButton(label: "Add a reminder", icon: "bell", kind: .secondary) { showReminder = true }
                    MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                    MessageLine(text: store.notice, isError: false).fadeSwitch(!store.notice.isEmpty)
                }
                .onAppear { if !seeded { draft = record.draft; notes = record.notes; seeded = true } }
            }
        }
        .sheet(isPresented: $showReminder) {
            ReminderSheet(title: $reminderTitle, due: $reminderDate) {
                Task {
                    let ok = await store.mutate(
                        "save_reminder",
                        ["id": "", "target_type": "contact", "target_id": .string(recordID),
                         "title": .string(reminderTitle), "due_at": .number(reminderDate.timeIntervalSince1970)],
                        notice: "Reminder saved.", askNotifications: true
                    )
                    if ok { showReminder = false }
                }
            }
        }
    }

    private func save(_ saved: Bool) {
        Task {
            await store.mutate("save_contact", ["id": .string(recordID), "saved": .bool(saved), "draft": .string(draft), "notes": .string(notes)])
        }
    }
}

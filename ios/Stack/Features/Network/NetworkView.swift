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
    @State private var task: TaskTarget?
    @State private var showPublicProfiles = false

    private func navigate(_ action: String) {
        NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
    }

    private var connections: [Connection] {
        store.account.contacts.compactMap { record in
            store.account.person(for: record).map { Connection(record: record, person: $0) }
        }
    }

    private var shown: [Connection] { showSavedOnly ? connections.filter(\.record.saved) : connections }

    var body: some View {
        Page {
            ScreenHeader(title: "Network", subtitle: "People worth a conversation", onProfile: onProfile).reveal(0)
            HStack(spacing: 8) {
                Chip(label: "Discover", selected: !showSavedOnly) { withAnimation(Motion.fadeAnimation) { showSavedOnly = false } }
                Chip(label: "Saved", selected: showSavedOnly) { withAnimation(Motion.fadeAnimation) { showSavedOnly = true } }
            }
            .reveal(1)
            if shown.isEmpty {
                EmptyNote(icon: "network", title: showSavedOnly ? "No saved contacts" : "No suggestions yet",
                          message: "Save a contact to keep your outreach draft and notes together.")
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
            NetworkAgentSection(onOpenTask: { task = TaskTarget(id: $0) }, onNavigate: navigate)
            ListRow(label: "Public profiles", icon: "profile", detail: "Draft your LinkedIn, GitHub and portfolio story") { showPublicProfiles = true }
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
        .sheet(item: $task) { target in AgentTaskSheet(taskID: target.id).environment(store) }
        .sheet(isPresented: $showPublicProfiles) { PublicProfilesView().environment(store) }
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
                    Text(person.bio).font(Typeface.body).foregroundStyle(Palette.text).reveal(1)
                    Card(tint: Palette.surfaceRaised) {
                        Text("Why connect?").font(Typeface.caption).foregroundStyle(Palette.muted)
                        Text(person.reason).font(Typeface.body).foregroundStyle(Palette.text)
                    }
                    .reveal(2)
                    StackField(label: "Outreach draft", text: $draft, multiline: true).reveal(3)
                    Text("Edit and save your draft. Sending is not enabled.").font(Typeface.caption).foregroundStyle(Palette.muted)
                    StackField(label: "Private notes", text: $notes, multiline: true)
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

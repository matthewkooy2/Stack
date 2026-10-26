import SwiftUI

private struct Connection: Identifiable, Hashable {
    let record: ContactRecord
    let person: Person
    var id: String { record.id }
}

/// Previously saved catalog profiles retain their notes and drafts, outside the real-contact roster.
@MainActor
struct DiscoveryCatalogView: View {
    var initialRecordID: String? = nil
    @Environment(AppStore.self) private var store
    @State private var savedOnly = true
    @State private var selected: Connection?
    private var connections: [Connection] {
        store.account.contacts.compactMap { record in
            guard !savedOnly || record.saved, let person = store.account.person(for: record) else { return nil }
            return Connection(record: record, person: person)
        }
    }

    var body: some View {
        SheetPage(title: "Discovery catalog") {
            Text("Catalog profiles, not real discovered contacts. Your saved notes and drafts are kept here.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ToggleRow(label: "Saved only", isOn: $savedOnly)
            if connections.isEmpty {
                Text(savedOnly ? "No saved catalog profiles." : "No catalog profiles.")
                    .font(Typeface.body).foregroundStyle(Palette.muted)
            }
            ForEach(connections) { connection in
                ListRow(label: connection.person.name, icon: "network",
                        detail: [connection.person.role, connection.person.company].filter { !$0.isEmpty }.joined(separator: " · ")) {
                    selected = connection
                }
            }
        }
        .task {
            guard let id = initialRecordID,
                  let record = store.account.contacts.first(where: { $0.id == id }),
                  let person = store.account.person(for: record) else { return }
            selected = Connection(record: record, person: person)
        }
        .sheet(item: $selected) { connection in
            ContactDetailView(recordID: connection.id).environment(store)
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

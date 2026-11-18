import SwiftUI

/// Follow-up reminders for applications and contacts: edit, complete or delete.
@MainActor
struct RemindersView: View {
    @Environment(AppStore.self) private var store

    @State private var editing: Reminder?
    @State private var title = ""
    @State private var due = Date().addingTimeInterval(86_400)
    @State private var deleting: Reminder?

    private var open: [Reminder] { store.account.reminders.filter { !$0.done }.sorted { $0.dueAt < $1.dueAt } }
    private var done: [Reminder] { store.account.reminders.filter(\.done).sorted { $0.dueAt > $1.dueAt } }

    var body: some View {
        SheetPage(title: "Follow-ups") {
            StoreMessages()
            if open.isEmpty, done.isEmpty {
                EmptyNote(icon: "bell", title: "No reminders yet",
                          message: "Add one from an application or contact.")
            }
            ForEach(Array(open.enumerated()), id: \.element.id) { index, reminder in
                row(reminder).reveal(index + 1)
            }
            if !done.isEmpty {
                SectionLabel(text: "Completed")
                ForEach(done) { reminder in row(reminder) }
            }
        }
        .sheet(item: $editing) { reminder in
            ReminderSheet(title: $title, due: $due) {
                Task {
                    let ok = await store.mutate(
                        "save_reminder",
                        ["id": .string(reminder.id), "target_type": .string(reminder.targetType),
                         "target_id": .string(reminder.targetID), "title": .string(title),
                         "due_at": .number(due.timeIntervalSince1970)],
                        notice: "Reminder saved.", askNotifications: true
                    )
                    if ok { editing = nil }
                }
            }
        }
        .confirmationDialog("Delete this reminder?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let target = deleting {
                    Task { await store.mutate("change_reminder", ["id": .string(target.id), "action": "delete"], notice: "Reminder deleted.") }
                }
                deleting = nil
            }
        }
    }

    private func row(_ reminder: Reminder) -> some View {
        Card(spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(reminder.title).font(.headline).foregroundStyle(Palette.ink)
                    Text(target(reminder)).font(Typeface.caption).foregroundStyle(Palette.muted)
                    Label(reminder.done ? "Completed" : dateTime(reminder.dueAt),
                          systemImage: reminder.done ? "checkmark.circle" : "clock")
                        .font(.footnote).foregroundStyle(reminder.done ? Palette.success : Palette.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    if !reminder.done {
                        Button {
                            title = reminder.title
                            due = max(Date(timeIntervalSince1970: reminder.dueAt), Date().addingTimeInterval(60))
                            editing = reminder
                        } label: { Label("Edit", systemImage: "pencil") }
                    }
                    Button(role: .destructive) { deleting = reminder } label: { Label("Delete", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Actions for \(reminder.title)")
            }
            if !reminder.done {
                Button {
                    Task { await store.mutate("change_reminder", ["id": .string(reminder.id), "action": "complete"], notice: "Marked complete.") }
                } label: { Label("Complete", systemImage: "checkmark").font(.subheadline.weight(.semibold)).frame(minHeight: 44) }
                .tint(Brand.accent)
            }
        }
    }

    private func target(_ reminder: Reminder) -> String {
        if reminder.targetType == "application" {
            if let app = store.account.applications.first(where: { $0.id == reminder.targetID }) {
                return "\(app.job.title) · \(app.job.company)"
            }
            return "Application"
        }
        if let record = store.account.contacts.first(where: { $0.id == reminder.targetID }),
           let person = store.account.person(for: record) {
            return person.name
        }
        return "Contact"
    }
}

import SwiftUI

@MainActor
struct ApplicationsView: View {
    @Environment(AppStore.self) private var store
    var onProfile: () -> Void
    var onNavigate: (StackTab) -> Void

    @State var filter = "All"
    @State var selected: Application?
    @State var showCalendar = false
    @State var showReminders = false

    private var filters: [String] {
        ["All"] + Array(Set(store.account.applications.map(\.status))).filter { !$0.isEmpty }.sorted()
    }

    private var rows: [Application] {
        let all = store.account.applications.sorted { $0.createdAt > $1.createdAt }
        return filter == "All" ? all : all.filter { $0.status == filter }
    }

    var body: some View {
        Page {
            ScreenHeader(title: "Applications", subtitle: "\(store.account.applications.count) saved", onProfile: onProfile).reveal(0)
            HStack(spacing: 8) {
                Chip(label: "Calendar") { showCalendar = true }
                Chip(label: "Follow-ups") { showReminders = true }
            }
            .reveal(1)
            if filters.count > 2 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(filters, id: \.self) { name in
                            Chip(label: name, selected: filter == name) { withAnimation(Motion.fadeAnimation) { filter = name } }
                        }
                    }
                }
                .reveal(1)
            }
            if rows.isEmpty {
                EmptyNote(icon: "applications", title: "Nothing saved yet", message: "Save a role from Jobs and it will show up here.")
                    .reveal(1)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, app in
                        ListRow(label: app.job.title, detail: "\(app.job.company) · \(app.status)") { selected = app }
                            .reveal(index + 2)
                    }
                }
            }
        }
        .refreshable { await store.refresh() }
        .task(id: store.pendingOpen) {
            guard store.pendingOpen["target_type"] == "application", let id = store.pendingOpen["target_id"],
                  let app = store.account.applications.first(where: { $0.id == id }) else { return }
            store.pendingOpen = [:]
            selected = app
        }
        .sheet(isPresented: $showCalendar) { ApplicationCalendarView().environment(store) }
        .sheet(isPresented: $showReminders) { RemindersView().environment(store) }
        .sheet(item: $selected) { app in
            ApplicationDetailView(applicationID: app.id).environment(store)
        }
    }
}

@MainActor
struct ApplicationDetailView: View {
    let applicationID: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State var notes = ""
    @State var loadedNotes = false
    @State var reminderTitle = "Follow up"
    @State var reminderDate = Date().addingTimeInterval(86_400)
    @State var showReminder = false

    private var application: Application? { store.account.applications.first { $0.id == applicationID } }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            if let app = application {
                Page {
                    HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(app.job.title).font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                        Text("\(app.job.company) · \(app.job.location)").font(Typeface.body).foregroundStyle(Palette.muted)
                        Chip(label: app.status + (app.isDemo ? " · Demo" : ""), selected: true)
                    }
                    .reveal(0)

                    if !app.isDemo, app.status != "Submitted" {
                        VStack(spacing: Spacing.option) {
                            if let url = URL(string: app.job.url), !app.job.url.isEmpty {
                                StackButton(label: "Apply on the employer site", icon: "link") { openURL(url) }
                            }
                            StackButton(label: "I submitted this application", icon: "done", disabled: store.busy) {
                                Task { await store.mutate("mark_application_submitted", ["id": .string(app.id)], notice: "Marked as submitted.") }
                            }
                        }
                        .reveal(1)
                    }

                    Card {
                        Text("Resume").font(Typeface.section).foregroundStyle(Palette.ink)
                        FlowLayout(spacing: 8) {
                            Chip(label: "None", selected: app.resumeID.isEmpty) { select("") }
                            ForEach(store.account.resumes) { resume in
                                Chip(label: resume.name, selected: app.resumeID == resume.id) { select(resume.id) }
                            }
                        }
                    }
                    .reveal(2)

                    VStack(alignment: .leading, spacing: 12) {
                        StackField(label: "Your notes", text: $notes, multiline: true)
                        StackButton(label: "Save notes", disabled: store.busy || notes == app.notes) {
                            Task { await store.mutate("save_application", ["id": .string(app.id), "notes": .string(notes)]) }
                        }
                    }
                    .reveal(3)

                    StackButton(label: "Add a follow-up reminder", icon: "bell", kind: .secondary) { showReminder = true }

                    if !app.history.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Status history").font(Typeface.caption).foregroundStyle(Palette.muted)
                            ForEach(Array(app.history.enumerated()), id: \.offset) { _, event in
                                Text("\(event.status) · \(dateTime(event.at)) · \(event.source)")
                                    .font(Typeface.caption).foregroundStyle(Palette.text)
                            }
                        }
                    }

                    MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                    MessageLine(text: store.notice, isError: false).fadeSwitch(!store.notice.isEmpty)

                    if !app.isDemo { ApplicationAgentSection(application: app) }
                }
                .onAppear { if !loadedNotes { notes = app.notes; loadedNotes = true } }
            } else {
                EmptyNote(icon: "applications", title: "This application is no longer available")
            }
        }
        .sheet(isPresented: $showReminder) {
            ReminderSheet(title: $reminderTitle, due: $reminderDate) {
                Task {
                    let ok = await store.mutate(
                        "save_reminder",
                        ["id": "", "target_type": "application", "target_id": .string(applicationID),
                         "title": .string(reminderTitle), "due_at": .number(reminderDate.timeIntervalSince1970)],
                        notice: "Reminder saved.", askNotifications: true
                    )
                    if ok { showReminder = false }
                }
            }
        }
    }

    private func select(_ resumeID: String) {
        Task { await store.mutate("select_application_resume", ["id": .string(applicationID), "resume_id": .string(resumeID)]) }
    }
}

@MainActor
struct ReminderSheet: View {
    @Binding var title: String
    @Binding var due: Date
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.stack) {
                HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                Text("Follow-up reminder").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                StackField(label: "Reminder", text: $title)
                DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .font(Typeface.body)
                    .tint(Palette.dark)
                Spacer()
                StackButton(label: "Save reminder", disabled: title.trimmingCharacters(in: .whitespaces).isEmpty, action: onSave)
            }
            .padding(Spacing.page)
        }
        .presentationDetents([.medium])
    }
}

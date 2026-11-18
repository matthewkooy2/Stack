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
    private enum TrackingDestination: Int, Identifiable {
        case overview, manage
        var id: Self { self }
    }

    @State private var trackingDestination: TrackingDestination?

    private var filters: [String] {
        ["All"] + Array(Set(store.account.applications.map(\.status))).filter { !$0.isEmpty }.sorted()
    }

    private var rows: [Application] {
        let all = store.account.applications.sorted { $0.createdAt > $1.createdAt }
        return filter == "All" ? all : all.filter { $0.status == filter }
    }

    var body: some View {
        let displayed = rows
        Page {
            ScreenHeader(title: "Applications", onProfile: onProfile)
            HStack(spacing: 12) {
                if filters.count > 2 || filter != "All" {
                    Menu {
                        Picker("Status", selection: $filter) {
                            ForEach(filters, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter == "All" ? "All applications" : filter)
                            Image(systemName: "chevron.down").font(.caption)
                        }
                    }
                    .accessibilityLabel("Filter applications")
                    .accessibilityValue(filter)
                } else {
                    Text("All applications")
                }
                Text("\(displayed.count)").monospacedDigit().foregroundStyle(Palette.muted)
                Spacer(minLength: 4)
                Menu {
                    Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
                    Button { showReminders = true } label: { Label("Follow-ups", systemImage: "bell") }
                    Button { trackingDestination = .overview } label: { Label("Gmail tracking", systemImage: "envelope") }
                } label: {
                    Label("Tools", systemImage: "ellipsis.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44)
                        .foregroundStyle(Brand.accent)
                }
                .accessibilityLabel("Application tools")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Palette.ink)
            if displayed.isEmpty {
                EmptyNote(icon: "applications", title: "Nothing saved yet", message: "Roles you save from Jobs appear here.")
                StackButton(label: "Browse jobs", icon: "jobs") { onNavigate(.jobs) }
                StackButton(label: "Track with Gmail", icon: "link", kind: .secondary) { trackingDestination = .overview }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayed) { app in
                        Button { selected = app } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(app.job.title.isBlank ? "Untitled role" : app.job.title)
                                    .font(.headline).foregroundStyle(Palette.ink)
                                if !app.job.company.isBlank {
                                    Text(app.job.company).font(.subheadline).foregroundStyle(Palette.muted)
                                }
                                if !app.status.isBlank {
                                    Text(app.status).font(.caption.weight(.semibold))
                                        .foregroundStyle(Brand.accent)
                                        .padding(.horizontal, 9).padding(.vertical, 3)
                                        .background(Palette.halo, in: Capsule())
                                }
                            }
                            .padding(.trailing, 20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .trailing) {
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.muted).accessibilityHidden(true)
                            }
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, 4)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel([app.job.title.isBlank ? "Untitled role" : app.job.title, app.job.company, app.status]
                            .filter { !$0.isBlank }.joined(separator: ", "))
                        if app.id != displayed.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 16)
                .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        .onChange(of: filters) { _, values in
            if !values.contains(filter) { filter = "All" }
        }
        .sheet(item: $trackingDestination) { destination in
            switch destination {
            case .overview:
                SheetPage(title: "Gmail tracking") {
                    GmailTrackingSection(onManage: { trackingDestination = .manage })
                }
                .environment(store)
            case .manage:
                AgentHubView(initialPage: .email).environment(store)
            }
        }
        .sheet(item: $selected) { app in
            ApplicationDetailView(applicationID: app.id).environment(store)
        }
    }
}

@MainActor
struct ApplicationDetailView: View {
    let applicationID: String
    @Environment(AppStore.self) private var store
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
                SheetPage(title: "Application") {
                    JobHeading(job: app.job)
                    if !app.status.isBlank || app.isDemo {
                        StatusPill(label: [app.status, app.isDemo ? "Demo" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                    }
                    if !app.isDemo, ["Saved", "Ready to apply"].contains(app.status) {
                        let url = JobListingLink.safeURL(app.job.url)
                        VStack(spacing: Spacing.option) {
                            if let url {
                                StackButton(label: "Apply on the employer site", icon: "link") { openURL(url) }
                            }
                            StackButton(label: "I submitted this application", icon: "done", kind: url == nil ? .primary : .secondary, disabled: store.busy) {
                                Task { await store.mutate("mark_application_submitted", ["id": .string(app.id)], notice: "Marked as submitted.") }
                            }
                        }
                        .reveal(1)
                    }

                    MessageLine(text: store.error).fadeSwitch(!store.error.isEmpty)
                    MessageLine(text: store.notice, isError: false).fadeSwitch(!store.notice.isEmpty)

                    if !app.isDemo { ApplicationAgentSection(application: app) }

                    VStack(spacing: 0) {
                        DisclosureSection("Resume", detail: resumeName(for: app)) {
                            FlowLayout(spacing: 8) {
                                Chip(label: "None", selected: app.resumeID.isEmpty) { select("") }
                                ForEach(store.account.resumes) { resume in
                                    Chip(label: resume.name, selected: app.resumeID == resume.id) { select(resume.id) }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        DisclosureSection("Notes", detail: app.notes.isBlank ? "" : app.notes, open: !app.notes.isBlank) {
                            VStack(alignment: .leading, spacing: 12) {
                                StackField(label: "Your notes", text: $notes, multiline: true)
                                StackButton(label: "Save notes", disabled: store.busy || notes == app.notes) {
                                    Task { await store.mutate("save_application", ["id": .string(app.id), "notes": .string(notes)]) }
                                }
                            }
                        }
                        ListRow(label: "Add a follow-up reminder", icon: "bell") { showReminder = true }
                        if !app.history.isEmpty {
                            DisclosureSection("Status history", detail: "\(app.history.count) updates") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(app.history.enumerated()), id: \.offset) { _, event in
                                        Text("\(event.status) · \(dateTime(event.at)) · \(event.source)")
                                            .font(Typeface.caption).foregroundStyle(Palette.text)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .reveal(2)
                }
                .onAppear { if !loadedNotes { notes = app.notes; loadedNotes = true } }
            } else {
                SheetPage(title: "Application unavailable") {
                    Text("This application is no longer available.").font(Typeface.body).foregroundStyle(Palette.muted)
                }
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

    private func resumeName(for app: Application) -> String {
        app.resumeID.isEmpty ? "None attached" : (store.account.resume(app.resumeID)?.name ?? "Attached")
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
    @Environment(AppStore.self) private var store

    var body: some View {
        SheetPage(title: "Follow-up reminder") {
            StackField(label: "Reminder", text: $title)
            DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .font(Typeface.body)
                .tint(Brand.accent)
            StoreMessages()
            StackButton(label: "Save reminder", disabled: store.busy || title.isBlank, action: onSave)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

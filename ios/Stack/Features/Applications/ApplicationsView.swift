import SwiftUI

@MainActor
struct ApplicationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.stackReduceMotion) private var reduceMotion
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

    private var pendingApplication: Application? {
        guard store.pendingOpen["target_type"] == "application", let id = store.pendingOpen["target_id"] else { return nil }
        return store.account.applications.first { $0.id == id }
    }

    private var stages: [String] {
        let known = ["Saved", "Ready to apply", "Submitted", "Applied", "Assessment", "Interview", "Interviewing", "Offer", "Rejected"]
        let present = Set(store.account.applications.map(\.trackerStage))
        return known.filter(present.contains) + present.subtracting(known).sorted()
    }

    var body: some View {
        let all = store.account.applications.sorted { $0.createdAt > $1.createdAt }
        CollectionPage(title: "Applications", onProfile: onProfile) {
            Menu {
                if stages.count > 1 {
                    Picker("Stage", selection: $filter) {
                        Text("All stages").tag("All")
                        ForEach(stages, id: \.self) { Text($0).tag($0) }
                    }
                    .accessibilityLabel("Filter applications")
                    .accessibilityValue(filter)
                    Divider()
                }
                Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
                Button { showReminders = true } label: { Label("Follow-ups", systemImage: "bell") }
                Button { trackingDestination = .overview } label: { Label("Gmail tracking", systemImage: "envelope") }
            } label: {
                Image(systemName: "ellipsis").font(.headline).foregroundStyle(Palette.ink)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Application tools")
        } content: { availableHeight in
            if all.isEmpty {
                CollectionEmptyState(symbol: "tray", title: "No applications yet", actionTitle: "Browse jobs") {
                    onNavigate(.jobs)
                }
                .frame(minHeight: availableHeight)
            } else {
                let displayed = filter == "All" ? all : all.filter { $0.trackerStage == filter }
                VStack(alignment: .leading, spacing: 18) {
                    if filter != "All" {
                        Button { filter = "All" } label: {
                            Label(filter, systemImage: "xmark.circle.fill").font(.subheadline.weight(.medium))
                                .frame(minHeight: 44)
                        }
                        .accessibilityLabel("Clear stage filter, \(filter)")
                    }
                    if all.count <= 2 {
                        ForEach(displayed) { app in
                            featured(app, isOnlyRole: all.count == 1)
                            if app.id != displayed.last?.id { Divider() }
                        }
                    } else {
                        let grouped = Dictionary(grouping: displayed, by: \.trackerStage)
                        ForEach(stages, id: \.self) { stage in
                            if let roles = grouped[stage] {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    if filter == "All" {
                                        Text(stage).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                                            .padding(.bottom, 4).accessibilityAddTraits(.isHeader)
                                    }
                                    ForEach(roles) { app in
                                        compact(app)
                                        if app.id != roles.last?.id { Divider().padding(.leading, 48) }
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, minHeight: all.count == 1 ? availableHeight : nil,
                       alignment: all.count == 1 ? .center : .topLeading)
            }
        }
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: min(all.count, 3))
        .animation(reduceMotion ? nil : Motion.fadeAnimation, value: filter)
        .refreshable { await store.refresh() }
        .onChange(of: pendingApplication, initial: true) { _, app in
            guard let app else { return }
            store.pendingOpen = [:]
            selected = app
        }
        .sheet(isPresented: $showCalendar) { ApplicationCalendarView().environment(store) }
        .sheet(isPresented: $showReminders) { RemindersView().environment(store) }
        .onChange(of: stages) { _, values in
            if values.count <= 1 || !values.contains(filter) { filter = "All" }
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

    private func featured(_ app: Application, isOnlyRole: Bool) -> some View {
        let reminder = app.firstFollowUp(in: store.account.reminders)
        let trail = app.recentActivity(limit: isOnlyRole ? 3 : 2, reminder: reminder)
        return Button { selected = app } label: {
            VStack(alignment: .leading, spacing: isOnlyRole ? 22 : 14) {
                ApplicationIdentity(application: app, featured: isOnlyRole, showsChevron: true)
                if !trail.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(trail.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Image(systemName: item.symbol).font(.footnote).foregroundStyle(Brand.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                                    Text(item.date).font(.footnote).foregroundStyle(Palette.muted)
                                }
                            }
                        }
                    }
                }
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(([app.roleTitle, app.job.company, app.job.location, app.stageLabel]
                             + trail.map { "\($0.title), \($0.date)" })
            .filter { !$0.isBlank }.joined(separator: ", "))
    }

    private func compact(_ app: Application) -> some View {
        Button { selected = app } label: {
            HStack(spacing: 12) {
                EmployerMark(job: app.job, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.roleTitle).font(.headline).foregroundStyle(Palette.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    let context = [app.job.company, app.isDemo ? "Demo" : ""].filter { !$0.isBlank }.joined(separator: " · ")
                    if !context.isEmpty { Text(context).font(.subheadline).foregroundStyle(Palette.muted) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.muted)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 12).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([app.roleTitle, app.job.company, app.stageLabel].filter { !$0.isBlank }.joined(separator: ", "))
    }
}

private struct ApplicationTrailItem {
    let title: String
    let date: String
    let symbol: String
}

private extension Application {
    var roleTitle: String { job.title.isBlank ? "Untitled role" : job.title }
    var trackerStage: String { status.isBlank ? "No status" : status }
    var stageLabel: String { [trackerStage, isDemo ? "Demo" : ""].filter { !$0.isEmpty }.joined(separator: " · ") }

    func firstFollowUp(in reminders: [Reminder]) -> Reminder? {
        reminders.filter { !$0.done && $0.targetType == "application" && $0.targetID == id && $0.dueAt > 0 }
            .min { $0.dueAt < $1.dueAt }
    }

    func recentActivity(limit: Int, reminder: Reminder?) -> [ApplicationTrailItem] {
        var events = history.filter { $0.at > 0 && !$0.status.isBlank }
        if createdAt > 0, !events.contains(where: { abs($0.at - createdAt) < 1 }) {
            events.append(StatusEvent(status: "Added to Stack", at: createdAt, source: ""))
        }
        var items = events.sorted { $0.at < $1.at }.suffix(limit).map { event in
            ApplicationTrailItem(title: event.status,
                                 date: Date(timeIntervalSince1970: event.at).formatted(date: .abbreviated, time: .omitted),
                                 symbol: event.status == "Added to Stack" ? "tray" : "clock")
        }
        if let reminder {
            items.append(ApplicationTrailItem(title: reminder.title.isBlank ? "Follow-up" : reminder.title,
                                               date: Date(timeIntervalSince1970: reminder.dueAt).formatted(date: .abbreviated, time: .shortened),
                                               symbol: "bell"))
        }
        return items
    }
}

private struct EmployerMark: View {
    let job: Job
    let size: CGFloat

    var body: some View {
        Group {
            if let image = JobLogoImages.image(job) {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.14)
                    .background(Color.white)
            } else if job.company.isBlank {
                Image(systemName: "building.2").foregroundStyle(Palette.muted)
            } else {
                Text(String(job.company.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .semibold)).foregroundStyle(Brand.accent)
            }
        }
        .frame(width: size, height: size)
        .background(Palette.halo)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .accessibilityHidden(true)
    }
}

private struct ApplicationIdentity: View {
    let application: Application
    var featured = false
    var showsChevron = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                EmployerMark(job: application.job, size: featured ? 54 : 42)
                Text(application.job.company.isBlank ? "Employer not listed" : application.job.company)
                    .font(.headline).foregroundStyle(Palette.ink)
                Spacer(minLength: 6)
                if showsChevron {
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted)
                }
            }
            Text(application.roleTitle).font(featured ? .largeTitle.weight(.bold) : Typeface.title).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text([application.stageLabel, application.job.location].filter { !$0.isBlank }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Palette.muted)
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
    @State private var practicing = false

    private var application: Application? { store.account.applications.first { $0.id == applicationID } }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            if let app = application {
                SheetPage(title: "Application") {
                    ApplicationIdentity(application: app, featured: true)
                    if !app.isDemo, ["Saved", "Ready to apply"].contains(app.status) {
                        let url = JobListingLink.safeURL(app.job.url)
                        VStack(spacing: Spacing.option) {
                            if let url {
                                StackButton(label: "Open employer site", icon: "link") { openURL(url) }
                            }
                            StackButton(label: "Mark as submitted", icon: "done", kind: url == nil ? .primary : .secondary, disabled: store.busy) {
                                Task { await store.mutate("mark_application_submitted", ["id": .string(app.id)], notice: "Marked as submitted.") }
                            }
                        }
                    } else if !app.isDemo, ["Interview", "Interviewing"].contains(app.status) {
                        StackButton(label: "Practice for interview", icon: "chat") { practicing = true }
                    }

                    if let reminder = app.firstFollowUp(in: store.account.reminders) {
                        Label {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(reminder.title.isBlank ? "Follow-up" : reminder.title).font(.headline)
                                Text(Date(timeIntervalSince1970: reminder.dueAt), format: .dateTime.month().day().year().hour().minute())
                                    .font(.subheadline).foregroundStyle(Palette.muted)
                            }
                        } icon: { Image(systemName: "bell").foregroundStyle(Brand.accent) }
                        .foregroundStyle(Palette.ink)
                        .accessibilityElement(children: .combine)
                    }
                    if !store.error.isEmpty { MessageLine(text: store.error) }
                    if !store.notice.isEmpty { MessageLine(text: store.notice, isError: false) }

                    VStack(spacing: 0) {
                        ListRow(label: "Add follow-up", icon: "bell") { showReminder = true }
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
                        if !app.history.isEmpty {
                            DisclosureSection("Status history", detail: app.history.count == 1 ? "1 update" : "\(app.history.count) updates") {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(Array(app.history.sorted { $0.at > $1.at }.enumerated()), id: \.offset) { _, event in
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(event.status).font(.headline).foregroundStyle(Palette.ink)
                                            let info = [event.at > 0 ? dateTime(event.at) : "", event.source]
                                                .filter { !$0.isBlank }.joined(separator: " · ")
                                            if !info.isEmpty { Text(info).font(.footnote).foregroundStyle(Palette.muted) }
                                        }
                                        .accessibilityElement(children: .combine)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !app.isDemo { ApplicationAgentSection(application: app) }
                }
                .onAppear { if !loadedNotes { notes = app.notes; loadedNotes = true } }
            } else {
                SheetPage(title: "Application unavailable") {
                    Text("This application is no longer available.").font(Typeface.body).foregroundStyle(Palette.muted)
                }
            }
        }
        .sheet(isPresented: $practicing) {
            InterviewView(initialApplicationID: applicationID).environment(store)
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

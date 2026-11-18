import SwiftUI

@MainActor
struct ApplicationsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.stackReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    var onProfile: () -> Void
    var onNavigate: (StackTab) -> Void

    @State var filter = "All"
    @State var selected: Application?
    @State var showCalendar = false
    @State var showReminders = false
    @Namespace private var pipelineSpace
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
        let present = Set(store.account.applications.map(\.stage))
        return ApplicationStage.order.filter(present.contains) + present.subtracting(ApplicationStage.order).sorted()
    }

    var body: some View {
        let all = store.account.applications.sorted { $0.lastActivity > $1.lastActivity }
        CollectionPage(title: "Applications", onProfile: onProfile) {
            HeaderMenu("ellipsis", label: "Application tools") {
                Button { showCalendar = true } label: { Label("Calendar", systemImage: "calendar") }
                Button { showReminders = true } label: { Label("Reminders", systemImage: "bell") }
                Button { trackingDestination = .overview } label: { Label("Gmail tracking", systemImage: "envelope") }
            }
        } content: { availableHeight in
            if all.isEmpty {
                CollectionEmptyState(symbol: "tray", title: "No applications yet", actionTitle: "Browse jobs") {
                    onNavigate(.jobs)
                }
                .frame(minHeight: availableHeight)
            } else if all.count <= 2 {
                VStack(alignment: .leading, spacing: Spacing.group) {
                    ForEach(all) { app in hero(app, isOnlyRole: all.count == 1) }
                }
                .padding(.top, 4)
                .padding(.bottom, all.count == 1 ? 40 : 0)
                .frame(maxWidth: .infinity, minHeight: all.count == 1 ? availableHeight : nil,
                       alignment: all.count == 1 ? .center : .topLeading)
            } else {
                list(all)
            }
        }
        .animation(reduceMotion ? nil : Motion.smooth, value: all.count > 2)
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

    // MARK: List

    private func list(_ all: [Application]) -> some View {
        let displayed = filter == "All" ? all : all.filter { $0.stage == filter }
        let grouped = Dictionary(grouping: displayed, by: \.stage)
        return VStack(alignment: .leading, spacing: Spacing.group) {
            if stages.count > 1 {
                pipeline(all)
            }
            ForEach(stages, id: \.self) { stage in
                if let roles = grouped[stage] {
                    VStack(alignment: .leading, spacing: 8) {
                        if filter == "All" {
                            SectionHeader(title: stage) {
                                Text("\(roles.count)").font(.footnote.weight(.semibold)).foregroundStyle(Palette.muted)
                                    .contentTransition(.numericText())
                            }
                        }
                        Card(spacing: 0) {
                            ForEach(roles) { app in
                                row(app)
                                if app.id != roles.last?.id { Divider().padding(.leading, 56) }
                            }
                        }
                    }
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }
            }
        }
        .padding(.top, 4)
        .animation(reduceMotion ? nil : Motion.snappy, value: filter)
        .sensoryFeedback(.selection, trigger: filter)
    }

    /// Stage counts that also filter. Runs edge to edge so the strip scrolls under the page margin.
    private func pipeline(_ all: [Application]) -> some View {
        let counts = Dictionary(grouping: all, by: \.stage).mapValues(\.count)
        let entries = [("All", all.count)] + stages.map { ($0, counts[$0] ?? 0) }
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(entries, id: \.0) { entry in
                    let isSelected = filter == entry.0
                    Button {
                        withAnimation(reduceMotion ? nil : Motion.snappy) { filter = entry.0 }
                    } label: {
                        HStack(spacing: 6) {
                            Text(entry.0)
                            Text("\(entry.1)").contentTransition(.numericText())
                                .foregroundStyle(isSelected ? Palette.onDark.opacity(0.7) : Palette.muted)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isSelected ? Palette.onDark : Palette.ink)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 40)
                        .background {
                            ZStack {
                                Capsule().fill(Palette.surface)
                                    .overlay(Capsule().strokeBorder(Palette.rule.opacity(0.7), lineWidth: 0.5))
                                if isSelected {
                                    Capsule().fill(Palette.dark).matchedGeometryEffect(id: "pipeline", in: pipelineSpace)
                                }
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.tap(scale: 0.96, dim: 1))
                    .accessibilityLabel("\(entry.0), \(entry.1)")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, Spacing.page, for: .scrollContent)
        .scrollIndicators(.hidden)
        .padding(.horizontal, -Spacing.page)
    }

    private func row(_ app: Application) -> some View {
        let reminder = app.firstFollowUp(in: store.account.reminders)
        return Button { selected = app } label: {
            HStack(spacing: 12) {
                EmployerMark(job: app.job, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.roleTitle).font(.headline).foregroundStyle(Palette.ink)
                        .lineLimit(typeSize.isAccessibilitySize ? nil : 2)
                    if !app.job.company.isBlank {
                        Text(app.job.company).font(.subheadline).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 6) {
                    if app.lastActivity > 0 {
                        Text(relativeDay(app.lastActivity)).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    if let reminder { followUpPill(reminder) }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .multilineTextAlignment(.leading)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.985, dim: 1))
        .contextMenu { actions(for: app) }
        .accessibilityLabel(([app.roleTitle, app.job.company, app.stage]
                             + (reminder.map { [followUpText($0)] } ?? [])).filter { !$0.isBlank }.joined(separator: ", "))
    }

    @ViewBuilder
    private func actions(for app: Application) -> some View {
        Button { selected = app } label: { Label("Details", systemImage: "doc.text") }
        if !app.isDemo, ["Saved", "Ready to apply"].contains(app.status) {
            Button {
                Task { await store.mutate("mark_application_submitted", ["id": .string(app.id)], notice: "Marked as applied") }
            } label: { Label("Mark as applied", systemImage: "checkmark.circle") }
        }
        if !app.isDemo, let url = JobListingLink.safeURL(app.job.url) {
            Button { openURL(url) } label: { Label("Open listing", systemImage: "link") }
        }
    }

    private func followUpText(_ reminder: Reminder) -> String {
        reminder.dueAt <= Date().timeIntervalSince1970 ? "Follow up" : "Follow up " + dueLabel(reminder.dueAt)
    }

    private func followUpPill(_ reminder: Reminder) -> some View {
        StatusPill(text: followUpText(reminder), tone: reminder.dueAt <= Date().timeIntervalSince1970 ? .warning : .accent)
    }

    // MARK: Hero cards (one or two roles)

    private func hero(_ app: Application, isOnlyRole: Bool) -> some View {
        let reminder = app.firstFollowUp(in: store.account.reminders)
        let trail = app.recentActivity(limit: isOnlyRole ? 3 : 2, reminder: reminder)
        return Button { selected = app } label: {
            Card(spacing: isOnlyRole ? 22 : 16) {
                HStack(alignment: .top) {
                    EmployerMark(job: app.job, size: isOnlyRole ? 64 : 52)
                    Spacer(minLength: 8)
                    StatusPill(text: app.stage, tone: ApplicationStage.tone(app.stage))
                }
                VStack(alignment: .leading, spacing: 6) {
                    if !app.job.company.isBlank {
                        Text(app.job.company).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.muted)
                    }
                    Text(app.roleTitle)
                        .font(isOnlyRole ? .largeTitle.weight(.bold) : .title2.weight(.bold))
                        .foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if !app.job.location.isBlank {
                        Text(app.job.location).font(.subheadline).foregroundStyle(Palette.muted)
                    }
                }
                if !trail.isEmpty {
                    Divider()
                    ActivityFeed(items: trail, compact: true)
                }
                HStack(spacing: 4) {
                    Text("Details").font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.bold))
                }
                .foregroundStyle(Brand.accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .multilineTextAlignment(.leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.tap(scale: 0.98, dim: 1))
        .contextMenu { actions(for: app) }
        .accessibilityLabel(([app.roleTitle, app.job.company, app.job.location, app.stage]
                             + trail.map { "\($0.title), \($0.date)" })
            .filter { !$0.isBlank }.joined(separator: ", "))
    }
}

// MARK: - Stage and activity

enum ApplicationStage {
    /// Display order. Server statuses "Ready to apply", "Submitted" and "Interview" read as the first three below.
    static let order = ["Saved", "Applied", "Assessment", "Interviewing", "Offer", "Rejected"]

    static func display(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "": return "No stage"
        case "ready to apply": return "Saved"
        case "submitted": return "Applied"
        case "interview": return "Interviewing"
        default: return raw
        }
    }

    static func tone(_ stage: String) -> StatusPill.Tone {
        switch stage {
        case "Applied", "Interviewing": return .accent
        case "Assessment": return .warning
        case "Offer": return .success
        case "Rejected": return .danger
        default: return .neutral
        }
    }

    static func symbol(_ stage: String) -> String {
        switch stage {
        case "Saved": return "bookmark"
        case "Applied": return "paperplane"
        case "Assessment": return "list.clipboard"
        case "Interviewing": return "person.2"
        case "Offer": return "checkmark.seal"
        case "Rejected": return "xmark.circle"
        default: return "clock"
        }
    }
}

struct ApplicationTrailItem {
    let title: String
    let date: String
    let symbol: String
    var upcoming = false
}

/// A native-feeling activity feed: a symbol disc per event joined by a hairline, newest first.
private struct ActivityFeed: View {
    let items: [ApplicationTrailItem]
    var compact = false

    var body: some View {
        let disc: CGFloat = compact ? 26 : 30
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: item.symbol)
                        .font(.system(size: disc * 0.42, weight: .semibold))
                        .foregroundStyle(item.upcoming ? Palette.warning : Brand.accent)
                        .frame(width: disc, height: disc)
                        .background(item.upcoming ? Palette.warning.opacity(0.14) : Palette.halo, in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(item.date).font(.footnote).foregroundStyle(Palette.muted)
                    }
                    .padding(.top, 2)
                    .padding(.bottom, index == items.count - 1 ? 0 : 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(alignment: .topLeading) {
                    if index < items.count - 1 {
                        Rectangle().fill(Palette.rule.opacity(0.8)).frame(width: 1.5)
                            .padding(.top, disc + 3).padding(.leading, disc / 2 - 0.75)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private func relativeDay(_ seconds: Double) -> String {
    let date = Date(timeIntervalSince1970: seconds)
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

/// "Thu" within the coming week, otherwise "Mar 3".
private func dueLabel(_ seconds: Double) -> String {
    let date = Date(timeIntervalSince1970: seconds)
    if date.timeIntervalSinceNow < 6 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
    return date.formatted(.dateTime.month(.abbreviated).day())
}

private extension Application {
    var roleTitle: String { job.title.isBlank ? "Untitled" : job.title }
    var stage: String { ApplicationStage.display(status) }
    var lastActivity: Double { max(createdAt, history.map(\.at).max() ?? 0) }

    func firstFollowUp(in reminders: [Reminder]) -> Reminder? {
        reminders.filter { !$0.done && $0.targetType == "application" && $0.targetID == id && $0.dueAt > 0 }
            .min { $0.dueAt < $1.dueAt }
    }

    /// Newest first: an upcoming reminder, then the latest stage changes.
    func recentActivity(limit: Int, reminder: Reminder?) -> [ApplicationTrailItem] {
        var events = history.filter { $0.at > 0 && !$0.status.isBlank }
        if createdAt > 0, !events.contains(where: { abs($0.at - createdAt) < 1 }) {
            events.append(StatusEvent(status: "Saved", at: createdAt, source: ""))
        }
        var items: [ApplicationTrailItem] = []
        if let reminder {
            items.append(ApplicationTrailItem(
                title: reminder.title.isBlank ? "Follow up" : reminder.title,
                date: Date(timeIntervalSince1970: reminder.dueAt).formatted(date: .abbreviated, time: .shortened),
                symbol: "bell", upcoming: true))
        }
        items += events.sorted { $0.at > $1.at }.prefix(limit).map { event in
            let stage = ApplicationStage.display(event.status)
            return ApplicationTrailItem(title: stage,
                                        date: Date(timeIntervalSince1970: event.at).formatted(date: .abbreviated, time: .omitted),
                                        symbol: ApplicationStage.symbol(stage))
        }
        return items
    }
}

/// The employer's logo, or a tinted rounded square with its initial.
private struct EmployerMark: View {
    let job: Job
    let size: CGFloat

    var body: some View {
        let tint = Palette.tint(for: job.company)
        Group {
            if let image = JobLogoImages.image(job) {
                Image(uiImage: image).resizable().scaledToFit().padding(size * 0.14)
                    .background(Color.white)
            } else if job.company.isBlank {
                Image(systemName: "building.2").foregroundStyle(Palette.muted)
            } else {
                Text(job.company.stackInitials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded)).foregroundStyle(tint.ink)
            }
        }
        .frame(width: size, height: size)
        .background(job.company.isBlank ? Palette.halo : tint.fill)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .strokeBorder(Palette.rule.opacity(0.35), lineWidth: 0.5))
        .accessibilityHidden(true)
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
                    hero(app)
                    activity(app)

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
                                StackField(label: "Notes", text: $notes, multiline: true)
                                StackButton(label: "Save notes", disabled: store.busy || notes == app.notes) {
                                    Task { await store.mutate("save_application", ["id": .string(app.id), "notes": .string(notes)]) }
                                }
                            }
                        }
                    }
                    if !store.error.isEmpty { MessageLine(text: store.error) }
                    if !store.notice.isEmpty { MessageLine(text: store.notice, isError: false) }
                    if !app.isDemo { ApplicationAgentSection(application: app) }
                    actions(app)
                }
                .onAppear { if !loadedNotes { notes = app.notes; loadedNotes = true } }
            } else {
                SheetPage(title: "Application unavailable") {
                    Text("This application is no longer available").font(Typeface.body).foregroundStyle(Palette.muted)
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
                        notice: "Reminder added", askNotifications: true
                    )
                    if ok { showReminder = false }
                }
            }
        }
    }

    private func hero(_ app: Application) -> some View {
        let reminder = app.firstFollowUp(in: store.account.reminders)
        return VStack(alignment: .leading, spacing: 16) {
            EmployerMark(job: app.job, size: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(app.roleTitle).font(.title.weight(.bold)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                let line = [app.job.company, app.job.location].filter { !$0.isBlank }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.body).foregroundStyle(Palette.muted) }
            }
            HStack(spacing: 8) {
                StatusPill(text: app.stage, tone: ApplicationStage.tone(app.stage))
                if let reminder, reminder.dueAt > Date().timeIntervalSince1970 {
                    StatusPill(text: "Follow up " + dueLabel(reminder.dueAt), tone: .warning)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func activity(_ app: Application) -> some View {
        let items = app.recentActivity(limit: 20, reminder: app.firstFollowUp(in: store.account.reminders))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: "Activity")
                Card { ActivityFeed(items: items) }
            }
        }
    }

    /// The next step and the quieter ways to manage the application, together at the end.
    @ViewBuilder
    private func actions(_ app: Application) -> some View {
        VStack(spacing: Spacing.option) {
            if !app.isDemo, ["Saved", "Ready to apply"].contains(app.status) {
                let url = JobListingLink.safeURL(app.job.url)
                StackButton(label: "Mark as applied", icon: "done", disabled: store.busy) {
                    Task { await store.mutate("mark_application_submitted", ["id": .string(app.id)], notice: "Marked as applied") }
                }
                if let url {
                    StackButton(label: "Open listing", icon: "link", kind: .secondary) { openURL(url) }
                }
            } else if !app.isDemo, ["Interview", "Interviewing"].contains(app.status) {
                StackButton(label: "Practice interview", icon: "chat") { practicing = true }
            }
            StackButton(label: "Add reminder", icon: "bell", kind: .secondary) { showReminder = true }
        }
        .padding(.top, 4)
    }

    private func resumeName(for app: Application) -> String {
        app.resumeID.isEmpty ? "None" : (store.account.resume(app.resumeID)?.name ?? "Attached")
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
        SheetPage(title: "New reminder") {
            StackField(label: "Title", text: $title)
            DatePicker("When", selection: $due, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .font(Typeface.body)
                .tint(Brand.accent)
            StoreMessages()
            StackButton(label: "Save", disabled: store.busy || title.isBlank, action: onSave)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

import SwiftUI

struct CalendarEntry: Hashable {
    let title: String
    let company: String
    let time: String
}

/// The Applications calendar: applications by the day they were saved or updated, interviews found in
/// email invitations, and follow-up reminders. The same three maps the other clients draw.
enum ApplicationCalendar {
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func timeRange(_ start: Date, _ end: Date?) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened)
        return start.formatted(style) + (end.map { "–" + $0.formatted(style) } ?? "")
    }

    static func parse(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    static func build(applications: [Application], reminders: [Reminder], interviews: [JSON],
                      calendar: Calendar = .current) -> (activity: [String: [String]], events: [String: [CalendarEntry]]) {
        var activity: [String: [String]] = [:]
        var events: [String: [CalendarEntry]] = [:]
        for app in applications where !app.isDemo {
            let label = "\(app.job.company.isEmpty ? "Employer" : app.job.company) · \(app.job.title.isEmpty ? "Saved job" : app.job.title)"
            // One entry per application per day: a later change that day (such as Submitted) names the entry.
            var days: [String: String] = [dayKey(Date(timeIntervalSince1970: app.createdAt), calendar: calendar): label]
            for event in app.history {
                days[dayKey(Date(timeIntervalSince1970: event.at), calendar: calendar)] = "\(label) · \(event.status)"
            }
            for (day, text) in days { activity[day, default: []].append(text) }
        }
        for reminder in reminders where reminder.targetType == "application" {
            let date = Date(timeIntervalSince1970: reminder.dueAt)
            let company = applications.first { $0.id == reminder.targetID }?.job.company ?? ""
            events[dayKey(date, calendar: calendar), default: []].append(
                CalendarEntry(title: reminder.title + (reminder.done ? " (done)" : ""),
                              company: company.isEmpty ? "Follow-up" : company, time: timeRange(date, nil))
            )
        }
        for interview in interviews {
            guard let start = parse(interview["start"]["dateTime"].string), interview["status"].string != "cancelled" else { continue }
            let end = parse(interview["end"]["dateTime"].string)
            let company = applications.first { $0.id == interview["application_id"].string }?.job.company ?? ""
            events[dayKey(start, calendar: calendar), default: []].append(
                CalendarEntry(title: interview["summary"].string.isEmpty ? "Interview" : interview["summary"].string,
                              company: company.isEmpty ? "Interview" : company, time: timeRange(start, end))
            )
        }
        return (activity, events)
    }

    /// Consecutive days, ending today, with application activity.
    static func streak(activity: [String: [String]], today: Date, calendar: Calendar = .current) -> Int {
        var count = 0
        var day = today
        while !(activity[dayKey(day, calendar: calendar)] ?? []).isEmpty {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return count
    }
}

struct ApplicationCalendarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var interviews: [JSON] = []
    @State private var connected = false
    @State private var loading = true
    @State private var error = ""
    @State private var month = Date()
    @State private var selected = Date()

    private var model: (activity: [String: [String]], events: [String: [CalendarEntry]]) {
        ApplicationCalendar.build(applications: store.account.applications, reminders: store.account.reminders, interviews: interviews)
    }

    private var calendar: Calendar { .current }

    var body: some View {
        let data = model
        SheetPage(title: "Calendar") {
            let streak = ApplicationCalendar.streak(activity: data.activity, today: Date())
            if streak > 0 {
                Text("\(streak)-day streak of application activity").font(Typeface.body).foregroundStyle(Palette.text)
            }
            HStack {
                Chip(label: "‹") { shift(-1) }.accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(Typeface.section).foregroundStyle(Palette.ink)
                Spacer()
                Chip(label: "›") { shift(1) }.accessibilityLabel("Next month")
            }
            grid(data)
            dayDetail(data)
            if !connected {
                Card(tint: Palette.oat, spacing: 8) {
                    Text("Interviews from your email").font(Typeface.option).foregroundStyle(Palette.icon)
                    Text("Connect Google Calendar so Stack can find interview invitations and, only after you approve, add events.")
                        .font(Typeface.caption).foregroundStyle(Palette.text)
                    StackButton(label: "Connect Google Calendar", icon: "link", kind: .secondary) { Task { await connect() } }
                }
            }
            if loading { ProgressView().tint(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
        .task { await load() }
    }

    private func shift(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: month) {
            withAnimation(Motion.fadeAnimation) { month = next }
        }
    }

    private func grid(_ data: (activity: [String: [String]], events: [String: [CalendarEntry]])) -> some View {
        let days = monthDays()
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        return VStack(spacing: 6) {
            HStack {
                ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, label in
                    Text(label).font(Typeface.caption).foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let key = ApplicationCalendar.dayKey(day)
                        let isSelected = calendar.isDate(day, inSameDayAs: selected)
                        let hasActivity = !(data.activity[key] ?? []).isEmpty
                        let hasEvent = !(data.events[key] ?? []).isEmpty
                        Button { selected = day } label: {
                            VStack(spacing: 3) {
                                Text("\(calendar.component(.day, from: day))")
                                    .font(Typeface.caption.weight(isSelected ? .bold : .regular))
                                    .foregroundStyle(isSelected ? Palette.onDark : Palette.text)
                                HStack(spacing: 3) {
                                    Circle().fill(hasActivity ? Palette.ring : .clear).frame(width: 6, height: 6)
                                    Circle().fill(hasEvent ? Color(hex: 0xC8742B) : .clear).frame(width: 6, height: 6)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(isSelected ? Palette.dark : (calendar.isDateInToday(day) ? Palette.halo : Palette.surface),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.tap(scale: 0.94, dim: 1))
                        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month().day())
                                            + (hasActivity ? ", application activity" : "") + (hasEvent ? ", has events" : ""))
                    } else {
                        Color.clear.frame(height: 44)
                    }
                }
            }
        }
    }

    private func dayDetail(_ data: (activity: [String: [String]], events: [String: [CalendarEntry]])) -> some View {
        let key = ApplicationCalendar.dayKey(selected)
        let activity = data.activity[key] ?? []
        let events = data.events[key] ?? []
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: selected.formatted(.dateTime.weekday(.wide).month(.wide).day()))
            if activity.isEmpty, events.isEmpty {
                Text("Nothing on this day.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(Array(events.enumerated()), id: \.offset) { _, entry in
                Card(spacing: 4) {
                    Text(entry.title).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text("\(entry.company) · \(entry.time)").font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            ForEach(activity, id: \.self) { Text($0).font(Typeface.body).foregroundStyle(Palette.text) }
        }
    }

    /// Leading blanks, then every day of `month`, Monday first.
    private func monthDays() -> [Date?] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let blanks = (weekday - calendar.firstWeekday + 7) % 7
        let count = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 30
        let leading: [Date?] = Array(repeating: nil, count: blanks)
        let days: [Date?] = (0..<count).map { calendar.date(byAdding: .day, value: $0, to: interval.start) }
        return leading + days
    }

    private func load() async {
        do {
            async let events = store.call("agent_events")
            async let settings = store.call("agent_settings")
            let (eventResult, settingsResult) = try await (events, settings)
            interviews = eventResult["interviews"].array
            connected = settingsResult["connections"].array.contains {
                $0["provider"].string == "google" && $0["state"].string == "connected"
                    && $0["scopes"].strings.contains { $0.localizedCaseInsensitiveContains("calendar") }
            }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
        loading = false
    }

    private func connect() async {
        do {
            let result = try await store.call("agent_google_start", ["capabilities": ["calendar"]])
            guard let url = URL(string: result["url"].string), url.scheme == "https" else {
                throw APIError(message: result["error"].string.isEmpty ? "Google Calendar could not be connected." : result["error"].string)
            }
            openURL(url)
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

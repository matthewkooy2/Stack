import SwiftUI

enum AgentPage: String, CaseIterable, Identifiable {
    case needsYou = "Needs you"
    case activity = "Activity"
    case features = "Setup"
    case email = "Connections"
    case facts = "Answers"

    var id: String { rawValue }
}

extension Notification.Name {
    /// Posted with `userInfo["destination"]` (resume, jobs, applications, contacts, prep) to switch tabs.
    static let stackNavigate = Notification.Name("stack.navigate")
}

/// Activity center: attention, activity, feature guide, email and calendar, standing rules and facts.
@MainActor
struct AgentHubView: View {
    var initialPage: AgentPage = .needsYou
    var initialTask = ""
    var initialAction = ""

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.stackReduceMotion) private var reduceMotion

    @State private var page: AgentPage = .needsYou
    @State private var taskID = ""
    @State private var seeded = false
    @State private var settings: JSON = [:]
    @State private var events: [JSON] = []
    @State private var interviews: [JSON] = []
    @State private var error = ""
    @State private var notice = ""
    @State private var busy = false

    // Standing permissions
    @State private var rulesDirty = false
    @State private var enabled = false
    @State private var actions: [String] = []
    @State private var domains = ""
    @State private var daily = "5"
    @State private var followups = "0"
    @State private var analyzeTop = false

    // Facts and messages to confirm
    @State private var factKey = ""
    @State private var factValue = ""
    @State private var eventApplication: [String: String] = [:]
    @State private var eventStatus: [String: String] = [:]

    private var runs: [JSON] { store.account.runViews }
    private var attention: [JSON] { runs.filter { $0["attention"].bool } }
    private var active: [JSON] { runs.filter { AgentLabels.active.contains($0["status"].string) } }
    private var recent: [JSON] { runs.filter { !$0["attention"].bool && !AgentLabels.active.contains($0["status"].string) } }
    private var unresolved: [JSON] { events.filter { $0["ambiguous"].bool && !$0["resolved"].bool } }
    private var realApplications: [Application] { store.account.applications.filter { !$0.isDemo } }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            if !taskID.isEmpty {
                TaskDetailView(id: taskID, webURL: settings["web_url"].string, onBack: { taskID = "" }, onNavigate: go)
                    .id(taskID)
            } else {
                SheetPage(title: "Activity") { hub }
            }
        }
        .task {
            if !seeded {
                seeded = true
                page = initialPage
                taskID = initialTask
                if !initialAction.isEmpty { go(initialAction) }
            }
            await loadSettings(resetRules: true)
            await loadEvents()
        }
        .task(id: "poll") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                if Task.isCancelled { break }
                await store.refresh()
                guard !busy, taskID.isEmpty else { continue }
                if page == .needsYou || page == .email { await loadEvents() }
                if page == .facts { await loadSettings(resetRules: false) }
            }
        }
    }

    // MARK: Pages

    private var hub: some View {
        let pending = attention.count + unresolved.count
        return VStack(alignment: .leading, spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentPage.allCases) { item in
                        Chip(label: item == .needsYou && pending > 0 ? "\(item.rawValue) · \(pending)" : item.rawValue,
                             selected: page == item) {
                            withAnimation(reduceMotion ? nil : Motion.snappy) { page = item }
                        }
                    }
                }
                .padding(.horizontal, Spacing.page)
            }
            .padding(.horizontal, -Spacing.page)
            .accessibilityLabel("Section")
            .onChange(of: page) { _, _ in error = ""; notice = "" }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            switch page {
            case .needsYou: needsYou
            case .activity: activity
            case .features: featuresPage
            case .email: emailPage
            case .facts: factsPage
            }
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(attention.enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { taskID = run["id"].string }
            }
            if !unresolved.isEmpty {
                Card(spacing: 8) {
                    Text("To confirm").font(.headline).foregroundStyle(Palette.icon)
                    Text("Couldn’t match some emails to an application").font(Typeface.caption).foregroundStyle(Palette.muted)
                    Chip(label: "Open connections") { page = .email }
                }
            }
            if attention.isEmpty, unresolved.isEmpty {
                EmptyNote(icon: "done", title: "You’re all caught up")
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attention.isEmpty {
                SectionLabel(text: "Needs you")
                ForEach(Array(attention.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            }
            if !active.isEmpty {
                SectionLabel(text: "In progress")
                ForEach(Array(active.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            }
            if !recent.isEmpty {
                SectionLabel(text: "Recent")
                ForEach(Array(recent.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            }
            if attention.isEmpty, active.isEmpty, recent.isEmpty {
                EmptyNote(icon: "activity", title: "No activity yet")
            }
            if store.account.modelProviderName.isEmpty, !store.account.modelProviderMessage.isEmpty {
                Card(spacing: 6) {
                    StatusPill(text: "AI model not set up", tone: .warning)
                    Text(store.account.modelProviderMessage).font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.account.features) { feature in
                if feature.key == "email" { GmailTrackingSection() }
                else { FeatureCardView(feature: feature, onAction: go) }
            }
        }
    }

    private var emailPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            GmailTrackingSection(onConnected: { await loadSettings(resetRules: false) })
            DisclosureSection("Settings", detail: "Sending and calendar") { rulesPage }
            if let calendar = store.account.feature("calendar") { FeatureCardView(feature: calendar, onAction: go, compact: true) }
            SectionLabel(text: "To confirm")
            ForEach(Array(unresolved.enumerated()), id: \.offset) { _, event in
                let key = event["id"].string
                Card(spacing: 10) {
                    Text(event["subject"].string.isEmpty ? "Message" : event["subject"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text(String(event["excerpt"].string.prefix(280))).font(Typeface.caption).foregroundStyle(Palette.text)
                    Text("Which application?").font(Typeface.caption).foregroundStyle(Palette.muted)
                    FlowLayout(spacing: 8) {
                        ForEach(realApplications) { app in
                            Chip(label: "\(app.job.company) · \(app.job.title)", selected: eventApplication[key] == app.id) {
                                eventApplication[key] = app.id
                            }
                        }
                    }
                    Text("What does it confirm?").font(Typeface.caption).foregroundStyle(Palette.muted)
                    ChoiceChips(options: ["Submitted", "Assessment", "Interview", "Offer", "Rejected"],
                                isSelected: { eventStatus[key] == $0 }, onTap: { eventStatus[key] = $0 })
                    StackButton(label: "Save",
                                disabled: busy || (eventApplication[key] ?? "").isEmpty || (eventStatus[key] ?? "").isEmpty) {
                        Task {
                            await perform("agent_resolve_event",
                                          ["id": .string(key), "application_id": .string(eventApplication[key] ?? ""),
                                           "status": .string(eventStatus[key] ?? "")],
                                          done: "Status updated")
                        }
                    }
                }
            }
            if unresolved.isEmpty { Text("Nothing to confirm").font(Typeface.caption).foregroundStyle(Palette.muted) }
            SectionLabel(text: "From email")
            ForEach(Array(events.filter { !$0["ambiguous"].bool || $0["resolved"].bool }.prefix(10).enumerated()), id: \.offset) { _, event in
                Card(spacing: 4) {
                    Text("\(event["status"].string.isEmpty ? "Update" : event["status"].string) · \(event["subject"].string)")
                        .font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("“\(String(event["quote"].string.prefix(200)))”").font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            SectionLabel(text: "Interviews")
            ForEach(Array(interviews.enumerated()), id: \.offset) { _, item in
                Card(spacing: 8) {
                    Text(item["summary"].string.isEmpty ? "Interview" : item["summary"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text(isoTime(item["start"]["dateTime"].string)).font(Typeface.caption).foregroundStyle(Palette.muted)
                    ForEach(Array(runs.filter { $0["target_id"].string == item["id"].string && $0["kind"].string == "calendar" }.enumerated()), id: \.offset) { _, run in
                        TaskRow(run: run) { taskID = run["id"].string }
                    }
                    if !item["study_plan"].array.isEmpty {
                        Chip(label: "\(item["study_plan"].array.count) practice sessions") { go("prep") }
                    }
                }
            }
            if interviews.isEmpty {
                Text("Invitations from Gmail appear here")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var rulesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("You approve every change")
                .font(Typeface.body).foregroundStyle(Palette.text)
            ToggleRow(label: "Allow sending and calendar changes", isOn: Binding(get: { enabled }, set: { enabled = $0; rulesDirty = true }))
            if settings["policy"]["enabled"].bool, settings["policy"]["expires_at"].double > 0 {
                Text("Expires \(dateTime(settings["policy"]["expires_at"].double))")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ChoiceChips(options: ["send_email", "calendar_write"],
                        isSelected: { actions.contains($0) },
                        onTap: { actions = actions.toggled($0); rulesDirty = true },
                        labelFor: { $0.replacingOccurrences(of: "_", with: " ").capitalized })
            ToggleRow(label: "Analyze top matches daily", isOn: Binding(get: { analyzeTop }, set: { analyzeTop = $0; rulesDirty = true }))
            StackField(label: "Allowed domains", text: Binding(get: { domains }, set: { domains = $0; rulesDirty = true }),
                       placeholder: "company.com", multiline: true, keyboard: .URL, autocapitalization: .never)
            StackField(label: "Daily limit", text: Binding(get: { daily }, set: { daily = $0; rulesDirty = true }), keyboard: .numberPad)
            StackField(label: "Follow-ups per contact", text: Binding(get: { followups }, set: { followups = $0; rulesDirty = true }), keyboard: .numberPad)
            Text("Expires in 30 days")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Save", disabled: busy) {
                Task { await savePolicy() }
            }
            if rulesDirty, !settings.object.isEmpty {
                StackButton(label: "Discard", kind: .secondary) { fillRules(settings["policy"]) }
            }
            Text("Google").font(Typeface.title).foregroundStyle(Palette.ink)
            StackButton(label: "Allow Gmail sending", kind: .secondary, disabled: busy) { Task { await connect(["send"]) } }
            StackButton(label: "Connect Google Calendar", kind: .secondary, disabled: busy) { Task { await connect(["calendar", "availability"]) } }
            ForEach(Array(settings["connections"].array.filter { $0["state"].string == "connected" }.enumerated()), id: \.offset) { _, connection in
                Card(spacing: 8) {
                    Text("\(connection["provider"].string.capitalized) · \(connection["state"].string)")
                        .font(Typeface.option).foregroundStyle(Palette.icon)
                    StackButton(label: "Disconnect Google", kind: .secondary, disabled: busy) {
                        Task { await perform("agent_disconnect", ["id": connection["id"]], done: "Disconnected") }
                    }
                }
            }
        }
    }

    private var factsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answers Stack can reuse on applications")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(settings["facts"].array.enumerated()), id: \.offset) { _, fact in
                Card(spacing: 6) {
                    Text(fact["key"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text(fact["value"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    Text(fact["source"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if fact["verified"].bool {
                        Chip(label: "Confirmed", selected: true)
                    } else {
                        StackButton(label: "Confirm", kind: .secondary, disabled: busy) {
                            var confirmed = fact
                            confirmed["verified"] = true
                            Task { await perform("agent_save_facts", ["facts": [confirmed]], done: "Confirmed") }
                        }
                    }
                }
            }
            if settings["facts"].array.isEmpty { Text("No answers yet").font(Typeface.caption).foregroundStyle(Palette.muted) }
            StackField(label: "Question", text: $factKey, placeholder: "Work authorization", autocapitalization: .never)
            StackField(label: "Your answer", text: $factValue, multiline: true)
            StackButton(label: "Save answer", disabled: busy || factKey.isBlank || factValue.isBlank) {
                Task {
                    await perform("agent_save_facts",
                                  ["facts": [["key": .string(factKey), "value": .string(factValue), "verified": true, "source": "User confirmed"]]],
                                  done: "Saved")
                    if error.isEmpty { factKey = ""; factValue = "" }
                }
            }
        }
    }

    // MARK: Actions

    /// Routes a fix or result action to the page that handles it.
    private func go(_ action: String) {
        if action == "rules" { page = .email; taskID = "" }
        else if action == "facts" { page = .facts; taskID = "" }
        else if action.hasPrefix("connect:") {
            page = .email
            taskID = ""
            Task { await connect([String(action.dropFirst(8))]) }
        } else if action == "web" {
            if let url = URL(string: settings["web_url"].string), !settings["web_url"].string.isEmpty { openURL(url) }
        } else if action == "features" { page = .features; taskID = "" }
        else if action == "Agents" || action == "Activity" { page = .activity; taskID = "" }
        else {
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
            dismiss()
        }
    }

    private func fillRules(_ policy: JSON) {
        enabled = policy["enabled"].bool
        actions = policy["actions"].strings.filter { !["model", "browser_fill", "submit_application"].contains($0) }
        domains = policy["domains"].strings.joined(separator: ", ")
        followups = policy["followup_limit"].isNull ? "0" : policy["followup_limit"].string
        analyzeTop = policy["analyze_top_matches"].bool
        if let limit = policy["daily_limits"].object.values.first { daily = limit.string }
        rulesDirty = false
    }

    private func loadSettings(resetRules: Bool) async {
        do {
            let result = try await store.call("agent_settings")
            settings = result
            // Refreshes never overwrite rules you are still editing.
            if resetRules || !rulesDirty { fillRules(result["policy"]) }
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func loadEvents() async {
        do {
            let result = try await store.call("agent_events")
            events = result["events"].array
            interviews = result["interviews"].array
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func perform(_ endpoint: String, _ args: JSON, done: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        notice = ""
        defer { busy = false }
        do {
            try await store.call(endpoint, args)
            await store.refresh()
            notice = done
            await loadSettings(resetRules: endpoint == "agent_save_policy")
            await loadEvents()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func connect(_ capabilities: [String]) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            try await store.googleConnection.connect(capabilities)
            await store.refresh()
            await loadSettings(resetRules: false)
            notice = "Google connected"
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func savePolicy() async {
        guard let limit = Int(daily.trimmingCharacters(in: .whitespaces)), let count = Int(followups.trimmingCharacters(in: .whitespaces)),
              limit >= 0, count >= 0 else {
            error = "Use whole numbers"
            return
        }
        let policy: JSON = [
            "enabled": .bool(enabled),
            "actions": .array(actions.map { .string($0) }),
            "domains": .array(domains.commaSeparated.map { .string($0.lowercased()) }),
            "daily_limits": ["send_email": .number(Double(limit)), "calendar_write": .number(Double(limit))],
            "expires_at": .number(Date().timeIntervalSince1970 + 30 * 86_400),
            "followup_limit": .number(Double(count)),
            "followup_days": settings["policy"]["followup_days"].isNull ? .number(7) : settings["policy"]["followup_days"],
            "analyze_top_matches": .bool(analyzeTop),
        ]
        await perform("agent_save_policy", ["policy": policy], done: "Saved")
    }
}

/// A task opened directly, from an application or a notification.
@MainActor
struct AgentTaskSheet: View {
    let taskID: String
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var hubPage: AgentPage?
    @State private var hubAction = ""

    var body: some View {
        TaskDetailView(id: taskID, onBack: { dismiss() }) { destination in
            if destination == "rules" || destination == "facts" || destination == "features" || destination.hasPrefix("connect:") {
                hubAction = destination.hasPrefix("connect:") ? destination : ""
                hubPage = destination == "facts" ? .facts : (destination == "features" ? .features : .email)
            } else {
                NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": destination])
                dismiss()
            }
        }
        .sheet(item: $hubPage) { page in
            AgentHubView(initialPage: page, initialAction: hubAction).environment(store)
        }
    }
}

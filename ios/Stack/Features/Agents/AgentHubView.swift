import SwiftUI

enum AgentPage: String, CaseIterable, Identifiable {
    case needsYou = "Needs you"
    case activity = "Activity"
    case features = "Features"
    case email = "Email & calendar"
    case rules = "Rules"
    case facts = "Facts"

    var id: String { rawValue }
}

extension Notification.Name {
    /// Posted with `userInfo["destination"]` (resume, jobs, applications, contacts, prep) to switch tabs.
    static let stackNavigate = Notification.Name("stack.navigate")
}

/// Agents center: attention, activity, feature guide, email and calendar, standing rules and facts.
@MainActor
struct AgentHubView: View {
    var initialPage: AgentPage = .needsYou
    var initialTask = ""
    var initialAction = ""

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

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
            Page {
                HStack { BackButton(label: "Close") { dismiss() }; Spacer() }
                if !taskID.isEmpty {
                    TaskDetailView(id: taskID, webURL: settings["web_url"].string, onBack: { taskID = "" }, onNavigate: go)
                        .id(taskID)
                } else {
                    hub
                }
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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your agents.").font(Typeface.display).tracking(-1).foregroundStyle(Palette.ink)
                Text("\(store.account.activeRunCount) in progress · \(store.account.attentionRunCount) need you. Updates every few seconds.")
                    .font(Typeface.body).foregroundStyle(Palette.muted)
            }
            .reveal(0)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AgentPage.allCases) { item in
                        let count = attention.count + unresolved.count
                        Chip(label: item.rawValue + (item == .needsYou && count > 0 ? " (\(count))" : ""), selected: page == item) {
                            withAnimation(Motion.fadeAnimation) { page = item }
                            error = ""
                            notice = ""
                        }
                    }
                }
            }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            switch page {
            case .needsYou: needsYou
            case .activity: activity
            case .features: featuresPage
            case .email: emailPage
            case .rules: rulesPage
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
                    Text("Messages to confirm").font(Typeface.option).foregroundStyle(Palette.icon)
                    Text("Email tracking could not tell which application these belong to.").font(Typeface.caption).foregroundStyle(Palette.muted)
                    Chip(label: "Open Email & calendar") { page = .email }
                }
            }
            if attention.isEmpty, unresolved.isEmpty {
                EmptyNote(icon: "done", title: "Nothing needs you right now.",
                          message: "Reviews, questions and paused tasks will appear here.")
            }
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !attention.isEmpty {
                SectionLabel(text: "Needs you")
                ForEach(Array(attention.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            }
            SectionLabel(text: "In progress")
            ForEach(Array(active.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            if active.isEmpty {
                Text("No tasks are running. Start one from Applications, Network, Resume, or Prep.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            SectionLabel(text: "Recent")
            ForEach(Array(recent.enumerated()), id: \.offset) { _, run in TaskRow(run: run) { taskID = run["id"].string } }
            Card(tint: Palette.oat, spacing: 6) {
                let provider = store.account.modelProviderName
                Text("Model provider: \(provider.isEmpty ? "Not configured" : provider)")
                    .font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(store.account.modelProviderMessage).font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var featuresPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Every agent, what it needs, and where to start it. Stack never sends email or changes your calendar without your approval.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            ForEach(store.account.features) { feature in FeatureCardView(feature: feature, onAction: go) }
        }
    }

    private var emailPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let email = store.account.feature("email") { FeatureCardView(feature: email, onAction: go, compact: true) }
            if let calendar = store.account.feature("calendar") { FeatureCardView(feature: calendar, onAction: go, compact: true) }
            SectionLabel(text: "Messages to confirm")
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
                    ChoiceChips(options: ["Submitted", "Assessment", "Interview", "Rejected"],
                                isSelected: { eventStatus[key] == $0 }, onTap: { eventStatus[key] = $0 })
                    StackButton(label: "Save to application",
                                disabled: busy || (eventApplication[key] ?? "").isEmpty || (eventStatus[key] ?? "").isEmpty) {
                        Task {
                            await perform("agent_resolve_event",
                                          ["id": .string(key), "application_id": .string(eventApplication[key] ?? ""),
                                           "status": .string(eventStatus[key] ?? "")],
                                          done: "Application status updated from this message.")
                        }
                    }
                }
            }
            if unresolved.isEmpty { Text("No messages need confirmation.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            SectionLabel(text: "Recent updates from email")
            ForEach(Array(events.filter { !$0["ambiguous"].bool || $0["resolved"].bool }.prefix(10).enumerated()), id: \.offset) { _, event in
                Card(spacing: 4) {
                    Text("\(event["status"].string.isEmpty ? "Update" : event["status"].string) · \(event["subject"].string)")
                        .font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("“\(String(event["quote"].string.prefix(200)))”").font(Typeface.caption).foregroundStyle(Palette.muted)
                }
            }
            if events.isEmpty {
                Text("Tracked updates appear here and in each application’s status history.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
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
                        Chip(label: "\(item["study_plan"].array.count) practice sessions in Prep") { go("prep") }
                    }
                }
            }
            if interviews.isEmpty {
                Text("Interview invitations found by email tracking appear here, each with a calendar change for you to review.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var rulesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Standing permissions let agents work toward your goals. They never replace per-action review: you approve every email and calendar change.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            ToggleRow(label: "Enable standing permissions", isOn: Binding(get: { enabled }, set: { enabled = $0; rulesDirty = true }))
            if settings["policy"]["enabled"].bool, settings["policy"]["expires_at"].double > 0 {
                Text("Current permissions expire \(dateTime(settings["policy"]["expires_at"].double)).")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ChoiceChips(options: ["model", "gmail_read", "send_email", "calendar_write"],
                        isSelected: { actions.contains($0) },
                        onTap: { actions = actions.toggled($0); rulesDirty = true },
                        labelFor: { $0.replacingOccurrences(of: "_", with: " ").capitalized })
            ToggleRow(label: "Analyze up to three top matches daily", isOn: Binding(get: { analyzeTop }, set: { analyzeTop = $0; rulesDirty = true }))
            StackField(label: "Allowed destination domains", text: Binding(get: { domains }, set: { domains = $0; rulesDirty = true }),
                       placeholder: "company.com", multiline: true, keyboard: .URL, autocapitalization: .never)
            Text("Email recipients must be on this list. Use exact domains.").font(Typeface.caption).foregroundStyle(Palette.muted)
            StackField(label: "Daily limit per action", text: Binding(get: { daily }, set: { daily = $0; rulesDirty = true }), keyboard: .numberPad)
            StackField(label: "Follow-ups per contact (0–3)", text: Binding(get: { followups }, set: { followups = $0; rulesDirty = true }), keyboard: .numberPad)
            Text("Permissions expire after 30 days. Follow-ups are drafted seven days apart, wait for your approval, and stop when a reply arrives.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StackButton(label: "Save standing permissions" + (rulesDirty ? " · unsaved changes" : ""), disabled: busy) {
                Task { await savePolicy() }
            }
            if rulesDirty, !settings.object.isEmpty {
                StackButton(label: "Discard changes", kind: .secondary) { fillRules(settings["policy"]) }
            }
            Text("Google").font(Typeface.title).foregroundStyle(Palette.ink)
            StackButton(label: "Connect Gmail tracking", kind: .secondary) { Task { await connect(["read"]) } }
            StackButton(label: "Allow Gmail sending", kind: .secondary) { Task { await connect(["send"]) } }
            StackButton(label: "Connect Google Calendar", kind: .secondary) { Task { await connect(["calendar", "availability"]) } }
            Text("Gmail read access covers your whole mailbox. Stack only processes messages related to your applications and selected contacts.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            ForEach(Array(settings["connections"].array.enumerated()), id: \.offset) { _, connection in
                Card(spacing: 8) {
                    Text("\(connection["provider"].string.capitalized) · \(connection["state"].string)")
                        .font(Typeface.option).foregroundStyle(Palette.icon)
                    StackButton(label: "Disconnect", kind: .secondary, disabled: busy) {
                        Task { await perform("agent_disconnect", ["id": connection["id"]], done: "Disconnected.") }
                    }
                }
            }
            if !settings["account_id"].string.isEmpty {
                Text("Account ID (for local subscription setup): \(settings["account_id"].string)")
                    .font(Typeface.caption).foregroundStyle(Palette.muted).textSelection(.enabled)
            }
        }
    }

    private var factsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents reuse only confirmed facts. Extract text from a resume on the Resume tab, then confirm what is accurate.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            ForEach(Array(settings["facts"].array.enumerated()), id: \.offset) { _, fact in
                Card(spacing: 6) {
                    Text(fact["key"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text(fact["value"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    Text(fact["source"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                    if fact["verified"].bool {
                        Chip(label: "Confirmed", selected: true)
                    } else {
                        StackButton(label: "Confirm this fact", kind: .secondary, disabled: busy) {
                            var confirmed = fact
                            confirmed["verified"] = true
                            Task { await perform("agent_save_facts", ["facts": [confirmed]], done: "Fact confirmed.") }
                        }
                    }
                }
            }
            if settings["facts"].array.isEmpty { Text("No facts yet.").font(Typeface.caption).foregroundStyle(Palette.muted) }
            StackField(label: "Fact name", text: $factKey, placeholder: "email, phone, name, work_authorization", autocapitalization: .never)
            StackField(label: "Your answer", text: $factValue, multiline: true)
            StackButton(label: "Save confirmed fact", disabled: busy || factKey.isBlank || factValue.isBlank) {
                Task {
                    await perform("agent_save_facts",
                                  ["facts": [["key": .string(factKey), "value": .string(factValue), "verified": true, "source": "User confirmed"]]],
                                  done: "Fact saved.")
                    if error.isEmpty { factKey = ""; factValue = "" }
                }
            }
        }
    }

    // MARK: Actions

    /// Routes a fix or result action to the page that handles it.
    private func go(_ action: String) {
        if action == "rules" { page = .rules; taskID = "" }
        else if action == "facts" { page = .facts; taskID = "" }
        else if action.hasPrefix("connect:") {
            page = .rules
            taskID = ""
            Task { await connect([String(action.dropFirst(8))]) }
        } else if action == "web" {
            if let url = URL(string: settings["web_url"].string), !settings["web_url"].string.isEmpty { openURL(url) }
        } else if action == "features" { page = .features; taskID = "" }
        else if action == "Agents" { page = .activity; taskID = "" }
        else {
            NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": action])
            dismiss()
        }
    }

    private func fillRules(_ policy: JSON) {
        enabled = policy["enabled"].bool
        actions = policy["actions"].strings.filter { !["browser_fill", "submit_application"].contains($0) }
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
            notice = done
            await loadSettings(resetRules: endpoint == "agent_save_policy")
            await loadEvents()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func connect(_ capabilities: [String]) async {
        error = ""
        do {
            let result = try await store.call("agent_google_start", ["capabilities": .array(capabilities.map { .string($0) })])
            guard let url = URL(string: result["url"].string), url.scheme == "https" else {
                throw APIError(message: "Google connection is unavailable.")
            }
            openURL(url)
            notice = "Finish connecting Google in your browser, then return to Stack."
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func savePolicy() async {
        guard let limit = Int(daily.trimmingCharacters(in: .whitespaces)), let count = Int(followups.trimmingCharacters(in: .whitespaces)),
              limit >= 0, count >= 0 else {
            error = "Enter whole numbers for daily and follow-up limits."
            return
        }
        let policy: JSON = [
            "enabled": .bool(enabled),
            "actions": .array(actions.map { .string($0) }),
            "domains": .array(domains.commaSeparated.map { .string($0.lowercased()) }),
            "daily_limits": ["send_email": .number(Double(limit)), "calendar_write": .number(Double(limit))],
            "expires_at": .number(Date().timeIntervalSince1970 + 30 * 86_400),
            "followup_limit": .number(Double(count)),
            "followup_days": 7,
            "analyze_top_matches": .bool(analyzeTop),
        ]
        await perform("agent_save_policy", ["policy": policy], done: "Standing permissions saved for 30 days.")
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
        SheetPage(title: "Task") {
            TaskDetailView(id: taskID, onBack: { dismiss() }) { destination in
                if destination == "rules" || destination == "facts" || destination == "features" || destination.hasPrefix("connect:") {
                    hubAction = destination.hasPrefix("connect:") ? destination : ""
                    hubPage = destination == "facts" ? .facts : (destination == "features" ? .features : .rules)
                } else {
                    NotificationCenter.default.post(name: .stackNavigate, object: nil, userInfo: ["destination": destination])
                    dismiss()
                }
            }
        }
        .sheet(item: $hubPage) { page in
            AgentHubView(initialPage: page, initialAction: hubAction).environment(store)
        }
    }
}

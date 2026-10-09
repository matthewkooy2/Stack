import SwiftUI

/// Technical practice: save answers and code, run tests, and get focused coaching.
struct PracticeView: View {
    @Environment(AppStore.self) private var store

    @State private var problems: [PrepQuestion] = []
    @State private var sessions: [JSON] = []
    @State private var current: JSON = [:]
    @State private var answer = ""
    @State private var code = ""
    @State private var notes = ""
    @State private var dirty = false
    @State private var busy = false
    @State private var error = ""
    @State private var message = ""
    @State private var web = ""
    @State private var taskID: TaskTarget?

    @Environment(\.openURL) private var openURL

    private var data: JSON { current["data"] }
    private var problem: PrepQuestion? { problems.first { $0.id == data["problem_id"].string } }
    private var hasLanguage: Bool { !data["language"].string.isEmpty }
    private var coachingFeature: AgentFeature? { store.account.feature("coaching") }
    private var codeFeature: AgentFeature? { store.account.feature("code") }
    private var liveFeature: AgentFeature? { store.account.feature("live") }

    var body: some View {
        SheetPage(title: "Technical practice", subtitle: "Save answers and code, run tests, and get focused feedback.") {
            featureSummary
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
            if let url = URL(string: web), !web.isEmpty {
                StackButton(label: "Open web workspace (editor, timer, live interview)", kind: .secondary) { openURL(url) }
            } else {
                Text("The laptop workspace and live interviews become available when hosting is configured.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if current.object.isEmpty { chooser } else { editor }
            if !sessions.isEmpty {
                SectionLabel(text: "Continue a session")
                ForEach(Array(sessions.enumerated()), id: \.offset) { _, row in
                    let language = row["data"]["language"].string
                    OptionRow(label: row["data"]["problem_id"].string + (language.isEmpty ? "" : " · \(language)"), icon: "code", disabled: busy) {
                        Task { await resume(row["id"].string) }
                    }
                }
            }
        }
        .task { await reload() }
        .task(id: current["id"].string) {
            while !Task.isCancelled, !current["id"].string.isEmpty {
                try? await Task.sleep(for: .milliseconds(1500))
                if Task.isCancelled { break }
                await pollResults()
            }
        }
        .sheet(item: $taskID) { AgentTaskSheet(taskID: $0.id).environment(store) }
    }

    // MARK: Sections

    @ViewBuilder
    private var featureSummary: some View {
        let features = [coachingFeature, codeFeature, liveFeature].compactMap { $0 }
        if !features.isEmpty {
            Card(spacing: 10) {
                ForEach(features) { feature in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(feature.title).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                            Spacer()
                            StatusPill(label: AgentLabels.featureState[feature.state] ?? feature.state, tone: AgentLabels.featureTone(feature.state))
                        }
                        Text(feature.summary).font(Typeface.caption).foregroundStyle(Palette.muted)
                        ForEach(feature.missingRequired) { Text("✕ \($0.fix)").font(Typeface.caption).foregroundStyle(Palette.text) }
                        if feature.state != "ready", !feature.alternative.isEmpty {
                            Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
                        }
                    }
                }
            }
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(problems) { item in
                Card(spacing: 8) {
                    Text(item.title).font(Typeface.option).foregroundStyle(Palette.icon)
                    Text("\(item.topic) · \(item.minutes) min").font(Typeface.caption).foregroundStyle(Palette.muted)
                    if item.languages.isEmpty {
                        Chip(label: "Start practice") { Task { await start(item.id, language: "") } }
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(item.languages, id: \.self) { language in
                                Chip(label: "Start \(language == "cpp" ? "C++" : language.uppercased())") {
                                    Task { await start(item.id, language: language) }
                                }
                            }
                        }
                    }
                }
            }
            if problems.isEmpty {
                Text("Technical exercises appear here when your account has them.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem { Text(problem.prompt).font(Typeface.body).foregroundStyle(Palette.text) }
            StackField(label: "Explain your approach", text: Binding(get: { answer }, set: { answer = $0; dirty = true }), multiline: true)
            if hasLanguage {
                StackField(label: "Your code", text: Binding(get: { code }, set: { code = $0; dirty = true }),
                           multiline: true, autocapitalization: .never)
            }
            StackField(label: "Practice notes", text: Binding(get: { notes }, set: { notes = $0; dirty = true }), multiline: true)
            if dirty { Text("Unsaved changes").font(Typeface.caption).foregroundStyle(Palette.muted) }
            StackButton(label: "Save practice", disabled: busy) { Task { await save(kind: "") } }
            if hasLanguage {
                StackButton(label: "Save and run tests", kind: .secondary, disabled: busy || codeFeature?.state == "unavailable") {
                    Task { await save(kind: "code") }
                }
            }
            StackButton(label: "Save and get coaching", disabled: busy || coachingFeature?.state == "unavailable") {
                Task { await save(kind: "prep") }
            }
            StackButton(label: "Refresh results", kind: .secondary, disabled: busy) { Task { await resume(current["id"].string) } }
            ForEach(Array(store.account.runViews.filter {
                $0["target_id"].string == current["id"].string && ["prep", "code", "live"].contains($0["kind"].string)
            }.prefix(3).enumerated()), id: \.offset) { _, run in
                TaskRow(run: run) { taskID = TaskTarget(id: run["id"].string) }
            }
            ForEach(Array(current["results"].array.enumerated()), id: \.offset) { _, result in
                Text("Tests: \(result["data"]["passed"].int) / \(result["data"]["total"].int) \(result["data"]["error"].string)")
                    .font(Typeface.body).foregroundStyle(Palette.text)
            }
            ForEach(Array(current["feedback"].array.enumerated()), id: \.offset) { _, item in
                Card(tint: Palette.surfaceRaised, spacing: 8) {
                    Text("Coaching").font(Typeface.option).foregroundStyle(Palette.icon)
                    let text = item["data"]["text"].string
                    Text(text.isEmpty ? item["data"]["summary"].string : text).font(Typeface.body).foregroundStyle(Palette.text)
                    ForEach(Array(item["data"]["rubric"].array.enumerated()), id: \.offset) { _, row in
                        Text("\(row["criterion"].string) · \(row["score"].int)/4 — \(row["feedback"].string)")
                            .font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                    if !item["run_id"].string.isEmpty, !item["output_version"].string.isEmpty {
                        AgentFeedbackForm(runID: item["run_id"].string, outputVersion: item["output_version"].string)
                    }
                }
            }
            StackButton(label: dirty ? "Save to switch exercises" : "Choose another exercise", kind: .secondary, disabled: dirty || busy) {
                current = [:]
            }
        }
    }

    // MARK: Actions

    private func seed(from row: JSON) {
        current = row
        let data = row["data"]
        answer = data["answer"].string
        code = data["code"].string
        notes = data["notes"].string
        dirty = false
    }

    private func reload() async {
        do {
            let catalog = try await store.prep.catalog()
            problems = catalog.filter { $0.track.lowercased() != "behavioral" }
            let rows = try await store.call("prep_sessions")["sessions"].array
            sessions = rows.filter { $0["data"]["canvas"][PrepCodec.marker].isNull }
            let settings = try await store.call("agent_settings")
            web = settings["web_url"].string
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func start(_ id: String, language: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            seed(from: try await store.call("prep_create", ["problem_id": .string(id), "language": .string(language)]))
            await reload()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func resume(_ id: String) async {
        if dirty {
            error = "You have unsaved changes. Save practice before refreshing or switching sessions."
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            seed(from: try await store.call("prep_get", ["id": .string(id)]))
            error = ""
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func save(kind: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        message = ""
        defer { busy = false }
        do {
            var value = data
            value["answer"] = .string(answer)
            value["code"] = .string(code)
            value["notes"] = .string(notes)
            let saved = try await store.call("prep_save", ["id": current["id"], "revision": current["revision"], "data": value])
            seed(from: saved)
            if kind.isEmpty {
                message = "Practice saved. Continue on either device."
            } else {
                let result = try await store.call("agent_start", ["kind": .string(kind), "target_id": current["id"]])
                message = "\(result["title"].string) started. Status appears below; results are added to this session."
            }
            await reload()
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    /// Picks up test results and coaching while keeping unsaved edits.
    private func pollResults() async {
        guard !busy, !current["id"].string.isEmpty else { return }
        do {
            let result = try await store.call("prep_get", ["id": current["id"]])
            current["feedback"] = result["feedback"]
            current["results"] = result["results"]
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }
}

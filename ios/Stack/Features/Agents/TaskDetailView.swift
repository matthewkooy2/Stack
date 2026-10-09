import SwiftUI

/// One agent task: context, progress, what it needs from you, review, recovery and results.
@MainActor
struct TaskDetailView: View {
    let id: String
    var webURL = ""
    let onBack: () -> Void
    let onNavigate: (String) -> Void

    @Environment(AppStore.self) private var store
    @Environment(\.openURL) private var openURL

    @State private var run: JSON = [:]
    @State private var draft = AgentDrafts.Draft()
    @State private var error = ""
    @State private var notice = ""
    @State private var busy = false
    @State private var preview: PDFPreview?
    @State private var confirmCancel = false

    private var review: JSON { run["review"] }
    private var status: String { run["status"].string }
    private var kind: String { run["kind"].string }
    private var requests: [JSON] { run["requests"].array }
    private var feature: AgentFeature? { store.account.feature(forKind: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StackButton(label: "Back to tasks", icon: "return", kind: .secondary, action: onBack)
            if run.object.isEmpty, error.isEmpty { Text("Loading task…").font(Typeface.body).foregroundStyle(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            MessageLine(text: notice, isError: false).fadeSwitch(!notice.isEmpty)
            if !run.object.isEmpty {
                header
                happening
                if status == "review" { reviewBox }
                if run["needs_resume_review"].bool {
                    TailorBlocker(run: run, onNavigate: onNavigate) { next in
                        run = next
                        notice = next["status"].string == "queued"
                            ? "Tailoring started. Stack will show you every change to keep or reject." : ""
                    }
                }
                if kind != "linkedin", status == "needs_input", !run["needs_resume_review"].bool { answersBox }
                if kind == "linkedin", status == "needs_input" { linkedinBox }
                if run["browser"]["available"].bool {
                    BrowserEntryView(id: id, task: run) { Task { await load() } }
                }
                if status == "uncertain" { uncertainBox }
                if ["blocked", "failed"].contains(status) { stoppedBox }
                if run["artifacts"]["tailor"]["final"].bool {
                    Card(tint: Palette.surfaceRaised, spacing: 8) {
                        Text("Saved to Resume → Tailored resumes, labelled with this job.")
                            .font(Typeface.caption).foregroundStyle(Palette.text)
                        Chip(label: "Open Tailored resumes") { onNavigate("resume") }
                    }
                }
                results
                ForEach(Array(run["feedback"].array.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your feedback · \(item["rating"].string.capitalized)").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(item["note"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    }
                }
                footer
            }
        }
        .task(id: id) { await start() }
        .task(id: id + ":poll") {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                if Task.isCancelled { break }
                if run.object.isEmpty || !AgentLabels.terminal.contains(status) { await load() }
            }
        }
        .sheet(item: $preview) { PDFSheet(preview: $0) }
        .confirmationDialog("Cancel this task?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Cancel task", role: .destructive) { Task { await perform("agent_cancel", ["id": .string(id)], done: "Cancelled.") } }
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(run["title"].string).font(Typeface.title).foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusPill(label: AgentLabels.runLabel(run), tone: AgentLabels.tone(for: status))
            }
            if !run["context_label"].string.isEmpty {
                Text(run["context_label"].string).font(Typeface.body).foregroundStyle(Palette.text)
            }
            let updated = run["updated_at"].double > 0 ? run["updated_at"].double : run["created_at"].double
            Text("Started \(dateTime(run["created_at"].double)) · Updated \(dateTime(updated))")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
        }
    }

    private var happening: some View {
        Card(tint: Palette.oat, spacing: 8) {
            Text("What’s happening").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            if run["step_total"].int > 1 {
                Text("Step \(run["step_number"].int) of \(run["step_total"].int) · \(run["step_label"].string)")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            Text(run["explanation"].string).font(Typeface.body).foregroundStyle(Palette.text)
            if !run["message"].string.isEmpty, run["message"].string != run["explanation"].string {
                Text(run["message"].string).font(Typeface.caption).foregroundStyle(Palette.text)
            }
            if run["step_total"].int > 1 {
                let current = run["step_number"].int
                ForEach(Array(run["steps"].strings.enumerated()), id: \.offset) { index, label in
                    let done = index < current - 1 || status == "completed"
                    Text("\(done ? "✓" : (index == current - 1 ? "●" : "○")) \(label)")
                        .font(Typeface.caption.weight(index == current - 1 ? .bold : .regular))
                        .foregroundStyle(index == current - 1 ? Palette.ink : Palette.muted)
                }
            }
        }
    }

    private var reviewBox: some View {
        let step = review["step"].string
        let changes = review["changes"].array
        let kept = changes.count - changes.filter { draft.rejected.contains($0["id"].string) }.count
        return Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: "Nothing is shared until you approve")
            Text(review["title"].string).font(Typeface.title).foregroundStyle(Palette.ink)
            if step == "approve_resume" {
                if !review["summary"].string.isEmpty { Text(review["summary"].string).font(Typeface.body).foregroundStyle(Palette.text) }
                if !review["score"]["after"].isNull {
                    ScoreCardView(after: review["score"]["after"], before: review["score"]["before"],
                                  title: "Score for this job · with every change")
                }
                if !run["artifacts"]["tailor"]["pdf"]["content"].string.isEmpty {
                    StackButton(label: "Preview proposed resume", icon: "resume", kind: .secondary) {
                        showPDF(run["artifacts"]["tailor"]["pdf"])
                    }
                }
                Text("The preview includes every change. Rejected changes go back to your original wording when Stack rebuilds · \(review["pages"].int) page")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                SectionLabel(text: "Changes · \(kept) of \(changes.count) kept")
                ForEach(Array(changes.enumerated()), id: \.offset) { _, change in
                    ChangeRow(change: change, rejected: draft.rejected.contains(change["id"].string)) { toggle(change["id"].string) }
                }
                if changes.isEmpty { Text("No wording or order changes were suggested.").font(Typeface.body).foregroundStyle(Palette.text) }
                if !review["dropped"].array.isEmpty { DroppedList(dropped: review["dropped"].array) }
            }
            if step == "send" {
                Text("To: \(review["to"].string)").font(Typeface.body).foregroundStyle(Palette.text)
                StackField(label: "Email subject", text: Binding(get: { draft.subject }, set: { draft.subject = $0; remember() }))
                StackField(label: "Email message", text: Binding(get: { draft.body }, set: { draft.body = $0; remember() }), multiline: true)
                Text("Edits are yours. Stack sends exactly this text.").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if step == "calendar" {
                let event = review["event"]
                Text(event["summary"].string).font(Typeface.body).foregroundStyle(Palette.text)
                Text("\(isoTime(event["start"].string)) – \(isoTime(event["end"].string))").font(Typeface.caption).foregroundStyle(Palette.muted)
                if !event["location"].string.isEmpty { Text(event["location"].string).font(Typeface.caption).foregroundStyle(Palette.muted) }
            }
            ForEach(review["notes"].strings.filter { $0 != review["blocked"].string }, id: \.self) {
                Text("• \($0)").font(Typeface.caption).foregroundStyle(Palette.text)
            }
            Text(review["consequence"].string).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            if !review["blocked"].string.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(review["blocked"].string).font(Typeface.caption).foregroundStyle(Color(hex: 0x8A4B08))
                    Chip(label: step == "send" ? "Connect Gmail sending" : "Connect Google Calendar") {
                        onNavigate(step == "send" ? "connect:send" : "connect:calendar")
                    }
                }
                .padding(12).background(Color(hex: 0xFFE7C2), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            StackButton(label: approveLabel(step), icon: "check", disabled: busy || !review["blocked"].string.isEmpty) {
                Task { await approve() }
            }
            StackButton(label: "Don’t do this · cancel task", kind: .secondary, disabled: busy) {
                Task { await perform("agent_cancel", ["id": .string(id)], done: "Cancelled. Nothing was shared.") }
            }
            if let feature, !feature.alternative.isEmpty {
                Text("Prefer to do it yourself? \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var answersBox: some View {
        let asking = requests.filter { $0["key"].string != "browser" }
        return Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: requests.isEmpty ? "What stopped this task" : "Stack needs your answers")
            if requests.isEmpty, !run["message"].string.isEmpty {
                Text(run["message"].string).font(Typeface.body).foregroundStyle(Palette.text)
            }
            ForEach(Array(asking.enumerated()), id: \.offset) { _, question in
                let key = question["key"].string
                StackField(label: question["label"].string,
                           text: Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0; remember() }))
            }
            ForEach(requests.filter { $0["key"].string == "browser" }, id: \.self) {
                Text("In the browser: \($0["label"].string)").font(Typeface.body).foregroundStyle(Palette.text)
            }
            if !asking.isEmpty {
                Text("Answers you save are confirmed facts and can be reused on later applications. Review them in Agents → Facts.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            StackButton(label: requests.isEmpty ? "Try again" : "Save answers and resume", icon: requests.isEmpty ? "refresh" : "",
                        disabled: busy) { Task { await respond() } }
            if let url = URL(string: webURL), !webURL.isEmpty {
                StackButton(label: "Open web workspace for the browser", kind: .secondary) { openURL(url) }
            } else {
                Text("Browser handoff opens in the web workspace once it is hosted. Until then, complete the form on the employer site.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    private var linkedinBox: some View {
        let analysis = run["step_number"].int == 2
        let asking = requests.filter { $0["key"].string != "browser" }
        return Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: analysis ? "Analysis paused" : "Stack needs your answers")
            if analysis, requests.isEmpty {
                Text(run["message"].string).font(Typeface.body).foregroundStyle(Palette.text)
                Text("There is no question to answer. Your captured profile is saved; retry analysis without signing in again.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                StackButton(label: "Retry analysis", disabled: busy) { Task { await respond() } }
            } else {
                ForEach(Array(asking.enumerated()), id: \.offset) { _, question in
                    let key = question["key"].string
                    StackField(label: question["label"].string,
                               text: Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0; remember() }))
                }
                ForEach(requests.filter { $0["key"].string == "browser" }, id: \.self) {
                    Text("In the browser: \($0["label"].string)").font(Typeface.body).foregroundStyle(Palette.text)
                }
                StackButton(label: "Continue", disabled: busy) { Task { await respond() } }
            }
        }
    }

    private var uncertainBox: some View {
        Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: "Confirm what happened")
            Text("Stack cannot tell whether the last outbound action completed. Check your email, calendar, or the employer site, then tell Stack. It will not retry on its own.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            StackField(label: "What you checked (at least 10 characters)",
                       text: Binding(get: { draft.evidence }, set: { draft.evidence = $0; remember() }), multiline: true)
            let ready = draft.evidence.trimmingCharacters(in: .whitespaces).count >= 10
            StackButton(label: "It completed", disabled: busy || !ready) { Task { await reconcile("confirmed") } }
            StackButton(label: "Nothing was sent", kind: .secondary, disabled: busy || !ready) { Task { await reconcile("not_sent") } }
        }
    }

    private var stoppedBox: some View {
        Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: status == "blocked" ? "How to continue" : "What went wrong")
            Text(run["message"].string).font(Typeface.body).foregroundStyle(Palette.text)
            ForEach(feature?.missingRequired ?? []) { check in
                VStack(alignment: .leading, spacing: 4) {
                    Text("✕ \(check.label) — \(check.fix)").font(Typeface.caption).foregroundStyle(Palette.text)
                    if !check.action.isEmpty { Chip(label: "Fix: \(check.label)") { onNavigate(check.action) } }
                }
            }
            StackButton(label: kind == "linkedin" && run["step_number"].int == 2 ? "Retry analysis" : "Retry now", icon: "refresh", disabled: busy) {
                Task { await perform("agent_retry", ["id": .string(id)], done: "Retrying. Progress updates here automatically.") }
            }
            if let feature, !feature.alternative.isEmpty {
                Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var results: some View {
        let artifacts = run["artifacts"].object
        if !artifacts.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Results").font(Typeface.title).foregroundStyle(Palette.ink)
                ForEach(artifacts.keys.sorted(), id: \.self) { name in
                    ArtifactView(name: name, value: artifacts[name] ?? [:], taskID: id) { showPDF($0) }
                }
            }
            if !run["output_version"].string.isEmpty {
                AgentFeedbackForm(runID: run["id"].string, outputVersion: run["output_version"].string)
                    .id(run["id"].string + run["output_version"].string)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where results appear: \(run["results_where"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
            if run["cost_cents"].double > 0 {
                Text("Reserved API spend: $\(String(format: "%.2f", run["cost_cents"].double / 100))")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if run["subscription_calls"].int > 0 {
                Text("Subscription requests: \(run["subscription_calls"].int) · provider limits apply")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if !AgentLabels.terminal.contains(status), status != "review" {
                StackButton(label: "Cancel task", kind: .secondary, disabled: busy) { confirmCancel = true }
            }
            if status == "failed", !run["dismissed"].bool {
                StackButton(label: "Dismiss from Needs you", kind: .secondary, disabled: busy) {
                    Task { await perform("agent_dismiss", ["id": .string(id)], done: "Dismissed.") }
                }
            }
        }
    }

    // MARK: Actions

    private func remember() { AgentDrafts.save(draft, for: id) }

    private func toggle(_ change: String) {
        draft.rejected = draft.rejected.toggled(change)
        remember()
    }

    private func approveLabel(_ step: String) -> String {
        ["approve_resume": "Apply the changes I kept", "send": "Approve and send", "calendar": "Approve calendar change"][step] ?? "Approve"
    }

    private func showPDF(_ document: JSON) {
        do { preview = try PDFPreview.make(name: document["name"].string.isEmpty ? "Document" : document["name"].string, base64: document["content"].string) }
        catch { self.error = error.localizedDescription }
    }

    private func start() async {
        draft = AgentDrafts.draft(id)
        await load()
    }

    private func load() async {
        guard !busy else { return }
        do {
            let latest = try await store.call("agent_run", ["id": .string(id)])
            let step = latest["review"]["step"].string
            let hash = latest["review"]["hash"].string
            if step == "send", hash != draft.editsFor {
                draft.subject = latest["review"]["subject"].string
                draft.body = latest["review"]["body"].string
                draft.editsFor = hash
                remember()
            }
            if step == "approve_resume", hash != draft.rejectFor {
                draft.rejected = latest["review"]["rejected"].strings
                draft.rejectFor = hash
                remember()
            }
            run = latest
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func perform(_ endpoint: String, _ args: JSON, done: String) async {
        guard !busy else { return }
        busy = true
        error = ""
        notice = ""
        defer { busy = false }
        do {
            run = try await store.call(endpoint, args)
            notice = done
        } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
    }

    private func respond() async {
        let answers: [JSON] = draft.values.filter { !$0.value.isBlank }.map { entry in
            ["key": .string(entry.key), "value": .string(entry.value), "verified": true,
             "source": "User confirmed application answer"]
        }
        let message = kind == "linkedin"
            ? "Reading your LinkedIn profile. Progress appears below."
            : (answers.isEmpty ? "Trying again. Progress updates here automatically."
                               : "Answers saved and confirmed. The task resumes automatically.")
        await perform("agent_respond", ["id": .string(id), "values": .array(answers), "reuse": true], done: message)
        if error.isEmpty {
            draft.values = [:]
            remember()
        }
    }

    private func approve() async {
        var edits: JSON = [:]
        let step = review["step"].string
        if step == "send", draft.subject != review["subject"].string || draft.body != review["body"].string {
            edits = ["subject": .string(draft.subject), "body": .string(draft.body)]
        }
        if step == "approve_resume" {
            edits = ["rejected": .array(draft.rejected.map { .string($0) })]
        }
        await perform("agent_approve", ["id": .string(id), "step": .string(step), "review_hash": review["hash"], "edits": edits],
                      done: "Approved. Stack continues with exactly what you reviewed.")
        if error.isEmpty {
            draft.editsFor = ""
            remember()
        }
    }

    private func reconcile(_ outcome: String) async {
        await perform("agent_reconcile", ["id": .string(id), "outcome": .string(outcome), "evidence": .string(draft.evidence)],
                      done: "Thanks. The task continues from what you confirmed.")
        if error.isEmpty {
            draft.evidence = ""
            remember()
        }
    }
}

/// One proposed resume change. `onToggle` is nil outside the review, where the choice is only shown.
@MainActor
struct ChangeRow: View {
    let change: JSON
    let rejected: Bool
    var onToggle: (() -> Void)?

    private static let labels = ["rewrite": "Reworded", "omit": "Removed", "reorder": "Reordered"]

    var body: some View {
        let kind = change["kind"].string
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(Self.labels[kind] ?? kind) · \(change["where"].string)")
                    .font(Typeface.caption.weight(.bold)).foregroundStyle(Palette.text)
                Spacer()
                if let onToggle { Chip(label: rejected ? "Keep this" : "Reject", selected: rejected, action: onToggle) }
            }
            if kind != "reorder", !change["before"].string.isEmpty {
                Text(change["before"].string.replacingOccurrences(of: "**", with: ""))
                    .font(Typeface.caption).foregroundStyle(Palette.muted).strikethrough()
            }
            if kind == "reorder", !change["before"].string.isEmpty {
                Text("Was: \(change["before"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if !change["after"].string.isEmpty {
                Text((kind == "reorder" && !change["before"].string.isEmpty ? "Now: " : "") + change["after"].string.replacingOccurrences(of: "**", with: ""))
                    .font(Typeface.body).foregroundStyle(Palette.text)
            }
            if !change["reason"].string.isEmpty {
                Text("Why: \(change["reason"].string)").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if rejected, onToggle == nil {
                Text("Rejected · your original stays").font(Typeface.caption).foregroundStyle(Color(hex: 0x8A4B08))
            }
        }
        .opacity(rejected ? 0.55 : 1)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Rectangle().fill(Palette.rule).frame(height: 1) }
    }
}

@MainActor
struct DroppedList: View {
    let dropped: [JSON]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "Left out to fit one page · least relevant first")
            ForEach(Array(dropped.enumerated()), id: \.offset) { _, item in
                Text("• \(item["where"].string): \(item["text"].string.replacingOccurrences(of: "**", with: ""))")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            }
        }
    }
}

/// A named result of a task, in a readable form.
@MainActor
struct ArtifactView: View {
    let name: String
    let value: JSON
    let taskID: String
    let onPreview: (JSON) -> Void

    private static let eyebrows = [
        "inspect": "Application form", "fit": "Job fit", "tailor": "Tailored resume", "fill": "Form filled",
        "submit": "Submission receipt", "research": "Contact source", "draft": "Email draft", "send": "Email sent",
        "profile": "Profile suggestions", "coach": "Coaching", "execute": "Test results", "sync": "Gmail check",
        "calendar": "Calendar", "interview": "Transcript",
    ]

    var body: some View {
        switch name {
        case "linkedin_review": linkedInReview
        case "linkedin_scan":
            Card(tint: Palette.oat, spacing: 8) {
                Text("Profile captured").font(Typeface.option).foregroundStyle(Palette.icon)
                Text(value["summary"].string).font(Typeface.body).foregroundStyle(Palette.text)
                Text(value["limitations"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        case "tailor": TailoredResultView(value: value, onPreview: onPreview)
        default: generic
        }
    }

    private var generic: some View {
        Card(tint: Palette.surfaceRaised, spacing: 8) {
            SectionLabel(text: Self.eyebrows[name] ?? name)
            if !value["summary"].string.isEmpty { Text(value["summary"].string).font(Typeface.body).foregroundStyle(Palette.text) }
            if name == "inspect" {
                Text("\(value["fields"].array.count) form fields found on \(value["adapter"].string.isEmpty ? "the employer site" : value["adapter"].string).")
                    .font(Typeface.body).foregroundStyle(Palette.text)
            }
            lines("✓ ", value["strengths"].strings)
            lines("~ ", value["gaps"].strings)
            lines("? ", value["unknowns"].strings)
            lines("• ", value["suggested_edits"].strings)
            lines("• ", value["edits"].strings)
            if !value["suggested_headline"].string.isEmpty {
                Text(value["suggested_headline"].string).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            }
            if !value["suggested_about"].string.isEmpty {
                Text(value["suggested_about"].string).font(Typeface.body).foregroundStyle(Palette.text)
            }
            if name == "draft" {
                Text(value["subject"].string).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                Text(value["body"].string).font(Typeface.body).foregroundStyle(Palette.text)
            }
            ForEach(Array(value["rubric"].array.enumerated()), id: \.offset) { _, row in
                Text("\(row["criterion"].string) · \(row["score"].int)/4 — \(row["feedback"].string)").font(Typeface.body).foregroundStyle(Palette.text)
            }
            lines("Follow-up question: ", value["followup_questions"].strings)
            lines("Practice next: ", value["next_exercises"].strings)
            if name == "execute" {
                Text("Tests passed: \(value["passed"].int) of \(value["total"].int)" + (value["error"].string.isEmpty ? "" : " · \(value["error"].string)"))
                    .font(Typeface.body).foregroundStyle(Palette.text)
            }
            if name == "sync" { Text("\(value["events"].array.count) relevant messages found.").font(Typeface.body).foregroundStyle(Palette.text) }
            if !value["receipt"].isNull { Text("Receipt: \(String(value["receipt"].string.prefix(300)))").font(Typeface.caption).foregroundStyle(Palette.muted) }
            if !value["transcript"].isNull { Text(String(value["transcript"].string.prefix(600))).font(Typeface.caption).foregroundStyle(Palette.muted) }
            ForEach(Array(value["evidence"].array.enumerated()), id: \.offset) { _, item in
                Text("“\(item["quote"].string)”").font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if !value["pdf"]["content"].string.isEmpty {
                StackButton(label: "Preview tailored resume", icon: "resume", kind: .secondary) { onPreview(value["pdf"]) }
            }
            if !value["cover_letter"]["content"].string.isEmpty {
                StackButton(label: "Preview cover letter", icon: "resume", kind: .secondary) { onPreview(value["cover_letter"]) }
            }
        }
    }

    @ViewBuilder
    private func lines(_ prefix: String, _ items: [String]) -> some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, text in
            Text(prefix + text).font(Typeface.body).foregroundStyle(Palette.text)
        }
    }

    private var linkedInReview: some View {
        Card(tint: Palette.surfaceRaised, spacing: 12) {
            Text("Your LinkedIn review").font(Typeface.title).foregroundStyle(Palette.ink)
            Text(value["summary"].string).font(Typeface.body).foregroundStyle(Palette.text)
            let captured = value["captured_at"].double
            Text("\(value["profile_url"].string) · Captured \(dateTime(captured))").font(Typeface.caption).foregroundStyle(Palette.muted)
            lines("✓ ", value["strengths"].strings)
            ForEach(Array(value["findings"].array.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item["priority"].string.capitalized) priority · \(item["section"].string.capitalized)")
                        .font(Typeface.caption.weight(.bold)).foregroundStyle(Palette.text)
                    Text(item["weakness"].string).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                    Text("“\(item["quote"].string)”").font(Typeface.caption).foregroundStyle(Palette.muted)
                    Text(item["why_it_matters"].string).font(Typeface.body).foregroundStyle(Palette.text)
                    Text(item["recommendation"].string).font(Typeface.body).foregroundStyle(Palette.text)
                }
                .padding(.vertical, 6)
            }
            LinkedInRewriteEditor(taskID: taskID, rewrites: value["rewrites"].array).id(value["rewrites"])
            lines("To strengthen this: ", value["questions"].strings)
            Text(value["limitations"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
            Text("Sections not read: \(value["unread_sections"].strings.joined(separator: ", "))").font(Typeface.caption).foregroundStyle(Palette.muted)
            Text("Suggested edits are yours to review and apply on LinkedIn.").font(Typeface.caption).foregroundStyle(Palette.muted)
        }
    }
}

@MainActor
struct TailoredResultView: View {
    let value: JSON
    let onPreview: (JSON) -> Void
    @State private var comparison = "Changes"

    var body: some View {
        let pdf = value["pdf"]
        let legacy = value["changes"].isNull
        let final = value["final"].bool || legacy
        let rejected = value["rejected"].strings
        VStack(alignment: .leading, spacing: 14) {
            Text(final ? "Your tailored resume" : "Proposed tailored resume").font(Typeface.title).foregroundStyle(Palette.ink)
            if !final {
                Text("Waiting for your review: keep or reject each change, then Stack rebuilds the PDF.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if !pdf["content"].string.isEmpty {
                StackButton(label: final ? "Preview tailored resume" : "Preview proposed resume", icon: "resume") { onPreview(pdf) }
            } else {
                MessageLine(text: "No PDF was generated.")
            }
            if legacy {
                Text("Your uploaded resume is unchanged.").font(Typeface.caption).foregroundStyle(Palette.muted)
            } else {
                Text("\(pdf["pages"].int) \(pdf["pages"].int == 1 ? "page" : "pages") · \(value["format"].string == "latex" ? "your LaTeX format" : "built-in LaTeX template") · your original is unchanged")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            if !value["summary"].string.isEmpty { Text(value["summary"].string).font(Typeface.body).foregroundStyle(Palette.text) }
            if !value["score"]["after"].isNull {
                ScoreCardView(after: value["score"]["after"], before: value["score"]["before"], title: "Score for this job")
            }
            ChoiceChips(options: ["Changes", "Original text", "Tailored text"] + (value["tex"].string.isEmpty ? [] : ["LaTeX"]),
                        isSelected: { comparison == $0 }, onTap: { comparison = $0 })
            switch comparison {
            case "Changes":
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(value["changes"].array.enumerated()), id: \.offset) { _, change in
                        ChangeRow(change: change, rejected: rejected.contains(change["id"].string))
                    }
                    if value["changes"].array.isEmpty, !legacy {
                        Text("No wording or order changes were needed.").font(Typeface.body).foregroundStyle(Palette.text)
                    }
                    if !value["dropped"].array.isEmpty { DroppedList(dropped: value["dropped"].array) }
                    ForEach(value["notes"].strings, id: \.self) { Text("• \($0)").font(Typeface.caption).foregroundStyle(Palette.text) }
                    if legacy, !pdf["diff"].string.isEmpty {
                        Text("Text changes").font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
                        Text(pdf["diff"].string).font(Typeface.caption).foregroundStyle(Palette.text).textSelection(.enabled)
                    }
                }
            case "Original text":
                let original = pdf["original_text"].string
                Text(original.isEmpty ? "Original text is not included in this older result." : original)
                    .font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
            case "Tailored text":
                Text(pdf["text"].string).font(Typeface.body).foregroundStyle(Palette.text).textSelection(.enabled)
            default:
                Text("Select and copy this into Overleaf to keep editing it there.").font(Typeface.caption).foregroundStyle(Palette.muted)
                CodeBlock(text: value["tex"].string)
            }
            if !value["cover_letter"]["content"].string.isEmpty {
                StackButton(label: "Preview cover letter", icon: "resume", kind: .secondary) { onPreview(value["cover_letter"]) }
            }
        }
    }
}

/// A task paused before tailoring because its resume has no LaTeX. The fix happens here, then it continues.
@MainActor
struct TailorBlocker: View {
    let run: JSON
    let onNavigate: (String) -> Void
    let onContinued: (JSON) -> Void

    @Environment(AppStore.self) private var store
    @State private var working = ""
    @State private var error = ""
    @State private var busy = false

    var body: some View {
        let resumes = store.account.resumes
        let current = resumes.first { $0.id == run["resume_id"].string }
        // Started before any resume existed, or its resume was deleted: continuing attaches the default resume.
        let stale = current == nil && !resumes.isEmpty
        let fixed = stale || (current.map { store.account.hasLatex($0.id) } ?? false)
        Card(tint: Palette.surfaceRaised, spacing: 12) {
            SectionLabel(text: "One step before tailoring")
            if resumes.isEmpty {
                Text("Upload a resume first").font(Typeface.title).foregroundStyle(Palette.ink)
                Text("Stack tailors a resume you have uploaded, and you have none yet. Nothing has been generated.")
                    .font(Typeface.body).foregroundStyle(Palette.text)
                StackButton(label: "Go to the Resume tab", icon: "resume", disabled: busy) { onNavigate("resume") }
            } else if fixed {
                Text(stale ? "Your resume is uploaded" : "\(current?.name ?? "Your resume") has its LaTeX")
                    .font(Typeface.title).foregroundStyle(Palette.ink)
                Text(stale ? "This task started before you uploaded it. Continue, and Stack uses your default resume."
                           : "Continue to generate your tailored resume.")
                    .font(Typeface.body).foregroundStyle(Palette.text)
                StackButton(label: "Continue tailoring", icon: "check", disabled: busy) { Task { await continueWith("") } }
            } else if let current {
                Text("Nothing has been generated yet.").font(Typeface.body).foregroundStyle(Palette.text)
                LatexSetupView(resume: current, others: resumes.filter { store.account.hasLatex($0.id) && $0.id != current.id }) { id in
                    await continueWith(id)
                }
            }
            if !working.isEmpty { Text(working).font(Typeface.caption).foregroundStyle(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
    }

    private func continueWith(_ resumeID: String) async {
        busy = true
        error = ""
        working = "Starting tailoring…"
        defer { busy = false; working = "" }
        do {
            let next = try await store.call("agent_continue_tailoring", ["id": run["id"], "resume_id": .string(resumeID)])
            onContinued(next)
        } catch {
            if error is CancellationError { return }
            self.error = error.localizedDescription
            // Stack may have attached the default resume; show what that resume still needs.
            if let latest = try? await store.call("agent_run", ["id": run["id"]]) { onContinued(latest) }
        }
    }
}

/// ISO-8601 timestamp as a short local date and time.
func isoTime(_ value: String) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: value)
    if date == nil {
        formatter.formatOptions = [.withInternetDateTime]
        date = formatter.date(from: value)
    }
    guard let date else { return value.isEmpty ? "Time not stated" : value }
    return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
}

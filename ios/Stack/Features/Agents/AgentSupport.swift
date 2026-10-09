import SwiftUI

/// Labels and tones for agent task state, shared by the hub, task detail and application screens.
enum AgentLabels {
    static let status: [String: String] = [
        "queued": "Queued", "running": "Working", "waiting": "Ready", "needs_input": "Needs your answers",
        "blocked": "Paused · setup", "review": "Needs your review", "uncertain": "Confirm what happened",
        "failed": "Stopped", "completed": "Done", "cancelled": "Cancelled",
    ]
    static let featureState: [String: String] = ["ready": "Ready", "setup": "Needs setup", "unavailable": "Unavailable"]
    static let terminal: Set<String> = ["completed", "cancelled", "failed"]
    static let attention: Set<String> = ["needs_input", "blocked", "review", "uncertain", "failed"]
    static let active: Set<String> = ["queued", "running", "waiting"]

    static func statusLabel(_ status: String) -> String { Self.status[status] ?? status }

    /// A task paused for its resume's LaTeX is not waiting for answers; say what it needs.
    static func runLabel(_ run: JSON) -> String {
        if run["needs_resume_review"].bool { return "Needs your LaTeX" }
        if run["status"].string == "needs_input", run["has_requests"].isNull == false, !run["has_requests"].bool {
            return "Stopped · try again"
        }
        return statusLabel(run["status"].string)
    }

    static func tone(for status: String) -> StatusPill.Tone {
        if attention.contains(status) { return .attention }
        if active.contains(status) { return .active }
        if status == "completed" { return .done }
        return .quiet
    }

    static func featureTone(_ state: String) -> StatusPill.Tone {
        switch state {
        case "ready": return .done
        case "setup": return .attention
        default: return .quiet
        }
    }
}

/// Unsent answers and email edits survive refreshes and closing a task, for this session.
@MainActor
enum AgentDrafts {
    struct Draft {
        var values: [String: String] = [:]
        var subject = ""
        var body = ""
        var evidence = ""
        var editsFor = ""
        var rejected: [String] = []
        var rejectFor = ""
    }

    private static var drafts: [String: Draft] = [:]

    static func draft(_ id: String) -> Draft { drafts[id] ?? Draft() }
    static func save(_ draft: Draft, for id: String) { drafts[id] = draft }
    static func removeAll() { drafts = [:] }
}

struct TaskRow: View {
    let run: JSON
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top) {
                    Text(run["title"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatusPill(label: AgentLabels.runLabel(run), tone: AgentLabels.tone(for: run["status"].string))
                }
                if !run["context_label"].string.isEmpty {
                    Text(run["context_label"].string).font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                Text(stepLine).font(Typeface.caption).foregroundStyle(Palette.muted)
                if !run["explanation"].string.isEmpty {
                    Text(run["explanation"].string).font(Typeface.body).foregroundStyle(Palette.text)
                }
                if run["attention"].bool, !run["message"].string.isEmpty {
                    Text(run["message"].string).font(Typeface.caption).foregroundStyle(Palette.text)
                }
                HStack {
                    Text("Updated \(dateTime(run["updated_at"].double > 0 ? run["updated_at"].double : run["created_at"].double))")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    Spacer()
                    Text(run["next_action"].string == "review" ? "Review" : (run["attention"].bool ? "Respond" : "Details"))
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radius, style: .continuous))
        }
        .buttonStyle(.tap(scale: 0.985))
        .accessibilityLabel("Open task \(run["title"].string), \(AgentLabels.runLabel(run))")
    }

    private var stepLine: String {
        let total = run["step_total"].int
        let prefix = total > 1 ? "Step \(run["step_number"].int) of \(total) · " : ""
        return prefix + run["step_label"].string
    }
}

/// One agent: what it is, whether it is ready, what it needs and how to fix what is missing.
struct FeatureCardView: View {
    let feature: AgentFeature
    let onAction: (String) -> Void
    var compact = false

    var body: some View {
        Card(spacing: 10) {
            HStack(alignment: .top) {
                Text(feature.title).font(Typeface.option).foregroundStyle(Palette.icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatusPill(label: (AgentLabels.featureState[feature.state] ?? feature.state) + (feature.limited ? " · limited" : ""),
                           tone: AgentLabels.featureTone(feature.state))
            }
            Text(feature.summary).font(Typeface.body).foregroundStyle(Palette.text)
            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Needs: \(feature.input)")
                    Text("Your control: \(feature.review)")
                    Text("Start from: \(feature.whereToStart)")
                }
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
            ForEach(feature.checks.filter { !compact || !$0.ok }) { check in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(check.ok ? "✓" : (check.optional ? "○" : "✕")) \(check.label)\(check.optional && !check.ok ? " (optional)" : "")")
                        .font(Typeface.caption)
                        .foregroundStyle(check.ok ? Palette.success : (check.optional ? Palette.muted : Palette.danger))
                    if !check.ok, !check.fix.isEmpty {
                        Text(check.fix).font(Typeface.caption).foregroundStyle(Palette.muted)
                    }
                    if !check.ok, !check.action.isEmpty {
                        Chip(label: "Fix: \(check.label)") { onAction(check.action) }
                    }
                }
            }
            if feature.state != "ready", !feature.alternative.isEmpty {
                Text("Meanwhile: \(feature.alternative)").font(Typeface.caption).foregroundStyle(Palette.text)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.oat, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
}

extension FeatureCheck: Identifiable { var id: String { key } }

/// The two resume scores (job match and quality), before to after when tailoring.
struct ScoreCardView: View {
    let after: JSON
    var before: JSON = [:]
    var title = "Resume score"
    @State private var open = false

    var body: some View {
        let missing = after["missing"].array
        let required = missing.filter { $0["required"].bool }
        Card(tint: Palette.oat, spacing: 8) {
            SectionLabel(text: title)
            Text(scoreLine("Job match", before: before["match"], after: after["match"])).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            Text(scoreLine("Resume quality", before: before["quality"], after: after["quality"])).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            if !required.isEmpty {
                Text("Missing required: \(required.prefix(4).map { $0["term"].string }.joined(separator: ", "))")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            }
            Button(open ? "Hide score details" : "Score details") { withAnimation(Motion.fadeAnimation) { open.toggle() } }
                .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
            if open { details(missing) }
        }
    }

    @ViewBuilder
    private func details(_ missing: [JSON]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Job match · " + components(after["match_components"].array, before["match_components"].array))
            Text("Quality · " + components(after["quality_components"].array, before["quality_components"].array))
            if missing.isEmpty {
                Text("Every skill the listing names appears on your resume.")
            } else {
                Text("Missing from your resume (add only if true): " + missing.map {
                    $0["term"].string + ($0["supported"].bool ? " · in your facts" : "") + ($0["required"].bool ? " · required" : "")
                }.joined(separator: ", "))
            }
            if !after["listed_only"].strings.isEmpty {
                Text("Only on your skills line: \(after["listed_only"].strings.joined(separator: ", ")). Show them in a bullet where your work used them.")
            }
            let absent = after["keywords"].array.filter { !$0["found"].bool }.map { $0["term"].string }
            if !absent.isEmpty { Text("Listing phrases not on your resume: " + absent.joined(separator: ", ")) }
            let stuffed = after["stuffed"].array
            if !stuffed.isEmpty {
                Text("Repeated too often: " + stuffed.map { "\($0["term"].string) ×\($0["count"].int)" }.joined(separator: ", "))
            }
            let years = after["requirements"]["years"]
            if years["min"].int > 0 {
                Text("The listing asks for \(years["min"].int)+ years; Stack counts about \(after["requirements"]["resume_years"].int) from your dates (internships count half).")
            }
            ForEach(Array(after["issues"].array.prefix(6).enumerated()), id: \.offset) { _, issue in
                Text("• \(issue["where"].string): \(issue["detail"].string) — “\(issue["text"].string)”")
            }
            Text("Stack's own weights, computed without AI. A guide to tailoring, not a prediction of hiring.")
                .foregroundStyle(Palette.muted)
        }
        .font(Typeface.caption)
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func scoreLine(_ label: String, before: JSON, after: JSON) -> String {
        if after.isNull { return "\(label): not enough information" }
        if before.isNull || before == after { return "\(label): \(after.string)" }
        let change = after.int - before.int
        return "\(label): \(before.string) → \(after.string) (\(change > 0 ? "+" : "")\(change))"
    }

    private func components(_ after: [JSON], _ before: [JSON]) -> String {
        let previous = Dictionary(before.map { ($0["key"].string, $0["score"]) }, uniquingKeysWith: { _, last in last })
        return after.map { component in
            let key = component["key"].string
            var line = component["label"].string + " "
            if let old = previous[key], old != component["score"] { line += "\(old.string) → " }
            return line + component["score"].string
        }.joined(separator: " · ")
    }
}

/// Rating and note for an agent's output.
struct AgentFeedbackForm: View {
    let runID: String
    let outputVersion: String
    @Environment(AppStore.self) private var store
    @State private var rating = ""
    @State private var note = ""
    @State private var working = false
    @State private var message = ""
    @State private var error = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent feedback").font(Typeface.section).foregroundStyle(Palette.ink)
            ChoiceChips(options: ["good", "mixed", "bad"], isSelected: { rating == $0 },
                        onTap: { rating = $0; message = "" }, labelFor: { $0.capitalized })
            StackField(label: "What worked or needs improvement?", text: $note, multiline: true)
            StackButton(label: "Save agent feedback", icon: "chat", disabled: working || rating.isEmpty || note.isBlank) {
                working = true
                error = ""
                message = ""
                Task {
                    do {
                        try await store.call("agent_feedback", ["id": .string(runID), "output_version": .string(outputVersion),
                                                               "rating": .string(rating), "note": .string(note)])
                        note = ""
                        rating = ""
                        message = "Feedback saved."
                    } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                    working = false
                }
            }
            MessageLine(text: message, isError: false).fadeSwitch(!message.isEmpty)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
        }
    }
}

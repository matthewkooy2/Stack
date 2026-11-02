import SwiftUI

/// Presentation of the `stack.job_score` v1 contract (docs/JOB_SCORE.md): the job's score from confirmed details only.
struct JobScoreCopy {
    static let contract = "stack.job_score"
    static let version = 1
    let result: JSON

    /// False for a contract or version this build does not know; nothing else is shown then.
    var isSupported: Bool { result["contract"].string == Self.contract && result["version"].int == Self.version }
    var isScored: Bool { isSupported && result["status"].string == "scored" && !result["score"].isNull }

    var headline: String {
        guard isSupported else { return "Update Stack to see this score" }
        return isScored ? "Job score: \(result["score"].int)" : "This listing has too little to compare"
    }

    private var requirements: [JSON] { isSupported ? result["requirements"].array : [] }
    private func terms(_ keep: (JSON) -> Bool) -> [String] { requirements.filter(keep).map { $0["term"].string } }
    private func isSkill(_ row: JSON) -> Bool { row["kind"].string == "skill" }

    var missingRequired: [String] { isSupported ? result["missing_required"].strings : [] }
    var shown: [String] { terms { isSkill($0) && ["applied", "mentioned"].contains($0["status"].string) } }
    var listedOnly: [String] { terms { isSkill($0) && $0["status"].string == "listed" } }
    var missing: [String] { terms { isSkill($0) && $0["status"].string == "missing" } }
    var phrasesMissing: [String] { terms { ["keyword", "soft_skill"].contains($0["kind"].string) && $0["status"].string == "missing" } }

    var components: String {
        guard isScored else { return "" }
        return result["components"].array.map { "\($0["label"].string) \($0["score"].int)" }.joined(separator: " · ")
    }

    var experience: String {
        guard let row = requirements.first(where: { $0["kind"].string == "experience" }) else { return "" }
        return "The listing asks for \(row["term"].string); your confirmed dates count about \(row["counted_years"].string) (internships count half)."
    }
}

/// The job score for one saved job, with its reasons one tap away.
@MainActor
struct JobScoreCardView: View {
    let result: JSON
    @State private var open = false

    var body: some View {
        let copy = JobScoreCopy(result: result)
        Card(tint: Palette.oat, spacing: 8) {
            SectionLabel(text: "Job score · your confirmed details")
            Text(copy.headline).font(Typeface.body.weight(.semibold)).foregroundStyle(Palette.ink)
            if !copy.missingRequired.isEmpty {
                Text("Missing required: \(copy.missingRequired.prefix(4).joined(separator: ", "))")
                    .font(Typeface.caption).foregroundStyle(Palette.text)
            }
            if copy.isScored {
                Button(open ? "Hide score details" : "Score details") { withAnimation(Motion.fadeAnimation) { open.toggle() } }
                    .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                if open { details(copy) }
            }
        }
    }

    @ViewBuilder
    private func details(_ copy: JobScoreCopy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(copy.components)
            if !copy.shown.isEmpty { Text("In your confirmed details: " + copy.shown.joined(separator: ", ")) }
            if !copy.listedOnly.isEmpty { Text("Only on your skills line: " + copy.listedOnly.joined(separator: ", ")) }
            if !copy.missing.isEmpty { Text("Not in your confirmed details: " + copy.missing.joined(separator: ", ")) }
            if !copy.phrasesMissing.isEmpty { Text("Listing phrases not found: " + copy.phrasesMissing.joined(separator: ", ")) }
            if !copy.experience.isEmpty { Text(copy.experience) }
            Text("Uses only details you confirmed, computed without AI. Add a skill only if it is true. Not a prediction of hiring.")
                .foregroundStyle(Palette.muted)
        }
        .font(Typeface.caption)
        .foregroundStyle(Palette.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

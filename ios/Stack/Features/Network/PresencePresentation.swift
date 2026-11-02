import Foundation

/// Presentation of a real saved LinkedIn result. Raw coaching is not a structured rewrite,
/// and an evidence quote or the account's target role is not the current profile section.
struct PresenceLinkedInPresentation {
    let taskID: String
    let status: String
    let message: String
    let rewrites: [JSON]
    let summary: String
    let rewriteIndex: Int?
    let section: String
    let current: String?

    init(run: JSON) {
        taskID = run["id"].string
        status = run["status"].string
        message = run["message"].string
        let artifact = run["artifacts"]["linkedin_review"]
        let sourceRewrites = artifact["rewrites"].array
        rewrites = sourceRewrites
        summary = artifact["summary"].string.isBlank ? artifact["text"].string : artifact["summary"].string
        let usable = sourceRewrites.indices.filter { !sourceRewrites[$0]["text"].string.isBlank && !sourceRewrites[$0]["section"].string.isBlank }
        let selected = usable.first { sourceRewrites[$0]["section"].string.lowercased() == "headline" }
            ?? usable.first { sourceRewrites[$0]["section"].string.lowercased() == "intro" }
            ?? usable.first
        rewriteIndex = selected
        let selectedSection = selected.map { sourceRewrites[$0]["section"].string } ?? ""
        section = selectedSection
        // Only an explicitly captured matching section can populate Current. Whole-page captures,
        // generated findings and confirmed-fact citations are deliberately not guessed into fields.
        let captured = run["artifacts"]["linkedin_scan"]["sections"][selectedSection.lowercased()].string
        current = captured.isBlank ? nil : captured
    }

    var sectionLabel: String { section.isEmpty ? "Profile review" : section.capitalized }
    var hasReview: Bool { !summary.isBlank || rewriteIndex != nil }

    func suggested(saved: SavedRewriteReview?) -> String? {
        guard let rewriteIndex else { return nil }
        if let saved, saved.source == rewrites,
           let edited = saved.review.drafts.first(where: { $0.id == rewriteIndex }) {
            return edited.text
        }
        return rewrites[rewriteIndex]["text"].string
    }

    /// Bootstrap includes attention items before recent items, so array order is not chronological.
    static func latestRun(in runs: [JSON]) -> JSON? {
        runs.filter { $0["kind"].string == "linkedin" && !$0["id"].string.isBlank }
            .max { left, right in
                let leftTime = left["created_at"].double
                let rightTime = right["created_at"].double
                return leftTime == rightTime ? left["updated_at"].double < right["updated_at"].double : leftTime < rightTime
            }
    }
}

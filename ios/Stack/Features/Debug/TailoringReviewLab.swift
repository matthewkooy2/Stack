#if DEBUG
import SwiftUI

/// Offline reference content; decisions never reach the signed-in account.
@MainActor
struct TailoringReviewLab: View {
    let onBack: () -> Void
    @State private var rejected: [String] = []
    @State private var reviewed: [String] = []
    @State private var applied = false

    private let review: JSON = ["changes": [
        ["id": "r5", "kind": "rewrite", "where": "Experience · Analyst · Example Co",
         "title": "Remove introductory filler",
         "before": "Successfully documented SQL queries for the team.",
         "after": "Documented SQL queries for the team.", "reason": "Remove introductory filler."],
        ["id": "order:r4", "kind": "order", "where": "Experience · Analyst · Example Co",
         "title": "Move SQL work to the top",
         "before_items": [
            ["id": "r4", "text": "I built Python dashboards that reduced review time by 25%."],
            ["id": "r5", "text": "Successfully documented SQL queries for the team."],
            ["id": "r6", "text": "Kept test notes for internal training."]],
         "after_items": [
            ["id": "r5", "text": "Successfully documented SQL queries for the team."],
            ["id": "r4", "text": "I built Python dashboards that reduced review time by 25%."],
            ["id": "r6", "text": "Kept test notes for internal training."]],
         "reason": "Lead this bullet group with the most relevant content."]
    ]]

    var body: some View {
        TailoringReviewScreen(review: review, rejected: rejected, busy: false, reviewed: reviewed,
                              context: "Experience · Analyst · Example Co", onBack: onBack, onPreview: {},
                              onSetRejected: { ids, value in
                                  rejected.removeAll { ids.contains($0) }
                                  if value { rejected.append(contentsOf: ids) }
                                  reviewed = Array(Set(reviewed + ids))
                              }, onApply: { applied = true }, onCancel: onBack)
            .alert("Preview only", isPresented: $applied) {
                Button("Done", role: .cancel) {}
            } message: {
                Text("No resume was changed. Open a real tailoring task to apply your choices.")
            }
    }
}
#endif

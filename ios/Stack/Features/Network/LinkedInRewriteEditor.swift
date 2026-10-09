import SwiftUI

struct RewriteDraft: Identifiable, Equatable {
    let id: Int
    let section: String
    var text: String
    var included = true
}

struct RewriteReview: Equatable {
    var drafts: [RewriteDraft]
    private(set) var approved = false
    var canApprove: Bool { drafts.contains { $0.included } && drafts.filter(\.included).allSatisfy { !$0.text.isBlank } }
    var approvedText: String? {
        guard approved, canApprove else { return nil }
        return drafts.filter(\.included).map { $0.section.uppercased() + "\n" + $0.text }.joined(separator: "\n\n")
    }
    mutating func edit(_ index: Int, text: String) { drafts[index].text = text; approved = false }
    mutating func include(_ index: Int, selected: Bool) { drafts[index].included = selected; approved = false }
    mutating func approve() { approved = canApprove }
}

struct SavedRewriteReview {
    let source: [JSON]
    let review: RewriteReview
}

@MainActor
struct LinkedInRewriteEditor: View {
    @Environment(AppStore.self) private var store
    let taskID: String
    let rewrites: [JSON]
    @State private var review: RewriteReview
    @State private var copied = false
    @State private var generation = -1
    init(taskID: String, rewrites: [JSON]) {
        self.taskID = taskID
        self.rewrites = rewrites
        _review = State(initialValue: RewriteReview(drafts: rewrites.enumerated().map {
            RewriteDraft(id: $0.offset, section: $0.element["section"].string, text: $0.element["text"].string)
        }))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(review.drafts.indices, id: \.self) { index in
                StackField(label: "Suggested \(review.drafts[index].section)", text: Binding(
                    get: { review.drafts[index].text },
                    set: { review.edit(index, text: $0); copied = false }), multiline: true)
                ToggleRow(label: "Keep \(review.drafts[index].section) rewrite", isOn: Binding(
                    get: { review.drafts[index].included },
                    set: { review.include(index, selected: $0); copied = false }))
            }
            StackButton(label: review.approved ? "Rewrites approved" : "Approve selected rewrites",
                        disabled: !review.canApprove || review.approved) { review.approve() }
            if let text = review.approvedText {
                StackButton(label: "Copy approved rewrites", kind: .secondary) {
                    guard store.phase == .ready else { return }
                    UIPasteboard.general.string = text
                    copied = true
                }
            }
            if copied { Text("Copied. Apply the text on LinkedIn when you're ready.").font(Typeface.caption).foregroundStyle(Palette.muted) }
        }
        .onAppear {
            generation = store.sessionGeneration
            if let saved = store.rewriteDrafts[taskID], saved.source == rewrites { review = saved.review }
            else { store.rewriteDrafts[taskID] = SavedRewriteReview(source: rewrites, review: review) }
        }
        .onChange(of: review) { _, value in
            guard generation == store.sessionGeneration, store.phase == .ready else { return }
            store.rewriteDrafts[taskID] = SavedRewriteReview(source: rewrites, review: value)
        }
    }
}

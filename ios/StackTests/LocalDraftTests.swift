import XCTest
@testable import Stack

final class RewriteReviewTests: XCTestCase {
    func testOnlySelectedApprovedTextCanBeCopiedAndEditingInvalidatesApproval() {
        var review = RewriteReview(drafts: [RewriteDraft(id: 0, section: "headline", text: "Original"),
            RewriteDraft(id: 1, section: "about", text: "Private excluded text")])
        XCTAssertNil(review.approvedText)
        review.include(1, selected: false)
        review.approve()
        XCTAssertEqual(review.approvedText, "HEADLINE\nOriginal")
        review.edit(0, text: "Changed")
        XCTAssertNil(review.approvedText)
        review.approve()
        XCTAssertEqual(review.approvedText, "HEADLINE\nChanged")
    }
    func testSelectionChangesAndBlankSelectedRewriteRequireFreshApproval() {
        var review = RewriteReview(drafts: [RewriteDraft(id: 0, section: "headline", text: "Valid"),
            RewriteDraft(id: 1, section: "about", text: "  \n")])
        review.approve()
        XCTAssertNil(review.approvedText)
        review.include(1, selected: false)
        review.approve()
        XCTAssertNotNil(review.approvedText)
        review.include(0, selected: false)
        review.approve()
        XCTAssertFalse(review.canApprove)
        XCTAssertNil(review.approvedText)
    }
}

@MainActor
final class ProfileDraftTests: XCTestCase {
    func testSigningOutClearsSessionOnlyDrafts() async {
        let store = AppStore(api: APIClient(origin: URL(string: "https://stack.invalid")!))
        store.profileDrafts["LinkedIn:headline"] = "Private draft"
        store.rewriteDrafts["task"] = SavedRewriteReview(source: [], review: RewriteReview(drafts: []))
        await store.signOut()
        XCTAssertTrue(store.profileDrafts.isEmpty)
        XCTAssertTrue(store.rewriteDrafts.isEmpty)
    }
}

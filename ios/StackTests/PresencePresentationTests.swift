import XCTest
@testable import Stack

/// Manual UI/presentation coverage; not added to native core or any blocking selection.
final class PresencePresentationTests: XCTestCase {
    func testHeadlineUsesCapturedSectionAndPrefersItOverOtherRewrites() {
        let model = PresenceLinkedInPresentation(run: [
            "id": "review-1", "status": "completed", "artifacts": [
                "linkedin_scan": ["sections": ["headline": "Software engineer", "about": "Original about"]],
                "linkedin_review": ["rewrites": [
                    ["section": "about", "text": "Suggested about"],
                    ["section": "headline", "text": "Software engineer building APIs"]
                ]]
            ]
        ])
        XCTAssertEqual(model.sectionLabel, "Headline")
        XCTAssertEqual(model.current, "Software engineer")
        XCTAssertEqual(model.suggested(saved: nil), "Software engineer building APIs")
        XCTAssertEqual(model.rewriteIndex, 1)
    }

    func testRawCoachingIsNotPresentedAsAHeadlineOrRewrite() {
        let model = PresenceLinkedInPresentation(run: [
            "id": "raw-review", "status": "completed", "artifacts": [
                "linkedin_scan": ["sections": ["profile": "Candidate\nSoftware engineer\nAbout me"]],
                "linkedin_review": ["summary": "Try a more specific headline: Software engineer building APIs."]
            ]
        ])
        XCTAssertTrue(model.hasReview)
        XCTAssertNil(model.rewriteIndex)
        XCTAssertNil(model.suggested(saved: nil))
        XCTAssertNil(model.current)
        XCTAssertEqual(model.sectionLabel, "Profile review")
    }

    func testCurrentNeverComesFromFactsQuotesOrWholeProfile() {
        let model = PresenceLinkedInPresentation(run: [
            "id": "review", "artifacts": [
                "linkedin_scan": ["sections": ["profile": "Entire profile", "intro": "Name and current introduction"]],
                "linkedin_review": ["rewrites": [[
                    "section": "headline", "text": "Suggested headline", "evidence": [
                        ["source": "confirmed_fact", "quote": "Not a profile headline"],
                        ["source": "profile", "quote": "An arbitrary excerpt"]
                    ]
                ]]]
            ]
        ])
        XCTAssertNil(model.current)
        XCTAssertEqual(model.suggested(saved: nil), "Suggested headline")
    }

    func testIntroIsHonestlyLabelledIntroNotHeadline() {
        let model = PresenceLinkedInPresentation(run: [
            "id": "review", "artifacts": [
                "linkedin_scan": ["sections": ["intro": "Name and introduction"]],
                "linkedin_review": ["rewrites": [["section": "intro", "text": "Suggested introduction"]]]
            ]
        ])
        XCTAssertEqual(model.sectionLabel, "Intro")
        XCTAssertEqual(model.current, "Name and introduction")
    }

    func testBlankOrUnnamedRewriteDoesNotInventAvailableText() {
        let model = PresenceLinkedInPresentation(run: [
            "id": "empty-review", "artifacts": ["linkedin_review": ["rewrites": [
                ["section": "headline", "text": " \n"], ["section": "", "text": "No field"]
            ]]]
        ])
        XCTAssertFalse(model.hasReview)
        XCTAssertNil(model.suggested(saved: nil))
        XCTAssertNil(model.current)
    }

    func testSessionEditMatchesSourceAndKeepsIntentionallyBlankEdit() {
        let rewrites: [JSON] = [["section": "headline", "text": "Original suggestion"]]
        let model = PresenceLinkedInPresentation(run: [
            "id": "review", "artifacts": ["linkedin_review": ["rewrites": .array(rewrites)]]
        ])
        let saved = SavedRewriteReview(source: rewrites, review: RewriteReview(drafts: [
            RewriteDraft(id: 0, section: "headline", text: "Edited suggestion")
        ]))
        XCTAssertEqual(model.suggested(saved: saved), "Edited suggestion")
        let empty = SavedRewriteReview(source: rewrites, review: RewriteReview(drafts: [
            RewriteDraft(id: 0, section: "headline", text: "")
        ]))
        XCTAssertEqual(model.suggested(saved: empty), "")
        let outdated = SavedRewriteReview(source: [], review: saved.review)
        XCTAssertEqual(model.suggested(saved: outdated), "Original suggestion")
    }

    func testLatestRunDoesNotMistakeAttentionOrderingForRecency() {
        let runs: [JSON] = [
            ["id": "old-attention", "kind": "linkedin", "created_at": 10, "updated_at": 90],
            ["id": "irrelevant", "kind": "network", "created_at": 100],
            ["id": "recent", "kind": "linkedin", "created_at": 50, "updated_at": 50],
            ["id": "", "kind": "linkedin", "created_at": 200]
        ]
        XCTAssertEqual(PresenceLinkedInPresentation.latestRun(in: runs)?["id"].string, "recent")
        XCTAssertNil(PresenceLinkedInPresentation.latestRun(in: []))
    }

    func testMissingRunAndFailedRunHaveNoSyntheticReview() {
        let empty = PresenceLinkedInPresentation(run: .null)
        XCTAssertFalse(empty.hasReview)
        XCTAssertNil(empty.current)
        let failed = PresenceLinkedInPresentation(run: ["id": "failed", "status": "failed", "message": "Connection interrupted"])
        XCTAssertEqual(failed.status, "failed")
        XCTAssertEqual(failed.message, "Connection interrupted")
        XCTAssertFalse(failed.hasReview)
    }
}

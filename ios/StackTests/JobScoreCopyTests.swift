import XCTest
@testable import Stack

/// Manual UI-model regressions for the `stack.job_score` v1 card. Not part of the selected native-core gate.
final class JobScoreCopyTests: XCTestCase {
    /// Trimmed from the backend's real output for tests/test_job_score.py's fixed inputs.
    private let scored: JSON = [
        "contract": "stack.job_score", "version": 1, "status": "scored", "score": 62,
        "components": [["key": "skills", "label": "Skills", "weight": 55, "score": 71],
                       ["key": "title", "label": "Job title", "weight": 10, "score": 33]],
        "requirements": [
            ["kind": "skill", "term": "Python", "required": true, "status": "applied", "credit": 1.0, "evidence": ["r4"]],
            ["kind": "skill", "term": "AWS", "required": false, "status": "mentioned", "credit": 0.8, "evidence": ["r8"]],
            ["kind": "skill", "term": "Docker", "required": false, "status": "listed", "credit": 0.6, "evidence": ["r9"]],
            ["kind": "skill", "term": "Data analysis", "required": true, "status": "missing", "credit": 0.0, "evidence": []],
            ["kind": "experience", "term": "2+ years", "required": true, "status": "met", "credit": 1.0, "counted_years": 3.0, "evidence": ["r3"]],
            ["kind": "keyword", "term": "cpa license", "required": false, "status": "missing", "credit": 0.0, "evidence": []],
        ],
        "missing_required": ["Data analysis"],
    ]

    func testScoredResultShowsScoreReasonsAndOnlyConfirmedEvidence() {
        let copy = JobScoreCopy(result: scored)
        XCTAssertEqual(copy.headline, "Job score: 62")
        XCTAssertEqual(copy.components, "Skills 71 · Job title 33")
        XCTAssertEqual(copy.shown, ["Python", "AWS"])
        XCTAssertEqual(copy.listedOnly, ["Docker"])
        XCTAssertEqual(copy.missing, ["Data analysis"])
        XCTAssertEqual(copy.missingRequired, ["Data analysis"])
        XCTAssertEqual(copy.phrasesMissing, ["cpa license"])
        XCTAssertEqual(copy.experience, "The listing asks for 2+ years; your confirmed dates count about 3 (internships count half).")
    }

    func testThinListingAndUnknownContractShowNoNumber() {
        let thin = JobScoreCopy(result: ["contract": "stack.job_score", "version": 1, "status": "insufficient_job", "score": nil, "components": [], "requirements": [], "missing_required": []])
        XCTAssertFalse(thin.isScored)
        XCTAssertEqual(thin.headline, "This listing has too little to compare")
        XCTAssertEqual(thin.components, "")

        var newer = scored
        newer["version"] = 2
        let unknown = JobScoreCopy(result: newer)
        XCTAssertFalse(unknown.isSupported)
        XCTAssertEqual(unknown.headline, "Update Stack to see this score")
        XCTAssertTrue(unknown.shown.isEmpty && unknown.missingRequired.isEmpty)

        XCTAssertEqual(JobScoreCopy(result: .null).headline, "Update Stack to see this score")
    }
}

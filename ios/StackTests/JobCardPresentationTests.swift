import XCTest
@testable import Stack

/// Manual UI-model regressions. Not part of the selected native-core gate.
final class JobCardPresentationTests: XCTestCase {
    func testCompactFeedUsesEmployerExcerptsInsteadOfFitClaims() {
        let job = Job([
            "company": "Example", "title": "Engineer", "salary": "$90k–$110k",
            "compensation": ["unit": "year"],
            "fit": "Generated fit note", "reason": "Generated recommendation",
            "highlights": ["responsibilities": ["Build APIs for the product team."],
                           "requirements": ["Python experience", "SQL knowledge", "A third requirement"]],
        ])
        let copy = JobCardCopy(job: job)
        XCTAssertEqual(copy.roleExcerpt, "Build APIs for the product team.")
        XCTAssertEqual(copy.requirements, ["Python experience", "SQL knowledge"])
        XCTAssertEqual(copy.payPeriod, "/ year")
        XCTAssertFalse(copy.accessibilityLabel.contains("Generated"))
    }

    func testMissingFactsAreNotFabricatedAndFullDocumentsStillWork() {
        let missing = JobCardCopy(job: Job(["fit": "A match", "reason": "A recommendation"]))
        XCTAssertEqual(missing.location, "Location not listed")
        XCTAssertEqual(missing.pay, "Pay not listed")
        XCTAssertTrue(missing.roleExcerpt.isEmpty)
        XCTAssertTrue(missing.requirements.isEmpty)
        XCTAssertTrue(missing.payPeriod.isEmpty)

        let full = JobCardCopy(job: Job(["description": "Employer description.", "requirements": ["SQL", "SQL", "Python"]]))
        XCTAssertEqual(full.roleExcerpt, "Employer description.")
        XCTAssertEqual(full.requirements, ["SQL", "Python"])
    }

    func testPayPeriodsAreNotRepeatedAndUnknownUnitsStayUnknown() {
        let yearly = JobCardCopy(job: Job(["salary": "$100k / year", "compensation": ["unit": "year"]]))
        XCTAssertEqual(yearly.payPeriod, "")
        let unknown = JobCardCopy(job: Job(["salary": "$100k", "compensation": ["unit": "unknown"]]))
        XCTAssertEqual(unknown.payPeriod, "")
        let excerpt = JobCardCopy(job: Job(["salary": "Pay not listed", "highlights": ["pay_excerpt": "Salary depends on location: $90k–$110k."]]))
        XCTAssertEqual(excerpt.payExcerpt, "Salary depends on location: $90k–$110k.")
    }

    func testOnlyDecisiveHorizontalDragsSaveOrPass() {
        XCTAssertEqual(JobCardSwipe.decision(for: CGSize(width: 150, height: 20)), true)
        XCTAssertEqual(JobCardSwipe.decision(for: CGSize(width: -150, height: 20)), false)
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 100, height: 0)))
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 140, height: 180)))
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 0, height: -200)))
    }
}

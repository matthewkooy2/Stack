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
        XCTAssertFalse(excerpt.showsPayHeadline)
        XCTAssertFalse(excerpt.accessibilityLabel.contains("Pay not listed"))
        let scoped = JobCardCopy(job: Job(["salary": "USD 90000–110000 / year", "highlights": ["pay_context": "US base salary range."]]))
        XCTAssertTrue(scoped.showsPayHeadline)
        XCTAssertTrue(scoped.accessibilityLabel.contains("US base salary range."))
        XCTAssertTrue(yearly.showsPayHeadline)
        XCTAssertTrue(JobCardCopy(job: Job(["salary": "Pay not listed"])).showsPayHeadline)
    }

    func testLegacyPostingsResolveVerifiedCitiesAndServerAssignmentsWin() {
        XCTAssertEqual(JobPhoto.id(for: Job(["id": "seattle", "location": "Seattle, Washington, US"])), "seattle")
        XCTAssertEqual(JobPhoto.id(for: Job(["id": "chicago", "location": "Chicago, IL", "photo_id": "missing-photo"])), "chicago")
        XCTAssertEqual(JobPhoto.id(for: Job(["id": "seattle-bare", "location": "Seattle", "country": "US"])), "seattle")
        XCTAssertEqual(JobPhoto.id(for: Job(["id": "dublin", "location": "Dublin, Ireland"])), "dublin")
        XCTAssertEqual(JobPhoto.id(for: Job(["id": "assigned", "location": "Chicago, IL", "photo_id": "desert"])), "desert")
        XCTAssertNotEqual(JobPhoto.id(for: Job(["id": "ambiguous", "location": "Dublin, CA"])), "dublin")
        let multiple = Job(["id": "multiple", "locations": ["Seattle, WA", "New York, NY"]])
        XCTAssertEqual(JobPhoto.id(for: multiple, preferredLocation: "New York"), "new-york")
        let remote = Job(["id": "remote", "location": "North America", "mode": "Remote"])
        XCTAssertEqual(JobPhoto.id(for: remote), JobPhoto.id(for: remote))
        XCTAssertTrue(["coast", "desert", "forest", "mountain-lake"].contains(JobPhoto.id(for: remote)))
        let fallbackIDs = (0..<20).map { JobPhoto.id(for: Job(["id": .string("remote-\($0)"), "location": "Remote US"])) }
        XCTAssertEqual(Set(fallbackIDs).count, 4)
    }

    func testOnlyDecisiveHorizontalDragsSaveOrPass() {
        XCTAssertEqual(JobCardSwipe.decision(for: CGSize(width: 150, height: 20)), true)
        XCTAssertEqual(JobCardSwipe.decision(for: CGSize(width: -150, height: 20)), false)
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 100, height: 0)))
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 140, height: 180)))
        XCTAssertNil(JobCardSwipe.decision(for: CGSize(width: 0, height: -200)))
    }

    func testBundledBrandsRequireReviewedIdentityAndRejectConflicts() {
        XCTAssertEqual(JobBrand.domain(for: Job(["employer_domain": " WWW.Stripe.Com. "])), "stripe.com")
        XCTAssertEqual(JobBrand.domain(for: Job(["source_id": "greenhouse:stripe"])), "stripe.com")
        XCTAssertNil(JobBrand.domain(for: Job(["company": "Stripe"])))
        XCTAssertNil(JobBrand.domain(for: Job(["source_id": "greenhouse:stripe", "employer_domain": "unknown.example"])))
        XCTAssertNil(JobBrand.domain(for: Job(["source_id": "greenhouse:stripe", "employer_domain": "asana.com"])))
    }
}

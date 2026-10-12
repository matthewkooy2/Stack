import XCTest
@testable import Stack

final class JobListingLinkTests: XCTestCase {
    func testHttpAndHttpsListingsAreAccepted() {
        XCTAssertEqual(JobListingLink.safeURL("https://boards.example.com/jobs/42?src=stack")?.absoluteString,
                       "https://boards.example.com/jobs/42?src=stack")
        XCTAssertEqual(JobListingLink.safeURL("http://example.com/careers")?.scheme, "http")
        XCTAssertEqual(JobListingLink.safeURL("HTTPS://Example.com/a")?.host, "Example.com")
        XCTAssertEqual(JobListingLink.safeURL("  https://example.com/a \n")?.absoluteString, "https://example.com/a")
    }

    func testExplicitPortsAndIPLiteralHostsAreAccepted() {
        XCTAssertEqual(JobListingLink.safeURL("http://127.0.0.1:18765/listing")?.port, 18765)
        XCTAssertEqual(JobListingLink.safeURL("https://example.com:8443/jobs")?.absoluteString,
                       "https://example.com:8443/jobs")
        XCTAssertEqual(JobListingLink.safeURL("http://[::1]:8080/jobs")?.port, 8080)
    }

    func testOtherSchemesAndMalformedLinksAreRefused() {
        for raw in ["", "   ", "javascript:alert(1)", "file:///etc/passwd", "tel:5551212", "mailto:a@b.co",
                    "stack://jobs/1", "data:text/html,hi", "ftp://example.com/a", "example.com/jobs", "//example.com/a",
                    "https://", "https:///path", "https://exa mple.com", "https://example.com/a b",
                    "https://example.com/a\nb", "https://example.com/a\tb"] {
            XCTAssertNil(JobListingLink.safeURL(raw), "\(raw) must not open in the browser")
        }
    }

    func testLinksWithEmbeddedCredentialsAreRefused() {
        XCTAssertNil(JobListingLink.safeURL("https://user:secret@example.com/jobs"))
        XCTAssertNil(JobListingLink.safeURL("https://trusted.example.com@evil.example.net/jobs"))
        XCTAssertNil(JobListingLink.safeURL("https://user@example.com/jobs"), "a user name alone is still refused")
    }

    func testPresentationsCoverTheDeckWithoutEndingTheVisit() throws {
        let job = Job(["id": "a", "listing_url": "https://example.com/a"])
        XCTAssertFalse(JobsLifecycle.isCovered(listing: nil, detail: nil, sheet: nil))
        XCTAssertTrue(JobsLifecycle.isCovered(listing: JobListing(job: job), detail: nil, sheet: nil))
        XCTAssertTrue(JobsLifecycle.isCovered(listing: nil, detail: job, sheet: nil))
        XCTAssertTrue(JobsLifecycle.isCovered(listing: nil, detail: nil, sheet: .filters))
    }

    func testListingFollowsTheJobsPreferredLinkAndIsNilWithoutOne() {
        let withListing = Job(["id": "a", "listing_url": "https://example.com/listing", "apply_url": "https://example.com/apply"])
        XCTAssertEqual(JobListing(job: withListing)?.url.absoluteString, "https://example.com/listing")
        XCTAssertEqual(JobListing(job: withListing)?.id, "a")
        XCTAssertEqual(JobListing(job: Job(["id": "b", "apply_url": "https://example.com/apply"]))?.url.path, "/apply")
        XCTAssertNil(JobListing(job: Job(["id": "c"])))
        XCTAssertNil(JobListing(job: Job(["id": "d", "listing_url": "javascript:void(0)"])))
    }
}

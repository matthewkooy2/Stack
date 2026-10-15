import XCTest
@testable import Stack

final class LinkedInSetupTests: XCTestCase {
    func testProfileAddressAcceptsLinkedInProfilesAndAddsAMissingScheme() {
        XCTAssertEqual(LinkedInSetup.profileURL(" https://www.linkedin.com/in/ada-example/ "), "https://www.linkedin.com/in/ada-example/")
        XCTAssertEqual(LinkedInSetup.profileURL("linkedin.com/in/ada"), "https://linkedin.com/in/ada")
    }

    func testProfileAddressPassesThroughOtherSitesSchemesAndPaths() {
        for bad in ["", "   ", "http://www.linkedin.com/in/ada", "https://evil.example/in/ada",
                    "https://www.linkedin.com.evil.example/in/ada", "https://www.linkedin.com/company/acme",
                    "https://user@www.linkedin.com/in/ada", "https://www.linkedin.com:8443/in/ada",
                    "https://www.linkedin.com/in/ada/details"] {
            XCTAssertEqual(LinkedInSetup.profileURL(bad), bad.contains("://") ? bad : "https://" + bad.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}

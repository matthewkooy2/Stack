import XCTest
@testable import Stack

final class GoogleConnectionTests: XCTestCase {
    func testConsentAcceptsEmptyFragmentAndStillRejectsInvalidCallbacks() throws {
        let state = "native.fixture-state"
        let callback = "stack://oauth/google?state=\(state)&code=fixture-code"
        for suffix in ["", "#"] {
            XCTAssertEqual(try GoogleConnection.code(URL(string: callback + suffix)!, state: state), "fixture-code")
        }
        for value in [callback + "#fragment", callback + "#access_token=fixture", callback + "&state=other",
                      callback + "&code=other", callback.replacingOccurrences(of: state, with: "native.other"),
                      callback.replacingOccurrences(of: "stack://oauth", with: "stack://other")] {
            XCTAssertThrowsError(try GoogleConnection.code(URL(string: value)!, state: state))
        }
        XCTAssertThrowsError(try GoogleConnection.code(URL(string: "stack://oauth/google?state=\(state)&error=access_denied")!, state: state)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}

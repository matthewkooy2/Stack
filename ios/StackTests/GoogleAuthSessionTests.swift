import XCTest
@testable import Stack

@MainActor
final class GoogleAuthSessionTests: XCTestCase {
    private let state = String(repeating: "s", count: 43)
    private var provider: URL {
        URL(string: "https://accounts.google.com/o/oauth2/v2/auth?scope=openid+email+profile&code_challenge_method=S256&state=\(state)")!
    }

    func testSystemSheetStartsAtTheGatewayWithoutChangingTheGoogleRequest() throws {
        let url = try GoogleAuthSession.startURL(provider: provider, origin: URL(string: "https://dev.stackmvp.top")!)
        XCTAssertEqual(url.host, "dev.stackmvp.top")
        XCTAssertEqual(url.path, "/auth/google/start")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, provider.absoluteString)
    }

    func testCallbackMustMatchTheAttemptAndCannotCarryASessionOrProviderToken() throws {
        let callback = "com.matthewkooy.stack://auth/google?state=\(state)"
        XCTAssertNoThrow(try GoogleAuthSession.validateCallback(URL(string: callback)!, provider: provider))
        for invalid in [callback + "&state=other", callback + "&token=secret", callback + "#fragment",
                        callback.replacingOccurrences(of: state, with: String(repeating: "x", count: 43)),
                        callback.replacingOccurrences(of: "://auth/", with: "://other/"),
                        callback.replacingOccurrences(of: "com.matthewkooy.stack", with: "attacker")] {
            XCTAssertThrowsError(try GoogleAuthSession.validateCallback(URL(string: invalid)!, provider: provider))
        }
    }

    func testAppLinksNavigateToKnownScreensAndNeverConsumeAuthentication() {
        XCTAssertEqual(StackAppLink.destination(URL(string: "com.matthewkooy.stack://open/resume")!), "resume")
        XCTAssertEqual(StackAppLink.destination(URL(string: "https://dev.stackmvp.top/open/prep")!), "prep")
        XCTAssertEqual(StackAppLink.destination(URL(string: "https://stackmvp.top/open")!), "jobs")
        for invalid in ["https://evil.example/open/jobs", "https://dev.stackmvp.top/sso/google/callback",
                        "com.matthewkooy.stack://auth/google?state=abc", "https://dev.stackmvp.top/open/unknown",
                        "https://user@dev.stackmvp.top/open", "https://dev.stackmvp.top/open?token=secret"] {
            XCTAssertNil(StackAppLink.destination(URL(string: invalid)!))
        }
    }
}

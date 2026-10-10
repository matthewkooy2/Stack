import AuthenticationServices
import XCTest
@testable import Stack

@MainActor
final class AppleSignInTests: XCTestCase {
    private let state = String(repeating: "s", count: 43)
    private let nonce = String(repeating: "a", count: 64)
    private func client() -> APIClient {
        let api = APIClient(origin: URL(string: "https://apple-\(UUID().uuidString).invalid")!, session: stubSession())
        api.forget()
        StubProtocol.seen = []
        return api
    }
    private func install(_ apple: AppleSignIn) {
        let state = state, nonce = nonce
        apple.authorize = { receivedState, receivedNonce, _ in
            XCTAssertEqual(receivedState, state)
            XCTAssertEqual(receivedNonce, nonce)
            return AppleSignIn.Proof(state: state, identityToken: "native-proof", authorizationCode: "one-use-code", user: "apple-user")
        }
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("_begin") {
                return (200, envelope(["ok": true, "state": .string(state), "nonce": .string(nonce)]))
            }
            if request.url!.path.hasSuffix("_finish") { return (200, envelope(["ok": true, "token": "stack-session"])) }
            if request.url!.path.hasSuffix("auth_google_status") { return (200, envelope([:])) }
            if request.url!.path.hasSuffix("agent_admission") { return (200, envelope(["admitted": false])) }
            return (200, envelope([:]))
        }
    }

    func testAppleSessionStillRequiresBetaAdmission() async {
        let api = client(), store = AppStore(api: client())
        defer { api.forget(); store.api.forget(); store.apple.forget() }
        install(store.apple)
        await store.signInWithApple(window: UIWindow())
        XCTAssertEqual(store.api.token, "stack-session")
        XCTAssertEqual(store.phase, .admission)
        XCTAssertFalse(StubProtocol.seen.contains { $0.url!.path.hasSuffix("bootstrap") })
        let finish = StubProtocol.seen.first { $0.url!.path.hasSuffix("auth_apple_finish") }!
        let payload = try! JSONDecoder().decode(JSON.self, from: finish.httpBody!)
        XCTAssertEqual(payload["state"].string, state)
        XCTAssertEqual(payload["authorization_code"].string, "one-use-code")
    }

    func testMismatchedStateNeverReachesFinish() async {
        let api = client(), apple = AppleSignIn(api: client())
        defer { api.forget(); apple.api.forget() }
        install(apple)
        apple.authorize = { _, _, _ in
            AppleSignIn.Proof(state: "wrong", identityToken: "proof", authorizationCode: "code", user: "user")
        }
        do { _ = try await apple.perform(window: UIWindow()); XCTFail("Mismatched state accepted") }
        catch { XCTAssertTrue(error is APIError) }
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testSignOutWhileAppleSheetIsOpenCannotAdoptSession() async {
        let store = AppStore(api: client())
        install(store.apple)
        let state = state
        store.apple.authorize = { _, _, _ in
            await store.signOut()
            return AppleSignIn.Proof(state: state, identityToken: "proof", authorizationCode: "code", user: "user")
        }
        await store.signInWithApple(window: UIWindow())
        XCTAssertFalse(store.api.hasSession)
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertEqual(store.error, "")
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testCancellationIsQuietAndDoesNotExchangeProof() async {
        let store = AppStore(api: client())
        install(store.apple)
        store.apple.authorize = { _, _, _ in throw CancellationError() }
        await store.signInWithApple(window: UIWindow())
        XCTAssertFalse(store.api.hasSession)
        XCTAssertEqual(store.error, "")
        XCTAssertFalse(store.busy)
        XCTAssertEqual(StubProtocol.seen.count, 1)
    }

    func testLinkUsesSameAccountCredentialsAndPrivateEndpoints() async {
        let store = AppStore(api: client())
        install(store.apple)
        store.phase = .admission
        store.api.adopt(token: "original")
        defer { store.api.forget(); store.apple.forget() }
        await store.signInWithApple(window: UIWindow(), link: true, username: "owner", password: "confirmed-password")
        let first = StubProtocol.seen.first!
        XCTAssertEqual(first.url!.path, "/function/auth_apple_link_begin")
        XCTAssertEqual(first.value(forHTTPHeaderField: "Authorization"), "Bearer original")
        let payload = try! JSONDecoder().decode(JSON.self, from: first.httpBody!)
        XCTAssertEqual(payload["username"].string, "owner")
        XCTAssertEqual(payload["password"].string, "confirmed-password")
        XCTAssertTrue(StubProtocol.seen.contains { $0.url!.path.hasSuffix("auth_apple_link_finish") })
    }

    func testUnadmittedAccountCanDeleteWithFreshProof() async {
        let store = AppStore(api: client())
        install(store.apple)
        store.phase = .admission
        store.api.adopt(token: "original")
        let previous = StubProtocol.handler!
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("account_delete_apple") {
                let payload = try JSONDecoder().decode(JSON.self, from: request.httpBody!)
                XCTAssertEqual(payload["name"], .null)
                XCTAssertEqual(payload["identity_token"].string, "native-proof")
                return (200, envelope(["deleted": true]))
            }
            return try previous(request)
        }
        await store.deleteWithApple(window: UIWindow())
        XCTAssertFalse(store.api.hasSession)
        XCTAssertEqual(store.phase, .signedOut)
    }

    func testRevocationIsScopedToTheExactAppleSession() async {
        let api = client(), apple = AppleSignIn(api: client())
        defer { api.forget(); apple.api.forget(); apple.forget() }
        apple.api.adopt(token: "apple-session")
        apple.remember(user: "apple-user")
        apple.credentialState = { _ in .revoked }
        let revoked = await apple.isRevoked()
        XCTAssertTrue(revoked)
        apple.api.adopt(token: "subsequent-google-session")
        let other = await apple.isRevoked()
        XCTAssertFalse(other)
    }

    func testOfflineCredentialCheckPreservesSession() async {
        let api = client(), apple = AppleSignIn(api: client())
        defer { api.forget(); apple.api.forget(); apple.forget() }
        apple.api.adopt(token: "apple-session")
        apple.remember(user: "apple-user")
        apple.credentialState = { _ in throw URLError(.notConnectedToInternet) }
        let revoked = await apple.isRevoked()
        XCTAssertFalse(revoked)
        XCTAssertTrue(apple.api.hasSession)
    }
}

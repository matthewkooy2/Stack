import Foundation

/// The Jac OAuthSession handoff used by the existing clients. The server creates provider PKCE and a
/// separate one-time poll capability; Safari completes authorization and this app retrieves its Stack
/// session by polling. No Stack session or Google token passes through a browser redirect.
struct GoogleHandoff: Codable, Equatable {
    var poll: String
    var invite: String
    var link: Bool
    var at: Double
}

enum GoogleSignInError: LocalizedError {
    case invalidURL
    case invalidPermissions
    case unavailable
    case cancelled
    case openFailed
    case failed
    case expired

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Google sign-in URL is invalid."
        case .invalidPermissions: return "Google sign-in permissions are invalid."
        case .unavailable: return "Google sign-in is unavailable."
        case .cancelled: return "Google sign-in was cancelled."
        case .openFailed: return "Could not open Google sign-in."
        case .failed: return "Google sign-in was cancelled or could not finish. Try again."
        case .expired: return "Google sign-in expired. Please try again."
        }
    }
}

@MainActor
final class GoogleSignIn {
    static let lifetime: TimeInterval = 600
    static let pollInterval: Duration = .milliseconds(2500)

    private let api: APIClient
    private var attempt = 0
    private var key: String { "google-pending@" + api.origin.absoluteString }

    init(api: APIClient) { self.api = api }

    /// Only Google's own authorization endpoint, asking for exactly `openid email profile` with S256.
    nonisolated static func validate(_ value: String) throws -> URL {
        guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw GoogleSignInError.invalidURL
        }
        guard components.scheme == "https", components.host == "accounts.google.com",
              components.path == "/o/oauth2/v2/auth", components.user == nil, components.password == nil,
              components.port == nil else { throw GoogleSignInError.invalidURL }
        // OAuth query parameters use form encoding. Foundation leaves literal + intact;
        // decode those as spaces before percent decoding, preserving an encoded literal %2B.
        // Validate the decoded query without rewriting the provider URL opened by Safari.
        var formQuery = components
        formQuery.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = formQuery.queryItems ?? []
        let scopes = items.filter { $0.name == "scope" }
        guard scopes.count == 1,
              (scopes[0].value ?? "").split(separator: " ").map(String.init).sorted() == ["email", "openid", "profile"],
              items.first(where: { $0.name == "code_challenge_method" })?.value == "S256" else {
            throw GoogleSignInError.invalidPermissions
        }
        return url
    }

    func pending() -> GoogleHandoff? {
        guard let text = Keychain.read(account: key), let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GoogleHandoff.self, from: data)
    }

    func clearPending() { Keychain.delete(account: key) }

    func cancel() {
        attempt += 1
        clearPending()
    }

    private func store(_ handoff: GoogleHandoff) {
        if let data = try? JSONEncoder().encode(handoff), let text = String(data: data, encoding: .utf8) {
            Keychain.write(text, account: key)
        }
    }

    /// Starts authorization: asks the server for the provider URL, persists the poll capability, opens Safari.
    func begin(invite: String, link: Bool, open: (URL) async -> Bool) async throws -> GoogleHandoff {
        attempt += 1
        let observed = attempt
        let data = try await api.post(
            "/sso/google/begin",
            ["challenge": .string(String(repeating: "A", count: 43)), "mode": "native"],
            authenticated: link
        )
        guard observed == attempt else { throw GoogleSignInError.cancelled }
        guard data["ok"].bool, !data["poll"].string.isEmpty else { throw GoogleSignInError.unavailable }
        let url = try Self.validate(data["url"].string)
        let handoff = GoogleHandoff(poll: data["poll"].string, invite: invite, link: link, at: Date().timeIntervalSince1970)
        store(handoff)
        guard observed == attempt else { clearPending(); throw GoogleSignInError.cancelled }
        guard await open(url) else { clearPending(); throw GoogleSignInError.openFailed }
        guard observed == attempt else { clearPending(); throw GoogleSignInError.cancelled }
        return handoff
    }

    /// Polls until Google authorization finishes. Polling pauses while the app is inactive; cancellation
    /// or a session change rejects any late result.
    func wait(for handoff: GoogleHandoff, isActive: () -> Bool) async throws -> String {
        let observed = attempt
        while Date().timeIntervalSince1970 - handoff.at < Self.lifetime {
            guard observed == attempt, !Task.isCancelled else { throw GoogleSignInError.cancelled }
            if isActive() {
                do {
                    let result = try await api.post("/sso/google/poll", ["poll": .string(handoff.poll)], authenticated: false)
                    guard observed == attempt else { throw GoogleSignInError.cancelled }
                    if result["ok"].bool, !result["token"].string.isEmpty {
                        clearPending()
                        return result["token"].string
                    }
                    if !result["error"].string.isEmpty {
                        clearPending()
                        throw GoogleSignInError.failed
                    }
                } catch let failure as APIError where failure.status == 0 {
                    // A dropped connection is retried until the capability expires.
                }
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        clearPending()
        throw GoogleSignInError.expired
    }
}

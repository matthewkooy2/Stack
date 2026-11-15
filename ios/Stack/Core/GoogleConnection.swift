import AuthenticationServices
import UIKit

/// Optional Gmail/Calendar consent uses the current Stack account, independently of its login provider.
@MainActor
final class GoogleConnection: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let api: APIClient
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var connecting = false
    private var attempt = 0
    private weak var anchor: UIWindow?

    init(api: APIClient) { self.api = api }

    func connect(_ capabilities: [String]) async throws {
        guard !connecting else { throw APIError(message: "A Google connection is already in progress.") }
        connecting = true
        defer { connecting = false }
        let generation = api.sessionGeneration
        let result = try await api.call("agent_google_start", ["capabilities": .array(capabilities.map { .string($0) }), "native": true])
        guard generation == api.sessionGeneration else { throw CancellationError() }
        let (url, state) = try Self.authorization(result["url"].string)
        let callback = try await authorize(url)
        guard generation == api.sessionGeneration, !Task.isCancelled else { throw CancellationError() }
        let code = try Self.code(callback, state: state)
        try await api.call("agent_google_finish", ["state": .string(state), "code": .string(code)])
    }

    nonisolated static func authorization(_ value: String) throws -> (URL, String) {
        guard let url = URL(string: value), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "accounts.google.com", parts.path == "/o/oauth2/v2/auth",
              parts.user == nil, parts.password == nil, parts.port == nil else {
            throw APIError(message: "Google connection URL is invalid.")
        }
        let states = (parts.queryItems ?? []).filter { $0.name == "state" }
        guard states.count == 1, let state = states.first?.value, state.hasPrefix("native."), state.count > 7 else {
            throw APIError(message: "This backend cannot finish Google consent in the app yet.")
        }
        return (url, state)
    }

    nonisolated static func code(_ url: URL, state: String) throws -> String {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "stack", parts.host == "oauth", parts.path == "/google",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment?.isEmpty != false else {
            throw APIError(message: "Google connection returned an invalid callback.")
        }
        var form = parts
        form.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%20")
        let items = form.queryItems ?? []
        guard items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              items.filter({ $0.name == "code" }).count <= 1,
              items.filter({ $0.name == "error" }).count <= 1 else {
            throw APIError(message: "Google connection did not match this request. Please retry.")
        }
        if items.contains(where: { $0.name == "error" }) { throw CancellationError() }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw APIError(message: "Google did not return an authorization code. Please retry.")
        }
        return code
    }

    private func authorize(_ url: URL) async throws -> URL {
        anchor = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.windows.first(where: { $0.isKeyWindow })
        guard anchor != nil else { throw APIError(message: "Open Stack to connect Google.") }
        attempt += 1
        let observed = attempt
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "stack") { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self, self.attempt == observed else { return }
                        if let callback { self.complete(.success(callback)) }
                        else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.complete(.failure(CancellationError()))
                        } else { self.complete(.failure(APIError(message: "Google connection could not finish. Please retry."))) }
                    }
                }
                self.session = session
                session.presentationContextProvider = self
                if !session.start() { complete(.failure(APIError(message: "Google connection could not open. Please retry."))) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                if self?.attempt == observed { self?.cancel() }
            }
        }
    }

    func cancel() {
        attempt += 1
        session?.cancel()
        complete(.failure(CancellationError()))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? UIWindow()
    }

    private func complete(_ result: Result<URL, Error>) {
        attempt += 1
        let pending = continuation
        continuation = nil
        session = nil
        pending?.resume(with: result)
    }
}

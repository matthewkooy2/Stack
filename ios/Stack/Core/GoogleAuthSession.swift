import AuthenticationServices
import UIKit

/// The system browser owns Google's pages and cookies. Stack receives only a completion signal;
/// the existing one-use server capability retrieves the actual Stack session.
@MainActor
final class GoogleAuthSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let scheme = "com.matthewkooy.stack"
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var attempt = UUID()
    private weak var window: UIWindow?

    static func startURL(provider: URL, origin: URL) throws -> URL {
        _ = try GoogleSignIn.validate(provider.absoluteString)
        guard let state = URLComponents(url: provider, resolvingAgainstBaseURL: false)?.queryItems?.filter({ $0.name == "state" }),
              state.count == 1, state[0].value?.count == 43 else { throw GoogleSignInError.invalidURL }
        var url = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        url.path = "/auth/google/start"
        url.queryItems = [URLQueryItem(name: "url", value: provider.absoluteString)]
        url.fragment = nil
        guard let result = url.url else { throw GoogleSignInError.invalidURL }
        return result
    }

    static func validateCallback(_ callback: URL, provider: URL) throws {
        let url = URLComponents(url: callback, resolvingAgainstBaseURL: false)
        let expected = URLComponents(url: provider, resolvingAgainstBaseURL: false)?.queryItems?.filter { $0.name == "state" }
        let query = url?.queryItems ?? []
        guard url?.scheme == scheme, url?.host == "auth", url?.path == "/google",
              url?.user == nil, url?.password == nil, url?.port == nil,
              // Browsers can preserve an empty fragment marker during OAuth redirects.
              url?.fragment?.isEmpty != false,
              expected?.count == 1, let state = expected?.first?.value, state.count == 43,
              query.count == 1, query[0].name == "state", query[0].value == state else {
            throw GoogleSignInError.invalidURL
        }
    }

    func authenticate(provider: URL, origin: URL) async throws -> URL {
        let url = try Self.startURL(provider: provider, origin: origin)
        guard let anchor = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .filter({ $0.activationState == .foregroundActive }).flatMap(\.windows).first(where: \.isKeyWindow) else {
            throw GoogleSignInError.openFailed
        }
        cancel()
        window = anchor
        let id = UUID()
        attempt = id
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { pending in
                continuation = pending
                let completion: ASWebAuthenticationSession.CompletionHandler = { [weak self] callback, error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let failure = error as? ASWebAuthenticationSessionError, failure.code == .canceledLogin {
                            self.complete(id, .failure(CancellationError()))
                        } else if let callback {
                            do {
                                try Self.validateCallback(callback, provider: provider)
                                self.complete(id, .success(callback))
                            } catch { self.complete(id, .failure(error)) }
                        } else { self.complete(id, .failure(GoogleSignInError.failed)) }
                    }
                }
                let browser = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.scheme, completionHandler: completion)
                browser.presentationContextProvider = self
                browser.prefersEphemeralWebBrowserSession = false
                session = browser
                if !browser.start() { complete(id, .failure(GoogleSignInError.openFailed)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attempt == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        session?.cancel()
        complete(attempt, .failure(CancellationError()))
    }

    private func complete(_ id: UUID, _ result: Result<URL, Error>) {
        guard attempt == id else { return }
        let pending = continuation
        continuation = nil
        session = nil
        window = nil
        attempt = UUID()
        pending?.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor { window ?? UIWindow() }
}

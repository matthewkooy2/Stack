import AuthenticationServices
import CryptoKit
import SwiftUI

/// A server-issued, single-use challenge precedes every native authorization request.
@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Proof {
        let state: String
        let identityToken: String
        let authorizationCode: String
        let user: String
        var name: String = ""
    }
    struct Result { let response: JSON; let user: String }
    typealias Authorize = (String, String, UIWindow) async throws -> Proof
    let api: APIClient
    var authorize: Authorize?
    var credentialState: (String) async throws -> ASAuthorizationAppleIDProvider.CredentialState = { user in
        try await withCheckedThrowingContinuation { continuation in
            ASAuthorizationAppleIDProvider().getCredentialState(forUserID: user) { state, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state) }
            }
        }
    }
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<Proof, Error>?
    private weak var anchor: UIWindow?
    private var operation = UUID()
    private var sessionAccount: String { "apple-session@" + api.origin.absoluteString }

    static var enabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "StackAppleSignInEnabled") as? NSString)?.boolValue ?? false
    }
    init(api: APIClient) { self.api = api }

    func perform(begin: String = "auth_apple_begin", finish: String = "auth_apple_finish",
                 arguments: JSON = [:], window: UIWindow) async throws -> Result {
        guard continuation == nil else { throw APIError(message: "Apple sign-in is already open.") }
        let generation = api.sessionGeneration
        let current = UUID()
        operation = current
        let challenge = try await api.call(begin, arguments)
        guard generation == api.sessionGeneration, current == operation, !Task.isCancelled else { throw CancellationError() }
        let state = challenge["state"].string
        let nonce = challenge["nonce"].string
        guard challenge["ok"].bool, state.count == 43, nonce.count == 64,
              nonce.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw APIError(message: "Stack could not prepare Apple sign-in. Please retry.")
        }
        let proof = try await (authorize ?? request)(state, nonce, window)
        guard generation == api.sessionGeneration, current == operation, !Task.isCancelled else { throw CancellationError() }
        guard proof.state == state, !proof.identityToken.isEmpty, !proof.authorizationCode.isEmpty, !proof.user.isEmpty else {
            throw APIError(message: "Apple sign-in returned an incomplete response. Please retry.")
        }
        var payload: JSON = ["state": .string(state), "identity_token": .string(proof.identityToken),
            "authorization_code": .string(proof.authorizationCode)]
        if finish != "account_delete_apple" { payload["name"] = .string(proof.name) }
        let response = try await api.call(finish, payload)
        guard generation == api.sessionGeneration, current == operation, !Task.isCancelled else { throw CancellationError() }
        return Result(response: response, user: proof.user)
    }

    private func request(state: String, nonce: String, window: UIWindow) async throws -> Proof {
        guard !window.isHidden else { throw APIError(message: "Open Stack to continue with Apple.") }
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.state = state
        request.nonce = nonce // Already SHA-256 from Stack; do not hash it again.
        anchor = window
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            self.controller = controller
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    func cancel() {
        operation = UUID()
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        controller = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Held by the visible official button throughout the authorization request.
        anchor ?? UIWindow()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard controller === self.controller else { return }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }),
              let code = credential.authorizationCode.flatMap({ String(data: $0, encoding: .utf8) }) else {
            complete(.failure(APIError(message: "Apple sign-in returned an incomplete response. Please retry.")))
            return
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) } ?? ""
        complete(.success(Proof(state: credential.state ?? "", identityToken: token, authorizationCode: code,
                                user: credential.user, name: name)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard controller === self.controller else { return }
        if (error as? ASAuthorizationError)?.code == .canceled { complete(.failure(CancellationError())) }
        else { complete(.failure(APIError(message: "Apple sign-in could not finish. Please retry."))) }
    }
    private func complete(_ result: Swift.Result<Proof, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }

    private func fingerprint() -> String {
        SHA256.hash(data: Data(api.token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func remember(user: String) {
        guard api.hasSession else { return }
        let value = ["user": user, "session": fingerprint()]
        if let data = try? JSONEncoder().encode(value), let string = String(data: data, encoding: .utf8) {
            Keychain.write(string, account: sessionAccount)
        }
    }
    func forget() { Keychain.delete(account: sessionAccount) }
    var hasAppleSession: Bool { savedUser() != nil }
    private func savedUser() -> String? {
        guard api.hasSession, let saved = Keychain.read(account: sessionAccount),
              let data = saved.data(using: .utf8), let value = try? JSONDecoder().decode([String: String].self, from: data),
              value["session"] == fingerprint() else { return nil }
        return value["user"]
    }
    /// Failed/offline checks preserve the session. Confirmed revocation signs it out.
    func isRevoked() async -> Bool {
        guard let user = savedUser() else { return false }
        let generation = api.sessionGeneration
        guard let state = try? await credentialState(user), generation == api.sessionGeneration else { return false }
        return state == .revoked || state == .notFound
    }
}

/// Apple's own control allows an async Stack challenge before presenting authorization.
struct AppleAccountButton: UIViewRepresentable {
    var disabled = false
    var action: (UIWindow) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: .black)
        button.addTarget(context.coordinator, action: #selector(Coordinator.tap(_:)), for: .touchUpInside)
        return button
    }
    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        button.isEnabled = !disabled
        context.coordinator.action = action
    }
    final class Coordinator: NSObject {
        var action: (UIWindow) -> Void
        init(action: @escaping (UIWindow) -> Void) { self.action = action }
        @objc func tap(_ sender: ASAuthorizationAppleIDButton) { if let window = sender.window { action(window) } }
    }
}

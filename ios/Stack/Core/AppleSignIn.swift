import AuthenticationServices
import SwiftUI

@MainActor
final class AppleSignIn: NSObject, ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    struct Proof { let state: String; let identityToken: String }
    let api: APIClient
    private var controller: ASAuthorizationController?
    private var continuation: CheckedContinuation<Proof, Error>?
    private weak var anchor: UIWindow?

    static var enabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "StackAppleSignInEnabled") as? NSString)?.boolValue ?? false
    }
    init(api: APIClient) { self.api = api }

    func perform(window: UIWindow) async throws -> JSON {
        let generation = api.sessionGeneration
        let challenge = try await api.call("auth_apple_begin")
        guard generation == api.sessionGeneration else { throw CancellationError() }
        let state = challenge["state"].string
        let nonce = challenge["nonce"].string
        guard challenge["ok"].bool, !state.isEmpty, !nonce.isEmpty else {
            throw APIError(message: "Stack could not prepare Apple sign-in. Please retry.")
        }
        let proof = try await request(state: state, nonce: nonce, window: window)
        guard generation == api.sessionGeneration else { throw CancellationError() }
        guard proof.state == state else {
            throw APIError(message: "Apple sign-in did not match this request. Please retry.")
        }
        return try await api.call("auth_apple_finish", ["state": .string(state), "identity_token": .string(proof.identityToken)])
    }

    private func request(state: String, nonce: String, window: UIWindow) async throws -> Proof {
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.state = state
        request.nonce = nonce
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
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        complete(.failure(CancellationError()))
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        anchor ?? UIWindow()
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let token = credential.identityToken.flatMap({ String(data: $0, encoding: .utf8) }) else {
            complete(.failure(APIError(message: "Apple sign-in returned an incomplete response. Please retry.")))
            return
        }
        complete(.success(Proof(state: credential.state ?? "", identityToken: token)))
    }
    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        if (error as? ASAuthorizationError)?.code == .canceled { complete(.failure(CancellationError())) }
        else { complete(.failure(APIError(message: "Apple sign-in could not finish. Please retry."))) }
    }
    private func complete(_ result: Swift.Result<Proof, Error>) {
        let pending = continuation
        continuation = nil
        controller = nil
        pending?.resume(with: result)
    }
}

/// Apple's own control allows an async Stack challenge before presenting authorization.
struct AppleAccountButton: UIViewRepresentable {
    var style: ASAuthorizationAppleIDButton.Style = .black
    var disabled = false
    var action: (UIWindow) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .continue, style: style)
        button.cornerRadius = 16
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

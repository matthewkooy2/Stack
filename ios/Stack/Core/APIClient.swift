import Foundation

struct APIError: LocalizedError {
    let message: String
    var status: Int = 0
    var failureCategory: String? = nil
    var errorDescription: String? { message }
    var isUnauthorized: Bool { status == 401 }
}

/// The Stack HTTP API: `POST /function/<name>` with a bearer token, answering `{ok, data: {result}}`.
final class APIClient {
    let origin: URL
    private(set) var token: String
    private let session: URLSession
    private(set) var sessionGeneration = 0
    private var linkedinTasks: Set<String> = []
    let linkedinSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }()
    func isLinkedInCall(_ name: String, _ args: JSON) -> Bool {
        name.hasPrefix("agent_linkedin_") || linkedinTasks.contains(args["id"].string)
    }
    private var account: String { "token@" + origin.absoluteString }

    init(origin: URL, session: URLSession = .shared) {
        self.origin = origin
        self.session = session
        self.token = Keychain.read(account: "token@" + origin.absoluteString) ?? ""
    }

    static var configuredOrigin: URL {
        let fallback = URL(string: "http://127.0.0.1:8000")!
        let value = Bundle.main.object(forInfoDictionaryKey: "StackAPIBaseURL") as? String ?? ""
        return value.isEmpty ? fallback : (URL(string: value) ?? fallback)
    }

    var hasSession: Bool { !token.isEmpty }

    func adopt(token: String) {
        sessionGeneration += 1
        self.token = token
        Keychain.write(token, account: account)
    }

    func forget() {
        sessionGeneration += 1
        token = ""
        Keychain.delete(account: account)
    }

    /// Raw request. Returns the envelope's `data`.
    func post(_ path: String, _ body: JSON, authenticated: Bool = true, timeout: TimeInterval = 25, linkedin: Bool = false) async throws -> JSON {
        let generation = sessionGeneration
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = linkedin ? .greatestFiniteMagnitude : timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await (linkedin ? linkedinSession : session).data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch let error as URLError {
            guard linkedin || generation == sessionGeneration else { throw CancellationError() }
            throw APIError(message: "Cannot reach Stack. Check your connection and retry.",
                           failureCategory: Self.safeNetworkCategory(error.code))
        }
        catch {
            guard linkedin || generation == sessionGeneration else { throw CancellationError() }
            throw APIError(message: "Cannot reach Stack. Check your connection and retry.",
                           failureCategory: "network transport")
        }
        guard linkedin || (generation == sessionGeneration && !Task.isCancelled) else { throw CancellationError() }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
            throw APIError(message: "Stack returned an invalid response. Please retry.", status: status)
        }
        if !(200..<300).contains(status) || json["ok"] == .bool(false) {
            var message = json["error"]["message"].string
            if message.isEmpty { message = json["detail"].string }
            if message.isEmpty { message = "Request failed. Please try again." }
            throw APIError(message: message, status: status)
        }
        return json["data"]
    }

    /// A personal API function. Throws the server's `error` string when the function reports one.
    @discardableResult
    func call(_ name: String, _ args: JSON = [:], timeout: TimeInterval = 25, linkedin: Bool = false) async throws -> JSON {
        let data = try await post("/function/" + name, args, timeout: timeout, linkedin: linkedin || isLinkedInCall(name, args))
        let result = data["result"]
        if result["kind"].string == "linkedin" { linkedinTasks.insert(result["id"].string) }
        if case .string(let message) = result["error"], !message.isEmpty {
            throw APIError(message: message, failureCategory: "Stack API response")
        }
        return result
    }

    private static func safeNetworkCategory(_ code: URLError.Code) -> String {
        switch code {
        case .timedOut: return "network timeout"
        case .notConnectedToInternet: return "offline"
        case .cannotFindHost, .dnsLookupFailed: return "host lookup failure"
        case .cannotConnectToHost: return "host connection failure"
        case .networkConnectionLost: return "connection lost"
        case .secureConnectionFailed: return "TLS failure"
        default: return "network transport"
        }
    }

    func authenticate(username: String, password: String, signUp: Bool) async throws {
        let identity: JSON = ["type": "username", "value": .string(username.trimmingCharacters(in: .whitespaces).lowercased())]
        let credential: JSON = ["type": "password", "password": .string(password)]
        let body: JSON = signUp ? ["identities": [identity], "credential": credential] : ["identity": identity, "credential": credential]
        let data = try await post(signUp ? "/user/register" : "/user/login", body, authenticated: false)
        let issued = data["token"].string
        guard !issued.isEmpty else { throw APIError(message: "Sign-in did not return a session. Please try again.") }
        adopt(token: issued)
    }
}

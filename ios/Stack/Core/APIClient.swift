import Foundation
import OSLog
import UIKit

struct StackRequestTrace {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stack", category: "HTTP")
    private let id: String
    private let route: String
    private let started = ProcessInfo.processInfo.systemUptime
    private let client: String

    @MainActor
    init(route: String) {
        let requestID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        id = requestID
        self.route = route
        let info = Bundle.main.infoDictionary ?? [:]
        let metadata = [
            "platform": "swiftui-ios",
            "device": UIDevice.current.model,
            "os": "iOS " + UIDevice.current.systemVersion,
            "version": info["CFBundleShortVersionString"] as? String ?? "",
            "build": info["CFBundleVersion"] as? String ?? "",
        ]
        let encoded = try? JSONEncoder().encode(metadata)
        let metadataJSON = encoded.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        client = metadataJSON
        Self.log.debug("Stack request started id=\(requestID, privacy: .public) route=\(route, privacy: .public) client=\(metadataJSON, privacy: .public)")
    }

    func apply(to request: inout URLRequest) {
        request.setValue(id, forHTTPHeaderField: "X-Request-Id")
        request.setValue(client, forHTTPHeaderField: "X-Stack-Client")
    }

    func finish(_ response: URLResponse? = nil, outcome: String = "response") {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let ray = http?.value(forHTTPHeaderField: "CF-Ray") ?? ""
        let cfRay = ray.range(of: #"^[a-f0-9]{16,32}(?:-[A-Z]{3})?$"#, options: .regularExpression) == nil ? "" : ray
        let ms = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        if status >= 400 || outcome != "response" {
            Self.log.error("Stack request failed id=\(id, privacy: .public) route=\(route, privacy: .public) status=\(status) outcome=\(outcome, privacy: .public) cf_ray=\(cfRay, privacy: .public) elapsed_ms=\(ms) client=\(client, privacy: .public)")
        } else {
            Self.log.debug("Stack request finished id=\(id, privacy: .public) route=\(route, privacy: .public) status=\(status) cf_ray=\(cfRay, privacy: .public) elapsed_ms=\(ms)")
        }
    }
}

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
    let linkedinSession: URLSession

    private static func makeLinkedInSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = .greatestFiniteMagnitude
        configuration.timeoutIntervalForResource = .greatestFiniteMagnitude
        return URLSession(configuration: configuration)
    }

    func isLinkedInCall(_ name: String, _ args: JSON) -> Bool {
        name.hasPrefix("agent_linkedin_") || linkedinTasks.contains(args["id"].string)
    }
    private var account: String { "token@" + origin.absoluteString }

    init(origin: URL, session: URLSession = .shared, linkedinSession: URLSession? = nil) {
        self.origin = origin
        self.session = session
        self.linkedinSession = linkedinSession ?? Self.makeLinkedInSession()
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
        let trace = await StackRequestTrace(route: path)
        guard linkedin || (generation == sessionGeneration && !Task.isCancelled) else {
            trace.finish(outcome: "cancelled")
            throw CancellationError()
        }
        var request = URLRequest(url: origin.appendingPathComponent(path))
        trace.apply(to: &request)
        request.httpMethod = "POST"
        request.timeoutInterval = linkedin ? .greatestFiniteMagnitude : timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, !token.isEmpty { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await (linkedin ? linkedinSession : session).data(for: request) }
        catch is CancellationError { trace.finish(outcome: "cancelled"); throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { trace.finish(outcome: "cancelled"); throw CancellationError() }
        catch let error as URLError {
            trace.finish(outcome: Self.safeNetworkCategory(error.code))
            guard linkedin || generation == sessionGeneration else { throw CancellationError() }
            throw APIError(message: "Cannot reach Stack. Check your connection and retry.",
                           failureCategory: Self.safeNetworkCategory(error.code))
        }
        catch {
            trace.finish(outcome: "network transport")
            guard linkedin || generation == sessionGeneration else { throw CancellationError() }
            throw APIError(message: "Cannot reach Stack. Check your connection and retry.",
                           failureCategory: "network transport")
        }
        guard linkedin || (generation == sessionGeneration && !Task.isCancelled) else {
            trace.finish(response, outcome: "cancelled")
            throw CancellationError()
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard let json = try? JSONDecoder().decode(JSON.self, from: data) else {
            trace.finish(response, outcome: "invalid_response")
            throw APIError(message: "Stack returned an invalid response. Please retry.", status: status)
        }
        if !(200..<300).contains(status) || json["ok"] == .bool(false) {
            trace.finish(response, outcome: "request_failed")
            var message = json["error"]["message"].string
            if message.isEmpty { message = json["detail"].string }
            if message.isEmpty { message = "Request failed. Please try again." }
            throw APIError(message: message, status: status)
        }
        trace.finish(response, outcome: json["data"]["result"]["error"].string.isEmpty ? "response" : "application_error")
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

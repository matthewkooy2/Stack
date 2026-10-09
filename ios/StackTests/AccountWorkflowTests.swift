import XCTest
@testable import Stack

// MARK: - Test doubles

/// Answers every request from a closure, so API and store behaviour can be tested without a network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(request)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubProtocol.self]
    return URLSession(configuration: configuration)
}

/// Parses a JSON document written inline in a test.
func parse(_ text: String) -> JSON {
    try! JSONDecoder().decode(JSON.self, from: Data(text.utf8))
}

func envelope(_ result: JSON) -> Data {
    try! JSONEncoder().encode(JSON.object(["ok": true, "data": ["result": result]]))
}

// MARK: - API client

final class APIClientTests: XCTestCase {
    private let origin = URL(string: "https://stack.example.com")!

    override func setUp() {
        StubProtocol.handler = nil
        StubProtocol.seen = []
    }

    func testCallReturnsTheResultAndSendsTheBearerToken() async throws {
        let api = APIClient(origin: origin, session: stubSession())
        api.adopt(token: "token-1")
        defer { api.forget() }
        StubProtocol.handler = { _ in (200, envelope(["answer": 42])) }
        let result = try await api.call("bootstrap")
        XCTAssertEqual(result["answer"].int, 42)
        XCTAssertEqual(StubProtocol.seen.last?.url?.path, "/function/bootstrap")
        XCTAssertEqual(StubProtocol.seen.last?.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
    }

    func testServerErrorStringBecomesAnError() async {
        let api = APIClient(origin: origin, session: stubSession())
        StubProtocol.handler = { _ in (200, envelope(["error": "Choose a title and a future date."])) }
        do {
            _ = try await api.call("save_reminder")
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Choose a title and a future date.")
        }
    }

    func testUnauthorizedIsRecognised() async {
        let api = APIClient(origin: origin, session: stubSession())
        StubProtocol.handler = { _ in (401, Data(#"{"ok":false,"error":{"message":"Expired"}}"#.utf8)) }
        do {
            _ = try await api.call("bootstrap")
            XCTFail("expected an error")
        } catch let failure as APIError {
            XCTAssertTrue(failure.isUnauthorized)
            XCTAssertEqual(failure.message, "Expired")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnreachableServerHasAReadableMessage() async {
        let api = APIClient(origin: origin, session: stubSession())
        StubProtocol.handler = { _ in throw URLError(.cannotConnectToHost) }
        do {
            _ = try await api.call("bootstrap")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Cannot reach Stack"))
        }
    }

    func testAuthenticateStoresTheIssuedToken() async throws {
        let api = APIClient(origin: origin, session: stubSession())
        defer { api.forget() }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/user/login")
            return (200, try JSONEncoder().encode(JSON.object(["ok": true, "data": ["token": "abc"]])))
        }
        try await api.authenticate(username: " Sam ", password: "password1", signUp: false)
        XCTAssertEqual(api.token, "abc")
        XCTAssertTrue(api.hasSession)
    }
}

// MARK: - Google sign-in

final class GoogleSignInTests: XCTestCase {
    private let valid = "https://accounts.google.com/o/oauth2/v2/auth?scope=openid%20email%20profile&code_challenge_method=S256&state=x"

    func testAcceptsGoogleAuthorizationWithTheExpectedScopes() throws {
        XCTAssertNoThrow(try GoogleSignIn.validate(valid))
    }

    func testRejectsOtherHostsSchemesAndPorts() {
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "accounts.google.com", with: "evil.example")))
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "https:", with: "http:")))
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "accounts.google.com", with: "accounts.google.com:8443")))
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "https://", with: "https://user@")))
    }

    func testRejectsBroaderPermissionsAndWeakChallenges() {
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "openid%20email%20profile", with: "openid%20email%20profile%20gmail")))
        XCTAssertThrowsError(try GoogleSignIn.validate(valid.replacingOccurrences(of: "S256", with: "plain")))
        XCTAssertThrowsError(try GoogleSignIn.validate(valid + "&scope=email"))
    }
}

// MARK: - Models and forms

final class AccountStateTests: XCTestCase {
    private let sample: JSON = parse("""
    {
      "user_id": "u1",
      "profile": {"name": "Sam", "role": "Designer", "location": "NYC", "mode": "Remote", "notifications": true,
                  "graduation_month": "2027-05", "available_from": "",
                  "preferences": {"stage": "Student", "years": null, "modes": ["Remote"], "salary_min": 90000,
                                  "salary_period": "year", "exclude_companies": ["Acme", "Initech"], "soft": ["pay"]}},
      "applications": [{"id": "a1", "status": "Ready to apply", "created_at": 100, "resume_id": "",
                        "job": {"id": "j1", "title": "Engineer", "company": "Forma"},
                        "tailor": {"resume_id": "r1", "resume_name": "Resume.pdf", "ready": true}, "history": []}],
      "resumes": [{"id": "r1", "name": "Resume.pdf", "size": 10, "created_at": 1, "details_status": "Confirmed",
                   "format": {"kind": "upload", "label": "Your LaTeX"}, "processing": {"source": {"status": "completed"}}}],
      "agents": {"active": 1, "attention": 2, "runs": [{"id": "t1", "status": "review", "attention": true}],
                 "features": [{"key": "tailoring", "title": "Tailoring", "state": "ready", "kinds": ["resume"],
                               "checks": [{"key": "latex", "label": "LaTeX", "ok": false, "optional": false,
                                           "fix": "Upload", "action": "resume"}]}]},
      "tailored_resumes": [{"id": "t1", "name": "Tailored", "job_title": "Engineer", "company": "Forma", "pages": 1}]
    }
    """)

    func testReadsProfileApplicationsAndAgents() {
        let account = AccountState(raw: sample)
        XCTAssertEqual(account.userID, "u1")
        XCTAssertEqual(account.graduationMonth, "2027-05")
        XCTAssertEqual(account.applications.first?.tailorResumeID, "r1")
        XCTAssertEqual(account.applications.first?.tailorReady, true)
        XCTAssertEqual(account.activeRunCount, 1)
        XCTAssertEqual(account.attentionRunCount, 2)
        XCTAssertEqual(account.feature(forKind: "resume")?.missingRequired.first?.action, "resume")
        XCTAssertTrue(account.hasLatex("r1"))
        XCTAssertEqual(account.tailored.first?.jobTitle, "Engineer")
    }

    func testPreferenceFormRoundTripsForTheServer() {
        let form = PreferenceForm(AccountState(raw: sample).preferences)
        XCTAssertEqual(form.stage, "Student")
        XCTAssertEqual(form.years, "")
        XCTAssertEqual(form.salaryMin, "90000")
        XCTAssertEqual(form.excludeCompanies, "Acme, Initech")
        let json = form.json
        XCTAssertEqual(json["modes"].strings, ["Remote"])
        XCTAssertEqual(json["exclude_companies"].string, "Acme, Initech")
        XCTAssertEqual(json["soft"].strings, ["pay"])
    }
}

final class AgentLabelTests: XCTestCase {
    func testAttentionAndActiveTones() {
        XCTAssertEqual(AgentLabels.tone(for: "review"), .attention)
        XCTAssertEqual(AgentLabels.tone(for: "running"), .active)
        XCTAssertEqual(AgentLabels.tone(for: "completed"), .done)
        XCTAssertEqual(AgentLabels.tone(for: "cancelled"), .quiet)
    }

    func testStoppedTaskWithNothingToAnswerSaysTryAgain() {
        XCTAssertEqual(AgentLabels.runLabel(["status": "needs_input", "has_requests": false]), "Stopped · try again")
        XCTAssertEqual(AgentLabels.runLabel(["status": "needs_input", "has_requests": true]), "Needs your answers")
        XCTAssertEqual(AgentLabels.runLabel(["status": "blocked", "needs_resume_review": true]), "Needs your LaTeX")
    }
}

// MARK: - Calendar

final class ApplicationCalendarTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "UTC")!
        return value
    }

    func testDayKeyUsesTheCalendarsZone() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(ApplicationCalendar.dayKey(date, calendar: calendar), "2023-11-14")
    }

    func testActivityRemindersAndInterviewsLandOnTheirDays() {
        let application = Application(parse("""
        {"id": "a1", "created_at": 1700000000, "status": "Submitted",
         "job": {"title": "Engineer", "company": "Forma"},
         "history": [{"status": "Submitted", "at": 1700086400, "source": "User confirmed"}]}
        """))
        let reminder = Reminder(parse("""
        {"id": "r1", "target_type": "application", "target_id": "a1", "title": "Follow up", "due_at": 1700172800, "done": false}
        """))
        let interview = parse("""
        {"summary": "Panel", "application_id": "a1", "start": {"dateTime": "2023-11-17T15:00:00Z"}}
        """)
        let result = ApplicationCalendar.build(applications: [application], reminders: [reminder], interviews: [interview], calendar: calendar)
        XCTAssertEqual(result.activity["2023-11-14"], ["Forma · Engineer"])
        XCTAssertEqual(result.activity["2023-11-15"], ["Forma · Engineer · Submitted"])
        XCTAssertEqual(result.events["2023-11-16"]?.first?.title, "Follow up")
        XCTAssertEqual(result.events["2023-11-17"]?.first?.company, "Forma")
    }

    func testStreakCountsConsecutiveDaysEndingToday() {
        let today = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = today.addingTimeInterval(-86_400)
        let activity = [
            ApplicationCalendar.dayKey(today, calendar: calendar): ["a"],
            ApplicationCalendar.dayKey(yesterday, calendar: calendar): ["b"],
        ]
        XCTAssertEqual(ApplicationCalendar.streak(activity: activity, today: today, calendar: calendar), 2)
        XCTAssertEqual(ApplicationCalendar.streak(activity: [:], today: today, calendar: calendar), 0)
    }
}

// MARK: - Store

@MainActor
final class AppStoreSessionTests: XCTestCase {
    private let origin = URL(string: "https://stack.example.com")!

    override func setUp() async throws {
        StubProtocol.handler = nil
        StubProtocol.seen = []
    }

    private func store() -> AppStore {
        let api = APIClient(origin: origin, session: stubSession())
        api.forget()
        let store = AppStore(api: api)
        store.openExternalURL = { _ in true }
        store.isForeground = { true }
        return store
    }

    func testSignInLoadsTheAccountAndSignOutClearsIt() async {
        let store = store()
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path == "/user/login" {
                return (200, try JSONEncoder().encode(JSON.object(["ok": true, "data": ["token": "t"]])))
            }
            switch path {
            case "/function/auth_google_status": return (200, envelope(["username": "sam", "google": false]))
            case "/function/agent_admission": return (200, envelope(["admitted": true]))
            case "/function/bootstrap": return (200, envelope(["user_id": "u1", "profile": ["name": "Sam"]]))
            default: return (404, Data(#"{"ok":false}"#.utf8))
            }
        }
        await store.signIn(username: "sam", password: "password1", signUp: false)
        XCTAssertEqual(store.phase, .ready)
        XCTAssertEqual(store.account.name, "Sam")
        XCTAssertEqual(store.googleInfo["username"].string, "sam")

        await store.signOut()
        XCTAssertEqual(store.phase, .signedOut)
        XCTAssertFalse(store.account.isLoaded)
        XCTAssertFalse(store.api.hasSession)
    }

    func testAccountWithoutAnInvitationWaitsAtTheGate() async {
        let store = store()
        StubProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/user/login": return (200, try JSONEncoder().encode(JSON.object(["ok": true, "data": ["token": "t"]])))
            case "/function/agent_admission": return (200, envelope(["admitted": false]))
            default: return (404, Data(#"{"ok":false}"#.utf8))
            }
        }
        await store.signIn(username: "sam", password: "password1", signUp: false)
        XCTAssertEqual(store.phase, .admission)
        XCTAssertFalse(store.account.isLoaded)
        await store.signOut()
    }

    func testPersonalCallsAreRefusedBeforeSignIn() async {
        let store = store()
        do {
            _ = try await store.call("bootstrap")
            XCTFail("expected the call to be dropped")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(StubProtocol.seen.isEmpty)
    }

    func testLateAnswerAfterSignOutIsDropped() async {
        let store = store()
        StubProtocol.handler = { request in
            switch request.url?.path ?? "" {
            case "/user/login": return (200, try JSONEncoder().encode(JSON.object(["ok": true, "data": ["token": "t"]])))
            case "/function/agent_admission": return (200, envelope(["admitted": true]))
            case "/function/bootstrap": return (200, envelope(["user_id": "u1", "profile": ["name": "Sam"]]))
            default: return (200, envelope(["late": true]))
            }
        }
        await store.signIn(username: "sam", password: "password1", signUp: false)
        let pending = Task { try await store.call("agent_settings") }
        await store.signOut()
        do {
            _ = try await pending.value
            XCTFail("a result for the previous session must not be delivered")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

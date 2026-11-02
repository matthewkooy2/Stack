import XCTest
@testable import Stack

@MainActor
final class PrepCoachingTests: XCTestCase {
    private var retainedStore: AppStore?
    private let row: JSON = ["id": "synthetic-session", "revision": 1,
        "data": ["problem_id": "project", "answer": "Older server draft", "canvas": [:],
                 "behavioral": ["index": 0, "plan": ["project"], "history": [], "complete": false]]]

    private func model(root: URL? = nil) -> PrepModel {
        let directory = root ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let api = APIClient(origin: URL(string: "https://coaching-test.invalid")!, session: stubSession())
        let store = AppStore(api: api); store.phase = .ready
        store.account = AccountState(raw: ["user_id": "synthetic-owner"]); retainedStore = store
        let model = PrepModel(drafts: PrepDraftStore(root: directory)); model.bind(store)
        model.current = row; model.page = .review
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return model
    }

    nonisolated private func body(_ request: URLRequest) throws -> JSON {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count))
            }
        }
        return try JSONDecoder().decode(JSON.self, from: data)
    }

    func testDoubleTapSendsOneVisibleSnapshotAndKeepsNewerEditsWithTheirOwnDraft() async throws {
        let model = model(); model.edited("  Exact visible answer.\nSecond line.  ")
        let requested = expectation(description: "model request")
        let release = DispatchSemaphore(value: 0)
        var calls = 0, packet: JSON = [:]
        StubProtocol.seen = []
        StubProtocol.handler = { request in
            let args = try self.body(request)
            switch request.url?.lastPathComponent {
            case "prep_catalog": return (200, envelope(["problems": [["id": "project"]]]))
            case "prep_coach":
                calls += 1; requested.fulfill(); _ = release.wait(timeout: .now() + 5)
                XCTAssertEqual(args["data"]["answer"].string, "  Exact visible answer.\nSecond line.  ")
                XCTAssertTrue(args["revision"].isNull)
                return (200, envelope(["id": "synthetic-session", "revision": 9, "data": args["data"], "feedback": ["summary": "Feedback for submitted text"]]))
            case "prep_save_coaching":
                packet = args["submission"]
                return (200, envelope(["id": "synthetic-session", "revision": 10, "data": packet["data"], "feedback": []]))
            case "prep_sessions": return (200, envelope(["sessions": []]))
            case "transcription_list": return (200, envelope(["runtime": [:]]))
            default: XCTFail("Unexpected prerequisite: \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil; release.signal() }
        let pending = Task { await model.coach() }
        await fulfillment(of: [requested], timeout: 3)
        await model.coach()
        model.edited("Newer edits while inference is pending")
        release.signal(); await pending.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(model.draft, "Newer edits while inference is pending")
        XCTAssertEqual(model.page, .review)
        XCTAssertEqual(packet["data"]["answer"].string, "  Exact visible answer.\nSecond line.  ")
        XCTAssertEqual(packet["feedback"]["summary"].string, "Feedback for submitted text")
    }

    func testFailedPersistenceShowsFeedbackAndReopensTheTypedDraftWithoutRepeatingInference() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = model(root: root); model.edited("My typed answer")
        let serverRow = row
        var inferenceCalls = 0, failSave = true
        StubProtocol.handler = { request in
            let args = try self.body(request)
            switch request.url?.lastPathComponent {
            case "prep_catalog": return (200, envelope(["problems": [["id": "project"]]]))
            case "prep_coach":
                inferenceCalls += 1
                return (200, envelope(["id": "synthetic-session", "revision": 7, "data": args["data"], "feedback": ["summary": "Available feedback"]]))
            case "prep_save_coaching":
                if failSave { return (500, Data()) }
                return (200, envelope(["id": "synthetic-session", "revision": 8, "data": args["submission"]["data"]]))
            case "prep_get": return (200, envelope(serverRow))
            case "prep_sessions": return (200, envelope(["sessions": []]))
            case "transcription_list": return (200, envelope(["runtime": [:]]))
            default: XCTFail("Unexpected request \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil }
        await model.coach()
        XCTAssertEqual(model.page, .coaching); XCTAssertEqual(model.feedback["summary"].string, "Available feedback")
        XCTAssertTrue(model.hasUnsavedCoaching)
        let reopened = PrepModel(drafts: PrepDraftStore(root: root)); reopened.bind(try XCTUnwrap(retainedStore))
        await reopened.openSession("synthetic-session")
        XCTAssertEqual(reopened.draft, "My typed answer"); XCTAssertTrue(reopened.hasUnsavedCoaching)
        failSave = false; await reopened.retryCoachingSave()
        XCTAssertEqual(inferenceCalls, 1); XCTAssertFalse(reopened.hasUnsavedCoaching)
        XCTAssertNil(PrepDraftStore(root: root).load(owner: "other-owner", session: "synthetic-session", index: 0))
    }

    func testFailedInferenceKeepsTypedAnswerAndLocalStorageFailureCannotBlockCoaching() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: root) // a file cannot be used as the draft directory
        let model = model(root: root); model.edited("Keep this answer")
        var failInference = true
        StubProtocol.handler = { request in
            let args = try self.body(request)
            switch request.url?.lastPathComponent {
            case "prep_catalog": return (200, envelope(["problems": [["id": "project"]]]))
            case "prep_coach":
                if failInference { return (500, Data()) }
                return (200, envelope(["id": "synthetic-session", "revision": 1, "data": args["data"], "feedback": ["summary": "Feedback despite local storage failure"]]))
            case "prep_save_coaching": return (200, envelope(["id": "synthetic-session", "revision": 2, "data": args["submission"]["data"]]))
            case "prep_sessions": return (200, envelope(["sessions": []]))
            case "transcription_list": return (200, envelope(["runtime": [:]]))
            default: XCTFail("Unexpected request \(request.url!)"); return (500, Data())
            }
        }
        defer { StubProtocol.handler = nil }
        await model.coach(); XCTAssertEqual(model.page, .review); XCTAssertEqual(model.draft, "Keep this answer")
        failInference = false; await model.coach()
        XCTAssertEqual(model.page, .coaching); XCTAssertEqual(model.feedback["summary"].string, "Feedback despite local storage failure")
        XCTAssertFalse(model.error.isEmpty)
    }

    func testLateTranscriptionDoesNotReplaceTypedText() async throws {
        let model = model(); model.recording = ["id": "synthetic-recording", "status": "queued"]
        let requested = expectation(description: "transcription request"), release = DispatchSemaphore(value: 0)
        StubProtocol.handler = { request in
            if request.url?.lastPathComponent == "transcription_get" {
                requested.fulfill(); _ = release.wait(timeout: .now() + 5)
                return (200, envelope(["id": "synthetic-recording", "status": "completed", "transcript": "Late transcription"]))
            }
            return (200, envelope(["runtime": [:]]))
        }
        defer { StubProtocol.handler = nil; release.signal() }
        let pending = Task { await model.poll() }
        await fulfillment(of: [requested], timeout: 3)
        model.edited("New typed text"); release.signal(); await pending.value
        XCTAssertEqual(model.draft, "New typed text")
    }
}

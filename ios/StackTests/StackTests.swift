import XCTest
@testable import Stack

final class JSONTests: XCTestCase {
    func testRoundTripKeepsUnknownKeys() throws {
        let source = #"{"a":1,"b":[true,null,"x"],"c":{"d":2.5}}"#
        let value = try JSONDecoder().decode(JSON.self, from: Data(source.utf8))
        let again = try JSONDecoder().decode(JSON.self, from: JSONEncoder().encode(value))
        XCTAssertEqual(value, again)
        XCTAssertEqual(again["c"]["d"].double, 2.5)
        XCTAssertTrue(again["b"][0].bool)
        XCTAssertTrue(again["b"][1].isNull)
    }

    func testSettingNullRemovesKey() {
        var value: JSON = ["a": 1, "b": 2]
        value["a"] = .null
        XCTAssertEqual(value.object.keys.sorted(), ["b"])
    }

    func testMissingKeysReadAsEmpty() {
        let value: JSON = [:]
        XCTAssertEqual(value["x"]["y"].string, "")
        XCTAssertEqual(value["x"].int, 0)
        XCTAssertFalse(value["x"].bool)
    }
}

final class PrepCodecTests: XCTestCase {
    private let available: Set<String> = ["project", "disagreement", "setback"]
    private let bundled = [PrepQuestion(["id": "project-2", "title": "t", "prompt": "Own it."])]

    func testNumberedVariantsFallBackToTheBaseQuestion() {
        XCTAssertEqual(PrepCodec.actualID("project-2", available: available), "project")
        XCTAssertEqual(PrepCodec.actualID("setback", available: available), "setback")
        XCTAssertEqual(PrepCodec.actualID("unknown-9", available: available), "unknown")
    }

    func testEncodeThenDecodeRestoresTheWorkflow() throws {
        let behavioral: JSON = ["focus": "Mixed questions", "plan": ["project-2"], "index": 0, "history": [], "complete": false]
        let data: JSON = ["problem_id": "project-2", "notes": "mine", "canvas": ["keep": 1], "behavioral": behavioral]
        let encoded = try PrepCodec.encode(data, available: available, bundled: bundled)
        XCTAssertEqual(encoded["problem_id"].string, "project")
        XCTAssertEqual(encoded["canvas"]["keep"].int, 1)
        XCTAssertTrue(encoded["notes"].string.hasPrefix("Practice question: Own it."))

        let decoded = PrepCodec.decode(["id": "s1", "data": encoded])
        XCTAssertEqual(decoded["data"]["problem_id"].string, "project-2")
        XCTAssertEqual(decoded["data"]["behavioral"], behavioral)
        XCTAssertEqual(decoded["data"]["notes"].string, "mine")
        XCTAssertTrue(decoded["data"]["canvas"][PrepCodec.marker].isNull)
        XCTAssertEqual(decoded["data"]["canvas"]["keep"].int, 1)
    }

    func testNonBehavioralSessionsPassThrough() throws {
        let data: JSON = ["problem_id": "two-sum", "code": "x"]
        XCTAssertEqual(try PrepCodec.encode(data, available: available, bundled: bundled), data)
        XCTAssertEqual(PrepCodec.decode(["data": data]), ["data": data])
    }

    func testUnavailableQuestionIsRejected() {
        let data: JSON = ["problem_id": "nope", "behavioral": ["index": 0]]
        XCTAssertThrowsError(try PrepCodec.encode(data, available: available, bundled: bundled))
    }

    func testOversizedSessionIsRejected() {
        let big = String(repeating: "a", count: PrepCodec.storageLimit)
        let data: JSON = ["problem_id": "project", "behavioral": ["history": [.string(big)]]]
        XCTAssertThrowsError(try PrepCodec.encode(data, available: available, bundled: bundled))
    }

    func testBundledCatalogIsPresent() {
        // The catalog resource ships inside the app bundle, which hosts the unit tests.
        XCTAssertFalse(PrepCodec.bundledCatalog().isEmpty)
    }
}

final class PrepFlowTests: XCTestCase {
    func testPageDepthsOrderTheSetupToCoachingPath() {
        let path: [PrepPage] = [.home, .type, .focus, .length, .question, .answer, .review, .processing, .coaching, .complete]
        XCTAssertEqual(path.map(\.depth), path.map(\.depth).sorted())
    }

    func testPlansCycleThroughFocusBases() {
        XCTAssertEqual(PrepFocus.mixed.bases, ["project", "disagreement", "setback"])
        XCTAssertEqual(PrepFocus.teamwork.bases, ["disagreement"])
    }
}

final class RecordingStoreTests: XCTestCase {
    func testClientIDsMatchTheServerContract() throws {
        let id = RecordingStore.newClientID()
        XCTAssertNotNil(id.range(of: "^[a-zA-Z0-9_-]{12,80}$", options: .regularExpression))
        XCTAssertThrowsError(try RecordingStore.url(owner: "owner", clientID: "short"))
    }
}

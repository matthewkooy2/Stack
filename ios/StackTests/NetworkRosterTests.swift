import XCTest
@testable import Stack

/// Manual suite: not added to native-core selection or any CI gate.
@MainActor
final class NetworkRosterTests: XCTestCase {
    private let response: JSON = ["contacts": [["id": "actual-1", "name": "Ada Example", "role": "Engineer", "company": "Example Co"]]]

    func testMapsOnlyRealContactEndpointRowsWithoutInventingMissingRoleOrCompany() {
        let rows = NetworkContact.contacts(from: ["people": [["id": "sample", "name": "Catalog Person"]],
            "contacts": [["id": "real", "name": "  Ada Example  "], ["id": "real", "name": "Duplicate"], ["name": "Missing ID"]]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.name, "Ada Example")
        XCTAssertEqual(rows.first?.initials, "AE")
        XCTAssertEqual(rows.first?.role, "")
        XCTAssertEqual(rows.first?.company, "")
    }

    func testSuccessfulEmptyResultIsAnEmptyRosterNotSamplePeople() async {
        let model = NetworkRoster()
        await model.load { ["contacts": []] }
        XCTAssertTrue(model.loaded)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.contacts.isEmpty)
        XCTAssertTrue(model.error.isEmpty)
    }

    #if DEBUG
    func testGalleryRetainsMutationsAcrossReadsAndIsolatesConcurrentPreviews() async throws {
        let first = ScreenFlowFixture(flow: "collections-empty")
        let saved = try await first.store.call("agent_save_contact", ["data": ["name": "Casey", "email": "casey@example.invalid"]])
        let id = try XCTUnwrap(saved["contacts"].array.first?["id"].string)
        let second = ScreenFlowFixture(flow: "collections-two")
        _ = try await first.store.call("agent_stop_contact", ["id": .string(id)])
        let csv = "name,email,relationship\nCasey,casey@example.invalid,Duplicate\nMorgan,morgan@example.invalid,\"Met at a talk, last month\""
        _ = try await first.store.call("agent_import_contacts", ["content": .string(csv)])
        let rows = try await first.store.call("agent_contacts")["contacts"].array
        XCTAssertEqual(rows.map { $0["name"].string }, ["Casey", "Morgan"])
        let casey = try XCTUnwrap(rows.first { $0["id"].string == id })
        let morgan = try XCTUnwrap(rows.first { $0["name"].string == "Morgan" })
        XCTAssertTrue(casey["stopped"].bool)
        XCTAssertEqual(morgan["relationship"].string, "Met at a talk, last month")
        let other = try await second.store.call("agent_contacts")["contacts"].array
        XCTAssertEqual(other.map { $0["name"].string }, ["Ada Park", "Mina Ellis"])
        let file = try await second.store.call("read_resume", ["id": "resume-2"])
        let bytes = try XCTUnwrap(Data(base64Encoded: file["content"].string))
        XCTAssertEqual(file["name"].string, "Elm Studio Research lead.docx")
        XCTAssertNotNil(bytes.range(of: Data("word/document.xml".utf8)))
    }
    #endif

    func testFailedInitialLoadIsRetryableAndNotReportedAsSuccessfulEmpty() async {
        let model = NetworkRoster()
        await model.load { throw APIError(message: "Offline") }
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.error, "Offline")
        await model.load { response }
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.contacts.first?.id, "actual-1")
        XCTAssertTrue(model.error.isEmpty)
    }

    func testFailedRefreshKeepsLastRealRoster() async {
        let model = NetworkRoster()
        await model.load { response }
        await model.load { throw APIError(message: "Offline") }
        XCTAssertEqual(model.contacts.first?.id, "actual-1")
        XCTAssertTrue(model.loaded)
        XCTAssertEqual(model.error, "Offline")
    }

    func testSessionResetDropsLateReadAndClearsCachedContactData() async {
        let model = NetworkRoster()
        await model.load { response }
        await model.load {
            model.reset()
            return response
        }
        XCTAssertTrue(model.contacts.isEmpty)
        XCTAssertFalse(model.loaded)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.error.isEmpty)
    }

    func testOverlappingRefreshDoesNotStartAnotherRead() async {
        let model = NetworkRoster()
        var reads = 0
        await model.load {
            reads += 1
            await model.load {
                reads += 1
                return [:]
            }
            return response
        }
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.contacts.first?.id, "actual-1")
    }
}

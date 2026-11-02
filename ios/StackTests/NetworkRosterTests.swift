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

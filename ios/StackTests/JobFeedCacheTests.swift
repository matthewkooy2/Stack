import XCTest
@testable import Stack

final class JobFeedCacheTests: XCTestCase {
    func testRestoredMatchesRespectAccountPreferencesDecisionsAndExpiry() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let cache = JobFeedCache(file: file, now: { now })
        defer { cache.remove() }
        let origin = URL(string: "https://stack.invalid")!
        let account = AccountState(raw: ["user_id": "swe-user", "profile": ["role": "Software engineer"],
                                         "saved_search": ["filters": ["levels": ["Entry-level"]]]])
        let context = JobFeedContext(origin: origin, account: account)
        let jobs = (0..<30).map { index in
            Job(["id": .string("swe-\(index)"), "title": "Software Engineer", "active": true,
                 "checked_at": .number(now.timeIntervalSince1970)])
        }
        cache.write(["next_cursor": "old-cursor"], jobs: jobs, for: context)
        let restored = JobFeedCache(file: file, now: { now }).read(for: context, decided: ["swe-0"])
        XCTAssertEqual(restored?["jobs"].array.count, 24)
        XCTAssertEqual(restored?["jobs"][0]["id"].string, "swe-1")
        XCTAssertEqual(restored?["next_cursor"].string, "")
        for key in ["role", "location", "mode", "graduation_month", "available_from", "preferences"] {
            var changed = account
            changed.raw["profile"][key] = key == "preferences" ? ["salary_min": 120000] : "different"
            XCTAssertNil(cache.read(for: JobFeedContext(origin: origin, account: changed), decided: []))
        }
        var other = account
        other.raw["user_id"] = "other-user"
        XCTAssertNil(cache.read(for: JobFeedContext(origin: origin, account: other), decided: []))
        var search = account
        search.raw["saved_search"]["filters"] = ["levels": ["Senior"]]
        XCTAssertNil(cache.read(for: JobFeedContext(origin: origin, account: search), decided: []))
        XCTAssertNil(cache.read(for: JobFeedContext(origin: URL(string: "https://other.invalid")!, account: account), decided: []))
        now += JobFeedCache.lifetime
        XCTAssertNil(cache.read(for: context, decided: []))
        try Data("broken".utf8).write(to: file)
        XCTAssertNil(cache.read(for: context, decided: []))
    }
}

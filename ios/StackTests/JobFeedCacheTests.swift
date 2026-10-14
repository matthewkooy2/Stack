import XCTest
@testable import Stack

final class JobFeedCacheTests: XCTestCase {
    private var directory: URL!
    private var file: URL!
    private var now = Date(timeIntervalSince1970: 1_800_000_000)
    private let origin = URL(string: "https://stack.invalid")!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("jobs.json")
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }

    private func account() -> AccountState {
        AccountState(raw: ["user_id": "swe-account", "profile": [
            "role": "Software engineer", "location": "Detroit", "mode": "Remote",
            "preferences": ["roles": "Software engineer", "modes": ["Remote"], "employment_types": ["Full-time"]],
            "graduation_month": "2027-05", "available_from": "2027-06",
        ], "saved_search": ["query": "", "filters": ["levels": ["Entry-level"], "confirmed_level": true]]])
    }

    private func result() -> JSON {
        ["jobs": .array((0..<30).map { index in
            ["id": .string("swe-\(index)"), "title": "Junior Software Engineer", "active": true,
             "checked_at": .number(now.timeIntervalSince1970), "expires_at": .number(now.timeIntervalSince1970 + 86400)]
        }), "next_cursor": "old-cursor", "criteria": ["roles": "Software engineer"], "total": 30]
    }

    private func seed() -> JobFeedContext {
        let context = JobFeedContext(origin: origin, account: account())
        let value = result()
        JobFeedCache(file: file, now: { self.now }).write(value, jobs: value["jobs"].array.map(Job.init), for: context)
        return context
    }

    func testRelaunchRestoresOnlyUndecidedMatchingCardsWithoutACursor() {
        let context = seed()
        let relaunched = JobFeedCache(file: file, now: { self.now })
        let cached = relaunched.read(for: context, decided: ["swe-0", "swe-1"])
        XCTAssertEqual(cached?["jobs"].array.count, 23)
        XCTAssertEqual(cached?["jobs"][0]["id"].string, "swe-2")
        XCTAssertEqual(cached?["criteria"]["roles"].string, "Software engineer")
        XCTAssertEqual(cached?["next_cursor"].string, "")
    }

    func testOtherAccountServerAndEveryMatchingInputInvalidateCachedCards() {
        _ = seed()
        let cache = JobFeedCache(file: file, now: { self.now })
        var changes: [AccountState] = []
        for key in ["role", "location", "mode", "graduation_month", "available_from"] {
            var changed = account()
            changed.raw["profile"][key] = "different"
            changes.append(changed)
        }
        for key in ["roles", "location", "modes", "stage", "years", "education", "employment_types", "salary_min", "salary_period", "exclude_companies", "exclude_terms", "soft"] {
            var changed = account()
            changed.raw["profile"]["preferences"][key] = "different"
            changes.append(changed)
        }
        var other = account(); other.raw["user_id"] = "other-account"; changes.append(other)
        var anonymous = account(); anonymous.raw["user_id"] = ""; changes.append(anonymous)
        var query = account(); query.raw["saved_search"]["query"] = "Registered nurse"; changes.append(query)
        var filter = account(); filter.raw["saved_search"]["filters"]["levels"] = ["Internship"]; changes.append(filter)
        for changed in changes {
            XCTAssertNil(cache.read(for: JobFeedContext(origin: origin, account: changed), decided: []))
        }
        XCTAssertNil(cache.read(for: JobFeedContext(origin: URL(string: "https://other.invalid")!, account: account()), decided: []))
    }

    func testExpiredClosedAndStaleListingsAreNeverRestored() {
        let context = seed()
        var value = result()
        var jobs = Array(value["jobs"].array.prefix(4))
        jobs[0]["active"] = false
        jobs[1]["expires_at"] = .number(now.timeIntervalSince1970 - 1)
        jobs[2]["checked_at"] = .number(now.timeIntervalSince1970 - 604801)
        value["jobs"] = .array(jobs)
        let cache = JobFeedCache(file: file, now: { self.now })
        cache.write(value, jobs: jobs.map(Job.init), for: context)
        XCTAssertEqual(cache.read(for: context, decided: [])?["jobs"].array.map { $0["id"].string }, ["swe-3"])
        XCTAssertNil(cache.read(for: context, decided: ["swe-3"]))
    }

    func testCacheExpiresAndMalformedDataFallsBackToTheNetwork() throws {
        let context = seed()
        let cache = JobFeedCache(file: file, now: { self.now })
        now += JobFeedCache.lifetime
        XCTAssertNil(cache.read(for: context, decided: []))
        now -= JobFeedCache.lifetime + 1
        XCTAssertNil(cache.read(for: context, decided: []))
        try Data("broken".utf8).write(to: file)
        XCTAssertNil(cache.read(for: context, decided: []))
        cache.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor
    func testSigningOutRemovesPersistedCards() async {
        let context = seed()
        let cache = JobFeedCache(file: file, now: { self.now })
        let store = AppStore(api: APIClient(origin: origin), jobFeedCache: cache)
        await store.signOut()
        XCTAssertNil(cache.read(for: context, decided: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}

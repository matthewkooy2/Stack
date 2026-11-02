import XCTest
@testable import Stack

/// Holds every `job_feed` request until the test answers it, so slow, failing and stale pages are deterministic.
/// Cancellation is recorded; by default a cancelled request still waits for an answer, like a response that was
/// already on the wire. `releaseAll` ends whatever the test left open.
@MainActor
private final class PageDesk {
    private(set) var requests: [(cursor: String, refresh: Bool)] = []
    private(set) var cancelled: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<JSON, Error>] = [:]

    func fetch(_ cursor: String, _ refresh: Bool) async throws -> JSON {
        let index = requests.count
        requests.append((cursor, refresh))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiting[index] = $0 }
        } onCancel: {
            Task { @MainActor in self.cancelled.insert(index) }
        }
    }

    func requested(_ count: Int) async {
        var spins = 0
        while requests.count < count, spins < 2_000 {
            spins += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertGreaterThanOrEqual(requests.count, count, "expected request \(count) to be made")
    }

    func wasCancelled(_ index: Int) async -> Bool {
        var spins = 0
        while !cancelled.contains(index), spins < 2_000 {
            spins += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
        return cancelled.contains(index)
    }

    func answer(_ index: Int, _ page: JSON) { waiting.removeValue(forKey: index)?.resume(returning: page) }
    func fail(_ index: Int) { waiting.removeValue(forKey: index)?.resume(throwing: URLError(.timedOut)) }

    func releaseAll() {
        for (_, continuation) in waiting { continuation.resume(throwing: CancellationError()) }
        waiting = [:]
    }

    /// Lets queued continuations run before an assertion about "nothing else happened".
    func settle() async { try? await Task.sleep(for: .milliseconds(150)) }
}

/// Test-owned state the feed's source closures read, so no closure refers back to the test case.
@MainActor
private final class Screen {
    var decided: Set<String> = []
    var current = true
    var generation = 1
    var log: [String] = []
    var onReceived: (Int) -> Void = { _ in }
    private(set) var received = 0

    func didReceive() {
        received += 1
        onReceived(received)
    }
}

/// Holds a server write open until the test lets it finish or fail.
@MainActor
private final class SaveDesk {
    private var waiting: CheckedContinuation<Void, Error>?
    private(set) var started = 0

    func save() async throws {
        started += 1
        try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func finish() { release(nil) }
    func fail() { release(URLError(.badServerResponse)) }
    func releaseAll() { release(CancellationError()) }

    private func release(_ error: Error?) {
        guard let continuation = waiting else { return }
        waiting = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

@MainActor
final class JobDeckFeedTests: XCTestCase {
    private var desk: PageDesk!
    private var screen: Screen!
    private var saves: SaveDesk!
    private var feed: JobDeckFeed!
    private var tasks: [Task<Void, Never>] = []

    override func setUp() async throws {
        desk = PageDesk()
        screen = Screen()
        saves = SaveDesk()
        feed = JobDeckFeed()
        tasks = []
    }

    /// Nothing may be left held or running: cancel paging, end held requests and saves, and join every task.
    override func tearDown() async throws {
        feed.cancel()
        for task in tasks { task.cancel() }
        desk.releaseAll()
        saves.releaseAll()
        for task in tasks { await task.value }
        tasks = []
    }

    private func page(_ ids: [String], next: String = "") -> JSON {
        let jobs = ids.map { "{\"id\":\"\($0)\",\"title\":\"Role \($0)\"}" }.joined(separator: ",")
        return parse("{\"jobs\":[\(jobs)],\"next_cursor\":\"\(next)\"}")
    }

    private func makeSource() -> JobDeckSource {
        let feed = feed!, desk = desk!, screen = screen!
        return JobDeckSource(
            fetch: { cursor, refresh in
                screen.log.append("request \(desk.requests.count)")
                return try await desk.fetch(cursor, refresh)
            },
            deckCount: { feed.jobs.filter { !screen.decided.contains($0.id) }.count },
            isCurrent: { screen.current },
            received: { _ in screen.didReceive() })
    }

    @discardableResult
    private func spawn(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let task = Task { await work() }
        tasks.append(task)
        return task
    }

    private func start(refresh: Bool = true, more: Bool = false) -> Task<Void, Never> {
        spawn { [feed = feed!, source = makeSource()] in await feed.load(refresh: refresh, more: more, source: source) }
    }

    /// The same call the view makes for a search change: the server write, then local adoption, then a reload.
    private func startChange(_ name: String, clearing: Bool = true, refresh: Bool = true, withSave: Bool = true) -> Task<Void, Never> {
        run(feed.reserveChange(), name, generation: screen.generation, clearing: clearing, refresh: refresh, withSave: withSave)
    }

    /// Reserving is synchronous at the "user event"; running the reserved change is a separate task whose start
    /// order the test is free to scramble, exactly as the scheduler may.
    private func run(_ ticket: Int, _ name: String, generation: Int = 1, clearing: Bool = true, refresh: Bool = true,
                     withSave: Bool = true) -> Task<Void, Never> {
        spawn { [self] in
            await feed.change(
                ticket: ticket, refresh: refresh, clearing: clearing, isCurrent: { [screen = screen!] in screen.current && screen.generation == generation },
                makeSource: { [self] in makeSource() },
                save: { [self] in
                    guard withSave else { return }
                    screen.log.append("save \(name)")
                    try await saves.save()
                },
                accepted: { [screen = screen!] in screen.log.append("accepted \(name)") })
        }
    }

    private var ids: [String] { feed.jobs.map(\.id) }

    /// Bounded wait (about 10s) for a condition that depends on the feed's own polling, with a clear failure.
    private func eventually(_ what: String, _ condition: () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("timed out waiting for \(what)")
    }

    // MARK: First page and background paging

    func testCachedMatchesRemainVisibleDuringASlowOrFailedRefresh() async {
        feed.restore(page(["cached-swe"], next: "old-cursor"))
        let refresh = start()
        await desk.requested(1)
        XCTAssertTrue(feed.loaded)
        XCTAssertEqual(feed.jobs.map(\.id), ["cached-swe"])
        XCTAssertEqual(desk.requests[0].cursor, "")
        desk.fail(0)
        await refresh.value
        XCTAssertEqual(feed.jobs.map(\.id), ["cached-swe"])
        XCTAssertFalse(feed.loadError.isEmpty)
    }

    func testFirstUsablePageShowsBeforeASlowLaterPage() async {
        let load = start()
        await desk.requested(1)
        XCTAssertFalse(feed.loaded, "nothing is known before the first answer")
        desk.answer(0, page(["a", "b", "c"], next: "p2"))
        await load.value
        XCTAssertTrue(feed.loaded, "the first usable page must not wait for later pages")
        XCTAssertFalse(feed.busy, "background paging must not hold the request gate")
        XCTAssertEqual(ids, ["a", "b", "c"])
        await desk.requested(2)
        XCTAssertEqual(desk.requests[1].cursor, "p2")
        XCTAssertEqual(ids, ["a", "b", "c"], "cards stay visible while the next page is slow")
        desk.answer(1, page(["d"], next: ""))
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b", "c", "d"])
    }

    func testFailingLaterPageKeepsTheCardsAndReportsTheError() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b"], next: "p2"))
        await load.value
        await desk.requested(2)
        desk.fail(1)
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertTrue(feed.loaded)
        XCTAssertFalse(feed.loadError.isEmpty)
        XCTAssertEqual(desk.requests.count, 2, "a failed page is not retried in a loop")
    }

    func testFailingFirstPageEndsLoadingWithAnError() async {
        let load = start()
        await desk.requested(1)
        desk.fail(0)
        await load.value
        XCTAssertTrue(feed.loaded)
        XCTAssertTrue(feed.jobs.isEmpty)
        XCTAssertFalse(feed.loadError.isEmpty)
    }

    func testBackgroundPagingStopsOnceTheDeckHasFiveCards() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a"], next: "p2"))
        await load.value
        for n in 2...5 {
            await desk.requested(n)
            desk.answer(n - 1, page(["x\(n)"], next: "p\(n + 1)"))
        }
        await desk.settle()
        XCTAssertEqual(ids.count, 5)
        XCTAssertEqual(desk.requests.count, 5, "five usable cards is enough")
    }

    func testAllReviewedFirstPageKeepsLookingThenShowsTheFirstUsableCard() async {
        screen.decided = ["old1", "old2"]
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["old1", "old2"], next: "p2"))
        await desk.requested(2)
        XCTAssertFalse(feed.loaded, "nothing reviewable yet, so the spinner is still the truthful state")
        desk.answer(1, page(["fresh"], next: "p3"))
        await load.value
        XCTAssertTrue(feed.loaded)
        XCTAssertEqual(ids, ["old1", "old2", "fresh"])
        await desk.requested(3)                // the deck is still short, so paging continues; teardown ends it
    }

    func testAllReviewedResultsTerminateAtThePageBoundAndSaySoTruthfully() async {
        screen.decided = ["old"]
        let load = start()
        for n in 1...JobDeckFeed.maxPages {
            await desk.requested(n)
            desk.answer(n - 1, page(["old"], next: "p\(n + 1)"))
        }
        await load.value
        await desk.settle()
        XCTAssertTrue(feed.loaded)
        XCTAssertEqual(desk.requests.count, JobDeckFeed.maxPages)
        XCTAssertFalse(feed.nextCursor.isEmpty, "the cursor stays so the person can ask for more")
        XCTAssertTrue(feed.loadError.isEmpty)
    }

    func testEmptyResultsEndAfterOneRequest() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page([]))
        await load.value
        await desk.settle()
        XCTAssertTrue(feed.loaded)
        XCTAssertTrue(feed.jobs.isEmpty)
        XCTAssertTrue(feed.nextCursor.isEmpty)
        XCTAssertEqual(desk.requests.count, 1)
    }

    func testLoadMoreContinuesFromTheCursorWithoutRefreshAndDropsDuplicates() async {
        let first = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b", "c", "d", "e"], next: "p2"))
        await first.value
        XCTAssertTrue(desk.requests[0].refresh)
        screen.decided = ["a", "b", "c", "d", "e"]
        let more = start(refresh: false, more: true)
        await desk.requested(2)
        XCTAssertEqual(desk.requests[1].cursor, "p2")
        XCTAssertFalse(desk.requests[1].refresh)
        desk.answer(1, page(["e", "f"], next: ""))
        await more.value
        XCTAssertEqual(ids, ["a", "b", "c", "d", "e", "f"])
    }

    func testDecidingACardDoesNotRestartOrBlockPaging() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b"], next: "p2"))
        await load.value
        await desk.requested(2)
        screen.decided.insert("a")             // swipe while the next page is loading
        desk.answer(1, page(["c"], next: ""))
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b", "c"], "decided cards are filtered by the view, not removed here")
        XCTAssertEqual(feed.jobs.filter { !screen.decided.contains($0.id) }.map(\.id), ["b", "c"])
    }

    // MARK: Session and lifecycle

    func testResponseAfterSessionChangeIsDropped() async {
        let load = start()
        await desk.requested(1)
        screen.current = false                 // signed out or another account
        desk.answer(0, page(["a"], next: "p2"))
        await load.value
        XCTAssertTrue(feed.jobs.isEmpty)
        XCTAssertTrue(feed.nextCursor.isEmpty)
        XCTAssertFalse(feed.loaded)
        XCTAssertFalse(feed.busy, "a dropped load must still release the gate")
    }

    func testNoBackgroundRequestIsIssuedOnceTheSessionIsGone() async {
        screen.onReceived = { [screen = screen!] count in if count == 2 { screen.current = false } }
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a"], next: "p2"))
        await load.value
        await desk.requested(2)
        desk.answer(1, page(["b"], next: "p3"))   // the session ends right after this page is applied
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertEqual(desk.requests.count, 2, "the next page must not be requested for a departed session")
    }

    func testSessionResetCancelsTheForegroundRequestAndClearsTheDeck() async {
        let load = start()
        await desk.requested(1)
        feed.invalidate(clearing: true)        // what the view does when the session generation changes
        let cancelled = await desk.wasCancelled(0)
        XCTAssertTrue(cancelled, "the in-flight request itself is cancelled, not only ignored")
        desk.answer(0, page(["late"], next: "p2"))
        await load.value
        XCTAssertTrue(feed.jobs.isEmpty)
        XCTAssertFalse(feed.busy)
    }

    func testTeardownCancelsPagingButKeepsTheCardsOnScreen() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b"], next: "p2"))
        await load.value
        await desk.requested(2)
        feed.cancel()                          // view teardown or onDisappear
        let cancelled = await desk.wasCancelled(1)
        XCTAssertTrue(cancelled)
        desk.answer(1, page(["late"], next: ""))
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b"])
    }

    // MARK: Search and profile changes (ordering through the same entry point the view uses)

    func testProfileChangeCancelsASlowForegroundLoadBeforeAnythingIsAdopted() async {
        let load = start()
        await desk.requested(1)                // first open, first page still slow
        let change = startChange("profile", clearing: false, refresh: false, withSave: false)
        let cancelled = await desk.wasCancelled(0)
        XCTAssertTrue(cancelled, "the old foreground request is cancelled as the change begins")
        XCTAssertFalse(screen.log.contains("accepted profile"), "adoption waits until the old request has let go")
        desk.answer(0, page(["old"], next: "p2"))     // old answer arrives late
        await load.value
        await desk.requested(2)
        desk.answer(1, page(["new"]))
        await change.value
        XCTAssertEqual(ids, ["new"], "the old criteria's cards were never applied")
        XCTAssertEqual(screen.log, ["request 0", "accepted profile", "request 1"])
        XCTAssertTrue(feed.loaded)
        XCTAssertFalse(feed.busy)
    }

    func testSearchChangeCancelsPrefetchBeforeTheServerSaveAndKeepsCardsUntilAccepted() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b"], next: "p2"))
        await load.value
        await desk.requested(2)                // prefetch for the old search in flight
        let change = startChange("filters")
        let cancelled = await desk.wasCancelled(1)
        XCTAssertTrue(cancelled, "old prefetch is cancelled before the save returns")
        await eventually("a save to start") { saves.started >= 1 }
        XCTAssertEqual(ids, ["a", "b"], "visible cards stay while the save is pending")
        desk.answer(1, page(["stale"], next: ""))
        await desk.settle()
        XCTAssertEqual(ids, ["a", "b"], "a late old page cannot join the deck")
        XCTAssertFalse(screen.log.contains("accepted filters"))
        saves.finish()
        await desk.requested(3)
        XCTAssertTrue(feed.jobs.isEmpty, "the deck clears only once the new search is accepted")
        desk.answer(2, page(["n1"]))
        await change.value
        XCTAssertEqual(ids, ["n1"])
        XCTAssertEqual(screen.log, ["request 0", "request 1", "save filters", "accepted filters", "request 2"])
    }

    func testFailedSaveKeepsTheVisibleCardsAndReportsTheError() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a", "b"]))
        await load.value
        let change = startChange("filters")
        await eventually("a save to start") { saves.started >= 1 }
        saves.fail()
        await change.value
        XCTAssertEqual(ids, ["a", "b"])
        XCTAssertTrue(feed.loaded)
        XCTAssertFalse(feed.loadError.isEmpty)
        XCTAssertFalse(screen.log.contains("accepted filters"))
        XCTAssertFalse(feed.busy)
        XCTAssertEqual(desk.requests.count, 1, "nothing to reload: the cards on screen are still the saved search's")
    }

    func testFailedSaveDuringFirstOpenDoesNotStrandTheSpinner() async {
        let load = start()
        await desk.requested(1)
        let change = startChange("filters")
        let cancelled = await desk.wasCancelled(0)
        XCTAssertTrue(cancelled)
        desk.answer(0, page(["old"]))
        await load.value
        await eventually("a save to start") { saves.started >= 1 }
        saves.fail()
        await desk.requested(2)                // the superseded first load is retried
        desk.answer(1, page(["a"]))
        await change.value
        XCTAssertEqual(ids, ["a"])
        XCTAssertTrue(feed.loaded)
    }

    private var writes: [String] { screen.log.filter { $0.hasPrefix("save") || $0.hasPrefix("accepted") } }

    func testThreeRapidChangesSaveAndAdoptInTheOrderTheyBeganAndTheLastResultsSurvive() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a1"], next: "pa2"))
        await load.value
        await desk.requested(2)                // prefetch for the original search

        let first = startChange("A")
        await eventually("save 1 to start") { saves.started >= 1 }
        let ticketB = feed.reserveChange()     // B then C are acted on while A's write is pending...
        let ticketC = feed.reserveChange()
        let third = run(ticketC, "C")          // ...but C's task happens to start before B's
        let second = run(ticketB, "B")
        await desk.settle()
        XCTAssertEqual(saves.started, 1, "queued writes wait for A")
        XCTAssertEqual(writes, ["save A"])

        saves.finish()                         // A accepted; its deck load starts and releases A's turn
        await desk.requested(3)
        let loadACancelled = await desk.wasCancelled(2)
        XCTAssertTrue(loadACancelled, "B cancels A's deck load instead of waiting for it")
        desk.answer(2, page(["A1"]))           // A's answer and the original prefetch arrive late
        desk.answer(1, page(["a2"]))
        await eventually("save 2 to start") { saves.started >= 2 }
        await desk.settle()
        XCTAssertEqual(saves.started, 2, "C must not overtake B")
        XCTAssertEqual(writes, ["save A", "accepted A", "save B"])

        saves.finish()                         // B accepted
        await desk.requested(4)
        let loadBCancelled = await desk.wasCancelled(3)
        XCTAssertTrue(loadBCancelled)
        desk.answer(3, page(["B1"]))
        await eventually("save 3 to start") { saves.started >= 3 }
        saves.finish()                         // C accepted
        await desk.requested(5)
        desk.answer(4, page(["C1"]))
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(writes, ["save A", "accepted A", "save B", "accepted B", "save C", "accepted C"])
        XCTAssertEqual(ids, ["C1"], "the newest search's cards are the only ones left")
        XCTAssertTrue(feed.loaded)
        XCTAssertFalse(feed.busy)
    }

    func testQueuedChangeThatIsCancelledLeavesTheQueueAndDoesNotBlockLaterOnes() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a1"]))
        await load.value

        let first = startChange("A")
        await eventually("save 1 to start") { saves.started >= 1 }
        let second = startChange("B")
        let third = startChange("C")
        await desk.settle()
        second.cancel()                        // B's owner went away while queued
        await second.value
        saves.finish()                         // A accepted, then its load starts
        await desk.requested(2)
        let loadACancelled = await desk.wasCancelled(1)
        XCTAssertTrue(loadACancelled)
        desk.answer(1, page(["A1"]))
        await eventually("save 2 to start") { saves.started >= 2 }
        saves.finish()                         // C's write
        await desk.requested(3)
        desk.answer(2, page(["C1"]))
        await first.value
        await third.value
        XCTAssertEqual(writes, ["save A", "accepted A", "save C", "accepted C"], "B never wrote or adopted")
        XCTAssertEqual(ids, ["C1"])
        XCTAssertFalse(feed.busy)
    }

    func testDelayedEventFromAPreviousAccountNeverWritesAndDoesNotBlockTheQueue() async {
        let oldTicket = feed.reserveChange()   // the person acted while signed in as account 1 (generation 1)
        screen.generation = 2                  // the session changed before that event's task began
        let old = run(oldTicket, "old", generation: 1)
        let newer = startChange("new")         // account 2's own, later event (generation 2)
        await eventually("the valid change to save") { saves.started >= 1 }
        XCTAssertEqual(screen.log, ["save new"], "the old event must not write or adopt for the new account")
        saves.finish()
        await desk.requested(1)
        desk.answer(0, page(["n1"]))
        await old.value
        await newer.value
        XCTAssertEqual(screen.log, ["save new", "accepted new", "request 0"])
        XCTAssertEqual(saves.started, 1)
        XCTAssertEqual(ids, ["n1"])
        XCTAssertFalse(feed.busy)
    }

    func testChangeForADepartedSessionIsNotAdopted() async {
        let load = start()
        await desk.requested(1)
        desk.answer(0, page(["a"]))
        await load.value
        let change = startChange("filters")
        await eventually("a save to start") { saves.started >= 1 }
        screen.current = false
        saves.finish()
        await change.value
        XCTAssertFalse(screen.log.contains("accepted filters"))
        XCTAssertFalse(feed.busy)
    }
}

final class JobSweepTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    func testOnlyMatchesFromBeforeTheLatestTenAMSweepAreStale() {
        // 09:59 New York (EDT) is still yesterday's sweep; 10:00 starts today's.
        let before = date("2026-10-27T13:59:00Z"), after = date("2026-10-27T14:01:00Z")
        XCTAssertEqual(JobSweep.latest(before: before), date("2026-10-26T14:00:00Z"))
        XCTAssertEqual(JobSweep.latest(before: after), date("2026-10-27T14:00:00Z"))
        let rankedThisMorning = date("2026-10-27T14:05:00Z").timeIntervalSince1970
        XCTAssertFalse(JobSweep.isNewer(than: rankedThisMorning, now: date("2026-10-27T20:00:00Z")))
        XCTAssertTrue(JobSweep.isNewer(than: rankedThisMorning, now: date("2026-10-28T14:30:00Z")))
        XCTAssertTrue(JobSweep.isNewer(than: 0, now: after))
    }
}

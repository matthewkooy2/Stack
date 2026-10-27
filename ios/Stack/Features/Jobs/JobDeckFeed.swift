import Foundation
import Observation

/// The server ranks every account's matches once a day, right after its 10:00 New York sweep.
enum JobSweep {
    static let zone = TimeZone(identifier: "America/New_York")!

    /// The most recent sweep start at or before `now`.
    static func latest(before now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let today = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    }

    /// True when matches ranked at `computedAt` may predate the latest sweep (or were never loaded).
    static func isNewer(than computedAt: Double, now: Date = Date()) -> Bool {
        computedAt < latest(before: now).timeIntervalSince1970
    }
}

/// Everything the feed needs from its screen, so paging can be tested without a view or a network.
struct JobDeckSource {
    /// Fetches one page for the cursor ("" for the first page).
    var fetch: (_ cursor: String, _ refresh: Bool) async throws -> JSON
    /// Cards the person can still review right now (not decided, not hidden).
    var deckCount: () -> Int
    /// False once the session, phase or account the request was made for has changed.
    var isCurrent: () -> Bool
    var received: (JSON) -> Void = { _ in }
    var animate: (() -> Void) -> Void = { $0() }
}

/// Loads the jobs deck. The first page that holds something reviewable is shown immediately; further
/// pages top the deck up in the background and can only add cards, never hide or remove them.
///
/// Every request belongs to one `token`. A search change, profile change, new load, sign-out or teardown
/// bumps the token and cancels the request in flight, so an older answer can never be applied or unlock
/// a newer owner of the request gate.
@MainActor
@Observable
final class JobDeckFeed {
    static let maxPages = 6
    static let targetDeck = 5

    private(set) var jobs: [Job] = []
    private(set) var loaded = false
    private(set) var nextCursor = ""
    /// When the server last ranked these matches (seconds since 1970); 0 until a page arrives.
    private(set) var computedAt: Double = 0
    /// One search save or deck load at a time, so a slow older response cannot overwrite a newer search.
    private(set) var gate = JobRequestGate()
    var loadError = ""
    private var token = 0
    /// Changes waiting for, or holding, the write turn, oldest first.
    @ObservationIgnored private var queue: [Int] = []
    @ObservationIgnored private var nextTicket = 0
    @ObservationIgnored private var prefetch: Task<Void, Never>?
    @ObservationIgnored private var inFlight: Task<JSON, Error>?

    private enum Step { case stale, failed, applied }

    var busy: Bool { gate.busy }

    /// Discards and cancels everything in flight without touching the cards on screen.
    func cancel() {
        token += 1
        prefetch?.cancel()
        prefetch = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Cancels in-flight work and forgets the cursor. `clearing` also empties the deck for a new search or account.
    func invalidate(clearing: Bool = false) {
        cancel()
        nextCursor = ""
        if clearing {
            jobs = []
            loaded = false
            computedAt = 0
        }
    }

    /// Restores server-matched cards before starting network work. A cached cursor is never reused.
    func restore(_ result: JSON) {
        guard !busy, jobs.isEmpty else { return }
        jobs = result["jobs"].array.map(Job.init)
        loaded = !jobs.isEmpty
        nextCursor = ""
        computedAt = result["computed_at"].double
    }

    /// Returns once the person has something to review, or once the results are known to be empty or failed.
    /// Remaining pages (up to `maxPages` in total) continue in the background.
    func load(refresh: Bool, more: Bool = false, source: JobDeckSource) async {
        guard gate.beginLoad() else { return }
        defer { gate.endLoad() }
        cancel()
        let mine = token
        loadError = ""
        var pages = 0
        var continuing = more
        while true {
            pages += 1
            switch await fetchPage(continuing: continuing, refresh: refresh && pages == 1, mine: mine, source: source) {
            case .stale: return
            case .failed:
                loaded = true
                return
            case .applied: break
            }
            continuing = true
            if source.deckCount() > 0 || nextCursor.isEmpty || pages >= Self.maxPages { break }
        }
        loaded = true
        guard source.isCurrent(), !nextCursor.isEmpty, source.deckCount() < Self.targetDeck, pages < Self.maxPages else { return }
        let done = pages
        prefetch = Task { [weak self] in await self?.fillAhead(after: done, mine: mine, source: source) }
    }

    /// Takes the next place in line for a saved-search or profile change, and supersedes paging at once.
    /// Call this synchronously from the user's event, before any `Task` is spawned: task start order is not
    /// guaranteed, so the order people acted in has to be fixed here. Every ticket must be passed to `change`,
    /// which also removes it from the queue if the work is cancelled or the session is gone.
    func reserveChange() -> Int {
        cancel()
        let ticket = nextTicket
        nextTicket += 1
        queue.append(ticket)
        return ticket
    }

    /// Runs a reserved change. It keeps the visible cards until the change is accepted. Changes take their turn
    /// strictly in ticket order; a turn covers only the server write and local adoption, so the next change can
    /// cancel this change's deck load instead of waiting for it. `save` is the server write (if any);
    /// `accepted` adopts the new search locally.
    func change(ticket: Int, refresh: Bool, clearing: Bool, isCurrent: () -> Bool, makeSource: () -> JobDeckSource,
                save: () async throws -> Void = {}, accepted: () -> Void) async {
        guard await waitForTurn(ticket, isCurrent: isCurrent) else { return }
        defer { release(ticket) }
        do {
            try await save()
        } catch {
            release(ticket)
            guard isCurrent() else { return }
            if !(error is CancellationError) { loadError = error.localizedDescription }
            // A superseded load may have left nothing on screen; do not strand the spinner.
            if !loaded { await load(refresh: false, source: makeSource()) }
            return
        }
        guard isCurrent() else { return }
        accepted()
        invalidate(clearing: clearing)
        release(ticket)
        await load(refresh: refresh, source: makeSource())
    }

    /// Waits until this ticket heads the queue and nothing else holds the gate, then claims it for the write.
    /// A load or prefetch that began after this change did is out of date, so it is cancelled rather than awaited.
    /// Gives up (and leaves the queue) when the task is cancelled or the session is gone.
    private func waitForTurn(_ ticket: Int, isCurrent: () -> Bool) async -> Bool {
        while true {
            if Task.isCancelled || !isCurrent() {
                dequeue(ticket)
                return false
            }
            if queue.first == ticket {
                if gate.loading { cancel() }
                if !gate.busy {
                    cancel()
                    if gate.beginSave() { return true }
                }
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func dequeue(_ ticket: Int) { queue.removeAll { $0 == ticket } }

    /// Ends this ticket's write turn. Only the ticket's own holder may end the gate's save, so a late or repeated
    /// release can never free a newer owner.
    private func release(_ ticket: Int) {
        guard queue.first == ticket else { return }
        queue.removeFirst()
        gate.endSave()
    }

    private func fillAhead(after done: Int, mine: Int, source: JobDeckSource) async {
        var pages = done
        while mine == token, !Task.isCancelled, source.isCurrent(),
              !nextCursor.isEmpty, source.deckCount() < Self.targetDeck, pages < Self.maxPages {
            pages += 1
            guard await fetchPage(continuing: true, refresh: false, mine: mine, source: source) == .applied else { return }
        }
    }

    private func fetchPage(continuing: Bool, refresh: Bool, mine: Int, source: JobDeckSource) async -> Step {
        guard mine == token, source.isCurrent(), !Task.isCancelled else { return .stale }
        let cursor = continuing ? nextCursor : ""
        let request = Task { try await source.fetch(cursor, refresh) }
        inFlight = request
        do {
            let result = try await withTaskCancellationHandler { try await request.value } onCancel: { request.cancel() }
            guard mine == token, source.isCurrent(), !Task.isCancelled else { return .stale }
            inFlight = nil
            let incoming = result["jobs"].array.map(Job.init)
            source.animate {
                if continuing {
                    let known = Set(jobs.map(\.id))
                    jobs += incoming.filter { !known.contains($0.id) }
                } else {
                    jobs = incoming
                }
            }
            nextCursor = result["next_cursor"].string
            if !continuing { computedAt = result["computed_at"].double }
            source.received(result)
            return .applied
        } catch {
            guard !(error is CancellationError), mine == token, source.isCurrent() else { return .stale }
            inFlight = nil
            loadError = error.localizedDescription
            return .failed
        }
    }
}

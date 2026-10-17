import Foundation

/// Identity comes from the authenticated bootstrap, never from a cached profile or a guessed role.
struct JobFeedContext: Codable, Equatable {
    let origin: String
    let userID: String
    let profile: JSON
    let query: String
    let filters: JSON

    init(origin: URL, account: AccountState, query: String, filters: JSON) {
        self.origin = origin.absoluteString
        userID = account.userID
        profile = ["role": .string(account.role), "location": .string(account.location),
                   "mode": .string(account.mode), "preferences": account.preferences,
                   "graduation_month": .string(account.graduationMonth),
                   "available_from": .string(account.availableFrom)]
        self.query = query
        self.filters = filters
    }

    init(origin: URL, account: AccountState) {
        self.init(origin: origin, account: account, query: account.savedSearch["query"].string,
                  filters: account.savedSearch["filters"].isNull ? [:] : account.savedSearch["filters"])
    }
}

/// A persistent local copy of server-matched cards. Only an exact current context can read it.
/// Cursors are never restored: every refresh starts from the server's first page.
final class JobFeedCache {
    static let limit = 25
    private let file: URL
    private let now: () -> Date

    private struct Entry: Codable {
        let version: Int
        let context: JobFeedContext
        let savedAt: Date
        let result: JSON
    }

    init(file: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.file = file ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("stack-job-feed-v1.json")
        self.now = now
    }

    func read(for context: JobFeedContext, decided: Set<String>) -> JSON? {
        guard !context.userID.isEmpty,
              let data = try? Data(contentsOf: file), data.count <= 1_000_000,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.version == 1, entry.context == context else { return nil }
        let jobs = entry.result["jobs"].array.filter { job in
            let expiry = job["expires_at"].double
            return !job["id"].string.isEmpty && !decided.contains(job["id"].string)
                && job["active"].bool
                && (expiry == 0 || expiry > now().timeIntervalSince1970)
        }
        guard !jobs.isEmpty else { return nil }
        var result = entry.result
        result["jobs"] = .array(jobs)
        result["next_cursor"] = .string("")
        return result
    }

    func write(_ result: JSON, jobs: [Job], for context: JobFeedContext) {
        guard !context.userID.isEmpty else { return }
        var compact = result
        compact["jobs"] = .array(Array(jobs.prefix(Self.limit)).map(\.raw))
        compact["next_cursor"] = .string("")
        let entry = Entry(version: 1, context: context, savedAt: now(), result: compact)
        guard let data = try? JSONEncoder().encode(entry), data.count <= 1_000_000 else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    func remove() { try? FileManager.default.removeItem(at: file) }
}

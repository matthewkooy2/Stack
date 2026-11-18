import Foundation
import Observation

/// The real outreach contact shape from `agent_contacts`, never the sample people catalog.
struct NetworkContact: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let company: String
    let email: String
    let relationship: String
    let stopped: Bool
    let nextFollowup: Double

    init(_ json: JSON) {
        id = json["id"].string
        let suppliedName = json["name"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        name = suppliedName.isEmpty ? "No name" : suppliedName
        role = json["role"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        company = json["company"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        email = json["email"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        relationship = json["relationship"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        stopped = json["stopped"].bool
        nextFollowup = json["next_at"].double
    }

    /// A follow-up draft is due now and outreach has not been stopped.
    func followupDue(now: Date = Date()) -> Bool {
        !stopped && nextFollowup > 0 && nextFollowup <= now.timeIntervalSince1970
    }

    var initials: String {
        name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)
            .map { String($0) }.joined().uppercased()
    }

    var detail: String {
        let work = [role, company].filter { !$0.isEmpty }.joined(separator: " · ")
        return work.isEmpty ? email : work
    }

    var directoryLetter: String {
        guard let letter = name.folding(options: .diacriticInsensitive, locale: .current).first,
              letter.isLetter else { return "#" }
        return String(letter).localizedUppercase
    }

    func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || [name, company, role, email, relationship].contains {
            $0.localizedStandardContains(term)
        }
    }

    static func contacts(from response: JSON) -> [Self] {
        var seen = Set<String>()
        return response["contacts"].array.map(Self.init).filter {
            !$0.id.isEmpty && seen.insert($0.id).inserted
        }
    }
}

@MainActor
@Observable
final class NetworkRoster {
    private(set) var contacts: [NetworkContact] = []
    private(set) var loaded = false
    private(set) var loading = false
    private(set) var error = ""
    private var requestID: UUID?

    func load(store: AppStore) async {
        await load { try await store.call("agent_contacts") }
    }

    /// An explicit refresh keeps the last successful roster if the request fails.
    /// The injected read also lets manual unit tests cover retry and cancellation without networking.
    func load(read: () async throws -> JSON) async {
        guard !loading else { return }
        let request = UUID()
        requestID = request
        loading = true
        error = ""
        defer {
            if requestID == request { loading = false }
        }
        do {
            let response = try await read()
            guard requestID == request, !Task.isCancelled else { return }
            contacts = NetworkContact.contacts(from: response)
            loaded = true
        } catch {
            guard requestID == request, !Task.isCancelled, !(error is CancellationError) else { return }
            self.error = error.localizedDescription
        }
    }

    func reset() {
        requestID = nil
        contacts = []
        loaded = false
        loading = false
        error = ""
    }
}

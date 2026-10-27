import Foundation
import Observation

/// The real outreach contact shape from `agent_contacts`, never the sample people catalog.
struct NetworkContact: Identifiable, Hashable {
    let id: String
    let name: String
    let role: String
    let company: String

    init(_ json: JSON) {
        id = json["id"].string
        let suppliedName = json["name"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        name = suppliedName.isEmpty ? "Unnamed contact" : suppliedName
        role = json["role"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        company = json["company"].string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var initials: String {
        name.split(whereSeparator: { $0.isWhitespace }).prefix(2).compactMap(\.first)
            .map { String($0) }.joined().uppercased()
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

import Foundation

/// A question in the Prep catalog.
struct PrepQuestion: Identifiable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let hints: [String]
    let track: String
    let topic: String
    let minutes: Int
    let languages: [String]

    init(_ json: JSON) {
        track = json["track"].string
        topic = json["topic"].string
        minutes = json["minutes"].int
        languages = json["languages"].strings
        id = json["id"].string
        title = json["title"].string
        prompt = json["prompt"].string
        hints = json["hints"].strings
    }
}

/// Keeps the behavioral workflow compatible with the account's existing prep API: workflow metadata
/// travels inside the persisted canvas document, and numbered question variants map onto catalog
/// questions the account actually has. This mirrors the React Native client, so sessions started on
/// either client open on the other.
enum PrepCodec {
    static let marker = "stack_prep_workflow_v1"
    static let storageLimit = 50_000

    static func bundledCatalog() -> [PrepQuestion] {
        guard let url = Bundle.main.url(forResource: "prep-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONDecoder().decode(JSON.self, from: data) else { return [] }
        return json.array.map(PrepQuestion.init)
    }

    /// `project-2` becomes `project` when the account does not list the variant.
    static func actualID(_ id: String, available: Set<String>) -> String {
        if available.contains(id) { return id }
        guard let range = id.range(of: #"-\d+$"#, options: .regularExpression) else { return id }
        return String(id[id.startIndex..<range.lowerBound])
    }

    static func decode(_ row: JSON) -> JSON {
        let stored = row["data"]["canvas"][marker]
        guard stored["version"].int == 1, !stored["behavioral"].isNull else { return row }
        var result = row
        var canvas = row["data"]["canvas"]
        canvas[marker] = .null
        result["data"]["canvas"] = canvas
        result["data"]["problem_id"] = stored["problem_id"]
        result["data"]["notes"] = .string(stored["notes"].string)
        result["data"]["behavioral"] = stored["behavioral"]
        return result
    }

    static func encode(_ data: JSON, available: Set<String>, bundled: [PrepQuestion]) throws -> JSON {
        guard !data["behavioral"].isNull else { return data }
        let wanted = data["problem_id"].string
        let actual = actualID(wanted, available: available)
        guard available.contains(actual) else {
            throw APIError(message: "This behavioral question is unavailable on your account.")
        }
        var canvas = data["canvas"]
        if case .object = canvas {} else { canvas = [:] }
        canvas[marker] = [
            "version": 1,
            "problem_id": .string(wanted),
            "notes": .string(data["notes"].string),
            "behavioral": data["behavioral"],
        ]
        if let encoded = try? JSONEncoder().encode(canvas), encoded.count > storageLimit {
            throw APIError(message: "This session exceeds the account storage limit. Your current answer is kept; shorten it before saving.")
        }
        var result = data
        result["problem_id"] = .string(actual)
        result["canvas"] = canvas
        if actual == wanted {
            result["notes"] = .string(data["notes"].string)
        } else {
            let prompt = bundled.first { $0.id == wanted }?.prompt ?? ""
            result["notes"] = .string("Practice question: \(prompt)\n\(data["notes"].string)")
        }
        return result
    }
}

/// Prep calls with the compatibility layer applied.
final class PrepTransport {
    private let api: APIClient
    private var serverIDs: Set<String>?
    private let bundled = PrepCodec.bundledCatalog()

    init(api: APIClient) { self.api = api }

    func resetCatalog() { serverIDs = nil }

    func catalog() async throws -> [PrepQuestion] {
        let result = try await api.call("prep_catalog")
        let server = result["problems"].array.map(PrepQuestion.init)
        serverIDs = Set(server.map(\.id))
        return server + bundled.filter { extra in !server.contains { $0.id == extra.id } }
    }

    private func available() async throws -> Set<String> {
        if let serverIDs { return serverIDs }
        _ = try await catalog()
        return serverIDs ?? []
    }

    func sessions() async throws -> [JSON] {
        let result = try await api.call("prep_sessions")
        return result["sessions"].array.map(PrepCodec.decode)
    }

    func get(_ id: String) async throws -> JSON {
        PrepCodec.decode(try await api.call("prep_get", ["id": .string(id)]))
    }

    func create(problemID: String) async throws -> JSON {
        let generation = api.sessionGeneration
        let ids = try await available()
        guard generation == api.sessionGeneration else { throw CancellationError() }
        let actual = PrepCodec.actualID(problemID, available: ids)
        guard ids.contains(actual) else { throw APIError(message: "This behavioral question is unavailable on your account.") }
        var made = try await api.call("prep_create", ["problem_id": .string(actual)])
        made["data"]["problem_id"] = .string(problemID)
        return made
    }

    func save(id: String, revision: Int, data: JSON) async throws -> JSON {
        let generation = api.sessionGeneration
        let ids = try await available()
        guard generation == api.sessionGeneration else { throw CancellationError() }
        let encoded = try PrepCodec.encode(data, available: ids, bundled: bundled)
        let saved = try await api.call("prep_save", ["id": .string(id), "revision": .number(Double(revision)), "data": encoded])
        return PrepCodec.decode(saved)
    }
}

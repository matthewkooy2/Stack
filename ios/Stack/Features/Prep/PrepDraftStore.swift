import CryptoKit
import Foundation

/// Local recovery for typed or recorded edits and an answer/feedback pair awaiting account storage.
struct PrepDraftStore {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PrepDrafts", isDirectory: true)
    }
    private func url(owner: String, session: String, index: Int) -> URL {
        let key = SHA256.hash(data: Data("\(owner)|\(session)|\(index)".utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(key + ".json")
    }
    func load(owner: String, session: String, index: Int) -> JSON? {
        guard let bytes = try? Data(contentsOf: url(owner: owner, session: session, index: index)),
              let value = try? JSONDecoder().decode(JSON.self, from: bytes),
              value["owner"].string == owner, value["session_id"].string == session, value["index"].int == index else { return nil }
        return value
    }
    func save(owner: String, session: String, index: Int, value: JSON) throws {
        guard !owner.isEmpty, !session.isEmpty else { return }
        var stored = value
        stored["owner"] = .string(owner); stored["session_id"] = .string(session); stored["index"] = .number(Double(index))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(stored).write(to: url(owner: owner, session: session, index: index), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func saveSubmission(owner: String, submission: JSON) throws {
        let session = submission["session_id"].string, index = submission["index"].int
        guard var stored = load(owner: owner, session: session, index: index),
              stored["submission"]["key"] == submission["key"] else { return }
        stored["submission"] = submission
        try save(owner: owner, session: session, index: index, value: stored)
    }
}

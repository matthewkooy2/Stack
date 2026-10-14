import CryptoKit
import Foundation

/// Unsaved resume-review edits, kept on this device so they survive dismissal, navigation and the
/// process ending. A draft belongs to one account and one resume; it is never sent anywhere.
struct ResumeReviewDraft: Codable, Equatable {
    var version = 2
    var userID: String
    var resumeID: String
    /// The revision these edits were made against.
    var baseRevision: JSON
    var document: ResumeDocument
    /// Normalized values at `baseRevision`; what "unchanged" means for this draft.
    var baseline: [String: String]
    /// Legacy record review (older imports); nil in section review.
    var records: [JSON]?
    var baselineRecords: [JSON]?
    var savedAt: Double

    /// Whether two drafts carry the same edits (ignores the save time).
    func sameContent(as other: ResumeReviewDraft) -> Bool {
        userID == other.userID && resumeID == other.resumeID && baseRevision == other.baseRevision
            && document == other.document && records == other.records
    }

    var hasEdits: Bool {
        if let records, let baselineRecords { return records != baselineRecords }
        return document.flatValues() != baseline || document.hasLocalOnlyRows
    }
}

protocol ResumeDraftStoring {
    func load(userID: String, resumeID: String) -> ResumeReviewDraft?
    /// Throws when the draft could not be written; the caller keeps the edits in memory and says so.
    func save(_ draft: ResumeReviewDraft) throws
    func clear(userID: String, resumeID: String)
    /// Removes the stored draft only when it still holds exactly `draft`'s edits. Returns whether it did.
    @discardableResult func clear(ifMatching draft: ResumeReviewDraft) -> Bool
}

enum ResumeDraftError: LocalizedError {
    case unavailable

    var errorDescription: String? { "There is no place to keep a draft for this account." }
}

/// Files under Application Support, one per account and resume. Names are digests, so neither the
/// account nor the resume id appears on disk, and a file is only used for the pair it records.
struct FileResumeDraftStore: ResumeDraftStoring {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.root = base.appendingPathComponent("ResumeReviewDrafts", isDirectory: true)
        }
    }

    static let shared = FileResumeDraftStore()

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func url(userID: String, resumeID: String) -> URL? {
        guard !userID.isEmpty, !resumeID.isEmpty else { return nil }
        return root.appendingPathComponent(Self.digest(userID), isDirectory: true)
            .appendingPathComponent(Self.digest(resumeID) + ".json")
    }

    func load(userID: String, resumeID: String) -> ResumeReviewDraft? {
        guard let url = url(userID: userID, resumeID: resumeID), let data = try? Data(contentsOf: url),
              let draft = try? JSONDecoder().decode(ResumeReviewDraft.self, from: data),
              draft.version == 2, draft.userID == userID, draft.resumeID == resumeID else { return nil }
        return draft
    }

    func save(_ draft: ResumeReviewDraft) throws {
        guard let url = url(userID: draft.userID, resumeID: draft.resumeID) else { throw ResumeDraftError.unavailable }
        let data = try JSONEncoder().encode(draft)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = URLResourceValues()
        excluded.isExcludedFromBackup = true
        var rootURL = root
        try? rootURL.setResourceValues(excluded)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func clear(userID: String, resumeID: String) {
        guard let url = url(userID: userID, resumeID: resumeID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    func clear(ifMatching draft: ResumeReviewDraft) -> Bool {
        guard let stored = load(userID: draft.userID, resumeID: draft.resumeID), stored.sameContent(as: draft) else { return false }
        clear(userID: draft.userID, resumeID: draft.resumeID)
        return true
    }

    /// Everything kept for every account. Not called on sign-out: a draft is meant to outlive a
    /// session so the same account finds its edits after signing in again.
    func removeAll() {
        try? FileManager.default.removeItem(at: root)
    }
}

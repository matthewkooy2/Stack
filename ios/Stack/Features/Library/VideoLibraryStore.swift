import Foundation

/// Practice-library answer videos, kept only on this phone and isolated per account. They are
/// excluded from device backup and removed on sign-out; the server never receives them.
enum VideoLibraryStore {
    static let folder = "PracticeVideos"
    static let maximumSeconds: TimeInterval = 180

    static func directory(owner: String) throws -> URL {
        let safe = owner.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        guard !safe.isEmpty, safe == owner, safe.count <= 80 else { throw APIError(message: "Sign in before recording.") }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = base.appendingPathComponent(folder, isDirectory: true)
        let directory = root.appendingPathComponent(safe, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = root
        try? mutable.setResourceValues(values)
        return directory
    }

    static func newVideoID() -> String { "video-" + UUID().uuidString.lowercased() }

    static func isValid(_ videoID: String) -> Bool {
        videoID.range(of: "^[a-zA-Z0-9_-]{12,80}$", options: .regularExpression) != nil
    }

    static func url(owner: String, videoID: String) throws -> URL {
        guard isValid(videoID) else { throw APIError(message: "Invalid video identifier.") }
        return try directory(owner: owner).appendingPathComponent(videoID + ".mov")
    }

    /// The saved video, or nil when it was recorded on another phone or already deleted.
    static func existing(owner: String, videoID: String) -> URL? {
        guard isValid(videoID), let url = try? url(owner: owner, videoID: videoID),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static func audioURL(owner: String, videoID: String) throws -> URL {
        try url(owner: owner, videoID: videoID).deletingPathExtension().appendingPathExtension("wav")
    }

    static func delete(owner: String, videoID: String) throws {
        guard isValid(videoID) else { return }
        for url in [try url(owner: owner, videoID: videoID), try audioURL(owner: owner, videoID: videoID)]
            where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Total bytes this account's videos use on the phone.
    static func usage(owner: String) -> Int64 {
        guard let directory = try? directory(owner: owner),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }

    /// Every account's videos on this phone; used on sign-out.
    static func removeAll() {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        try? FileManager.default.removeItem(at: base.appendingPathComponent(folder, isDirectory: true))
    }
}

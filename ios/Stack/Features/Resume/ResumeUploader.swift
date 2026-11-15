import Foundation
import Observation
import UniformTypeIdentifiers

/// The resume files Stack imports, and the limits it shares with the server (`upload_resume`).
enum ResumeFiles {
    static let limit = 10 * 1024 * 1024
    static let tooLarge = "Resume must be 10 MB or smaller."
    static let wrongType = "Choose a PDF or DOCX resume."
    /// What the file picker offers. DOCX has a system type on iOS; it is skipped rather than guessed if missing.
    static let allowedTypes: [UTType] = [.pdf] + [UTType("org.openxmlformats.wordprocessingml.document")].compactMap { $0 }

    static func isResume(_ url: URL) -> Bool { ["pdf", "docx"].contains(url.pathExtension.lowercased()) }
}

/// One resume upload at a time, from the tap that opens the file picker to the server's answer.
///
/// Every step shows at once (opening, reading, uploading). A second tap while one is open or running does nothing.
/// A failed attempt keeps the picked file, so Try again sends the same file without picking it again; nothing is
/// retried automatically, because an upload whose answer was lost may already be saved. Closing the picker
/// without a file returns to where it was before the tap.
@MainActor
@Observable
final class ResumeUploader {
    enum Phase: Equatable { case idle, choosing, reading, uploading, failed }
    typealias File = (name: String, content: String)

    private(set) var phase: Phase = .idle
    private(set) var fileName = ""
    private(set) var message = ""

    private let read: (URL) async throws -> File
    @ObservationIgnored private var pickedURL: URL?
    @ObservationIgnored private var file: File?
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var running = false

    init(read: @escaping (URL) async throws -> File = { url in
        try await readPickedFileInBackground(url, limit: ResumeFiles.limit, tooLarge: ResumeFiles.tooLarge)
    }) {
        self.read = read
    }

    /// The picker is open, or a file is being read or sent.
    var isBusy: Bool { [.choosing, .reading, .uploading].contains(phase) }
    /// The last attempt failed and its file is kept for Try again.
    var canRetry: Bool { phase == .failed && (file != nil || pickedURL != nil) }

    /// The one line shown under the upload control while something is happening.
    var progress: String {
        switch phase {
        case .choosing: return "Opening files…"
        case .reading: return fileName.isEmpty ? "Reading…" : "Reading \(fileName)…"
        case .uploading: return fileName.isEmpty ? "Uploading…" : "Uploading \(fileName)…"
        case .idle, .failed: return ""
        }
    }

    /// The upload tap. Returns whether to open the picker; false while one is already open or running.
    func begin() -> Bool {
        guard !isBusy else { return false }
        phase = .choosing
        return true
    }

    /// The picker closed. Without a picked file this returns to the state before the tap, keeping any
    /// failed file and its Try again.
    func pickerClosed() {
        guard phase == .choosing else { return }
        phase = (file != nil || pickedURL != nil) ? .failed : .idle
    }

    /// The picker's result. Returns whether `run` should now be awaited. A file is accepted whenever nothing is
    /// running, even if the picker's dismissal was reported first; a second result while one runs is ignored.
    func picked(_ result: Result<URL, Error>) -> Bool {
        guard phase != .reading, phase != .uploading else { return false }
        switch result {
        case .failure(let error):
            if let cocoa = error as? CocoaError, cocoa.code == .userCancelled {
                if phase == .choosing { pickerClosed() }
                return false
            }
            phase = .failed
            message = "This file could not be opened. Choose it again."
            return false
        case .success(let url):
            guard ResumeFiles.isResume(url) else {
                clearFile()
                phase = .failed
                message = ResumeFiles.wrongType
                return false
            }
            pickedURL = url
            file = nil
            fileName = url.lastPathComponent
            message = ""
            phase = .reading
            return true
        }
    }

    /// Try again with the kept file: the same bytes when they were read, otherwise the same picked file.
    func retry() -> Bool {
        guard canRetry else { return false }
        message = ""
        phase = file == nil ? .reading : .uploading
        return true
    }

    /// Reads the picked file if needed, then sends it once. Returns true when the server accepted it.
    func run(send: (File) async throws -> Void) async -> Bool {
        guard !running, phase == .reading || phase == .uploading, let url = pickedURL else { return false }
        running = true
        let token = attempt
        defer { if token == attempt { running = false } }
        if file == nil {
            phase = .reading
            do {
                let loaded = try await read(url)
                guard token == attempt else { return false }
                file = loaded
            } catch {
                guard token == attempt else { return false }
                fail(error)
                return false
            }
        }
        guard let file, token == attempt else { return false }
        phase = .uploading
        do {
            try await send(file)
            guard token == attempt else { return false }
            clearFile()
            phase = .idle
            return true
        } catch is CancellationError {
            // The account changed or the session ended: the file belongs to the old session, so it is dropped.
            guard token == attempt else { return false }
            reset()
            return false
        } catch {
            guard token == attempt else { return false }
            fail(error)
            return false
        }
    }

    /// Drops everything, including a running attempt's late answer. Used when the signed-in account changes.
    func reset() {
        attempt += 1
        running = false
        clearFile()
        message = ""
        phase = .idle
    }

    private func fail(_ error: Error) {
        let text = error.localizedDescription
        message = text.isBlank ? "Upload did not finish. Try again." : text
        phase = .failed
    }

    private func clearFile() {
        pickedURL = nil
        file = nil
        fileName = ""
    }
}

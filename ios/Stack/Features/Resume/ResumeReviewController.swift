import Foundation
import Observation

/// Where one editable value lives in a `ResumeDocument`.
enum ResumeFieldAddress: Hashable {
    case single(String)
    case entry(section: String, id: String, field: String)
}

extension ResumeDocument {
    func value(at address: ResumeFieldAddress) -> String {
        switch address {
        case .single(let key): return single(key)
        case .entry(let section, let id, let field): return value(section, id, field)
        }
    }

    mutating func set(_ value: String, at address: ResumeFieldAddress) {
        switch address {
        case .single(let key): setSingle(key, value)
        case .entry(let section, let id, let field): setField(section, id, field, value)
        }
    }

    func original(at address: ResumeFieldAddress) -> String {
        switch address {
        case .single(let key): return original(single: key)
        case .entry(let section, let id, let field): return original(section, id, field)
        }
    }

    func isChanged(at address: ResumeFieldAddress) -> Bool {
        switch address {
        case .single(let key): return isChanged(single: key)
        case .entry(let section, let id, let field): return isChanged(section, id, field)
        }
    }

    mutating func restoreOriginal(at address: ResumeFieldAddress) {
        switch address {
        case .single(let key): restoreOriginal(single: key)
        case .entry(let section, let id, let field): restoreOriginal(section, id, field)
        }
    }
}

struct ResumeSectionSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let changed: Bool
}

/// The state and rules of the resume review screen, free of SwiftUI so they can be tested.
///
/// - Reads and saves carry a token; a response is applied only while its token is the latest and the
///   screen still belongs to the same account, so an older response never overwrites newer edits.
/// - Edits are written to a local draft (debounced, and flushed on dismissal or backgrounding). A draft
///   is cleared only when it still equals the exact snapshot a save submitted.
/// - Editing is off while a save is in flight, so a save cannot race an edit.
@MainActor
@Observable
final class ResumeReviewController {
    struct Backend {
        var read: (String) async throws -> JSON
        var retry: (String) async throws -> Void
        var save: (_ id: String, _ revision: JSON, _ values: [String: String], _ confirm: Bool) async throws -> JSON
        var saveRecords: (_ id: String, _ revision: JSON, _ records: [JSON], _ confirm: Bool, _ template: JSON) async throws -> JSON
        /// Refreshes the account snapshot after a successful save (best effort).
        var refreshAccount: () async -> Void
    }

    let resumeID: String
    let userID: String

    private(set) var document = ResumeDocument()
    private(set) var records: [JSON] = []
    private(set) var recordMode = false
    private(set) var loaded = false
    private(set) var saving = false
    private(set) var reads = 0
    private(set) var confirmed = false
    private(set) var revision: JSON = .null
    private(set) var processing: JSON = .null
    private(set) var warnings: [String] = []
    private(set) var sourceText = ""
    /// The newer document the backend holds while local edits are kept.
    private(set) var conflict: JSON?
    private(set) var restoredDraft = false
    var error = ""
    var message = ""

    private let backend: Backend
    private let drafts: ResumeDraftStoring
    private let currentUserID: () -> String
    private let onConfirmed: (() async -> Void)?
    private let writeDelay: Duration
    private var baseline: [String: String] = [:]
    private var baselineRecords: [JSON] = []
    private var template: JSON = .null
    private var readToken = 0
    private var saveToken = 0
    private var invalidated = false
    private var writeTask: Task<Void, Never>?

    init(resumeID: String, userID: String, backend: Backend, drafts: ResumeDraftStoring,
         currentUserID: @escaping () -> String, writeDelay: Duration = .milliseconds(300),
         onConfirmed: (() async -> Void)? = nil) {
        self.resumeID = resumeID
        self.userID = userID
        self.backend = backend
        self.drafts = drafts
        self.currentUserID = currentUserID
        self.writeDelay = writeDelay
        self.onConfirmed = onConfirmed
    }

    // MARK: State

    /// Whether this screen still belongs to the signed-in account that opened it.
    var isCurrent: Bool { !invalidated && !userID.isEmpty && currentUserID() == userID }

    var dirty: Bool {
        guard loaded else { return false }
        return recordMode ? records != baselineRecords : document.flatValues() != baseline
    }

    var canEdit: Bool { loaded && !saving && isCurrent && !recordMode }
    var canEditRecords: Bool { loaded && !saving && isCurrent && recordMode }
    var hasConflict: Bool { conflict != nil }
    var initialLoading: Bool { !loaded && reads > 0 }

    var statusLabel: String {
        if conflict != nil { return "Changed elsewhere" }
        return dirty ? "Unsaved changes" : (confirmed ? "Confirmed" : "Needs review")
    }

    var statusID: String {
        if conflict != nil { return "conflict" }
        return dirty ? "unsaved" : (confirmed ? "confirmed" : "needs-review")
    }

    /// The edits as they would be kept on disk right now.
    func currentDraft() -> ResumeReviewDraft {
        ResumeReviewDraft(userID: userID, resumeID: resumeID, baseRevision: revision, document: document, baseline: baseline,
                          records: recordMode ? records : nil, baselineRecords: recordMode ? baselineRecords : nil,
                          savedAt: Date().timeIntervalSince1970)
    }

    // MARK: Reading

    func load(retry: Bool = false, quiet: Bool = false) async {
        guard !userID.isEmpty else {
            if !quiet { error = "Sign in to review resume details." }
            return
        }
        guard isCurrent else { return }
        readToken += 1
        let token = readToken
        reads += 1
        if !quiet { error = "" }
        defer { reads -= 1 }
        do {
            if retry { try await backend.retry(resumeID) }
            let result = try await backend.read(resumeID)
            guard token == readToken, isCurrent, !saving else { return }
            apply(result)
        } catch is CancellationError {
            return
        } catch {
            guard token == readToken, isCurrent, !quiet else { return }
            self.error = error.localizedDescription
        }
    }

    private func applyMetadata(_ result: JSON) {
        processing = result["processing"]
        warnings = result["warnings"].strings
        sourceText = result["text"].string
        if !result["template"].isNull { template = result["template"] }
    }

    private func sameRevision(_ a: JSON, _ b: JSON) -> Bool { a.string == b.string }

    /// Applies a read. Local edits are never replaced: a newer revision is held as `conflict`.
    private func apply(_ result: JSON) {
        let incoming = ResumeIncoming(result)
        if loaded, dirty {
            applyMetadata(result)
            if !sameRevision(incoming.revision, revision) { conflict = result }
            return
        }
        applyMetadata(result)
        let sectionMode = !result["sections"].array.isEmpty || incoming.records.isEmpty
        if !loaded, let draft = drafts.load(userID: userID, resumeID: resumeID) {
            if draft.hasEdits {
                document = draft.document
                baseline = draft.baseline
                recordMode = draft.records != nil
                records = draft.records ?? []
                baselineRecords = draft.baselineRecords ?? []
                revision = draft.baseRevision
                confirmed = result["confirmed"].bool
                // Spelled out: `cond ? nil : result` would read `nil` as `JSON.null`, a non-nil conflict.
                if sameRevision(draft.baseRevision, incoming.revision) { conflict = nil } else { conflict = result }
                restoredDraft = true
                loaded = true
                return
            }
            drafts.clear(userID: userID, resumeID: resumeID)
        }
        conflict = nil
        restoredDraft = false
        recordMode = !sectionMode
        if recordMode {
            records = incoming.records
            baselineRecords = incoming.records
            document = ResumeDocument()
            baseline = [:]
        } else {
            document = ResumeDocument(values: incoming.values, originals: incoming.originals, labels: incoming.labels)
            baseline = document.flatValues()
            records = []
            baselineRecords = []
        }
        revision = incoming.revision
        confirmed = result["confirmed"].bool
        loaded = true
    }

    // MARK: Editing

    private func edited() {
        message = ""
        error = ""
        scheduleWrite()
    }

    func set(_ value: String, at address: ResumeFieldAddress) {
        guard canEdit else { return }
        document.set(value, at: address)
        edited()
    }

    func restoreOriginal(at address: ResumeFieldAddress) {
        guard canEdit else { return }
        document.restoreOriginal(at: address)
        edited()
    }

    func bullets(at address: ResumeFieldAddress) -> [String] { ResumeBullets.split(document.value(at: address)) }

    func setBullets(_ items: [String], at address: ResumeFieldAddress) {
        set(ResumeBullets.join(items.map(ResumeBullets.clean)), at: address)
    }

    func setBullet(_ text: String, at index: Int, of address: ResumeFieldAddress) {
        var items = bullets(at: address)
        guard items.indices.contains(index) else { return }
        // Return (or a pasted list) starts the following bullets rather than putting a newline in one.
        let pieces = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        items.replaceSubrange(index...index, with: pieces)
        setBullets(items, at: address)
    }

    func addBullet(to address: ResumeFieldAddress) {
        var items = bullets(at: address)
        items.append("")
        setBullets(items, at: address)
    }

    func removeBullet(at index: Int, of address: ResumeFieldAddress) {
        var items = bullets(at: address)
        guard items.indices.contains(index) else { return }
        items.remove(at: index)
        setBullets(items, at: address)
    }

    func moveBullet(at index: Int, by offset: Int, of address: ResumeFieldAddress) {
        var items = bullets(at: address)
        let target = index + offset
        guard items.indices.contains(index), items.indices.contains(target) else { return }
        items.swapAt(index, target)
        setBullets(items, at: address)
    }

    @discardableResult
    func addEntry(_ section: String) -> String? {
        guard canEdit else { return nil }
        guard let id = document.addEntry(section) else {
            error = "Up to \(ResumeSchema.maxEntries) entries per section."
            return nil
        }
        edited()
        return id
    }

    func removeEntry(_ section: String, _ id: String) {
        guard canEdit else { return }
        document.removeEntry(section, id)
        edited()
    }

    func moveEntry(_ section: String, _ id: String, by offset: Int) {
        guard canEdit, document.moveEntry(section, id, by: offset) else { return }
        edited()
    }

    /// A legacy record, or `.null` when the index is out of range (a binding can outlive its row).
    func record(_ index: Int) -> JSON { records.indices.contains(index) ? records[index] : .null }

    func setRecord(_ index: Int, key: String, value: JSON) {
        guard canEditRecords, records.indices.contains(index) else { return }
        records[index][key] = value
        edited()
    }

    // MARK: Draft

    private func scheduleWrite() {
        writeTask?.cancel()
        let delay = writeDelay
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.persistNow()
        }
    }

    /// Writes (or, when nothing differs from the saved version, removes) this screen's draft now.
    func persistNow() {
        guard loaded, !userID.isEmpty, !invalidated else { return }
        if dirty { drafts.save(currentDraft()) } else { drafts.clear(userID: userID, resumeID: resumeID) }
    }

    /// Called when the screen disappears or the app leaves the foreground.
    func flush() {
        writeTask?.cancel()
        writeTask = nil
        persistNow()
    }

    /// The account changed under this screen: keep its edits on disk for that account, then drop
    /// everything in memory and ignore any response still in flight.
    func invalidate() {
        flush()
        invalidated = true
        readToken += 1
        saveToken += 1
        document = ResumeDocument()
        records = []
        conflict = nil
        loaded = false
        error = ""
        message = ""
    }

    /// Explicit choice after a revision conflict: drop the local edits and show the newer version.
    func discardEditsAndReload() {
        guard !saving, let latest = conflict else { return }
        writeTask?.cancel()
        drafts.clear(userID: userID, resumeID: resumeID)
        loaded = false
        conflict = nil
        restoredDraft = false
        readToken += 1
        apply(latest)
        message = "Showing the latest version."
        error = ""
    }

    // MARK: Saving

    func save(confirm: Bool) async {
        guard !saving, loaded, isCurrent, conflict == nil else { return }
        if !recordMode, let problem = document.problem {
            error = problem
            return
        }
        let needsSave = dirty || !confirmed || !confirm
        writeTask?.cancel()
        writeTask = nil
        error = ""
        message = ""
        saving = true
        readToken += 1
        saveToken += 1
        let token = saveToken
        let submitted = currentDraft()
        let submittedRevision = revision
        if dirty { drafts.save(submitted) }
        do {
            if needsSave {
                let result: JSON
                if recordMode {
                    result = try await backend.saveRecords(resumeID, submittedRevision, submitted.records ?? [], confirm, template)
                } else {
                    result = try await backend.save(resumeID, submittedRevision, submitted.document.flatValues(), confirm)
                }
                guard token == saveToken, isCurrent else {
                    // The account changed; the draft stays until the exact snapshot is known saved.
                    saving = false
                    return
                }
                drafts.clear(ifMatching: submitted)
                applySaved(result, submitted: submitted, confirm: confirm)
                saving = false
                await backend.refreshAccount()
            } else {
                saving = false
            }
            guard token == saveToken, isCurrent else { return }
            message = confirm ? "Resume details confirmed." : "Draft saved."
            if confirm, let onConfirmed { await onConfirmed() }
        } catch is CancellationError {
            saving = false
        } catch {
            saving = false
            guard token == saveToken, isCurrent else { return }
            self.error = error.localizedDescription
            await load(quiet: true)
        }
    }

    private func applySaved(_ result: JSON, submitted: ResumeReviewDraft, confirm: Bool) {
        let incoming = ResumeIncoming(result)
        applyMetadata(result)
        if submitted.records != nil {
            records = result["records"].isNull ? (submitted.records ?? []) : incoming.records
            baselineRecords = records
        } else if incoming.hasFields {
            document = ResumeDocument(values: incoming.values, originals: incoming.originals,
                                      carried: submitted.document.flatOriginals(), labels: incoming.labels)
            baseline = document.flatValues()
        } else {
            baseline = submitted.document.flatValues()
        }
        if !incoming.revision.isNull { revision = incoming.revision }
        confirmed = result["confirmed"].isNull ? confirm : result["confirmed"].bool
        conflict = nil
        restoredDraft = false
    }

    // MARK: Navigation summaries

    func sectionSummaries() -> [ResumeSectionSummary] {
        guard !recordMode else { return [] }
        let current = document.flatValues()
        func changed(_ prefix: String) -> Bool {
            let keys = Set(current.keys.filter { $0.hasPrefix(prefix + ".") } + baseline.keys.filter { $0.hasPrefix(prefix + ".") })
            return keys.contains { current[$0] != baseline[$0] }
        }
        var result: [ResumeSectionSummary] = []
        for spec in ResumeSchema.sections {
            let detail: String
            if spec.repeated {
                let count = document.entries(of: spec.key).count
                detail = count == 0 ? "None yet" : (count == 1 ? "1 entry" : "\(count) entries")
            } else if spec.key == "profile" {
                detail = ["profile.name", "profile.email", "profile.phone"].map { document.single($0) }
                    .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Not found"
            } else {
                let items = ResumeBullets.split(document.single("\(spec.key).descriptions"))
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                detail = items.isEmpty ? "Not found" : (items.count == 1 ? "1 item" : "\(items.count) items")
            }
            result.append(ResumeSectionSummary(id: spec.key, title: spec.title, detail: detail, changed: changed(spec.key)))
        }
        for key in document.unknownEntrySections {
            let count = document.entries(of: key).count
            result.append(ResumeSectionSummary(id: key, title: document.sectionTitle(key),
                                               detail: count == 1 ? "1 entry" : "\(count) entries", changed: changed(key)))
        }
        if !document.strayKeys.isEmpty {
            result.append(ResumeSectionSummary(id: ResumeReviewController.otherSectionID, title: "Other fields",
                                               detail: "\(document.strayKeys.count) kept", changed: document.strayKeys.contains { current[$0] != baseline[$0] }))
        }
        return result
    }

    static let otherSectionID = "other"
}

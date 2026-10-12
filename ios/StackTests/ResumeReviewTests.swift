import XCTest
@testable import Stack

/// Synthetic resume values only; nothing here is a real person's resume.
private enum Sample {
    static let values: [String: String] = [
        "profile.name": "Ada Example", "profile.email": "ada@example.invalid", "profile.phone": "555-0100",
        "profile.location": "Chicago, IL", "profile.url": "https://example.invalid/ada", "profile.summary": "Analyst.",
        "profile.pronouns": "she/her",
        "educations.0.school": "Example State", "educations.0.degree": "B.S.", "educations.0.gpa": "3.8",
        "educations.0.date": "2023", "educations.0.location": "Springfield", "educations.0.descriptions": "Dean's list\nTreasurer",
        "educations.1.school": "Lakeside College", "educations.1.degree": "A.A.", "educations.1.gpa": "", "educations.1.date": "2021",
        "educations.1.location": "", "educations.1.descriptions": "Honors",
        "workExperiences.0.company": "Northwind", "workExperiences.0.jobTitle": "Intern", "workExperiences.0.date": "2024",
        "workExperiences.0.location": "Remote", "workExperiences.0.descriptions": "Built dashboards\nAutomated reports",
        "workExperiences.0.badge": "kept",
        "projects.0.project": "Churn study", "projects.0.date": "2024", "projects.0.descriptions": "Modeled churn",
        "skills.descriptions": "SQL\nPython", "additional.descriptions": "Tutor",
        "certifications.0.name": "Analyst certificate",
    ]

    static func fields(_ values: [String: String], labels: [String: String] = [:]) -> [JSON] {
        let grouped = Dictionary(grouping: values.keys) { key -> String in
            let parts = key.split(separator: ".").map(String.init)
            return parts.count == 3 ? "\(parts[0]).\(parts[1])" : parts[0]
        }
        return grouped.keys.sorted().map { group in
            let rows: [JSON] = (grouped[group] ?? []).sorted().map {
                ["key": .string($0), "label": .string(labels[$0] ?? "Descriptions"), "value": .string(values[$0] ?? "")]
            }
            return ["key": .string(group), "label": .string(group), "summary": "", "fields": .array(rows)]
        }
    }

    static func document(_ values: [String: String] = Sample.values, revision: Int = 1, confirmed: Bool = false,
                         originals: [String: String]? = nil) -> JSON {
        var json: JSON = ["revision": .number(Double(revision)), "confirmed": .bool(confirmed), "text": "synthetic",
                          "sections": .array(fields(values))]
        if let originals { json["original_values"] = .object(originals.mapValues { .string($0) }) }
        return json
    }
}

// MARK: Document model

final class ResumeDocumentTests: XCTestCase {
    func testEveryContractFieldIsEditableAndRoundTrips() {
        let document = ResumeDocument(values: Sample.values)
        XCTAssertEqual(document.flatValues(), Sample.values.mapValues { $0 })
        // Every field the agreed contract names has an editor.
        let contract: [String: [String]] = [
            "profile": ["name", "email", "phone", "location", "url", "summary"],
            "educations": ["school", "degree", "gpa", "date", "location", "descriptions"],
            "workExperiences": ["company", "jobTitle", "date", "location", "descriptions"],
            "projects": ["project", "date", "descriptions"],
            "skills": ["descriptions"], "additional": ["descriptions"],
        ]
        for (section, names) in contract {
            XCTAssertEqual(Set(ResumeSchema.spec(section)?.fields.map(\.name) ?? []), Set(names), section)
        }
    }

    func testUnknownFieldsAreKeptAndReachable() {
        var document = ResumeDocument(values: Sample.values, labels: ["workExperiences.badge": "Badge"])
        XCTAssertEqual(document.extraKeys(in: "profile"), ["profile.pronouns"])
        XCTAssertEqual(document.unknownEntrySections, ["certifications"])
        XCTAssertEqual(document.entries(of: "workExperiences")[0].values["badge"], "kept")
        XCTAssertEqual(document.label(section: "workExperiences", field: "badge"), "Badge")
        document.setSingle("profile.pronouns", "they/them")
        XCTAssertEqual(document.flatValues()["profile.pronouns"], "they/them")
        XCTAssertEqual(document.flatValues()["certifications.0.name"], "Analyst certificate")
        XCTAssertEqual(document.flatValues()["workExperiences.0.badge"], "kept")
    }

    func testAddingFirstEntriesToEmptySections() {
        var document = ResumeDocument(values: [:])
        for section in ["educations", "workExperiences", "projects"] {
            let id = document.addEntry(section)
            XCTAssertNotNil(id, section)
        }
        let education = document.entries(of: "educations")[0].id
        document.setField("educations", education, "school", "Example State")
        let work = document.entries(of: "workExperiences")[0].id
        document.setField("workExperiences", work, "jobTitle", "Analyst")
        // The project stays blank and is not sent.
        let flat = document.flatValues()
        XCTAssertEqual(flat["educations.0.school"], "Example State")
        XCTAssertEqual(flat["workExperiences.0.jobTitle"], "Analyst")
        XCTAssertFalse(flat.keys.contains { $0.hasPrefix("projects.") })
        XCTAssertNil(ResumeDocument(values: [:]).problem)
    }

    func testEntryLimitIsTwenty() {
        var document = ResumeDocument(values: [:])
        for _ in 0..<ResumeSchema.maxEntries { XCTAssertNotNil(document.addEntry("projects")) }
        XCTAssertNil(document.addEntry("projects"))
        XCTAssertEqual(document.entries(of: "projects").count, 20)
    }

    func testRemoveAndReorderKeepOriginalsAndRenumberKeys() {
        var document = ResumeDocument(values: Sample.values)
        let first = document.entries(of: "educations")[0].id
        let second = document.entries(of: "educations")[1].id
        document.setField("educations", first, "school", "Corrected State")
        XCTAssertTrue(document.moveEntry("educations", first, by: 1))
        XCTAssertFalse(document.moveEntry("educations", first, by: 1), "cannot move past the end")
        var flat = document.flatValues()
        XCTAssertEqual(flat["educations.0.school"], "Lakeside College")
        XCTAssertEqual(flat["educations.1.school"], "Corrected State")
        XCTAssertEqual(document.flatOriginals()["educations.1.school"], "Example State", "the original travels with the entry")
        XCTAssertTrue(document.isChanged("educations", first, "school"))
        XCTAssertFalse(document.isChanged("educations", second, "school"))

        document.removeEntry("educations", second)
        flat = document.flatValues()
        XCTAssertEqual(flat["educations.0.school"], "Corrected State")
        XCTAssertNil(flat["educations.1.school"], "no stale key is left behind")
        XCTAssertEqual(flat["educations.0.degree"], "B.S.", "unedited fields of the surviving entry are untouched")

        document.restoreOriginal("educations", first, "school")
        XCTAssertEqual(document.flatValues()["educations.0.school"], "Example State")
    }

    func testBulletsEditIndependently() {
        var document = ResumeDocument(values: Sample.values)
        let id = document.entries(of: "workExperiences")[0].id
        XCTAssertEqual(document.bullets("workExperiences", id, "descriptions"), ["Built dashboards", "Automated reports"])
        var items = document.bullets("workExperiences", id, "descriptions")
        items.append("")
        document.setBullets("workExperiences", id, "descriptions", items)
        XCTAssertEqual(document.bullets("workExperiences", id, "descriptions").count, 3, "a new blank item stays editable")
        XCTAssertEqual(document.flatValues()["workExperiences.0.descriptions"], "Built dashboards\nAutomated reports",
                       "blank items are not saved")
        items.swapAt(0, 1)
        document.setBullets("workExperiences", id, "descriptions", items)
        XCTAssertEqual(document.flatValues()["workExperiences.0.descriptions"], "Automated reports\nBuilt dashboards")
    }

    func testOriginalsFromBackendWinOverFieldValue() {
        let document = ResumeDocument(values: ["profile.name": "Ada Corrected", "educations.0.school": "Corrected State"],
                                      originals: ["profile.name": "Ada Exampel", "educations.0.school": "Exmaple State"])
        XCTAssertEqual(document.original(single: "profile.name"), "Ada Exampel")
        XCTAssertTrue(document.isChanged(single: "profile.name"))
        XCTAssertEqual(document.original("educations", "educations.0", "school"), "Exmaple State")
        let fallback = ResumeDocument(values: ["profile.name": "Ada Example"])
        XCTAssertEqual(fallback.original(single: "profile.name"), "Ada Example")
        XCTAssertFalse(fallback.isChanged(single: "profile.name"))
    }

    func testIncomingReadsSectionsAndFlatValuesAndKeepsUnknownKeys() {
        var json = Sample.document(["profile.name": "Ada Example", "profile.custom": "x"])
        json["values"] = ["profile.name": "ignored", "profile.extra": "from flat map"]
        let incoming = ResumeIncoming(json)
        XCTAssertEqual(incoming.values["profile.name"], "Ada Example", "section fields win")
        XCTAssertEqual(incoming.values["profile.extra"], "from flat map")
        XCTAssertEqual(incoming.values["profile.custom"], "x")
        XCTAssertNil(incoming.originals)
        XCTAssertEqual(incoming.labels["profile.custom"], "Descriptions", "unknown fields use the backend label")
    }
}

// MARK: Draft storage

final class ResumeDraftStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-drafts-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func draft(user: String, resume: String = "resume-1", name: String = "Edited") -> ResumeReviewDraft {
        var document = ResumeDocument(values: ["profile.name": "Ada"])
        document.setSingle("profile.name", name)
        return ResumeReviewDraft(userID: user, resumeID: resume, baseRevision: 3, document: document,
                                 baseline: ["profile.name": "Ada"], savedAt: 1)
    }

    func testDraftSurvivesANewStoreInstance() {
        FileResumeDraftStore(root: root).save(draft(user: "user-a"))
        let reloaded = FileResumeDraftStore(root: root).load(userID: "user-a", resumeID: "resume-1")
        XCTAssertEqual(reloaded?.document.single("profile.name"), "Edited")
        XCTAssertEqual(reloaded?.baseRevision, 3)
        XCTAssertTrue(reloaded?.hasEdits ?? false)
    }

    func testDraftsAreIsolatedPerAccountAndResume() {
        let store = FileResumeDraftStore(root: root)
        store.save(draft(user: "user-a"))
        XCTAssertNil(store.load(userID: "user-b", resumeID: "resume-1"))
        XCTAssertNil(store.load(userID: "user-a", resumeID: "resume-2"))
        XCTAssertNil(store.load(userID: "", resumeID: "resume-1"))
        store.save(draft(user: "user-b", name: "Other account"))
        XCTAssertEqual(store.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"), "Edited")
        XCTAssertEqual(store.load(userID: "user-b", resumeID: "resume-1")?.document.single("profile.name"), "Other account")
    }

    func testIdentifiersAreNotOnDisk() throws {
        FileResumeDraftStore(root: root).save(draft(user: "user-secret-a", resume: "resume-secret-1"))
        let names = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? []
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(names.contains { $0.contains("secret") })
    }

    func testClearIfMatchingOnlyRemovesTheSubmittedSnapshot() {
        let store = FileResumeDraftStore(root: root)
        let submitted = draft(user: "user-a", name: "Submitted")
        store.save(draft(user: "user-a", name: "Edited after submitting"))
        XCTAssertFalse(store.clear(ifMatching: submitted))
        XCTAssertNotNil(store.load(userID: "user-a", resumeID: "resume-1"))
        store.save(submitted)
        XCTAssertTrue(store.clear(ifMatching: submitted))
        XCTAssertNil(store.load(userID: "user-a", resumeID: "resume-1"))
    }

    func testCorruptFileIsIgnored() throws {
        let store = FileResumeDraftStore(root: root)
        store.save(draft(user: "user-a"))
        let files = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        for file in files where file.pathExtension == "json" { try Data("{not json".utf8).write(to: file) }
        XCTAssertNil(store.load(userID: "user-a", resumeID: "resume-1"))
    }
}

// MARK: Controller

@MainActor
private final class FakeBackend {
    var document: JSON = Sample.document()
    var holdReads = false
    var heldReads: [(JSON, CheckedContinuation<JSON, Error>)] = []
    var readError: Error?
    var holdSave = false
    var heldSave: CheckedContinuation<JSON, Error>?
    var saveError: Error?
    var saves: [(revision: JSON, values: [String: String], confirm: Bool)] = []
    var recordSaves: [(revision: JSON, records: [JSON], confirm: Bool)] = []
    var refreshes = 0
    var onSave: (() -> Void)?

    var backend: ResumeReviewController.Backend {
        ResumeReviewController.Backend(
            read: { [unowned self] _ in try await self.read() },
            retry: { _ in },
            save: { [unowned self] _, revision, values, confirm in try await self.save(revision, values, confirm) },
            saveRecords: { [unowned self] _, revision, records, confirm, _ in
                self.recordSaves.append((revision, records, confirm))
                return ["revision": .number(revision.double + 1), "confirmed": .bool(confirm), "records": .array(records)]
            },
            refreshAccount: { [unowned self] in self.refreshes += 1 })
    }

    private func read() async throws -> JSON {
        if let readError { throw readError }
        let snapshot = document
        if holdReads {
            return try await withCheckedThrowingContinuation { heldReads.append((snapshot, $0)) }
        }
        return snapshot
    }

    private func save(_ revision: JSON, _ values: [String: String], _ confirm: Bool) async throws -> JSON {
        saves.append((revision, values, confirm))
        onSave?()
        if let saveError { throw saveError }
        if holdSave {
            return try await withCheckedThrowingContinuation { heldSave = $0 }
        }
        return commit(values, confirm)
    }

    func commit(_ values: [String: String], _ confirm: Bool) -> JSON {
        let next = document["revision"].int + 1
        document = Sample.document(values, revision: next, confirmed: confirm)
        return document
    }

    func settle() async { for _ in 0..<30 { await Task.yield() } }
}

private struct ConflictError: LocalizedError { var errorDescription: String? { "This resume changed." } }

@MainActor
final class ResumeReviewControllerTests: XCTestCase {
    private var root: URL!
    private var drafts: FileResumeDraftStore!
    private var user = "user-a"

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("resume-review-\(UUID().uuidString)")
        drafts = FileResumeDraftStore(root: root)
        user = "user-a"
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func controller(_ fake: FakeBackend, user: String = "user-a", confirmed: (() async -> Void)? = nil) -> ResumeReviewController {
        ResumeReviewController(resumeID: "resume-1", userID: user, backend: fake.backend, drafts: drafts,
                               currentUserID: { [unowned self] in self.user }, writeDelay: .milliseconds(5), onConfirmed: confirmed)
    }

    private let name = ResumeFieldAddress.single("profile.name")

    // MARK: Draft persistence

    func testEditsSurviveDismissalAndRelaunch() async {
        let fake = FakeBackend()
        let first = controller(fake)
        await first.load()
        first.set("Ada Corrected", at: name)
        first.flush()

        let second = controller(fake)
        await second.load()
        XCTAssertEqual(second.document.value(at: name), "Ada Corrected")
        XCTAssertTrue(second.dirty)
        XCTAssertTrue(second.restoredDraft)
        XCTAssertEqual(second.document.original(at: name), "Ada Example", "original is kept next to the correction")
        XCTAssertNil(second.conflict)
    }

    func testDebouncedWriteReachesDisk() async throws {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Typed", at: name)
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(drafts.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"), "Typed")
    }

    func testRevertingToTheSavedValueRemovesTheDraft() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Changed", at: name)
        screen.flush()
        XCTAssertNotNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
        screen.restoreOriginal(at: name)
        screen.flush()
        XCTAssertFalse(screen.dirty)
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
    }

    func testAnotherAccountNeverSeesTheDraft() async {
        let fake = FakeBackend()
        let owner = controller(fake)
        await owner.load()
        owner.set("Private edit", at: name)
        owner.flush()

        user = "user-b"
        let other = controller(fake, user: "user-b")
        await other.load()
        XCTAssertEqual(other.document.value(at: name), "Ada Example")
        XCTAssertFalse(other.dirty)
        XCTAssertFalse(other.restoredDraft)

        user = "user-a"
        let again = controller(fake)
        await again.load()
        XCTAssertEqual(again.document.value(at: name), "Private edit", "the same account finds its draft after signing in again")
    }

    func testNoAccountMeansNothingIsReadOrKept() async {
        let fake = FakeBackend()
        user = ""
        let screen = controller(fake, user: "")
        await screen.load()
        XCTAssertFalse(screen.loaded)
        XCTAssertFalse(screen.error.isEmpty)
        screen.set("x", at: name)
        screen.flush()
        XCTAssertNil(drafts.load(userID: "", resumeID: "resume-1"))
    }

    // MARK: Stale responses

    func testOlderReadCannotOverwriteNewerRead() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        fake.holdReads = true
        let older = Task { await screen.load() }
        await fake.settle()
        fake.document = Sample.document(["profile.name": "Newer"], revision: 2)
        let newer = Task { await screen.load() }
        await fake.settle()
        XCTAssertEqual(fake.heldReads.count, 2)
        fake.heldReads[1].1.resume(returning: fake.heldReads[1].0)
        await newer.value
        fake.heldReads[0].1.resume(returning: fake.heldReads[0].0)
        await older.value
        XCTAssertEqual(screen.document.value(at: name), "Newer")
        XCTAssertEqual(screen.revision.int, 2)
    }

    func testReadFinishingAfterAnEditKeepsTheEdit() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        fake.holdReads = true
        let poll = Task { await screen.load(quiet: true) }
        await fake.settle()
        screen.set("Typed while reading", at: name)
        fake.document = Sample.document(["profile.name": "Server newer"], revision: 2, confirmed: true)
        fake.heldReads[0].1.resume(returning: fake.document)
        await poll.value
        XCTAssertEqual(screen.document.value(at: name), "Typed while reading")
        XCTAssertNotNil(screen.conflict, "the newer revision is held, not applied")
        XCTAssertEqual(screen.revision.int, 1)
        XCTAssertEqual(screen.statusID, "conflict")
    }

    func testReadForSameRevisionWhileEditingOnlyRefreshesProcessing() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Typed", at: name)
        var polled = fake.document
        polled["processing"] = ["status": "completed"]
        fake.document = polled
        await screen.load(quiet: true)
        XCTAssertNil(screen.conflict)
        XCTAssertEqual(screen.document.value(at: name), "Typed")
        XCTAssertEqual(screen.processing["status"].string, "completed")
    }

    func testReadReturningAfterAccountChangeIsDropped() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        fake.holdReads = true
        let reading = Task { await screen.load() }
        await fake.settle()
        user = "user-b"
        fake.heldReads[0].1.resume(returning: fake.heldReads[0].0)
        await reading.value
        XCTAssertFalse(screen.loaded)
        XCTAssertEqual(screen.document.flatValues(), [:])
    }

    func testInvalidatedScreenKeepsItsDraftButRendersNothing() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Kept for account A", at: name)
        screen.invalidate()
        XCTAssertFalse(screen.loaded)
        XCTAssertEqual(screen.document.flatValues(), [:])
        XCTAssertEqual(drafts.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"), "Kept for account A")
        screen.set("ignored", at: name)
        XCTAssertEqual(screen.document.value(at: name), "")
        await screen.load()
        XCTAssertFalse(screen.loaded, "an invalidated screen does not read again")
    }

    // MARK: Conflict

    func testRevisionConflictKeepsDraftUntilExplicitDiscard() async {
        let fake = FakeBackend()
        let first = controller(fake)
        await first.load()
        first.set("My edit", at: name)
        first.flush()

        fake.document = Sample.document(["profile.name": "Someone else"], revision: 2)
        let second = controller(fake)
        await second.load()
        XCTAssertEqual(second.document.value(at: name), "My edit")
        XCTAssertNotNil(second.conflict)
        XCTAssertNotNil(drafts.load(userID: "user-a", resumeID: "resume-1"))

        await second.save(confirm: false)
        XCTAssertTrue(fake.saves.isEmpty, "a stale draft is never submitted")

        second.discardEditsAndReload()
        XCTAssertEqual(second.document.value(at: name), "Someone else")
        XCTAssertEqual(second.revision.int, 2)
        XCTAssertNil(second.conflict)
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
        XCTAssertFalse(second.dirty)
    }

    func testSaveRejectedForStaleRevisionPreservesEditsAndShowsConflict() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("My edit", at: name)
        fake.saveError = ConflictError()
        fake.onSave = { fake.document = Sample.document(["profile.name": "Remote"], revision: 5) }
        await screen.save(confirm: false)
        XCTAssertEqual(screen.error, "This resume changed.")
        XCTAssertEqual(screen.document.value(at: name), "My edit")
        XCTAssertNotNil(screen.conflict)
        XCTAssertFalse(screen.saving)
        XCTAssertEqual(drafts.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"), "My edit")
    }

    // MARK: Saving

    func testSaveSubmitsEditsAtTheLoadedRevisionThenClearsDraftAndAdvancesRevision() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Ada Corrected", at: name)
        screen.flush()
        await screen.save(confirm: false)
        XCTAssertEqual(fake.saves.count, 1)
        XCTAssertEqual(fake.saves[0].revision.int, 1)
        XCTAssertEqual(fake.saves[0].values["profile.name"], "Ada Corrected")
        XCTAssertFalse(fake.saves[0].confirm)
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
        XCTAssertEqual(screen.revision.int, 2)
        XCTAssertFalse(screen.dirty)
        XCTAssertEqual(screen.message, "Draft saved.")
        XCTAssertEqual(fake.refreshes, 1)
        XCTAssertEqual(screen.document.original(at: name), "Ada Example", "the original is carried across a save")

        await screen.save(confirm: true)
        XCTAssertEqual(fake.saves.count, 2)
        XCTAssertEqual(fake.saves[1].revision.int, 2, "confirm uses the revision the previous save returned")
        XCTAssertTrue(fake.saves[1].confirm)
        XCTAssertTrue(screen.confirmed)
    }

    func testEditsAreIgnoredWhileSavingAndSnapshotIsWhatWasSubmitted() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Submitted value", at: name)
        fake.holdSave = true
        let saving = Task { await screen.save(confirm: false) }
        await fake.settle()
        XCTAssertTrue(screen.saving)
        screen.set("Typed during save", at: name)
        screen.addEntry("projects")
        XCTAssertEqual(screen.document.value(at: name), "Submitted value")
        XCTAssertEqual(fake.saves[0].values["profile.name"], "Submitted value")
        fake.heldSave?.resume(returning: fake.commit(fake.saves[0].values, false))
        await saving.value
        XCTAssertFalse(screen.saving)
        XCTAssertEqual(screen.document.value(at: name), "Submitted value")
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
    }

    func testSaveDoesNotClearADraftThatChangedMeanwhile() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Submitted value", at: name)
        fake.holdSave = true
        let saving = Task { await screen.save(confirm: false) }
        await fake.settle()
        // A reopened screen for the same resume wrote newer edits while the save was in flight.
        var newer = screen.currentDraft()
        newer.document.setSingle("profile.name", "Edited elsewhere afterwards")
        drafts.save(newer)
        fake.heldSave?.resume(returning: fake.commit(fake.saves[0].values, false))
        await saving.value
        XCTAssertEqual(drafts.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"),
                       "Edited elsewhere afterwards")
    }

    func testFailedSaveKeepsEditsAndDraft() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Will not save", at: name)
        fake.saveError = URLError(.notConnectedToInternet)
        await screen.save(confirm: true)
        XCTAssertFalse(screen.error.isEmpty)
        XCTAssertTrue(screen.dirty)
        XCTAssertNil(screen.conflict, "same revision on the server: this is not a conflict")
        XCTAssertEqual(drafts.load(userID: "user-a", resumeID: "resume-1")?.document.single("profile.name"), "Will not save")
        fake.saveError = nil
        await screen.save(confirm: true)
        XCTAssertTrue(screen.confirmed)
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
    }

    func testSaveResponseAfterAccountChangeDoesNotTouchTheNewAccount() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("Account A edit", at: name)
        fake.holdSave = true
        let saving = Task { await screen.save(confirm: true) }
        await fake.settle()
        user = "user-b"
        fake.heldSave?.resume(returning: fake.commit(fake.saves[0].values, true))
        await saving.value
        XCTAssertEqual(fake.refreshes, 0, "no account refresh for a screen that no longer belongs to the signed-in account")
        XCTAssertFalse(screen.confirmed)
        XCTAssertNotNil(drafts.load(userID: "user-a", resumeID: "resume-1"), "kept until the save is known to have landed")
    }

    func testConfirmOfAnAlreadyConfirmedUntouchedResumeOnlyContinues() async {
        let fake = FakeBackend()
        fake.document = Sample.document(confirmed: true)
        var continued = 0
        let screen = controller(fake) { continued += 1 }
        await screen.load()
        await screen.save(confirm: true)
        XCTAssertTrue(fake.saves.isEmpty)
        XCTAssertEqual(continued, 1)
    }

    func testConfirmingAnUneditedReviewSubmitsTheSavedValues() async {
        let fake = FakeBackend()
        var continued = 0
        let screen = controller(fake) { continued += 1 }
        await screen.load()
        await screen.save(confirm: true)
        XCTAssertEqual(fake.saves.count, 1)
        XCTAssertEqual(fake.saves[0].values["profile.name"], "Ada Example")
        XCTAssertEqual(fake.saves[0].values["profile.pronouns"], "she/her", "unknown fields are sent back unchanged")
        XCTAssertEqual(continued, 1)
    }

    func testRemovingAnEntrySendsNoStaleKeys() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        let second = screen.document.entries(of: "educations")[1].id
        screen.removeEntry("educations", second)
        await screen.save(confirm: false)
        XCTAssertNotNil(fake.saves[0].values["educations.0.school"])
        XCTAssertFalse(fake.saves[0].values.keys.contains { $0.hasPrefix("educations.1.") })
        XCTAssertEqual(screen.document.entries(of: "educations").count, 1)
    }

    func testSavedValuesAreReloadedAfterTheServerNormalizes() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        screen.set("  Ada Spaced  ", at: name)
        await screen.save(confirm: false)
        XCTAssertEqual(fake.saves[0].values["profile.name"], "Ada Spaced")
        XCTAssertEqual(screen.document.value(at: name), "Ada Spaced")
    }

    // MARK: Legacy records

    func testLegacyRecordsAreEditedKeptAndSavedWithTheirRevision() async {
        let fake = FakeBackend()
        fake.document = ["revision": 4, "confirmed": false, "sections": [],
                         "records": [["id": "r1", "text": "Built dashboards", "kind": "bullet", "allow_omit": false]]]
        let first = controller(fake)
        await first.load()
        XCTAssertTrue(first.recordMode)
        first.setRecord(0, key: "text", value: "Built weekly dashboards")
        first.flush()

        let second = controller(fake)
        await second.load()
        XCTAssertTrue(second.recordMode)
        XCTAssertEqual(second.record(0)["text"].string, "Built weekly dashboards")
        XCTAssertTrue(second.dirty)
        await second.save(confirm: false)
        XCTAssertEqual(fake.recordSaves.count, 1)
        XCTAssertEqual(fake.recordSaves[0].revision.int, 4)
        XCTAssertEqual(fake.recordSaves[0].records[0]["text"].string, "Built weekly dashboards")
        XCTAssertNil(drafts.load(userID: "user-a", resumeID: "resume-1"))
        XCTAssertEqual(second.record(9), .null)
    }

    // MARK: Navigation

    func testSectionSummariesShowEveryHistoricalSectionAndEditedState() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        var summaries = screen.sectionSummaries()
        XCTAssertEqual(summaries.map(\.id), ["profile", "educations", "workExperiences", "projects", "skills", "additional",
                                              "certifications"])
        XCTAssertEqual(summaries.first { $0.id == "educations" }?.detail, "2 entries")
        XCTAssertFalse(summaries.contains { $0.changed })
        screen.set("Edited", at: .single("skills.descriptions"))
        summaries = screen.sectionSummaries()
        XCTAssertEqual(summaries.filter(\.changed).map(\.id), ["skills"])
    }

    func testEmptyResumeStillOffersEverySection() async {
        let fake = FakeBackend()
        fake.document = ["revision": 1, "confirmed": false, "sections": []]
        let screen = controller(fake)
        await screen.load()
        XCTAssertTrue(screen.loaded)
        XCTAssertFalse(screen.recordMode)
        XCTAssertEqual(screen.sectionSummaries().count, 6)
        let id = screen.addEntry("educations")
        XCTAssertNotNil(id)
        screen.set("Example State", at: .entry(section: "educations", id: id ?? "", field: "school"))
        await screen.save(confirm: false)
        XCTAssertEqual(fake.saves[0].values["educations.0.school"], "Example State")
    }

    func testBulletReturnStartsANewItem() async {
        let fake = FakeBackend()
        let screen = controller(fake)
        await screen.load()
        let skills = ResumeFieldAddress.single("skills.descriptions")
        screen.setBullet("SQL\nR", at: 0, of: skills)
        XCTAssertEqual(screen.bullets(at: skills), ["SQL", "R", "Python"])
        screen.moveBullet(at: 2, by: -1, of: skills)
        XCTAssertEqual(screen.bullets(at: skills), ["SQL", "Python", "R"])
        screen.removeBullet(at: 0, of: skills)
        XCTAssertEqual(screen.bullets(at: skills), ["Python", "R"])
    }
}

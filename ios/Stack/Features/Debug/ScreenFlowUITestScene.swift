#if DEBUG
import SwiftUI
import UIKit

/// Offline UI-test host for the real Settings, Resume, Network, Applications, Jobs-detail and sign-in
/// screens. Excluded entirely from Release builds. It never signs in, adopts a token or reaches a live
/// service: every request goes through `ScreenFlowURLProtocol`, which answers from a fictional account.
/// Chosen with the launch argument `--screen-flow=<settings|resume|network|applications|jobs|onboarding|recovery>`.
@MainActor
struct ScreenFlowUITestScene: View {
    @State private var store = ScreenFlowUITestScene.makeStore()

    static var flow: String {
        let prefix = "--screen-flow="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? ""
    }

    private static func makeStore() -> AppStore { makeStore(flow: flow) }

    static func makeStore(flow: String) -> AppStore {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenFlowURLProtocol.self]
        let api = APIClient(origin: URL(string: "https://stack.invalid")!, session: URLSession(configuration: configuration))
        let store = AppStore(api: api)
        if ProcessInfo.processInfo.arguments.contains("--reset-resume-drafts") { FileResumeDraftStore.shared.removeAll() }
        ScreenFlowServer.shared.reset(flow: flow)
        store.account = AccountState(raw: ScreenFlowServer.shared.snapshot())
        switch flow {
        case "onboarding":
            store.phase = .signedOut
        case "recovery":
            store.phase = .admission
            store.googleInfo = ["username": "ada.example", "can_recover": true, "google": false]
        default:
            store.phase = .ready
        }
        return store
    }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            screen
        }
        .environment(store)
        .tint(Palette.dark)
        .transaction { if ProcessInfo.processInfo.arguments.contains("--disable-draft-animations") { $0.animation = nil; $0.disablesAnimations = true } }
    }

    @ViewBuilder
    private var screen: some View {
        switch Self.flow {
        case "settings": ProfileView()
        case "resume": ResumeView(onProfile: {})
        case "resume-review": ResumeReviewFixtureHost()
        case "network": NetworkView(onProfile: {})
        case "applications", "applications-autofill-unavailable": ApplicationsView(onProfile: {}, onNavigate: { _ in })
        case "jobs": ScreenFlowJobHost(job: Job(ScreenFlowServer.job))
        case "deck", "deck-paging": JobsView(onProfile: {})
        case "onboarding": AccessView()
        case "recovery": InvitationView()
        default: Text("Unknown screen flow").font(Typeface.title)
        }
    }
}

/// The real resume review sheet over a fixture host, so a test can close it, reopen it and switch accounts.
@MainActor
private struct ResumeReviewFixtureHost: View {
    @Environment(AppStore.self) private var store
    @State private var open = true

    var body: some View {
        VStack(spacing: Spacing.stack) {
            Text("Resume review host").font(Typeface.title).foregroundStyle(Palette.ink)
            StackButton(label: "Open resume review") { open = true }
        }
        .padding(.horizontal, Spacing.page)
        .sheet(isPresented: $open) {
            ResumeDetailsView(resume: ResumeItem(["id": "resume-1", "name": "Ada Example resume.pdf", "size": 1000,
                                                  "created_at": 1_700_000_000, "details_status": "Needs review"]))
                .environment(store)
        }
    }
}

/// A deck card, the real detail sheet and the listing browser (a stub with `--stub-listing-browser`).
@MainActor
private struct ScreenFlowJobHost: View {
    let job: Job
    @Environment(AppStore.self) private var store
    @State private var detail: Job?
    @State private var listing: JobListing?

    var body: some View {
        VStack(spacing: Spacing.stack) {
            JobCard(job: job, onOpen: {
                if listing == nil { listing = JobListing(job: job) }
            }, accessibilityID: "job-card")
                .frame(height: 440)
            StackButton(label: "Open job details") { detail = job }
        }
        .padding(.horizontal, Spacing.page)
        .sheet(item: $detail) { JobDetailView(job: $0).environment(store) }
        .jobListingBrowser(item: $listing)
    }
}

/// The fictional account and the fixture's server rules. Fails each flow's first risky request once so
/// the recovery paths are exercised: a model-settings load, a LinkedIn profile load and a notes save.
final class ScreenFlowServer: @unchecked Sendable {
    static let shared = ScreenFlowServer()

    static let resumeName = "Ada Example - Senior Product Data Analyst Resume 2026 (reviewed, final version for analytics roles).pdf"
    static let jobTitle = "Senior Product Data Analyst, Growth Experimentation and Marketplace Insights (Hybrid)"
    static let fit = "Strong match: your SQL, experimentation and dashboard experience line up with the core duties. "
        + "Gaps to confirm: the listing asks for five years of experience and you have two. "
        + "The team also expects stakeholder-facing presentations, which your project work covers."
    static let tags = ["SQL", "Python", "Experimentation", "Dashboards", "A/B testing", "Stakeholders", "Remote friendly", "Growth"]
    static let linkedInFailure = "LinkedIn profile service is unavailable. Try again."
    static let notesFailure = "We couldn't save your notes. Check your connection and try again."
    static let modelFailure = "Model settings are unavailable right now."

    private let lock = NSLock()
    private var flow = ""
    private var notes = ""
    private var linkedInLoads = 0
    private var notesSaves = 0
    private var modelFailed = false
    private var autofillStarted = false
    private var reviewValues: [String: String] = [:]
    private var reviewRevision = 1
    private var reviewConfirmed = false
    private var reviewDetailsConfirmed = false
    private var reviewUnavailable = false
    private var reviewOriginalValues: [String: String] = [:]
    private var reviewProcessing: JSON = .null
    private var reviewImportPolls = 0
    private var reviewAccountProcessing: JSON?
    // Separate synthetic server storage, never the account's live backend or draft files.
    private let reviewPersistence = UserDefaults(suiteName: "StackOfflineResumeReviewServer")!
    private var reviewPersistenceKey: String { "resume-1:" + reviewUser }
    private var reviewUser = "fixture-user"

    /// A synthetic resume covering every field the review screen edits, plus one field it does not know.
    static let reviewFixture: [String: String] = [
        "profile.name": "Ada Example", "profile.email": "ada@example.invalid", "profile.phone": "555-0100",
        "profile.location": "Chicago, IL", "profile.url": "https://example.invalid/ada",
        "profile.summary": "Analyst who explains experiments clearly.", "profile.headline": "Experimentation analyst",
        "educations.0.school": "Example State University", "educations.0.degree": "B.S. Statistics",
        "educations.0.gpa": "3.8", "educations.0.date": "May 2023", "educations.0.location": "Springfield, IL",
        "educations.0.descriptions": "Dean's list\nStatistics club treasurer",
        "educations.1.school": "Lakeside Community College", "educations.1.degree": "A.A. General Studies",
        "educations.1.gpa": "3.9", "educations.1.date": "May 2021", "educations.1.location": "Lakeside, IL",
        "educations.1.descriptions": "Honors program",
        "workExperiences.0.company": "Northwind Analytics", "workExperiences.0.jobTitle": "Data Analyst Intern",
        "workExperiences.0.date": "Summer 2024", "workExperiences.0.location": "Remote",
        "workExperiences.0.descriptions": "Built weekly dashboards\nAutomated the reporting pipeline\nPresented results to stakeholders",
        "projects.0.project": "Churn study", "projects.0.date": "2024", "projects.0.descriptions": "Modeled customer churn\nShared findings",
        "skills.descriptions": "SQL\nPython\nExperiment design", "additional.descriptions": "Volunteer data tutor",
    ]
    private var decisions: [JSON] = []

    func reset(flow: String) {
        lock.lock(); defer { lock.unlock() }
        self.flow = flow
        notes = ""
        linkedInLoads = 0
        notesSaves = 0
        modelFailed = false
        autofillStarted = false
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        reviewUser = argument("resume-review-user") ?? "fixture-user"
        if arguments.contains("--reset-resume-drafts") {
            reviewPersistence.removePersistentDomain(forName: "StackOfflineResumeReviewServer")
        }
        reviewValues = arguments.contains("--resume-review-empty") ? [:] : Self.reviewFixture
        reviewOriginalValues = reviewValues
        reviewRevision = 1
        reviewConfirmed = false
        reviewDetailsConfirmed = false
        reviewUnavailable = arguments.contains("--resume-review-unavailable")
        if !arguments.contains("--resume-review-empty"),
           let data = reviewPersistence.data(forKey: reviewPersistenceKey),
           let saved = try? JSONDecoder().decode(JSON.self, from: data) {
            reviewValues = saved["values"].object.mapValues { $0.string }
            reviewOriginalValues = saved["original_values"].object.mapValues { $0.string }
            reviewRevision = saved["revision"].int
            reviewConfirmed = saved["confirmed"].bool
            reviewDetailsConfirmed = saved["details_confirmed"].isNull ? reviewConfirmed : saved["details_confirmed"].bool
        }
        if let revision = argument("resume-review-revision").flatMap(Int.init) { reviewRevision = revision }
        if arguments.contains("--resume-review-confirmed") {
            reviewConfirmed = true
            reviewDetailsConfirmed = true
        }
        if arguments.contains("--resume-review-unconfirmed-details") {
            reviewConfirmed = true // Previously confirmed raw records remain trusted by the backend.
            reviewDetailsConfirmed = false
        }
        if reviewUnavailable {
            reviewValues = Dictionary(uniqueKeysWithValues:
                ["profile.name", "profile.email", "profile.phone", "profile.location", "profile.url", "profile.summary",
                 "skills.descriptions", "additional.descriptions"].map { ($0, "") })
            reviewOriginalValues = [:]
        }
        if let edit = argument("resume-review-remote-name") { reviewValues["profile.name"] = edit }
        reviewProcessing = argument("resume-review-processing").map {
            JSON.object(["kind": "import", "status": .string($0)])
        } ?? .null
        reviewImportPolls = 0
        reviewAccountProcessing = argument("resume-review-account-processing").map {
            JSON.object(["kind": "import", "status": .string($0)])
        }
        decisions = []
    }

    /// The `deck` flow's roles, in deck order. The last one has a link that must never reach the browser.
    static let deckJobs: [JSON] = [
        deckJob("job-alpha", "Platform Analyst", firstListingURL),
        deckJob("job-bravo", "Growth Engineer", "https://example.invalid/jobs/bravo"),
        deckJob("job-charlie", "Broken Link Engineer", "javascript:void(0)"),
    ]
    /// What the entry-level quick pick returns, so a filter visibly changes the deck.
    static let entryJobs: [JSON] = [deckJob("job-entry", "Entry Level Developer", "https://example.invalid/jobs/entry")]

    private static func deckJob(_ id: String, _ title: String, _ url: String) -> JSON {
        ["id": .string(id), "title": .string(title), "company": "Northwind Analytics", "location": "Chicago, IL",
         "mode": "Hybrid", "posted": "1 day ago", "listing_url": .string(url), "fit": "Fixture fit note.",
         "description": "Fixture description."]
    }

    /// `paging` serves the deck in two pages: the first holds one job and a cursor, the second (answered late, see
    /// `delay`) holds the rest. Otherwise the whole deck is one page.
    static func deckPage(query: String, filters: JSON, cursor: String = "", paging: Bool = false) -> JSON {
        let entry = filters["levels"].strings == ["Entry-level"]
        let criteria: JSON = ["roles": .string(query.isEmpty ? "Product analyst" : query), "employment_types": ["Full-time"]]
        var jobs = entry ? entryJobs : deckJobs
        var next = ""
        if paging, !entry {
            jobs = cursor.isEmpty ? [deckJobs[0]] : Array(deckJobs.dropFirst())
            next = cursor.isEmpty ? "page-2" : ""
        }
        return ["jobs": .array(jobs), "next_cursor": .string(next), "criteria": criteria,
                "excluded": [], "occupations": []]
    }

    /// How long a request is held before it is answered, so a test can open the browser while a page is pending.
    func delay(for name: String, body: JSON) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return flow == "deck-paging" && name == "search_jobs" && !body["cursor"].string.isEmpty ? 3 : 0
    }

    /// `--listing-url-override=<http://127.0.0.1:port/path>` points the first deck job at a local fixture page so
    /// the real in-app browser can be tested without any live site. Only loopback hosts are honoured.
    private static var firstListingURL: String {
        let prefix = "--listing-url-override="
        let value = ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        if let value, let host = URL(string: value)?.host, host == "127.0.0.1" || host == "localhost" { return value }
        return "https://example.invalid/jobs/alpha"
    }

    static var job: JSON {
        let checks: [JSON] = [["status": "match", "label": "Level", "required": true, "detail": "Entry-level is stated in the listing."]]
        let match: JSON = ["label": "Strong match", "checks": .array(checks), "confirm": ["Confirm the experience requirement."]]
        var job: JSON = [
            "id": "job-1", "company": "Northwind Analytics", "location": "Chicago, IL", "mode": "Hybrid",
            "salary": "$95,000 - $120,000", "posted": "2 days ago", "listing_url": "https://example.invalid/jobs/1",
            "source_name": "Example Board", "checked_at": 1_700_000_000,
        ]
        job["title"] = .string(jobTitle)
        job["fit"] = .string(fit)
        job["tags"] = .array(tags.map { JSON.string($0) })
        job["requirements"] = ["SQL and Python for analysis", "Experience designing A/B tests"]
        job["description"] = "Partner with product teams to design experiments and explain results to stakeholders."
        job["match"] = match
        return job
    }

    func snapshot() -> JSON {
        lock.lock(); defer { lock.unlock() }
        return buildSnapshot()
    }

    private func buildSnapshot() -> JSON {
        let preferences: JSON = [
            "stage": "Student", "years": "1", "education": "Bachelor's", "modes": ["Remote"],
            "employment_types": ["Full-time"], "salary_period": "year",
        ]
        let profile: JSON = [
            "name": "Ada Example", "role": "Data analyst, Product analyst", "location": "Chicago, IL", "mode": "Any",
            "notifications": false, "graduation_month": "2027-05", "available_from": "", "preferences": preferences,
        ]
        let format: JSON = ["kind": "builtin", "label": "Jake's Resume", "pages": 1,
                            "summary": ["sections": 4, "entries": 6, "bullets": 14]]
        let resumes: [JSON] = [
            ["id": "resume-1", "name": .string(Self.resumeName), "size": 120_000, "created_at": 1_700_000_000,
             "details_status": "Needs review", "format": format, "processing": ["import": reviewAccountProcessing ?? reviewProcessing]],
            ["id": "resume-2", "name": "Backup resume.pdf", "size": 90_000, "created_at": 1_690_000_000,
             "details_status": "Confirmed", "format": format],
        ]
        let history: [JSON] = [["status": "Saved", "at": 1_700_000_000, "source": "You"]]
        let applications: [JSON] = [[
            "id": "application-1", "status": "Saved", "notes": .string(notes), "resume_id": "", "demo": false,
            "created_at": 1_700_000_000, "history": .array(history), "job": Self.job,
            "tailor": ["resume_id": "resume-1", "resume_name": .string(Self.resumeName), "ready": false],
        ]]
        let people: [JSON] = [[
            "id": "person-1", "name": "Katherine Example", "initials": "KE", "role": "Analytics Manager", "company": "Northwind Analytics",
            "color": "#F6E3BA", "reason": "Leads the team behind the role you saved.", "signal": "Posted about hiring this month",
            "bio": "Builds experimentation programs and mentors early-career analysts.", "draft": "",
        ]]
        let contacts: [JSON] = [["id": "contact-1", "person_id": "person-1", "saved": false, "draft": "", "notes": ""]]
        let setup: [JSON] = [[
            "key": "model", "label": "Model provider", "ok": false, "optional": false,
            "fix": "Connect a model provider in Agents.", "action": "",
        ]]
        let browserUnavailable = flow == "applications-autofill-unavailable"
        let features: [JSON] = [[
            "key": "jobs", "title": "Job fit", "state": "setup", "summary": "Explains how a role fits you.",
            "kinds": ["jobs", "resume"], "checks": .array(setup),
        ], [
            "key": "autofill", "title": "Saved-answer autofill", "state": .string(browserUnavailable ? "unavailable" : "ready"),
            "summary": "Fill confirmed saved answers; review and submit yourself.", "kinds": ["autofill"],
            "alternative": "Open the employer site yourself.",
            "checks": [["key": "browser", "label": "Browser worker", "ok": .bool(!browserUnavailable), "optional": false,
                        "fix": "Configure the browser worker for autofill.", "action": ""]],
        ]]
        return [
            "user_id": .string(reviewUser), "profile": profile, "resumes": .array(resumes), "selected_resume": "resume-1",
            "applications": .array(applications), "people": .array(people), "contacts": .array(contacts),
            "agents": ["features": .array(features), "runs": .array(autofillStarted ? [Self.autofillRun] : []), "active": 0, "attention": 0,
                       "model_provider": ["provider": "", "message": ""]],
            "tailored_resumes": [], "saved_search": [:], "decisions": .array(decisions), "reminders": [],
        ]
    }

    private static var autofillRun: JSON {
        ["id": "autofill-fixture", "kind": "autofill", "target_id": "application-1", "status": "needs_input",
         "title": "Autofill saved answers", "message": "Fixture autofill waiting for your review.", "step": "browser_autofill",
         "created_at": 1_700_000_000, "updated_at": 1_700_000_000, "requests": [], "context_label": "Northwind Analytics",
         "browser": ["supported": true, "available": false],
         "artifacts": ["browser_autofill": ["family": "lever", "filled": 1, "submission": "user_only",
                        "fields": [["label": "Email", "status": "filled", "required": true]]]]]
    }

    /// The `(status, body)` a request for `name` receives.
    func respond(_ name: String, body: JSON) -> (Int, JSON) {
        lock.lock(); defer { lock.unlock() }
        func ok(_ result: JSON) -> (Int, JSON) { (200, ["ok": true, "data": ["result": result]]) }
        func fail(_ message: String) -> (Int, JSON) { (500, ["ok": false, "error": ["message": .string(message)]]) }
        switch name {
        case "bootstrap":
            if flow == "resume-review", ["queued", "parsing"].contains(reviewProcessing["status"].string) {
                reviewImportPolls += 1
                reviewProcessing["status"] = reviewImportPolls > 1 ? "completed" : "parsing"
            }
            return ok(buildSnapshot())
        case "retry_resume_processing":
            guard flow == "resume-review", body["id"].string == "resume-1", body["kind"].string == "import" else {
                return fail("Unknown synthetic processing lane.")
            }
            reviewProcessing = ["kind": "import", "status": "queued"]
            reviewImportPolls = 0
            reviewAccountProcessing = nil
            return ok(buildSnapshot())
        case "agent_start":
            guard body["kind"].string == "autofill", body["target_id"].string == "application-1" else {
                return fail("Unsupported synthetic task.")
            }
            guard flow != "applications-autofill-unavailable" else { return fail("Browser worker unavailable.") }
            autofillStarted = true
            return ok(Self.autofillRun)
        case "agent_run":
            guard autofillStarted, body["id"].string == "autofill-fixture" else { return fail("Unknown synthetic task.") }
            return ok(Self.autofillRun)
        case "agent_settings":
            if flow == "settings", !modelFailed {
                modelFailed = true
                return fail(Self.modelFailure)
            }
            let options: [JSON] = [["selection": "codex-cli", "message": "Ready"], ["selection": "local", "message": "Not installed"]]
            return ok(["policy": ["followup_limit": 1, "followup_days": 7], "model_selection": "codex-cli",
                       "model_options": .array(options)])
        case "agent_contacts", "agent_save_contact", "agent_import_contacts", "agent_stop_contact":
            return ok(["contacts": []])
        case "agent_linkedin_profile":
            if !body["url"].isNull {
                return ok(["url": body["url"], "target_role": body["target_role"]])
            }
            linkedInLoads += 1
            if linkedInLoads == 1 { return fail(Self.linkedInFailure) }
            return ok(["url": "https://www.linkedin.com/in/ada-example/", "target_role": "Data analyst"])
        case "save_application":
            notesSaves += 1
            if notesSaves == 1 { return fail(Self.notesFailure) }
            notes = body["notes"].string
            return ok(buildSnapshot())
        case "get_job":
            let id = body["id"].string
            return ok((Self.deckJobs + Self.entryJobs).first { $0["id"].string == id } ?? Self.job)
        case "search_jobs":
            return ok(Self.deckPage(query: body["query"].string, filters: body["filters"],
                                    cursor: body["cursor"].string, paging: flow == "deck-paging"))
        case "save_search":
            return ok(["query": body["query"], "filters": body["filters"]])
        case "reset_search":
            return ok([:])
        case "swipe":
            decisions.append(["job_id": body["job_id"], "action": body["action"]])
            return ok(buildSnapshot())
        case "read_resume":
            return ok(["name": .string(Self.resumeName), "content": .string(Self.pdfBase64())])
        case "agent_extract_resume":
            return ok(reviewDocument())
        case "resume_save_details":
            guard body["revision"].int == reviewRevision else {
                return fail("This resume changed. Reload the latest version before saving.")
            }
            reviewValues = body["values"].object.mapValues { $0.string }
            reviewRevision += 1
            reviewConfirmed = body["confirm"].bool
            reviewDetailsConfirmed = reviewConfirmed
            let saved: JSON = ["values": .object(reviewValues.mapValues { .string($0) }),
                               "original_values": .object(reviewOriginalValues.mapValues { .string($0) }),
                               "revision": .number(Double(reviewRevision)), "confirmed": .bool(reviewConfirmed),
                               "details_confirmed": .bool(reviewDetailsConfirmed)]
            if let data = try? JSONEncoder().encode(saved) {
                reviewPersistence.set(data, forKey: reviewPersistenceKey)
            }
            return ok(reviewDocument())
        case "read_resume_source":
            return ok(["tex": "\\documentclass{article}", "preview": ["name": "preview.pdf", "content": .string(Self.pdfBase64())]])
        default:
            return ok(buildSnapshot())
        }
    }

    /// The backend's review document: sections of `{key, label, value}` fields, a revision and the text.
    private func reviewDocument() -> JSON {
        let titles = ["profile": "Profile", "educations": "Education", "workExperiences": "Work experience",
                      "projects": "Projects", "skills": "Skills", "additional": "Additional details"]
        let names = ["name": "Name", "email": "Email", "phone": "Phone", "location": "Location", "url": "Link",
                     "summary": "Summary", "school": "School", "degree": "Degree", "gpa": "GPA", "date": "Date",
                     "company": "Company", "jobTitle": "Job title", "project": "Project", "descriptions": "Descriptions",
                     "headline": "Headline"]
        var groups: [String: [(String, String)]] = [:]
        for (key, value) in reviewValues {
            let parts = key.split(separator: ".").map(String.init)
            let group = parts.count == 3 ? "\(parts[0]).\(parts[1])" : parts[0]
            groups[group, default: []].append((key, value))
        }
        let order = ["profile", "educations", "workExperiences", "projects", "skills", "additional"]
        let sections: [JSON] = groups.keys.sorted { lhs, rhs in
            let l = order.firstIndex(of: lhs.split(separator: ".").first.map(String.init) ?? "") ?? 99
            let r = order.firstIndex(of: rhs.split(separator: ".").first.map(String.init) ?? "") ?? 99
            return l == r ? lhs < rhs : l < r
        }.map { group in
            let base = group.split(separator: ".").first.map(String.init) ?? group
            let index = group.split(separator: ".").dropFirst().first.flatMap { Int($0) }
            let fields: [JSON] = (groups[group] ?? []).sorted { $0.0 < $1.0 }.map { key, value in
                let field = key.split(separator: ".").last.map(String.init) ?? key
                return ["key": .string(key), "label": .string(names[field] ?? field), "value": .string(value)]
            }
            let label = (titles[base] ?? base) + (index.map { " \($0 + 1)" } ?? "")
            return ["key": .string(group), "label": .string(label), "summary": .string(fields.first?["value"].string ?? "Not found"),
                    "fields": .array(fields)]
        }
        let definitions: [JSON] = ResumeSchema.sections.map { spec in
            let maximum: JSON = spec.repeated ? .number(Double(spec.key == "educations" ? 20 : 30)) : .null
            return ["key": .string(spec.key), "label": .string(spec.title), "repeatable": .bool(spec.repeated), "max": maximum,
                    "fields": .array(spec.fields.map { field in
                        ["key": .string(spec.key + (spec.repeated ? ".{n}." : ".") + field.name),
                         "name": .string(field.name), "label": .string(field.label), "multiline": .bool(field.multiline || field.bullets)]
                    })]
        }
        var document: JSON = ["revision": .number(Double(reviewRevision)), "confirmed": .bool(reviewConfirmed),
                "details_confirmed": .bool(reviewDetailsConfirmed), "sections": .array(sections),
                "values": .object(reviewValues.mapValues { .string($0) }),
                "original_values": .object(reviewOriginalValues.mapValues { .string($0) }),
                "definitions": .array(definitions),
                "limits": ["groups": ["educations": 20, "workExperiences": 30, "projects": 30], "scalar": 300,
                           "summary": 2000, "descriptions": 6000, "bullet": 1500, "text": 60000, "history": 100],
                "text": "Ada Example, Data analyst", "warnings": [["code": "synthetic", "message": "Check the extracted dates."]],
                "processing": reviewProcessing]
        document["details_status"] = reviewUnavailable ? "unavailable" : "ready"
        if reviewUnavailable {
            document["details_error"] = "Structured review unavailable for rotated PDF"
            document["records"] = [["id": "r0", "kind": "title", "text": "Accepted raw fallback", "allow_omit": false]]
        }
        return document
    }

    private static func pdfBase64() -> String {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        let data = renderer.pdfData { context in
            context.beginPage()
            ("Ada Example\nData analyst" as NSString).draw(at: CGPoint(x: 48, y: 48), withAttributes: nil)
        }
        return data.base64EncodedString()
    }
}

/// Answers every API request from `ScreenFlowServer`. Nothing leaves the process.
final class ScreenFlowURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        let body = Self.body(of: request)
        let delay = ScreenFlowServer.shared.delay(for: name, body: body)
        let answer = { [self] in
            guard !stopped.value else { return }
            let (status, payload) = ScreenFlowServer.shared.respond(name, body: body)
            let data = (try? JSONEncoder().encode(payload)) ?? Data()
            let response = HTTPURLResponse(url: request.url ?? URL(string: "https://stack.invalid")!, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: answer)
        } else {
            answer()
        }
    }

    private let stopped = StoppedFlag()

    override func stopLoading() { stopped.value = true }

    private final class StoppedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return flag }
            set { lock.lock(); defer { lock.unlock() }; flag = newValue }
        }
    }

    private static func body(of request: URLRequest) -> JSON {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                collected.append(buffer, count: count)
            }
            data = collected
        }
        return (try? JSONDecoder().decode(JSON.self, from: data ?? Data())) ?? [:]
    }
}
#endif

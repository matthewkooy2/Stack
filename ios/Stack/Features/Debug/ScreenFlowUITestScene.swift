#if DEBUG
import SwiftUI
import UIKit
import TabularData

/// Alternate sample populations for reviewing the production collection screens on a phone.
enum CollectionSampleSize: String, CaseIterable {
    case empty = "Empty", one = "One", two = "Two", full = "Full"

    var flow: String { "collections-" + rawValue.lowercased() }
    var count: Int {
        switch self {
        case .empty: return 0
        case .one: return 1
        case .two: return 2
        case .full: return 12
        }
    }
}

/// Each active preview owns its offline server. A delayed response from another preview stays with its original store.
@MainActor
final class ScreenFlowFixture: ObservableObject {
    let store: AppStore
    private let host: String
    private let cacheFile: URL

    init(flow: String) {
        let server = ScreenFlowServer()
        let host = UUID().uuidString.lowercased() + ".stack.invalid"
        self.host = host
        ScreenFlowURLProtocol.register(server, host: host)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenFlowURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let api = APIClient(origin: URL(string: "https://" + host)!, session: session, linkedinSession: session)
        cacheFile = FileManager.default.temporaryDirectory.appendingPathComponent(host + "-job-feed.json")
        store = AppStore(api: api, jobFeedCache: JobFeedCache(file: cacheFile))
        if flow == "resume-review", ProcessInfo.processInfo.arguments.contains("--reset-resume-drafts") {
            FileResumeDraftStore.shared.removeAll()
        }
        server.reset(flow: flow)
        store.account = AccountState(raw: server.snapshot())
        switch flow {
        case "onboarding":
            store.phase = .signedOut
        case "recovery":
            store.phase = .admission
            store.googleInfo = ["username": "ada.example", "can_recover": true, "google": false]
        default:
            store.phase = .ready
        }
    }

    deinit {
        ScreenFlowURLProtocol.remove(host: host)
        try? FileManager.default.removeItem(at: cacheFile)
    }
}

/// Offline UI-test host for the real Settings, Resume, Network, Applications, Jobs-detail and sign-in
/// screens. Excluded entirely from Release builds. It never signs in, adopts a token or reaches a live
/// service: every request goes through `ScreenFlowURLProtocol`, which answers from a fictional account.
/// Chosen with the launch argument `--screen-flow=<settings|resume|resume-upload|network|applications|jobs|onboarding|recovery>`.
@MainActor
struct ScreenFlowUITestScene: View {
    @StateObject private var fixture = ScreenFlowFixture(flow: ScreenFlowUITestScene.flow)

    static var flow: String {
        let prefix = "--screen-flow="
        return ProcessInfo.processInfo.arguments.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) } ?? ""
    }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            screen
        }
        .environment(fixture.store)
        .tint(Brand.accent)
        .environment(\.stackMotionPolicy, ProcessInfo.processInfo.arguments.contains("--reduced-card-motion") ? .reduced : .system)
        .transaction { if ProcessInfo.processInfo.arguments.contains("--disable-draft-animations") { $0.animation = nil; $0.disablesAnimations = true } }
    }

    @ViewBuilder
    private var screen: some View {
        switch Self.flow {
        case "keyboard-dismiss": KeyboardDismissFixture()
        case "browser-keyboard":
            RemoteBrowserView(id: "keyboard-fixture", task: ["id": "keyboard-fixture", "status": "paused"], onChanged: {})
        case "settings": ProfileView()
        case "resume", "resume-upload": ResumeView(onProfile: {})
        case "resume-review": ResumeReviewFixtureHost()
        case "memory-preview": MemoryBankView()
        case "tailor-preview": ResumeAgentsSection(setupFor: .constant(""), scores: .constant([:]), onOpenTask: { _ in }, onNavigate: { _ in })
        case "network": NetworkView(onProfile: {})
        case "linkedin-pdf": LinkedInFlow()
        case "linkedin-review":
            LinkedInReviewScreen(content: LinkedInReviewContent(LinkedInReviewSample.review), role: "Data analyst",
                                 onDone: {}, onAnother: {})
        case "applications", "applications-autofill-unavailable": ApplicationsView(onProfile: {}, onNavigate: { _ in })
        case "jobs": ScreenFlowJobHost(job: Job(ScreenFlowServer.job))
        case "deck", "deck-paging", "deck-reference": MainTabs()
        case let flow where CollectionSampleSize.allCases.contains(where: { $0.flow == flow }): MainTabs(selection: .applications)
        case "job-onboarding-preview": JobOnboardingGate(required: true)
        case "job-filters-preview": JobFiltersSheet(search: JobSearch()) { _, _ in {} }
        case "onboarding": AccessView()
        case "recovery": InvitationView()
        default: Text("Unknown screen flow").font(Typeface.title)
        }
    }
}

@MainActor
private struct KeyboardDismissFixture: View {
    @State private var answer = ""
    @State private var number = ""
    @State private var sheet = false

    var body: some View {
        VStack {
            AnswerEditor(text: $answer, placeholder: "Answer", label: "Answer")
            Button("Open form") { sheet = true }
        }
        .sheet(isPresented: $sheet) {
            StackField(label: "Number", text: $number, keyboard: .numberPad).padding()
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
        .fullScreenCover(isPresented: $open) {
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
    private var outreachContacts: [JSON] = []
    private var outreachPolicy: JSON = [:]
    private var sampleRoles: [JSON] = []
    private var sampleFiles: [JSON] = []
    private var sampleDocuments: [String: Data] = [:]
    private var sampleDefault = ""
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
    /// The `resume-upload` flow: the name of the PDF the person uploaded, and how many times its import has been polled.
    private var uploadedName = ""
    private var uploadPolls = 0
    private var reviewAccountProcessing: JSON?
    private var memorySelections: [String: [JSON]] = [:]
    private var memoryRevisions = ["resume-1": 1, "resume-2": 1]
    private var memorySaveFailed = false
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
    /// What `job_feed` ranks: the search last saved through `save_search`.
    private var savedSearch: JSON = ["query": "", "filters": [:]]
    private var onboardingProfile: JSON = [:]

    func reset(flow: String) {
        lock.lock(); defer { lock.unlock() }
        self.flow = flow
        sampleRoles = []
        sampleFiles = []
        sampleDocuments = [:]
        sampleDefault = ""
        outreachContacts = []
        outreachPolicy = ["followup_limit": 1, "followup_days": 7]
        if let sampleSize {
            let examples = collectionSamples(sampleSize)
            sampleRoles = examples.roles
            sampleFiles = examples.files
            outreachContacts = examples.people
            sampleDefault = sampleFiles.first?["id"].string ?? ""
        }
        onboardingProfile = [:]
        notes = ""
        linkedInLoads = 0
        notesSaves = 0
        modelFailed = false
        autofillStarted = false
        memorySelections = [:]
        memoryRevisions = ["resume-1": 1, "resume-2": 1]
        memorySaveFailed = false
        let arguments = ProcessInfo.processInfo.arguments
        func argument(_ name: String) -> String? {
            arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
        }
        reviewUser = argument("resume-review-user") ?? "fixture-user"
        if flow == "resume-review", arguments.contains("--reset-resume-drafts") {
            reviewPersistence.removePersistentDomain(forName: "StackOfflineResumeReviewServer")
        }
        reviewValues = arguments.contains("--resume-review-empty") ? [:] : Self.reviewFixture
        reviewOriginalValues = reviewValues
        reviewRevision = 1
        reviewConfirmed = false
        reviewDetailsConfirmed = false
        reviewUnavailable = arguments.contains("--resume-review-unavailable")
        if flow == "resume-review", !arguments.contains("--resume-review-empty"),
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
        uploadedName = ""
        uploadPolls = 0
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
        if ProcessInfo.processInfo.arguments.contains("--screen-flow=deck-reference") {
            let long = ProcessInfo.processInfo.arguments.contains("--job-card-long-content")
            let invalid = ProcessInfo.processInfo.arguments.contains("--job-card-invalid-media")
            jobs = [["id": "job-alpha", "title": .string(long ? Self.jobTitle : "Mobile Product Designer"),
                     "company": .string(long ? "Linear — Product Development and Collaboration for Distributed Teams" : "Linear"),
                     "location": "North America", "mode": "Remote", "employment_type": "Full-time",
                     "salary": "Pay not listed", "photo_id": .string(invalid ? "unknown-photo" : "forest"),
                     "employer_brand": "linear.app", "listing_url": "https://linear.app/careers/eac7f181-d658-4943-9430-51bae2bcd110",
                     "highlights": ["responsibilities": [.string(long ? String(repeating: "Own the experience of our iOS and Android mobile apps. ", count: 8) : "Own the experience of our iOS and Android mobile apps.")]]],
                    deckJobs[1], deckJobs[2]]
        }
        var next = ""
        if paging, !entry {
            jobs = cursor.isEmpty ? [deckJobs[0]] : Array(deckJobs.dropFirst())
            next = cursor.isEmpty ? "page-2" : ""
        }
        var logos: JSON = [:]
        if let url = Bundle.main.url(forResource: "job-preview-linear", withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            logos = ["linear.app": .string(ProcessInfo.processInfo.arguments.contains("--job-card-invalid-media") ? "invalid-png" : data.base64EncodedString())]
        }
        return ["jobs": .array(jobs), "employer_logos": logos, "next_cursor": .string(next), "criteria": criteria,
                "excluded": [], "occupations": []]
    }

    /// How long a request is held before it is answered, so a test can open the browser while a page is pending.
    func delay(for name: String, body: JSON) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        if ["resume-upload", "job-onboarding-preview"].contains(flow), name == "upload_resume" { return 1.5 }
        return flow == "deck-paging" && name == "job_feed" && !body["cursor"].string.isEmpty ? 3 : 0
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

    private var sampleSize: CollectionSampleSize? { CollectionSampleSize.allCases.first { $0.flow == flow } }

    private func collectionSamples(_ size: CollectionSampleSize) -> (roles: [JSON], files: [JSON], people: [JSON]) {
        let names = ["Ada Park", "Mina Ellis", "Jules Chen", "Robin Price", "Ana Vega", "Eli Wilson",
                     "Clara Moss", "Max Reed", "Lou Kim", "Nia Jones", "Pat Diaz", "Jin Hart"]
        let companies = ["Northwind", "Elm Studio", "Lake Street", "Rook", "Fieldwork", "Brightwater"]
        let titles = ["Product designer", "Research lead", "Design engineer", "Senior product designer"]
        let stages = ["Interview", "Saved", "Submitted", "Offer", "Saved"]
        var roles: [JSON] = [], files: [JSON] = [], people: [JSON] = []
        let today = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        for index in 0..<size.count {
            let id = index + 1
            let company = companies[index % companies.count]
            let role = titles[index % titles.count]
            let status = stages[index % stages.count]
            let date = today - Double(index + 1) * 86_400
            var job = Self.job
            job["id"] = .string("sample-job-\(id)")
            job["company"] = .string(company)
            job["title"] = .string(role)
            var history: [JSON] = [["status": "Saved", "at": .number(date - 5 * 86_400), "source": "You"]]
            if status == "Interview" || status == "Offer" {
                history.append(["status": "Submitted", "at": .number(date - 2 * 86_400), "source": "You"])
            }
            if status != "Saved" {
                history.append(["status": .string(status), "at": .number(date), "source": "You"])
            }
            roles.append(["id": .string("application-\(id)"), "job": job, "status": .string(status),
                          "history": .array(history), "created_at": history[0]["at"], "demo": false])
            let fileID = "resume-\(id)"
            let suffix = index == 1 ? "docx" : "pdf"
            let name = index == 0 ? "Ada Example.pdf" : "\(company) \(role).\(suffix)"
            let document = index == 1 ? Self.sampleWordDocument : Self.makePDF(role: role, company: company)
            sampleDocuments[fileID] = document
            files.append(["id": .string(fileID), "name": .string(name), "created_at": .number(date),
                          "size": .number(Double(document.count)), "details_status": "Confirmed"])
            let relationship = index == 0 ? "Met at the design meetup." : ""
            people.append(["relationship": .string(relationship), "id": .string("person-\(id)"), "name": .string(names[index]),
                           "email": .string("contact\(id)@example.invalid"), "role": .string(role),
                           "company": .string(company)])
        }
        return (roles, files, people)
    }

    private func buildSnapshot() -> JSON {
        let preferences: JSON = [
            "stage": "Student", "years": "1", "education": "Bachelor's", "modes": ["Remote"],
            "employment_types": ["Full-time"], "salary_period": "year",
        ]
        var profile: JSON = [
            "name": "Ada Example", "role": "Data analyst, Product analyst", "location": "Chicago, IL", "mode": "Any",
            "notifications": false, "graduation_month": "2027-05", "available_from": "", "preferences": preferences,
        ]
        let onboarding = flow == "job-onboarding-preview"
        if onboarding {
            profile["role"] = ""; profile["location"] = ""; profile["preferences"] = [:]
            for (key, value) in onboardingProfile.object { profile[key] = value }
        }
        let format: JSON = ["kind": "builtin", "label": "Jake's Resume", "pages": 1,
                            "summary": ["sections": 4, "entries": 6, "bullets": 14]]
        let resumes: [JSON] = [
            ["id": "resume-1", "name": .string(Self.resumeName), "size": 120_000, "created_at": 1_700_000_000,
             "details_status": "Needs review", "format": format, "processing": ["import": reviewAccountProcessing ?? reviewProcessing]],
            ["id": "resume-2", "name": "Backup resume.pdf", "size": 90_000, "created_at": 1_690_000_000,
             "details_status": "Confirmed", "format": format],
        ]
        let uploaded: [JSON] = uploadedName.isEmpty ? [] : [
            ["id": "resume-uploaded", "name": .string(uploadedName), "size": 150_000, "created_at": 1_700_000_000,
             "details_status": "Needs review", "format": format,
             "processing": ["import": ["kind": "import", "status": .string(uploadPolls > 2 ? "completed" : "parsing")]]],
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
        var snapshot: JSON = [
            "user_id": .string(reviewUser), "profile": profile,
            "resumes": flow == "resume-upload" || onboarding ? .array(uploaded) : .array(resumes),
            "selected_resume": flow == "resume-upload" || onboarding ? .string(uploadedName.isEmpty ? "" : "resume-uploaded") : "resume-1",
            "applications": .array(applications), "people": .array(people), "contacts": .array(contacts),
            "agents": ["features": .array(features), "runs": .array(autofillStarted ? [Self.autofillRun] : []), "active": 0, "attention": 0,
                       "model_provider": ["provider": "", "message": ""]],
            "tailored_resumes": [], "saved_search": [:], "decisions": .array(decisions), "reminders": [],
        ]
        if sampleSize != nil {
            snapshot["applications"] = .array(sampleRoles)
            snapshot["resumes"] = .array(sampleFiles)
            snapshot["selected_resume"] = .string(sampleDefault)
        }
        return snapshot
    }

    private static var autofillRun: JSON {
        ["id": "autofill-fixture", "kind": "autofill", "target_id": "application-1", "status": "needs_input",
         "title": "Autofill saved answers", "message": "Fixture autofill waiting for your review.", "step": "browser_autofill",
         "created_at": 1_700_000_000, "updated_at": 1_700_000_000, "requests": [], "context_label": "Northwind Analytics",
         "browser": ["supported": true, "available": false],
         "artifacts": ["browser_autofill": ["family": "lever", "filled": 1, "submission": "user_only",
                        "fields": [["label": "Email", "status": "filled", "required": true]]]]]
    }

    private func memorySnapshot() -> JSON {
        ["sources": [
            ["id": "memory-1", "name": "Product Designer · Northstar", "source": "2022–Present", "confirmed": true, "editable": true, "revision": 1,
             "records": [["id": "r0", "text": "Designed mobile experiences."], ["id": "r1", "text": "Partnered with engineers."]]],
            ["id": "memory-2", "name": "Skills", "source": "My notes", "confirmed": true, "editable": true, "revision": 1,
             "records": [["id": "r0", "text": "Figma and Swift"]]],
            ["id": "memory-3", "name": "Portfolio project", "source": "Project notes", "confirmed": false, "editable": true, "revision": 1,
             "records": [["id": "r0", "text": "Built a personal portfolio."]]],
        ], "resumes": .array(["resume-1", "resume-2"].map { id in
            ["id": .string(id), "name": .string(id == "resume-1" ? "Main resume.pdf" : "Backup resume.pdf"), "confirmed": true,
             "revision": .number(Double(memoryRevisions[id] ?? 1)), "selection": .array(memorySelections[id] ?? [])]
        })]
    }

    /// The `(status, body)` a request for `name` receives.
    func respond(_ name: String, body: JSON) -> (Int, JSON) {
        lock.lock(); defer { lock.unlock() }
        func ok(_ result: JSON) -> (Int, JSON) { (200, ["ok": true, "data": ["result": result]]) }
        func fail(_ message: String) -> (Int, JSON) { (500, ["ok": false, "error": ["message": .string(message)]]) }
        switch name {
        case "resume_bank":
            return ok(memorySnapshot())
        case "resume_bank_select":
            let id = body["id"].string
            guard let revision = memoryRevisions[id], body["revision"].int == revision else { return fail("Resume changed. Reload before choosing facts.") }
            for group in body["selection"].array {
                guard ["memory-1", "memory-2"].contains(group["id"].string), group["revision"].int == 1,
                      !group["record_ids"].strings.isEmpty, group["record_ids"].strings.allSatisfy({ ["r0", "r1"].contains($0) }) else {
                    return fail("Choose confirmed facts from the current memory.")
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--memory-save-fails-once"), !memorySaveFailed {
                memorySaveFailed = true
                return fail("Memory choices could not be saved. Try again.")
            }
            memorySelections[id] = body["selection"].array
            memoryRevisions[id] = revision + 1
            return ok(memorySnapshot())
        case "bootstrap":
            if !uploadedName.isEmpty { uploadPolls += 1 }
            if flow == "resume-review", ["queued", "parsing"].contains(reviewProcessing["status"].string) {
                reviewImportPolls += 1
                reviewProcessing["status"] = reviewImportPolls > 1 ? "completed" : "parsing"
            }
            return ok(buildSnapshot())
        case "save_profile":
            if flow == "job-onboarding-preview" { onboardingProfile = body }
            return ok(buildSnapshot())
        case "upload_resume" where sampleSize != nil:
            guard let data = Data(base64Encoded: body["content"].string), !data.isEmpty else {
                return fail("Couldn't read this document.")
            }
            let id = UUID().uuidString
            sampleFiles.append(["id": .string(id), "name": body["name"], "size": .number(Double(data.count)),
                                "created_at": .number(Date().timeIntervalSince1970), "details_status": "Needs review"])
            sampleDocuments[id] = data
            if sampleDefault.isEmpty { sampleDefault = id }
            return ok(buildSnapshot())
        case "change_resume" where sampleSize != nil:
            let id = body["id"].string
            guard let index = sampleFiles.firstIndex(where: { $0["id"].string == id }) else { return fail("Resume not found.") }
            switch body["action"].string {
            case "select": sampleDefault = id
            case "rename": sampleFiles[index]["name"] = body["name"]
            case "delete":
                sampleFiles.remove(at: index)
                sampleDocuments[id] = nil
                if sampleDefault == id { sampleDefault = sampleFiles.first?["id"].string ?? "" }
            default: return fail("Invalid resume action.")
            }
            return ok(buildSnapshot())
        case "upload_resume":
            guard ["resume-upload", "job-onboarding-preview"].contains(flow) else { return ok(buildSnapshot()) }
            uploadedName = body["name"].string
            uploadPolls = 0
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
            return ok(["policy": outreachPolicy, "model_selection": "codex-cli",
                       "model_options": .array(options)])
        case "agent_save_policy":
            outreachPolicy = body["policy"]
            return ok(["policy": outreachPolicy])
        case "agent_contacts":
            return ok(["contacts": .array(outreachContacts)])
        case "agent_save_contact":
            do {
                var contact = try Self.fixtureContact(body["data"])
                let id = body["id"].string
                if id.isEmpty {
                    contact["id"] = .string(UUID().uuidString)
                    outreachContacts.append(contact)
                } else {
                    guard let index = outreachContacts.firstIndex(where: { $0["id"].string == id }) else {
                        return fail("Contact not found.")
                    }
                    contact["id"] = .string(id)
                    contact["stopped"] = outreachContacts[index]["stopped"]
                    outreachContacts[index] = contact
                }
                return ok(["contacts": .array(outreachContacts)])
            } catch { return fail(error.localizedDescription) }
        case "agent_import_contacts":
            do {
                let rows = try Self.importedContacts(body["content"].string)
                var known = Set(outreachContacts.map { $0["email"].string.lowercased() })
                for var row in rows {
                    let email = row["email"].string
                    if !email.isEmpty && !known.insert(email).inserted { continue }
                    row["id"] = .string(UUID().uuidString)
                    outreachContacts.append(row)
                }
                return ok(["contacts": .array(outreachContacts)])
            } catch { return fail(error.localizedDescription) }
        case "agent_stop_contact":
            guard let index = outreachContacts.firstIndex(where: { $0["id"] == body["id"] }) else {
                return fail("Contact not found.")
            }
            outreachContacts[index]["stopped"] = true
            outreachContacts[index]["next_at"] = 0
            return ok(["contacts": .array(outreachContacts)])
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
        case "job_feed":
            return ok(Self.deckPage(query: savedSearch["query"].string, filters: savedSearch["filters"],
                                    cursor: body["cursor"].string, paging: flow == "deck-paging"))
        case "save_search":
            savedSearch = ["query": body["query"], "filters": body["filters"]]
            return ok(["query": body["query"], "filters": body["filters"]])
        case "reset_search":
            savedSearch = ["query": "", "filters": [:]]
            return ok([:])
        case "swipe":
            decisions.append(["job_id": body["job_id"], "action": body["action"]])
            return ok(buildSnapshot())
        case "read_resume" where sampleSize != nil:
            let id = body["id"].string
            guard let data = sampleDocuments[id], let file = sampleFiles.first(where: { $0["id"].string == id }) else {
                return fail("Resume not found.")
            }
            return ok(["name": file["name"], "content": .string(data.base64EncodedString())])
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
            if flow == "resume-review", let data = try? JSONEncoder().encode(saved) {
                reviewPersistence.set(data, forKey: reviewPersistenceKey)
            }
            return ok(reviewDocument())
        case "read_resume_source":
            return ok(["tex": "\\documentclass{article}", "preview": ["name": "preview.pdf", "content": .string(Self.pdfBase64())]])
        default:
            return ok(buildSnapshot())
        }
    }

    private static func fixtureContact(_ data: JSON) throws -> JSON {
        var result = data
        let name = data["name"].string.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = data["email"].string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty, name.count <= 120,
              email.isEmpty || email.range(of: #"^[^\s@<>]+@[^\s@<>]+\.[^\s@<>]+$"#, options: .regularExpression) != nil else {
            throw APIError(message: "Enter a name and a valid, verified email address.")
        }
        let source = data["source_url"].string
        guard source.isEmpty || URL(string: source)?.scheme?.lowercased() == "https" else {
            throw APIError(message: "Use an HTTPS research source.")
        }
        result["name"] = .string(name)
        result["email"] = .string(email)
        return result
    }

    private static func importedContacts(_ content: String) throws -> [JSON] {
        guard content.utf8.count <= 200_000 else { throw APIError(message: "Import at most 200 KB at a time.") }
        var values: [JSON] = []
        let keys = ["name", "email", "company", "role", "relationship", "source", "source_url"]
        let types = Dictionary(uniqueKeysWithValues: keys.map { ($0, CSVType.string) })
        if let table = try? DataFrame(csvData: Data(content.utf8), types: types),
           table.columns.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == "email" }) {
            for row in table.rows {
                var contact: JSON = ["selected": false]
                for column in table.columns {
                    let key = column.name.trimmingCharacters(in: .whitespaces).lowercased()
                    if keys.contains(key), let value = row[column.name] {
                        contact[key] = .string(String(describing: value))
                    }
                }
                values.append(contact)
            }
        } else {
            let pattern = try NSRegularExpression(pattern: #"[\w.!#$%&'*+/=?^_{}|~-]+@[\w.-]+\.[A-Za-z]{2,}"#)
            for match in pattern.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
                guard let range = Range(match.range, in: content) else { continue }
                let email = String(content[range])
                values.append(["name": .string(email), "email": .string(email), "selected": false])
            }
        }
        guard values.count <= 200 else { throw APIError(message: "Import at most 200 contacts at a time.") }
        return try values.map(fixtureContact)
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

    // A complete Office Open XML package containing the second sample's name and role.
    private static let sampleWordDocument = Data(base64Encoded: """
        UEsDBBQAAAAIAMQlcl10JJxTuwAAAD4BAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbJWQuQ7CMAyGX6XKiqgRAwNquwArMPAC
        Vuq2EbkUuxxvT8o1sDHa//FZrk73SFzcnPVcq0EkrgFYD+SQyxDJZ6ULyaHkMfUQUZ+xJ1guFivQwQt5mcvUoZpqSx2OVord
        La/ZBF+rRJZVsXkZJ1atMEZrNErW4eLbH8r8TShz8unhwUSeZYOCpjpcKCXTUnHEJHt0uQ6uIbXQBj26jCgn41+80HVG0zc/
        tcUUNDEb3ztbfhWHxn/ugOfbmgdQSwMEFAAAAAgAxCVyXWF7L0OJAAAA8gAAAAsAAABfcmVscy8ucmVsc43POw4CIRAG4KsQ
        DrCzWlgYoLLZ1ngBAsMjLo8MGPX2UlisxsJy5p98f0accdU9ltxCrI090pqb5KH3egRoJmDSbSoV80hcoaT7GMlD1eaqPcJ+
        ng9AW4MrsTXZYiWnxe44uzwr/mMX56LBUzG3hLn/qPi6GLImj13yeyEL9r2eBstBCfh4Ub0AUEsDBBQAAAAIAMQlcl20rh3X
        kgAAANcAAAARAAAAd29yZC9kb2N1bWVudC54bWxtj0ELwjAMhf9K2VnM8OChzIGH3TzpL4ht3AZNW9KOzn/vKoggXr6Q9/J4
        pCvaBrMw+axWdj7pcmqmnKMGSGYixrQPkfzmPYIw5m2VEUoQGyUYSmn2Izs4tO0RGGff9F3R92CfdcYKqcj92aIaVuToqIMq
        VMqb8ff2SolQzKQuhHanBsfqlhc7hz9J+NTB95X+BVBLAQIUABQAAAAIAMQlcl10JJxTuwAAAD4BAAATAAAAAAAAAAAAAACA
        AQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQAFAAAAAgAxCVyXWF7L0OJAAAA8gAAAAsAAAAAAAAAAAAAAIAB7AAAAF9y
        ZWxzLy5yZWxzUEsBAhQAFAAAAAgAxCVyXbSuHdeSAAAA1wAAABEAAAAAAAAAAAAAAIABngEAAHdvcmQvZG9jdW1lbnQueG1s
        UEsFBgAAAAADAAMAuQAAAF8CAAAAAA==
        """, options: .ignoreUnknownCharacters)!

    private static func pdfBase64() -> String { makePDF(role: "Data analyst", company: "Northwind Analytics").base64EncodedString() }

    private static func makePDF(role: String, company: String) -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return renderer.pdfData { context in
            context.beginPage()
            func line(_ text: String, y: CGFloat, size: CGFloat, bold: Bool = false) {
                let font = bold ? UIFont.boldSystemFont(ofSize: size) : UIFont.systemFont(ofSize: size)
                (text as NSString).draw(in: CGRect(x: 54, y: y, width: 504, height: 60),
                                        withAttributes: [.font: font, .foregroundColor: UIColor.black])
            }
            line("Ada Example", y: 55, size: 34, bold: true)
            line(role.capitalized, y: 104, size: 18)
            line("ada@example.invalid   ·   Chicago, IL", y: 132, size: 12)
            line("Profile", y: 194, size: 18, bold: true)
            line("Research, design and analysis for product teams.", y: 227, size: 14)
            line("Experience", y: 294, size: 18, bold: true)
            line(company + "   ·   " + role.capitalized, y: 330, size: 15, bold: true)
            line("2022–Present", y: 355, size: 12)
            line("Planned weekly research sessions and shared findings with product teams.", y: 390, size: 14)
            line("Skills", y: 475, size: 18, bold: true)
            line("User interviews, prototyping, analysis and presentation", y: 511, size: 14)
        }
    }

}

/// Answers every API request from `ScreenFlowServer`. Nothing leaves the process.
final class ScreenFlowURLProtocol: URLProtocol {
    private static let registryLock = NSLock()
    private static var servers: [String: ScreenFlowServer] = [:]

    static func register(_ server: ScreenFlowServer, host: String) {
        registryLock.withLock { servers[host] = server }
    }

    static func remove(host: String) {
        registryLock.withLock { servers[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let name = request.url?.lastPathComponent ?? ""
        let body = Self.body(of: request)
        guard let host = request.url?.host,
              let server = Self.registryLock.withLock({ Self.servers[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
            return
        }
        let delay = server.delay(for: name, body: body)
        let answer = { [self] in
            guard !stopped.value else { return }
            let (status, payload) = server.respond(name, body: body)
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

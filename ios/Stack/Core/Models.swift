import Foundation

struct Job: Identifiable, Hashable {
    let id: String
    let company: String
    let title: String
    let location: String
    let mode: String
    let salary: String
    let fit: String
    let reason: String
    let summary: String
    let posted: String
    let url: String
    let tags: [String]
    let requirements: [String]
    /// The complete server document, for fields only the detail screens read (match, timeline, source).
    let raw: JSON

    init(_ json: JSON) {
        raw = json
        id = json["id"].string
        company = json["company"].string
        title = json["title"].string
        location = json["location"].string
        mode = json["mode"].string
        salary = json["salary"].string
        fit = json["fit"].string
        reason = json["reason"].string
        summary = json["description"].string
        posted = json["posted"].string
        url = json["listing_url"].string.isEmpty
            ? (json["url"].string.isEmpty ? json["apply_url"].string : json["url"].string)
            : json["listing_url"].string
        tags = json["tags"].strings
        requirements = json["requirements"].strings
    }

    var initial: String { String(company.prefix(1)).uppercased() }
}

struct StatusEvent: Hashable {
    let status: String
    let at: Double
    let source: String
}

struct Application: Identifiable, Hashable {
    let id: String
    let job: Job
    let status: String
    let notes: String
    let resumeID: String
    let isDemo: Bool
    let createdAt: Double
    let history: [StatusEvent]
    /// The resume tailoring would start from, and whether its LaTeX is ready.
    let tailorResumeID: String
    let tailorResumeName: String
    let tailorReady: Bool

    init(_ json: JSON) {
        id = json["id"].string
        tailorResumeID = json["tailor"]["resume_id"].string
        tailorResumeName = json["tailor"]["resume_name"].string
        tailorReady = json["tailor"]["ready"].bool
        job = Job(json["job"])
        status = json["status"].string
        notes = json["notes"].string
        resumeID = json["resume_id"].string
        isDemo = json["demo"].bool
        createdAt = json["created_at"].double
        history = json["history"].array.map {
            StatusEvent(status: $0["status"].string, at: $0["at"].double, source: $0["source"].string)
        }
    }
}

struct Person: Identifiable, Hashable {
    let id: String
    let name: String
    let initials: String
    let role: String
    let company: String
    let colorHex: String
    let reason: String
    let signal: String
    let bio: String
    let draft: String

    init(_ json: JSON) {
        id = json["id"].string
        name = json["name"].string
        initials = json["initials"].string
        role = json["role"].string
        company = json["company"].string
        colorHex = json["color"].string
        reason = json["reason"].string
        signal = json["signal"].string
        bio = json["bio"].string
        draft = json["draft"].string
    }
}

struct ContactRecord: Identifiable, Hashable {
    let id: String
    let personID: String
    let saved: Bool
    let draft: String
    let notes: String

    init(_ json: JSON) {
        id = json["id"].string
        personID = json["person_id"].string
        saved = json["saved"].bool
        draft = json["draft"].string
        notes = json["notes"].string
    }
}

struct ResumeItem: Identifiable, Hashable {
    let id: String
    let name: String
    let size: Int
    let createdAt: Double
    let detailsStatus: String
    let isProcessing: Bool

    init(_ json: JSON) {
        id = json["id"].string
        name = json["name"].string
        size = json["size"].int
        createdAt = json["created_at"].double
        detailsStatus = json["details_status"].string
        isProcessing = !json["processing"].isNull && json["processing"] != .bool(false) && json["processing"] != .object([:])
    }
}

struct Reminder: Identifiable, Hashable {
    let id: String
    let targetType: String
    let targetID: String
    let title: String
    let dueAt: Double
    let done: Bool

    init(_ json: JSON) {
        id = json["id"].string
        targetType = json["target_type"].string
        targetID = json["target_id"].string
        title = json["title"].string
        dueAt = json["due_at"].double
        done = json["done"].bool
    }
}

struct AgentRun: Identifiable, Hashable {
    let id: String
    let kind: String
    let status: String
    let message: String
    let targetID: String
    let sessionRevision: Int

    init(_ json: JSON) {
        id = json["id"].string
        kind = json["kind"].string
        status = json["status"].string
        message = json["message"].string
        targetID = json["target_id"].string
        sessionRevision = json["session_revision"].int
    }

    var isStalled: Bool { ["needs_input", "blocked", "failed", "cancelled"].contains(status) }
}

/// A snapshot of the account, as returned by `bootstrap` and by every mutation.
struct AccountState {
    var raw: JSON = [:]

    var isLoaded: Bool { !raw.object.isEmpty }
    var userID: String { raw["user_id"].string }
    var name: String { raw["profile"]["name"].string }
    var role: String { raw["profile"]["role"].string }
    var location: String { raw["profile"]["location"].string }
    var mode: String { raw["profile"]["mode"].string }
    var notificationsOn: Bool { raw["profile"]["notifications"].bool }
    var applications: [Application] { raw["applications"].array.map(Application.init) }
    var people: [Person] { raw["people"].array.map(Person.init) }
    var contacts: [ContactRecord] { raw["contacts"].array.map(ContactRecord.init) }
    var resumes: [ResumeItem] { raw["resumes"].array.map(ResumeItem.init) }
    var reminders: [Reminder] { raw["reminders"].array.map(Reminder.init) }
    var selectedResumeID: String { raw["selected_resume"].string }
    var decidedJobIDs: Set<String> { Set(raw["decisions"].array.map { $0["job_id"].string }) }
    var runs: [AgentRun] { raw["agents"]["runs"].array.map(AgentRun.init) }

    func person(for contact: ContactRecord) -> Person? { people.first { $0.id == contact.personID } }
}


// MARK: - Agents, tailoring and search

struct FeatureCheck: Hashable {
    let key: String
    let label: String
    let ok: Bool
    let optional: Bool
    let fix: String
    let action: String

    init(_ json: JSON) {
        key = json["key"].string
        label = json["label"].string
        ok = json["ok"].bool
        optional = json["optional"].bool
        fix = json["fix"].string
        action = json["action"].string
    }
}

struct AgentFeature: Identifiable, Hashable {
    let key: String
    let title: String
    let state: String
    let summary: String
    let input: String
    let review: String
    let whereToStart: String
    let alternative: String
    let limited: Bool
    let kinds: [String]
    let checks: [FeatureCheck]

    var id: String { key }

    init(_ json: JSON) {
        key = json["key"].string
        title = json["title"].string
        state = json["state"].string
        summary = json["summary"].string
        input = json["input"].string
        review = json["review"].string
        whereToStart = json["where"].string
        alternative = json["alternative"].string
        limited = json["limited"].bool
        kinds = json["kinds"].strings
        checks = json["checks"].array.map(FeatureCheck.init)
    }

    var missingRequired: [FeatureCheck] { checks.filter { !$0.ok && !$0.optional } }
}

struct TailoredResume: Identifiable, Hashable {
    let id: String
    let name: String
    let jobTitle: String
    let company: String
    let createdAt: Double
    let pages: Int
    let sourceName: String
    let score: JSON

    init(_ json: JSON) {
        id = json["id"].string
        name = json["name"].string
        jobTitle = json["job_title"].string
        company = json["company"].string
        createdAt = json["created_at"].double
        pages = json["pages"].int
        sourceName = json["source_name"].string
        score = json["score"]
    }
}

extension AccountState {
    var agents: JSON { raw["agents"] }
    var features: [AgentFeature] { raw["agents"]["features"].array.map(AgentFeature.init) }
    var runViews: [JSON] { raw["agents"]["runs"].array }
    var activeRunCount: Int { raw["agents"]["active"].int }
    var attentionRunCount: Int { raw["agents"]["attention"].int }
    var tailored: [TailoredResume] { raw["tailored_resumes"].array.map(TailoredResume.init) }
    var savedSearch: JSON { raw["saved_search"] }
    var preferences: JSON { raw["profile"]["preferences"] }
    var graduationMonth: String { raw["profile"]["graduation_month"].string }
    var availableFrom: String { raw["profile"]["available_from"].string }
    var linkedInURL: String { raw["profile"]["linkedin_url"].string }
    var modelProviderName: String { raw["agents"]["model_provider"]["provider"].string }
    var modelProviderMessage: String { raw["agents"]["model_provider"]["message"].string }

    func feature(_ key: String) -> AgentFeature? { features.first { $0.key == key } }
    func feature(forKind kind: String) -> AgentFeature? { features.first { $0.kinds.contains(kind) } }
    func resume(_ id: String) -> ResumeItem? { resumes.first { $0.id == id } }
    func format(of resume: String) -> JSON { raw["resumes"].array.first { $0["id"].string == resume }?["format"] ?? [:] }
    func processing(of resume: String) -> JSON { raw["resumes"].array.first { $0["id"].string == resume }?["processing"] ?? [:] }
    func hasLatex(_ resume: String) -> Bool { ["upload", "builtin"].contains(format(of: resume)["kind"].string) }
}

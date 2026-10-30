import Foundation

/// A curated practice-library question. Each one is a permanent slot, so a person's best answer
/// to it builds up over time.
struct PracticeQuestion: Identifiable, Hashable {
    let id: String
    let title: String
    let prompt: String
    let topic: String
    let hints: [String]

    init(_ json: JSON) {
        id = json["id"].string
        title = json["title"].string
        prompt = json["prompt"].string
        topic = json["topic"].string
        hints = json["hints"].strings
    }
}

/// One recorded answer. The server keeps the reviewed transcript and coaching; the video stays on
/// this phone under `videoID`.
struct PracticeAttempt: Identifiable, Hashable {
    static let criteria = ["specificity", "ownership", "structure", "reflection"]

    let id: String
    let questionID: String
    let createdAt: Double
    let transcript: String
    let videoID: String
    let duration: Double
    /// 0-100, or nil until coaching returns a parseable rubric.
    let score: Int?
    /// Criterion name to a 0-4 rating.
    let rubric: [String: Double]
    let feedback: String
    /// scored, unscored, not_started, or the coaching run status (queued, running, needs_input, failed ...).
    let status: String
    let runID: String
    let runMessage: String

    init(_ json: JSON) {
        id = json["id"].string
        questionID = json["question_id"].string
        createdAt = json["created_at"].double
        transcript = json["transcript"].string
        videoID = json["video_id"].string
        duration = json["duration"].double
        score = json["score"].isNull ? nil : json["score"].int
        rubric = json["rubric"].object.mapValues(\.double)
        feedback = json["feedback"].string
        status = json["status"].string
        runID = json["run"]["id"].string
        runMessage = json["run"]["message"].string
    }

    var isCoaching: Bool { !["scored", "unscored", "needs_input", "blocked", "failed", "cancelled", "not_started"].contains(status) }
    var isStalled: Bool { ["needs_input", "blocked", "failed", "cancelled"].contains(status) }
}

struct PracticeSlot: Identifiable, Hashable {
    let question: PracticeQuestion
    let attemptCount: Int
    let best: PracticeAttempt?

    var id: String { question.id }

    init(_ json: JSON) {
        question = PracticeQuestion(json["question"])
        attemptCount = json["attempt_count"].int
        best = json["best"].object.isEmpty ? nil : PracticeAttempt(json["best"])
    }
}

struct PracticeChoice: Identifiable, Hashable {
    let id: String
    let label: String
    let available: Bool

    init(_ json: JSON) {
        id = json["id"].string
        label = json["label"].string
        available = json["available"].isNull ? true : json["available"].bool
    }
}

enum PracticeScore {
    /// Display label for a score badge.
    static func label(_ attempt: PracticeAttempt?) -> String {
        guard let attempt else { return "Not started" }
        if let score = attempt.score { return "\(score)" }
        return attempt.isCoaching ? "Scoring…" : "Unscored"
    }

    static func criterion(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }
}

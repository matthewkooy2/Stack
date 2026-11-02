import Foundation

/// What the coaching screen needs, read out of the agent's written coaching.
struct ParsedCoaching: Equatable {
    var verdict = ""
    var criteria: [CoachCriterion] = []
    var focus = ""
    var followUps: [String] = []
}

/// The coaching step returns free-form prose (`summary` and `text` hold the same string) and its layout changes from
/// one reply to the next: "Overall: 0/4 — …" in one, "Assessment: …" in another; scores written "0/4 —" or just
/// "0 —"; a Technical and a Behavioral list, or only one. This reads out the verdict, the scored rows and the next step
/// from any of those, and leaves whatever it cannot find empty so the screen can fall back gracefully.
enum CoachingText {
    private enum Section { case general, technical, behavioral }

    private static let scoreLine = try! NSRegularExpression(
        pattern: #"^\s*[-•*]?\s*([A-Z][A-Za-z' /&-]{2,32}?):\s*(\d(?:\.\d+)?)\s*(?:/\s*4|out of 4)?\s*[—–:\-]+\s*(.+?)\s*$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"^\s*\d+[.)]\s*([^:]{2,40}):"#)
    private static let verdictPrefixes = ["overall assessment:", "overall:", "assessment:", "summary:", "verdict:"]

    static func parse(_ raw: String) -> ParsedCoaching {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var result = ParsedCoaching()

        let paragraphs = paragraphs(text)
        if var first = paragraphs.first {
            for prefix in verdictPrefixes {
                if let range = first.range(of: prefix, options: [.caseInsensitive, .anchored]) {
                    first = String(first[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
            result.verdict = headline(first)
            // "Overall: 0/4" on a line of its own says nothing; the sentence after it is the headline.
            if result.verdict.range(of: #"^\d(\.\d)?\s*/\s*4\.?$"#, options: .regularExpression) != nil, paragraphs.count > 1 {
                result.verdict = result.verdict.trimmingCharacters(in: CharacterSet(charactersIn: ".")) + " — " + headline(paragraphs[1], limit: 70)
            }
        }

        var rows: [Section: [CoachCriterion]] = [:]
        var section = Section.general
        for line in lines {
            let heading = line.lowercased().trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("technical") && !heading.contains("correctness") { section = .technical; continue }
            if heading.hasPrefix("behavioral") { section = .behavioral; continue }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = scoreLine.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line), let score = Range(match.range(at: 2), in: line),
                  let why = Range(match.range(at: 3), in: line) else { continue }
            let title = String(line[name]).trimmingCharacters(in: .whitespaces)
            guard title.lowercased() != "overall", let value = Double(line[score]), value <= 4 else { continue }
            rows[section, default: []].append(CoachCriterion(name: title, score: min(max(Int(value.rounded()), 0), 4),
                                                             why: sentenceCase(String(line[why]))))
        }
        // The practice is behavioral: its list wins over a technical one that only reports missing evidence.
        result.criteria = rows[.behavioral] ?? rows[.general] ?? rows[.technical] ?? []

        let focusHeadings = ["focused next practice", "next practice", "work on"]
        if let index = lines.firstIndex(where: { line in focusHeadings.contains { line.lowercased().hasPrefix($0) } }) {
            let same = lines[index].split(separator: ":", maxSplits: 1).dropFirst().first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            let contentIndex = same.isEmpty ? lines[(index + 1)...].firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } : index
            let content = same.isEmpty ? (contentIndex.map { lines[$0] } ?? "") : same
            var focus = firstSentence(content, limit: 160)
            if focus.hasSuffix(":") {
                // "…using five explicit beats:" then a numbered list: name the beats.
                focus.removeLast()
                let labels = lines[((contentIndex ?? index) + 1)...].prefix(8).compactMap { line -> String? in
                    let range = NSRange(line.startIndex..., in: line)
                    guard let match = numbered.firstMatch(in: line, range: range), let label = Range(match.range(at: 1), in: line) else { return nil }
                    return String(line[label]).lowercased()
                }
                if !labels.isEmpty { focus += " (" + labels.joined(separator: ", ") + ")" }
            }
            result.focus = focus
        }

        if let index = lines.firstIndex(where: { $0.lowercased().contains("follow-up question") }) {
            for line in lines[(index + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), !trimmed[..<dot].isEmpty,
                      trimmed[..<dot].allSatisfy(\.isNumber) else {
                    if !trimmed.isEmpty { break } else { continue }
                }
                result.followUps.append(String(trimmed[trimmed.index(after: dot)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }

    /// A short headline: the first sentence, trimmed to its first clause when it runs long.
    static func headline(_ text: String, limit: Int = 90) -> String {
        var sentence = firstSentence(text, limit: 400)
        guard sentence.count > limit else { return sentence }
        for separator in [", so ", ", but ", ", and ", "; ", " — ", ", "] {
            if let range = sentence.range(of: separator), sentence.distance(from: sentence.startIndex, to: range.lowerBound) >= 24 {
                sentence = String(sentence[..<range.lowerBound])
                break
            }
        }
        if sentence.count > limit, let cut = sentence.prefix(limit).lastIndex(of: " ") { sentence = String(sentence[..<cut]) + "…" }
        if let last = sentence.last, !".?!…".contains(last) { sentence += "." }
        return sentence
    }

    /// Up to the first full stop, question mark or line break, cut short if it runs long.
    static func firstSentence(_ text: String, limit: Int = 140) -> String {
        let flat = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var end = flat.endIndex
        var index = flat.startIndex
        while index < flat.endIndex {
            let character = flat[index]
            if character == "\n" { end = index; break }
            if ".?!".contains(character) {
                let next = flat.index(after: index)
                if next == flat.endIndex || flat[next] == " " || flat[next] == "\n" { end = next; break }
            }
            index = flat.index(after: index)
        }
        var sentence = String(flat[..<end]).trimmingCharacters(in: .whitespaces)
        if sentence.count > limit, let cut = sentence.prefix(limit).lastIndex(of: " ") {
            sentence = String(sentence[..<cut]) + "…"
        }
        return sentence
    }

    private static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// The coaching as readable paragraphs, for the "Your answer" page.
    static func paragraphs(_ raw: String) -> [String] {
        raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Mock-interview coaching arrives as paragraphs headed "Strengths:" and "Improvements:" (and sometimes a next step).
/// This reads each section's first sentence so the screen can show one line per section.
struct InterviewNote: Equatable {
    var strength = ""
    var improvement = ""

    static func parse(_ raw: String) -> InterviewNote {
        var note = InterviewNote()
        for paragraph in CoachingText.paragraphs(raw) {
            let lower = paragraph.lowercased()
            for (label, keyPath) in [("strengths:", \InterviewNote.strength), ("strength:", \InterviewNote.strength),
                                     ("improvements:", \InterviewNote.improvement), ("improvement:", \InterviewNote.improvement),
                                     ("next step:", \InterviewNote.improvement)] where lower.hasPrefix(label) {
                let body = paragraph.dropFirst(label.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if note[keyPath: keyPath].isEmpty { note[keyPath: keyPath] = CoachingText.headline(body, limit: 150) }
            }
        }
        if note.strength.isEmpty && note.improvement.isEmpty { note.strength = CoachingText.headline(raw, limit: 150) }
        return note
    }
}

/// How a coaching reply becomes the scorecard, whether it arrives structured or as prose.
enum CoachingPresentation {
    static func make(from feedback: JSON) -> (verdict: String, criteria: [CoachCriterion], focus: String) {
        let structured: [CoachCriterion] = feedback["rubric"].array.compactMap { item in
            let name = item["criterion"].string
            guard !name.isEmpty else { return nil }
            return CoachCriterion(name: name.prefix(1).uppercased() + name.dropFirst(),
                                  score: min(max(Int(item["score"].double.rounded()), 0), 4), why: item["feedback"].string)
        }
        let raw = feedback["text"].string.isBlank ? feedback["summary"].string : feedback["text"].string
        let parsed = CoachingText.parse(raw)
        let criteria = structured.isEmpty ? parsed.criteria : structured
        var verdict = structured.isEmpty ? parsed.verdict : CoachingText.headline(feedback["summary"].string)
        if verdict.isBlank { verdict = CoachingText.headline(raw) }
        let weakest = criteria.min { $0.score < $1.score }?.why ?? ""
        let focus = feedback["next_exercises"].strings.first
            ?? (parsed.focus.isBlank ? CoachingText.firstSentence(weakest) : parsed.focus)
        return (verdict, criteria, focus)
    }
}

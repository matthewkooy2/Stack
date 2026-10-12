import Foundation

/// The resume fields Stack's review screen edits, as agreed with the backend: flat keys such as
/// `profile.name` and `workExperiences.1.jobTitle`. Entry sections repeat; `descriptions` is a
/// newline-separated list of bullets. Keys outside this table are kept, shown and sent back unchanged.
/// Limits and extra fields come from the server (`ResumeLimits`, `ResumeDefinition`), not from here.
struct ResumeFieldSpec: Hashable {
    let name: String
    let label: String
    var bullets = false
    var multiline = false
    var email = false
}

struct ResumeSectionSpec: Hashable {
    let key: String
    /// Navigation title.
    let title: String
    /// Name of one entry of a repeated section ("Education 2"); the title for a single section.
    let entryLabel: String
    let repeated: Bool
    let fields: [ResumeFieldSpec]
    var addLabel: String { "Add \(entryLabel.lowercased())" }
}

enum ResumeSchema {
    static let sections: [ResumeSectionSpec] = [
        ResumeSectionSpec(key: "profile", title: "Contact", entryLabel: "Contact", repeated: false, fields: [
            ResumeFieldSpec(name: "name", label: "Name"),
            ResumeFieldSpec(name: "email", label: "Email", email: true),
            ResumeFieldSpec(name: "phone", label: "Phone"),
            ResumeFieldSpec(name: "location", label: "Location"),
            ResumeFieldSpec(name: "url", label: "Link"),
            ResumeFieldSpec(name: "summary", label: "Summary", multiline: true),
        ]),
        ResumeSectionSpec(key: "educations", title: "Education", entryLabel: "Education", repeated: true, fields: [
            ResumeFieldSpec(name: "school", label: "School"),
            ResumeFieldSpec(name: "degree", label: "Degree"),
            ResumeFieldSpec(name: "date", label: "Date"),
            ResumeFieldSpec(name: "gpa", label: "GPA"),
            ResumeFieldSpec(name: "location", label: "Location"),
            ResumeFieldSpec(name: "descriptions", label: "Details", bullets: true),
        ]),
        ResumeSectionSpec(key: "workExperiences", title: "Work experience", entryLabel: "Experience", repeated: true, fields: [
            ResumeFieldSpec(name: "jobTitle", label: "Job title"),
            ResumeFieldSpec(name: "company", label: "Company"),
            ResumeFieldSpec(name: "date", label: "Date"),
            ResumeFieldSpec(name: "location", label: "Location"),
            ResumeFieldSpec(name: "descriptions", label: "Details", bullets: true),
        ]),
        ResumeSectionSpec(key: "projects", title: "Projects", entryLabel: "Project", repeated: true, fields: [
            ResumeFieldSpec(name: "project", label: "Project"),
            ResumeFieldSpec(name: "date", label: "Date"),
            ResumeFieldSpec(name: "descriptions", label: "Details", bullets: true),
        ]),
        ResumeSectionSpec(key: "skills", title: "Skills", entryLabel: "Skills", repeated: false, fields: [
            ResumeFieldSpec(name: "descriptions", label: "Skills", bullets: true),
        ]),
        ResumeSectionSpec(key: "additional", title: "Additional details", entryLabel: "Additional details", repeated: false, fields: [
            ResumeFieldSpec(name: "descriptions", label: "Other details", bullets: true),
        ]),
    ]

    static func spec(_ key: String) -> ResumeSectionSpec? { sections.first { $0.key == key } }
    static func field(section: String, name: String) -> ResumeFieldSpec? {
        spec(section)?.fields.first { $0.name == name }
    }

    /// `"workExperiences.1.jobTitle"` -> (`workExperiences`, 1, `jobTitle`). Anything else is a single key.
    static func entryKey(_ key: String) -> (section: String, index: Int, field: String)? {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, !parts[0].isEmpty, !parts[2].isEmpty, let index = Int(parts[1]), index >= 0 else { return nil }
        return (parts[0], index, parts[2])
    }

    /// A single key split into its section and field name: `profile.links.github` -> (`profile`, `github`).
    static func singleKey(_ key: String) -> (section: String, field: String) {
        let parts = key.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count > 1 else { return ("", key) }
        return (parts[0], parts[parts.count - 1])
    }

    /// A readable name for a field the app does not know: `jobTitle` -> `Job title`.
    static func humanized(_ name: String) -> String {
        var out = ""
        for character in name {
            if character == "_" || character == "-" { out.append(" "); continue }
            if character.isUppercase, !out.isEmpty { out.append(" ") }
            out.append(character)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed.prefix(1).uppercased() + trimmed.dropFirst().lowercased()
    }
}

/// Bullet items of a newline-separated `descriptions` value. Blank items are kept while editing so a
/// newly added bullet can be typed into, and dropped when the value is normalized for saving.
enum ResumeBullets {
    static func split(_ value: String) -> [String] {
        value.isEmpty ? [] : value.components(separatedBy: "\n")
    }
    static func join(_ items: [String]) -> String { items.joined(separator: "\n") }
    static func clean(_ item: String) -> String {
        item.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

/// The processing lane of structured resume extraction. Retired `pdf` tickets map onto it; the LaTeX
/// `source` lane is a separate lane and is never remapped.
enum ResumeLane {
    static let structured = "import"
    static let source = "source"

    static func kind(of processing: JSON) -> String {
        processing["kind"].string == source ? source : structured
    }
}

/// Bounds the server publishes with a review document. A value the server did not send is nil: no
/// client-side limit is applied for it and the server's own error is shown instead.
struct ResumeLimits: Codable, Hashable {
    var groups: [String: Int] = [:]
    var scalar: Int?
    var summary: Int?
    var descriptions: Int?
    var bullet: Int?
    var text: Int?
    var history: Int?
    /// Additional server-only compatibility projection bounds, including generated labels/separators.
    var projectionRecords: Int?
    var projectionText: Int?
    var textIncludesProjection: Bool?

    init() {}

    init(_ json: JSON) {
        func positive(_ value: JSON) -> Int? { value.isNull || value.int <= 0 ? nil : value.int }
        for (key, value) in json["groups"].object { if let limit = positive(value) { groups[key] = limit } }
        scalar = positive(json["scalar"])
        summary = positive(json["summary"])
        descriptions = positive(json["descriptions"])
        bullet = positive(json["bullet"])
        text = positive(json["text"])
        history = positive(json["history"])
        projectionRecords = positive(json["projection_records"])
        projectionText = positive(json["projection_text"])
        if !json["text_includes_projection"].isNull { textIncludesProjection = json["text_includes_projection"].bool }
    }

    var isEmpty: Bool { self == ResumeLimits() }

    /// Characters one field may hold: the summary, a `descriptions` list or any other text.
    func fieldLimit(section: String, field: String) -> Int? {
        if section == "profile", field == "summary" { return summary }
        return field == "descriptions" ? descriptions : scalar
    }
}

struct ResumeDefinitionField: Codable, Hashable {
    let name: String
    let label: String
    let multiline: Bool
}

/// One group of fields the server accepts, so a client can add entries when a parse found none.
struct ResumeDefinition: Codable, Hashable {
    let key: String
    let label: String
    let repeatable: Bool
    let max: Int?
    let fields: [ResumeDefinitionField]

    static func parse(_ json: JSON) -> [ResumeDefinition] {
        json.array.compactMap { item in
            let key = item["key"].string
            guard !key.isEmpty else { return nil }
            let fields: [ResumeDefinitionField] = item["fields"].array.compactMap { field in
                var name = field["name"].string
                if name.isEmpty { name = field["key"].string.split(separator: ".").last.map(String.init) ?? "" }
                guard !name.isEmpty else { return nil }
                return ResumeDefinitionField(name: name, label: field["label"].string, multiline: field["multiline"].bool)
            }
            let max = item["max"].isNull || item["max"].int <= 0 ? nil : item["max"].int
            return ResumeDefinition(key: key, label: item["label"].string, repeatable: item["repeatable"].bool, max: max, fields: fields)
        }
    }
}

enum ResumeWarnings {
    /// Warnings arrive as plain strings or as `{code, message}` objects; both read as one line each.
    static func normalize(_ json: JSON) -> [String] {
        let items: [JSON]
        switch json {
        case .array(let values): items = values
        case .null: items = []
        default: items = [json]
        }
        return items.compactMap { item in
            var text = item.string
            if case .object = item {
                text = item["message"].string.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { text = item["code"].string }
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

struct ResumeEntry: Codable, Hashable, Identifiable {
    /// Local identity that follows the entry through reordering; never sent to the backend.
    var id: String
    var values: [String: String]
    /// What each field held when this entry was last read or saved. This is the saved version, not the
    /// original extraction: the backend keeps no per-entry link to the original parse.
    var saved: [String: String]
}

/// The editable document: single fields by flat key, repeated entries in display order. Entries keep
/// their unknown fields and last-saved values while they are added, removed and reordered.
struct ResumeDocument: Codable, Hashable {
    var singles: [String: String] = [:]
    var singleSaved: [String: String] = [:]
    var entries: [String: [ResumeEntry]] = [:]
    /// Backend labels for fields and sections the app has no table entry for.
    var labels: [String: String] = [:]
    /// Bullet lists that hold exactly one blank item. An empty string cannot tell "no items" from "one
    /// blank item", so this local marker keeps the first new row until it is typed into or removed.
    var blankBullets: Set<String> = []

    init() {}

    /// - Parameter values: flat key/value map as read; it is also what each field's saved value is.
    init(values: [String: String], labels: [String: String] = [:]) {
        self.labels = labels
        var grouped: [String: [Int: [String: String]]] = [:]
        for (key, value) in values {
            if let entry = ResumeSchema.entryKey(key) {
                grouped[entry.section, default: [:]][entry.index, default: [:]][entry.field] = value
            } else {
                singles[key] = value
                singleSaved[key] = value
            }
        }
        for (section, indexed) in grouped {
            entries[section] = indexed.keys.sorted().map { index in
                let fields = indexed[index] ?? [:]
                return ResumeEntry(id: "\(section).\(index)", values: fields, saved: fields)
            }
        }
    }

    // MARK: Structure

    /// Repeated sections present in the document that the app does not know, in a stable order.
    var unknownEntrySections: [String] {
        entries.keys.filter { ResumeSchema.spec($0) == nil && !(entries[$0] ?? []).isEmpty }.sorted()
    }

    /// Single keys that do not belong to a known field of a known single section.
    func extraKeys(in section: String) -> [String] {
        let known = Set(ResumeSchema.spec(section)?.fields.map { "\(section).\($0.name)" } ?? [])
        return singles.keys.filter { $0.hasPrefix(section + ".") && !known.contains($0) }.sorted()
    }

    /// Single keys under a prefix with no section at all (for example `links.github`).
    var strayKeys: [String] {
        singles.keys.filter { key in
            let prefix = key.split(separator: ".", maxSplits: 1).first.map(String.init) ?? key
            return ResumeSchema.spec(prefix) == nil || ResumeSchema.spec(prefix)?.repeated == true
        }.sorted()
    }

    func entries(of section: String) -> [ResumeEntry] { entries[section] ?? [] }

    func entry(_ section: String, _ id: String) -> ResumeEntry? { entries(of: section).first { $0.id == id } }

    // MARK: Reading

    func single(_ key: String) -> String { singles[key] ?? "" }

    func value(_ section: String, _ id: String, _ field: String) -> String { entry(section, id)?.values[field] ?? "" }

    func label(forKey key: String) -> String {
        if let entry = ResumeSchema.entryKey(key) {
            return labels["\(entry.section).\(entry.field)"] ?? ResumeSchema.field(section: entry.section, name: entry.field)?.label
                ?? ResumeSchema.humanized(entry.field)
        }
        if let known = labels[key] { return known }
        let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
        if parts.count == 2, let field = ResumeSchema.field(section: parts[0], name: parts[1]) { return field.label }
        return ResumeSchema.humanized(parts.last ?? key)
    }

    func label(section: String, field: String) -> String {
        labels["\(section).\(field)"] ?? ResumeSchema.field(section: section, name: field)?.label ?? ResumeSchema.humanized(field)
    }

    func sectionTitle(_ section: String) -> String {
        ResumeSchema.spec(section)?.title ?? labels[section] ?? ResumeSchema.humanized(section)
    }

    // MARK: Editing

    // Typed text is stored exactly as given. Limits are checked by `problems(limits:)` before a save, so
    // an edit is never cut short silently.

    mutating func setSingle(_ key: String, _ value: String) {
        singles[key] = value
        blankBullets.remove(Self.blankKey(single: key))
        if singleSaved[key] == nil { singleSaved[key] = "" }
    }

    mutating func setField(_ section: String, _ id: String, _ field: String, _ value: String) {
        guard var list = entries[section], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].values[field] = value
        blankBullets.remove(Self.blankKey(section, id, field))
        if list[index].saved[field] == nil { list[index].saved[field] = "" }
        entries[section] = list
    }

    /// Adds an entry with every given field present and empty (the known fields when none are given).
    /// Returns nil at `limit`.
    @discardableResult
    mutating func addEntry(_ section: String, fields: [String]? = nil, limit: Int? = nil,
                           id: String = "new-" + UUID().uuidString.lowercased()) -> String? {
        var list = entries[section] ?? []
        if let limit, list.count >= limit { return nil }
        let names = fields ?? ResumeSchema.spec(section)?.fields.map(\.name) ?? []
        let blank = Dictionary(names.map { ($0, "") }, uniquingKeysWith: { first, _ in first })
        list.append(ResumeEntry(id: id, values: blank, saved: blank))
        entries[section] = list
        return id
    }

    mutating func removeEntry(_ section: String, _ id: String) {
        entries[section]?.removeAll { $0.id == id }
        let prefix = Self.blankKey(section, id, "")
        blankBullets = blankBullets.filter { !$0.hasPrefix(prefix) }
    }

    /// Moves an entry one place; returns whether it moved.
    @discardableResult
    mutating func moveEntry(_ section: String, _ id: String, by offset: Int) -> Bool {
        guard var list = entries[section], let index = list.firstIndex(where: { $0.id == id }) else { return false }
        let target = index + offset
        guard list.indices.contains(target) else { return false }
        list.swapAt(index, target)
        entries[section] = list
        return true
    }

    // Bullets are edited as items of the entry's newline-separated value.

    private static func blankKey(single key: String) -> String { "single:" + key }
    private static func blankKey(_ section: String, _ id: String, _ field: String) -> String { "entry:\(section):\(id):\(field)" }

    private func items(of value: String, blankKey: String) -> [String] {
        value.isEmpty && blankBullets.contains(blankKey) ? [""] : ResumeBullets.split(value)
    }

    func bullets(_ section: String, _ id: String, _ field: String) -> [String] {
        items(of: value(section, id, field), blankKey: Self.blankKey(section, id, field))
    }

    mutating func setBullets(_ section: String, _ id: String, _ field: String, _ items: [String]) {
        let cleaned = items.map(ResumeBullets.clean)
        setField(section, id, field, ResumeBullets.join(cleaned))
        if cleaned == [""], entry(section, id) != nil { blankBullets.insert(Self.blankKey(section, id, field)) }
    }

    func singleBullets(_ key: String) -> [String] { items(of: single(key), blankKey: Self.blankKey(single: key)) }

    mutating func setSingleBullets(_ key: String, _ items: [String]) {
        let cleaned = items.map(ResumeBullets.clean)
        setSingle(key, ResumeBullets.join(cleaned))
        if cleaned == [""] { blankBullets.insert(Self.blankKey(single: key)) }
    }

    // MARK: Saved versus edited

    func isChanged(single key: String) -> Bool {
        Self.normalize(single(key), bullets: Self.isBulletKey(key)) != Self.normalize(singleSaved[key] ?? "", bullets: Self.isBulletKey(key))
    }

    func isChanged(_ section: String, _ id: String, _ field: String) -> Bool {
        guard let entry = entry(section, id) else { return false }
        let bullets = ResumeSchema.field(section: section, name: field)?.bullets ?? (field == "descriptions")
        return Self.normalize(entry.values[field] ?? "", bullets: bullets) != Self.normalize(entry.saved[field] ?? "", bullets: bullets)
    }

    func saved(single key: String) -> String { singleSaved[key] ?? "" }
    func saved(_ section: String, _ id: String, _ field: String) -> String { entry(section, id)?.saved[field] ?? "" }

    mutating func revert(single key: String) {
        singles[key] = singleSaved[key] ?? ""
        blankBullets.remove(Self.blankKey(single: key))
    }

    mutating func revert(_ section: String, _ id: String, _ field: String) {
        guard var list = entries[section], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].values[field] = list[index].saved[field] ?? ""
        blankBullets.remove(Self.blankKey(section, id, field))
        entries[section] = list
    }

    /// Whether anything in the entry was edited, or the entry was added after the resume was read.
    func isChanged(_ section: String, _ id: String) -> Bool {
        guard let entry = entry(section, id) else { return false }
        return entry.values.keys.contains { isChanged(section, id, $0) }
    }

    // MARK: Flattening

    private static func isBulletKey(_ key: String) -> Bool { key.hasSuffix(".descriptions") }

    static func normalize(_ value: String, bullets: Bool) -> String {
        if bullets {
            return value.components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isEmptyEntry(_ entry: ResumeEntry) -> Bool {
        entry.values.allSatisfy { Self.normalize($0.value, bullets: $0.key == "descriptions").isEmpty }
    }

    /// Rows that exist only on this device because they hold no text yet: a new blank entry or a first
    /// blank bullet. They are never sent, but a local draft keeps them.
    var hasLocalOnlyRows: Bool {
        func hasBlankItems(_ value: String) -> Bool {
            ResumeBullets.split(value).contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        return !blankBullets.isEmpty
            || singles.contains { Self.isBulletKey($0.key) && hasBlankItems($0.value) }
            || entries.values.contains { list in
                list.contains { entry in
                    isEmptyEntry(entry) || entry.values.contains { $0.key == "descriptions" && hasBlankItems($0.value) }
                }
            }
    }

    /// The flat values to save. Entries are numbered in display order; an entry with every field empty
    /// is left out, so an unfilled "Add" does not become a blank entry on the backend.
    func flatValues() -> [String: String] {
        var flat: [String: String] = [:]
        for (key, value) in singles { flat[key] = Self.normalize(value, bullets: Self.isBulletKey(key)) }
        for (section, list) in entries {
            var index = 0
            for entry in list where !isEmptyEntry(entry) {
                for (field, value) in entry.values {
                    flat["\(section).\(index).\(field)"] = Self.normalize(value, bullets: field == "descriptions")
                }
                index += 1
            }
        }
        return flat
    }

    // MARK: Limits

    /// A sentence when `value` does not fit the server's bounds for this field, else nil.
    static func problem(value: String, section: String, field: String, label: String, limits: ResumeLimits) -> String? {
        let bullets = field == "descriptions"
        let text = normalize(value, bullets: bullets)
        if bullets, let bullet = limits.bullet,
           let long = text.components(separatedBy: "\n").first(where: { $0.count > bullet }) {
            return "\(label): each item can be up to \(bullet) characters (this one has \(long.count)). Your text is kept; shorten it to save."
        }
        if let limit = limits.fieldLimit(section: section, field: field), text.count > limit {
            return "\(label) can be up to \(limit) characters (it has \(text.count)). Your text is kept; shorten it to save."
        }
        return nil
    }

    /// Why this document cannot be saved, in a stable order. Empty when it fits the given limits.
    func problems(limits: ResumeLimits) -> [String] {
        var found: [String] = []
        for key in singles.keys.sorted() {
            let parts = ResumeSchema.singleKey(key)
            let label = "\(sectionTitle(parts.section)) \(self.label(forKey: key))"
            if let message = Self.problem(value: singles[key] ?? "", section: parts.section, field: parts.field,
                                          label: label, limits: limits) { found.append(message) }
        }
        for section in entries.keys.sorted() {
            let kept = entries(of: section).filter { !isEmptyEntry($0) }
            if let limit = limits.groups[section], kept.count > limit {
                found.append("\(sectionTitle(section)) can have up to \(limit) entries (there are \(kept.count)). Remove some to save.")
            }
            for (index, entry) in kept.enumerated() {
                for field in entry.values.keys.sorted() {
                    let label = "\(sectionTitle(section)) \(index + 1) \(self.label(section: section, field: field))"
                    if let message = Self.problem(value: entry.values[field] ?? "", section: section, field: field,
                                                  label: label, limits: limits) { found.append(message) }
                }
            }
        }
        if let limit = limits.text {
            let total = flatValues().values.reduce(0) { $0 + $1.count }
            if total > limit { found.append("Resume details can hold up to \(limit) characters in total (there are \(total)). Your text is kept; shorten it to save.") }
        }
        return found
    }
}

// MARK: Original extraction

struct ResumeOriginalField: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
}

struct ResumeOriginalGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let fields: [ResumeOriginalField]
}

/// The extractor's own values read back as a read-only list in the order they were extracted. Entry
/// numbers here are original-parse positions: no link to the current, possibly reordered, entries is
/// inferred, because the backend keeps none.
enum ResumeOriginalView {
    static func groups(values: [String: String], labels: [String: String] = [:]) -> [ResumeOriginalGroup] {
        let document = ResumeDocument(values: values, labels: labels)
        func fields(_ keys: [String], id: (String) -> String, label: (String) -> String, value: (String) -> String) -> [ResumeOriginalField] {
            keys.compactMap { key in
                let text = value(key)
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : ResumeOriginalField(id: id(key), label: label(key), value: text)
            }
        }
        var result: [ResumeOriginalGroup] = []
        func single(_ spec: ResumeSectionSpec) {
            let keys = spec.fields.map { "\(spec.key).\($0.name)" } + document.extraKeys(in: spec.key)
            let rows = fields(keys, id: { $0 }, label: { document.label(forKey: $0) }, value: { document.single($0) })
            if !rows.isEmpty { result.append(ResumeOriginalGroup(id: spec.key, title: spec.title, fields: rows)) }
        }
        func repeated(_ section: String, title: String) {
            for (position, entry) in document.entries(of: section).enumerated() {
                // The number is the original parse position carried by the key, not the list position.
                let number = (Int(entry.id.split(separator: ".").last ?? "") ?? position) + 1
                let known = ResumeSchema.spec(section)?.fields.map(\.name) ?? []
                let names = known.filter { entry.values[$0] != nil } + entry.values.keys.filter { !known.contains($0) }.sorted()
                let rows = fields(names, id: { "\(section).\(position).\($0)" }, label: { document.label(section: section, field: $0) },
                                  value: { entry.values[$0] ?? "" })
                if !rows.isEmpty { result.append(ResumeOriginalGroup(id: "\(section).\(position)", title: "\(title) \(number)", fields: rows)) }
            }
        }
        for spec in ResumeSchema.sections {
            if spec.repeated { repeated(spec.key, title: spec.entryLabel) } else { single(spec) }
        }
        for section in document.unknownEntrySections { repeated(section, title: document.sectionTitle(section)) }
        let stray = fields(document.strayKeys, id: { $0 }, label: { document.label(forKey: $0) }, value: { document.single($0) })
        if !stray.isEmpty { result.append(ResumeOriginalGroup(id: "other", title: "Other fields", fields: stray)) }
        return result
    }
}

/// What a read or save response carried, normalized.
struct ResumeIncoming {
    var revision: JSON
    var values: [String: String]
    /// The immutable original extraction (`original_values`), in the original parse's numbering.
    var originals: [String: String]?
    var labels: [String: String]
    var records: [JSON]
    var hasFields: Bool
    var warnings: [String]
    var limits: ResumeLimits
    var definitions: [ResumeDefinition]

    init(_ result: JSON) {
        revision = result["revision"]
        var flat: [String: String] = [:]
        var labels: [String: String] = [:]
        var sawSections = false
        if case .array = result["sections"] { sawSections = true }
        for section in result["sections"].array {
            sawSections = true
            let base = section["key"].string.split(separator: ".").first.map(String.init) ?? ""
            // Only fields and sections the app has no table entry for need the backend's wording.
            if !base.isEmpty, ResumeSchema.spec(base) == nil, labels[base] == nil {
                var words = section["label"].string.split(separator: " ").map(String.init)
                if words.count > 1, Int(words[words.count - 1]) != nil { words.removeLast() }
                if !words.isEmpty { labels[base] = words.joined(separator: " ") }
            }
            for field in section["fields"].array {
                let key = field["key"].string
                guard !key.isEmpty else { continue }
                flat[key] = field["value"].string
                let label = field["label"].string
                guard !label.isEmpty else { continue }
                if let entry = ResumeSchema.entryKey(key) {
                    if ResumeSchema.field(section: entry.section, name: entry.field) == nil { labels["\(entry.section).\(entry.field)"] = label }
                } else {
                    let parts = key.split(separator: ".", maxSplits: 1).map(String.init)
                    if parts.count != 2 || ResumeSchema.field(section: parts[0], name: parts[1]) == nil { labels[key] = label }
                }
            }
        }
        var sawValues = false
        if case .object = result["values"] { sawValues = true }
        for (key, value) in result["values"].object {
            sawValues = true
            if flat[key] == nil { flat[key] = value.string }
        }
        values = flat
        self.labels = labels
        hasFields = sawSections || sawValues
        if case .object(let originalObject) = result["original_values"] {
            originals = originalObject.mapValues { $0.string }
        } else {
            originals = nil
        }
        records = result["records"].array
        warnings = ResumeWarnings.normalize(result["warnings"])
        limits = ResumeLimits(result["limits"])
        definitions = ResumeDefinition.parse(result["definitions"])
    }
}

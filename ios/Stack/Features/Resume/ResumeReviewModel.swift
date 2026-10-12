import Foundation

/// The resume fields Stack's review screen edits, as agreed with the backend: flat keys such as
/// `profile.name` and `workExperiences.1.jobTitle`. Entry sections repeat; `descriptions` is a
/// newline-separated list of bullets. Keys outside this table are kept, shown and sent back unchanged.
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
    static let maxEntries = 20
    static let maxFieldLength = 8000
    static let maxTotalLength = 100_000

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

struct ResumeEntry: Codable, Hashable, Identifiable {
    /// Local identity that follows the entry through reordering; never sent to the backend.
    var id: String
    var values: [String: String]
    /// What the field held when the entry was read (or the backend's `original_values`).
    var original: [String: String]
}

/// The editable document: single fields by flat key, repeated entries in display order. Entries keep
/// their original values and unknown fields while they are added, removed and reordered.
struct ResumeDocument: Codable, Hashable {
    var singles: [String: String] = [:]
    var singleOriginals: [String: String] = [:]
    var entries: [String: [ResumeEntry]] = [:]
    /// Backend labels for fields and sections the app has no table entry for.
    var labels: [String: String] = [:]

    init() {}

    /// - Parameters:
    ///   - values: flat key/value map as read.
    ///   - originals: the backend's immutable original values, when it supplies them.
    ///   - carried: originals carried over from the document that was just saved (used when the
    ///     backend supplies none), keyed by the same flat keys as `values`.
    init(values: [String: String], originals: [String: String]? = nil, carried: [String: String]? = nil,
         labels: [String: String] = [:]) {
        self.labels = labels
        func original(_ key: String, _ value: String) -> String { originals?[key] ?? carried?[key] ?? value }
        var grouped: [String: [Int: [String: String]]] = [:]
        for (key, value) in values {
            if let entry = ResumeSchema.entryKey(key) {
                grouped[entry.section, default: [:]][entry.index, default: [:]][entry.field] = value
            } else {
                singles[key] = value
                singleOriginals[key] = original(key, value)
            }
        }
        for (section, indexed) in grouped {
            entries[section] = indexed.keys.sorted().map { index in
                let fields = indexed[index] ?? [:]
                var originalFields: [String: String] = [:]
                for (field, value) in fields { originalFields[field] = original("\(section).\(index).\(field)", value) }
                return ResumeEntry(id: "\(section).\(index)", values: fields, original: originalFields)
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

    mutating func setSingle(_ key: String, _ value: String) {
        singles[key] = String(value.prefix(ResumeSchema.maxFieldLength))
        if singleOriginals[key] == nil { singleOriginals[key] = "" }
    }

    mutating func setField(_ section: String, _ id: String, _ field: String, _ value: String) {
        guard var list = entries[section], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].values[field] = String(value.prefix(ResumeSchema.maxFieldLength))
        if list[index].original[field] == nil { list[index].original[field] = "" }
        entries[section] = list
    }

    /// Adds an entry with every known field present and empty. Returns nil at the entry limit.
    @discardableResult
    mutating func addEntry(_ section: String, id: String = "new-" + UUID().uuidString.lowercased()) -> String? {
        var list = entries[section] ?? []
        guard list.count < ResumeSchema.maxEntries else { return nil }
        let names = ResumeSchema.spec(section)?.fields.map(\.name) ?? []
        let blank = Dictionary(uniqueKeysWithValues: names.map { ($0, "") })
        list.append(ResumeEntry(id: id, values: blank, original: blank))
        entries[section] = list
        return id
    }

    mutating func removeEntry(_ section: String, _ id: String) {
        entries[section]?.removeAll { $0.id == id }
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

    func bullets(_ section: String, _ id: String, _ field: String) -> [String] {
        ResumeBullets.split(value(section, id, field))
    }

    mutating func setBullets(_ section: String, _ id: String, _ field: String, _ items: [String]) {
        setField(section, id, field, ResumeBullets.join(items.map(ResumeBullets.clean)))
    }

    func singleBullets(_ key: String) -> [String] { ResumeBullets.split(single(key)) }

    mutating func setSingleBullets(_ key: String, _ items: [String]) {
        setSingle(key, ResumeBullets.join(items.map(ResumeBullets.clean)))
    }

    // MARK: Original versus corrected

    func isChanged(single key: String) -> Bool {
        Self.normalize(single(key), bullets: Self.isBulletKey(key)) != Self.normalize(singleOriginals[key] ?? "", bullets: Self.isBulletKey(key))
    }

    func isChanged(_ section: String, _ id: String, _ field: String) -> Bool {
        guard let entry = entry(section, id) else { return false }
        let bullets = ResumeSchema.field(section: section, name: field)?.bullets ?? (field == "descriptions")
        return Self.normalize(entry.values[field] ?? "", bullets: bullets) != Self.normalize(entry.original[field] ?? "", bullets: bullets)
    }

    func original(single key: String) -> String { singleOriginals[key] ?? "" }
    func original(_ section: String, _ id: String, _ field: String) -> String { entry(section, id)?.original[field] ?? "" }

    mutating func restoreOriginal(single key: String) { singles[key] = singleOriginals[key] ?? "" }

    mutating func restoreOriginal(_ section: String, _ id: String, _ field: String) {
        guard var list = entries[section], let index = list.firstIndex(where: { $0.id == id }) else { return }
        list[index].values[field] = list[index].original[field] ?? ""
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

    private func isEmptyEntry(_ entry: ResumeEntry, section: String) -> Bool {
        entry.values.allSatisfy { Self.normalize($0.value, bullets: $0.key == "descriptions").isEmpty }
    }

    /// The flat values to save. Entries are numbered in display order; an entry with every field empty
    /// is left out, so an unfilled "Add" does not become a blank entry on the backend.
    func flatValues() -> [String: String] {
        var flat: [String: String] = [:]
        for (key, value) in singles { flat[key] = Self.normalize(value, bullets: Self.isBulletKey(key)) }
        for (section, list) in entries {
            var index = 0
            for entry in list where !isEmptyEntry(entry, section: section) {
                for (field, value) in entry.values {
                    flat["\(section).\(index).\(field)"] = Self.normalize(value, bullets: field == "descriptions")
                }
                index += 1
            }
        }
        return flat
    }

    /// The original values under the same numbering as `flatValues()`.
    func flatOriginals() -> [String: String] {
        var flat = singleOriginals
        for (section, list) in entries {
            var index = 0
            for entry in list where !isEmptyEntry(entry, section: section) {
                for (field, value) in entry.original { flat["\(section).\(index).\(field)"] = value }
                index += 1
            }
        }
        return flat
    }

    /// Why this document cannot be saved, or nil.
    var problem: String? {
        let total = flatValues().values.reduce(0) { $0 + $1.count }
        return total > ResumeSchema.maxTotalLength ? "Resume details can hold up to 100,000 characters in total." : nil
    }
}

/// What a read or save response carried, normalized.
struct ResumeIncoming {
    var revision: JSON
    var values: [String: String]
    var originals: [String: String]?
    var labels: [String: String]
    var records: [JSON]
    var hasFields: Bool

    init(_ result: JSON) {
        revision = result["revision"]
        var flat: [String: String] = [:]
        var labels: [String: String] = [:]
        var sawSections = false
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
        for (key, value) in result["values"].object {
            sawValues = true
            if flat[key] == nil { flat[key] = value.string }
        }
        values = flat
        self.labels = labels
        hasFields = sawSections || sawValues
        let originalObject = result["original_values"].object
        originals = originalObject.isEmpty ? nil : originalObject.mapValues { $0.string }
        records = result["records"].array
    }
}

import SwiftUI

/// What the deck is currently searching for, and how the server interpreted it.
struct JobSearch: Equatable {
    var query = ""
    var filters: JSON = [:]
    var criteria: JSON = [:]
    var excluded: [JSON] = []
    var occupations: [String] = []
    var graduation = ""

    mutating func apply(_ result: JSON) {
        criteria = result["criteria"]
        excluded = result["excluded"].array
        occupations = result["occupations"].strings
        graduation = result["timeline_preferences"]["graduation_month"].string
    }

    var notices: [String] { criteria["notices"].strings }

    /// Confirmed-timeline search with no saved graduation month: nothing can be confirmed yet.
    var missingGraduation: Bool {
        let timeline = filters["timeline"].string.isEmpty ? criteria["timeline"].string : filters["timeline"].string
        return timeline == "confirmed" && graduation.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var roleLabel: String {
        let roles = criteria["roles"].string
        return roles.isEmpty ? "All professions" : roles
    }

    var sortLabel: String { filters["sort"].string == "newest" ? "Newest first" : "Best match" }

    // MARK: Quick picks

    static let entryQuery = "Software engineer"

    /// What the server will search: this search's override when saved, otherwise the profile value it returned.
    /// The server drops overrides equal to the profile, so raw `query` and `filters` can omit an active choice.
    private var effectiveRoles: String {
        let own = query.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? criteria["roles"].string : own
    }

    private var effectiveTypes: [String] {
        filters["employment_types"].isNull ? criteria["employment_types"].strings : filters["employment_types"].strings
    }

    /// Stated entry-level, full-time software engineering. Unknown levels are rejected, other details are not.
    var entryLevelActive: Bool {
        effectiveRoles.trimmingCharacters(in: .whitespaces).lowercased() == Self.entryQuery.lowercased()
            && filters["levels"].strings == ["Entry-level"] && effectiveTypes == ["Full-time"]
            && filters["confirmed_level"].bool
    }

    var internshipActive: Bool {
        filters["levels"].strings == ["Internship"] && effectiveTypes == ["Internship"]
    }

    /// The query and filters after toggling a quick pick. Everything the pick does not own is kept.
    func togglingEntryLevel() -> (query: String, filters: JSON) {
        var next = filters
        if entryLevelActive {
            for key in ["levels", "confirmed_level"] { next[key] = .null }
            if filters["employment_types"].strings == ["Full-time"] { next["employment_types"] = .null }
            return ("", next)
        }
        next["levels"] = ["Entry-level"]
        next["employment_types"] = ["Full-time"]
        next["confirmed_level"] = true
        next["any_role"] = .null
        return (Self.entryQuery, next)
    }

    func togglingInternship() -> (query: String, filters: JSON) {
        var next = filters
        if internshipActive {
            next["levels"] = .null
            if filters["employment_types"].strings == ["Internship"] { next["employment_types"] = .null }
        } else {
            next["levels"] = ["Internship"]
            next["employment_types"] = ["Internship"]
        }
        return (query, next)
    }

    func sorting(by order: String) -> (query: String, filters: JSON) {
        var next = filters
        next["sort"] = .string(order)
        return (query, next)
    }

    // MARK: Active filters

    /// True when anything differs from the profile, including keys with no chip, so Reset is always reachable.
    var hasOverrides: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty || filters.object.keys.contains { $0 != "country" }
    }

    /// Explicit choices for this search, each of which can be removed on its own. A saved key is an override,
    /// including an empty one that clears a profile value.
    var active: [JobActiveFilter] {
        var items: [JobActiveFilter] = []
        func add(_ id: String, _ label: String) { items.append(.init(id: id, label: label)) }
        func listed(_ key: String, _ prefix: String, empty: String) {
            guard !filters[key].isNull else { return }
            let values = filters[key].strings
            add(key, values.isEmpty ? empty : prefix + values.joined(separator: ", "))
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if filters["any_role"].bool { add("any_role", "All professions") }
        else if !trimmed.isEmpty { add("query", trimmed) }
        let levels = filters["levels"].strings
        let stated = filters["confirmed_level"].bool
        if !levels.isEmpty { add("levels", levels.joined(separator: ", ") + (stated ? " (stated)" : "")) }
        else if stated { add("confirmed_level", "Level stated") }
        listed("employment_types", "", empty: "Any employment type")
        listed("modes", "", empty: "Any arrangement")
        if !filters["location"].isNull {
            let place = filters["location"].string.trimmingCharacters(in: .whitespaces)
            add("location", place.isEmpty ? "Any location" : place)
        }
        let occupation = filters["occupation"].string
        if !occupation.isEmpty, occupation != "Any" { add("occupation", occupation) }
        if !filters["salary_min"].isNull {
            let pay = filters["salary_min"].double
            let period = filters["salary_period"].string == "hour" ? "hr" : "yr"
            add("salary_min", pay > 0 ? "$\(filters["salary_min"].string)+/\(period)" : "No minimum pay")
        } else if !filters["salary_period"].isNull {
            add("salary_period", "Pay per \(filters["salary_period"].string == "hour" ? "hour" : "year")")
        }
        listed("exclude_companies", "Hiding ", empty: "No hidden employers")
        listed("exclude_terms", "Hiding terms: ", empty: "No hidden terms")
        listed("soft", "Flexible: ", empty: "Nothing flexible")
        let days = filters["posted_days"].int
        if days > 0 { add("posted_days", days == 1 ? "Past day" : "Past \(days) days") }
        if filters["has_posting_date"].bool { add("has_posting_date", "Dated posts") }
        if filters["confirmed_only"].bool { add("confirmed_only", "Confirmed details only") }
        let timeline = filters["timeline"].string
        if timeline == "confirmed" { add("timeline", "Confirmed timeline") }
        else if timeline == "all" { add("timeline", "All timelines") }
        return items
    }

    /// The query and filters with one active choice removed.
    func removing(_ id: String) -> (query: String, filters: JSON) {
        var next = filters
        switch id {
        case "query": return ("", next)
        case "levels": next["levels"] = .null; next["confirmed_level"] = .null
        case "salary_min": next["salary_min"] = .null; next["salary_period"] = .null
        default: next[id] = .null
        }
        return (query, next)
    }
}

/// Serializes saving a search and loading its deck so an older response can never replace a newer search.
struct JobRequestGate: Equatable {
    private(set) var saving = false
    private(set) var loading = false
    var busy: Bool { saving || loading }

    mutating func beginSave() -> Bool {
        guard !busy else { return false }
        saving = true
        return true
    }

    mutating func endSave() { saving = false }

    mutating func beginLoad() -> Bool {
        guard !busy else { return false }
        loading = true
        return true
    }

    mutating func endLoad() { loading = false }
}

struct JobActiveFilter: Identifiable, Equatable {
    let id: String
    let label: String
}

enum JobSheet: String, Identifiable {
    case filters, timeline, sources, importLink
    var id: String { rawValue }
}

/// Quick picks, sort and active filters above the deck. Secondary tools live behind More.
@MainActor
struct JobSearchBar: View {
    let search: JobSearch
    @Binding var sheet: JobSheet?
    var disabled = false
    let onChange: (String, JSON) -> Void
    let onReset: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Wraps instead of scrolling so Filters and sort stay visible on compact iPhones.
            FlowLayout(spacing: 8) {
                Chip(label: "Entry-level software", selected: search.entryLevelActive) {
                    let next = search.togglingEntryLevel()
                    onChange(next.query, next.filters)
                }
                Chip(label: "Internships", selected: search.internshipActive) {
                    let next = search.togglingInternship()
                    onChange(next.query, next.filters)
                }
                Chip(label: search.active.isEmpty ? "Filters" : "Filters · \(search.active.count)") { sheet = .filters }
                Menu {
                    Button("Best match") { let next = search.sorting(by: "relevance"); onChange(next.query, next.filters) }
                    Button("Newest first") { let next = search.sorting(by: "newest"); onChange(next.query, next.filters) }
                } label: { Chip(label: search.sortLabel) }
                .accessibilityLabel("Sort: \(search.sortLabel)")
                Menu {
                    Button(search.graduation.isEmpty ? "Set graduation timeline" : "Graduation: \(search.graduation)") { sheet = .timeline }
                    Button("Live sources") { sheet = .sources }
                    Button("Import a link") { sheet = .importLink }
                } label: { Chip(label: "More") }
                .accessibilityLabel("More job tools")
            }
            .disabled(disabled)
            .padding(.horizontal, Spacing.page)
            if search.hasOverrides {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(search.active) { item in
                            Button {
                                let next = search.removing(item.id)
                                onChange(next.query, next.filters)
                            } label: {
                                Text("\(item.label)  ✕")
                                    .font(Typeface.caption).foregroundStyle(Palette.text)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .overlay(Capsule().stroke(Palette.rule, lineWidth: 1))
                            }
                            .buttonStyle(.tap(scale: 0.95, dim: 1))
                            .accessibilityLabel("Remove filter \(item.label)")
                            .disabled(disabled)
                        }
                        Button("Reset", action: onReset)
                            .disabled(disabled)
                            .font(Typeface.caption.weight(.semibold))
                            .foregroundStyle(Palette.dark)
                            .accessibilityLabel("Reset filters to profile")
                    }
                    .padding(.horizontal, Spacing.page)
                }
            }
        }
    }
}

/// The filter sheet's editable values. Saved filter keys this sheet does not own pass through untouched.
struct JobFilterDraft: Equatable {
    var query = ""
    var anyRole = false
    var location = ""
    var modes: [String] = []
    var occupation = "Any"
    var levels: [String] = []
    var types: [String] = []
    var minimum = ""
    var period = "year"
    var confirmedOnly = false
    var confirmedLevel = false
    var timeline = "compatible"
    var datedOnly = false
    var age = "Any"

    /// Starts from the effective search: profile defaults plus this search's overrides.
    init(search: JobSearch) {
        let c = search.criteria
        let f = search.filters
        anyRole = f["any_role"].bool
        query = anyRole ? "" : c["roles"].string
        location = c["location"].string
        modes = c["modes"].strings
        types = c["employment_types"].strings
        levels = c["levels"].strings
        if c["salary_min"].double > 0 { minimum = c["salary_min"].string }
        if !c["salary_period"].string.isEmpty { period = c["salary_period"].string }
        confirmedOnly = c["confirmed_only"].bool
        confirmedLevel = f["confirmed_level"].bool
        if !c["timeline"].string.isEmpty { timeline = c["timeline"].string }
        if !f["occupation"].string.isEmpty { occupation = f["occupation"].string }
        if f["posted_days"].int > 0 { age = String(f["posted_days"].int) }
        datedOnly = f["has_posting_date"].bool
    }

    /// Saved filters with this draft's edits applied. A key is written when it was edited or already
    /// saved, so unedited profile defaults stay defaults and unrelated saved keys (sort, ...) survive.
    func filters(over saved: JSON, from baseline: JobFilterDraft) -> JSON {
        var out = saved
        func put(_ key: String, _ value: JSON, _ changed: Bool) {
            if changed || !saved[key].isNull { out[key] = value }
        }
        if out["country"].isNull { out["country"] = "US" }
        put("location", .string(location), location != baseline.location)
        put("modes", .array(modes.map { .string($0) }), modes != baseline.modes)
        put("occupation", .string(occupation), occupation != baseline.occupation)
        put("levels", .array(levels.map { .string($0) }), levels != baseline.levels)
        put("employment_types", .array(types.map { .string($0) }), types != baseline.types)
        put("salary_min", .number(Double(minimum) ?? 0), minimum != baseline.minimum)
        put("salary_period", .string(period), period != baseline.period)
        put("posted_days", .number(Double(age) ?? 0), age != baseline.age)
        put("has_posting_date", .bool(datedOnly), datedOnly != baseline.datedOnly)
        put("timeline", .string(timeline), timeline != baseline.timeline)
        put("confirmed_only", .bool(confirmedOnly), confirmedOnly != baseline.confirmedOnly)
        let level = confirmedLevel && !levels.isEmpty
        put("confirmed_level", .bool(level), level != (baseline.confirmedLevel && !baseline.levels.isEmpty))
        put("any_role", .bool(anyRole), anyRole != baseline.anyRole)
        return out
    }
}

@MainActor
struct JobFiltersSheet: View {
    let search: JobSearch
    let onApply: (String, JSON) async -> Void
    private let baseline: JobFilterDraft

    @State private var draft: JobFilterDraft
    @State private var working = false
    @State private var showMore = false

    init(search: JobSearch, onApply: @escaping (String, JSON) async -> Void) {
        self.search = search
        self.onApply = onApply
        let start = JobFilterDraft(search: search)
        baseline = start
        _draft = State(initialValue: start)
    }

    var body: some View {
        SheetPage(title: "Filters") {
            VStack(alignment: .leading, spacing: 20) {
                StackField(label: "Role or job title",
                           text: Binding(get: { draft.query }, set: { draft.query = $0; draft.anyRole = false }),
                           placeholder: "Nurse, electrician, software engineer…")
                ToggleRow(label: "Search all professions", isOn: $draft.anyRole)
                group("Level") {
                    ChoiceChips(options: ["Any level", "Internship", "Entry-level", "Mid-level", "Senior", "Leadership"],
                                isSelected: { $0 == "Any level" ? draft.levels.isEmpty : draft.levels.contains($0) },
                                onTap: { $0 == "Any level" ? (draft.levels = []) : (draft.levels = draft.levels.toggled($0)) })
                    if !draft.levels.isEmpty {
                        ToggleRow(label: "Only listings that state their level", isOn: $draft.confirmedLevel)
                    }
                }
                group("Employment") {
                    ChoiceChips(options: ["Any type", "Full-time", "Part-time", "Contract", "Temporary", "Internship"],
                                isSelected: { $0 == "Any type" ? draft.types.isEmpty : draft.types.contains($0) },
                                onTap: { $0 == "Any type" ? (draft.types = []) : (draft.types = draft.types.toggled($0)) })
                }
                group("Work arrangement") {
                    ChoiceChips(options: ["Any", "Remote", "Hybrid", "On-site"],
                                isSelected: { $0 == "Any" ? draft.modes.isEmpty : draft.modes.contains($0) },
                                onTap: { $0 == "Any" ? (draft.modes = []) : (draft.modes = draft.modes.toggled($0)) })
                }
                StackField(label: "City or state", text: $draft.location, placeholder: "United States")
                Button {
                    withAnimation(Motion.fadeAnimation) { showMore.toggle() }
                } label: {
                    Text(showMore ? "Fewer filters" : "More filters")
                        .font(Typeface.caption.weight(.semibold)).foregroundStyle(Palette.dark)
                }
                .accessibilityLabel(showMore ? "Fewer filters" : "More filters")
                if showMore { more }
                StackButton(label: "Show opportunities", disabled: working) {
                    working = true
                    Task {
                        await onApply(draft.anyRole ? "" : draft.query, draft.filters(over: search.filters, from: baseline))
                        working = false
                    }
                }
                Text("These choices apply to this search. Career stage, experience, education, exclusions and nice-to-haves come from your profile. Title aliases use O*NET 31.0 data · CC BY 4.0 · U.S. Department of Labor.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
            }
        }
    }

    @ViewBuilder
    private var more: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !search.occupations.isEmpty {
                group("Occupation") {
                    ChoiceChips(options: ["Any"] + search.occupations, isSelected: { draft.occupation == $0 }, onTap: { draft.occupation = $0 })
                }
            }
            StackField(label: "Minimum advertised pay (USD)", text: $draft.minimum, keyboard: .decimalPad)
            ChoiceChips(options: ["hour", "year"], isSelected: { draft.period == $0 }, onTap: { draft.period = $0 })
            Text("Hourly and yearly pay are compared at 2,080 hours per year.").font(Typeface.caption).foregroundStyle(Palette.muted)
            group("Listings missing details") {
                ChoiceChips(options: ["Show and flag them", "Confirmed matches only"],
                            isSelected: { ($0 == "Confirmed matches only") == draft.confirmedOnly },
                            onTap: { draft.confirmedOnly = $0 == "Confirmed matches only" })
            }
            group("Graduation timeline") {
                ChoiceChips(options: ["compatible", "confirmed", "all"], isSelected: { draft.timeline == $0 },
                            onTap: { draft.timeline = $0 },
                            labelFor: { ["compatible": "Hide timeline mismatches", "confirmed": "Confirmed timeline matches only", "all": "All timelines"][$0] ?? $0 })
            }
            group("Posting date") {
                ChoiceChips(options: ["Include unknown dates", "Has posting date"],
                            isSelected: { ($0 == "Has posting date") == draft.datedOnly },
                            onTap: { draft.datedOnly = $0 == "Has posting date" })
            }
            group("Posted within days") {
                ChoiceChips(options: ["Any", "1", "7", "30"], isSelected: { draft.age == $0 }, onTap: { draft.age = $0 })
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Typeface.caption).foregroundStyle(Palette.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct JobTimelineSheet: View {
    @Environment(AppStore.self) private var store
    @State private var graduation: String
    @State private var availableFrom: String
    @State private var working = false
    let onSaved: () async -> Void

    init(graduation: String, availableFrom: String, onSaved: @escaping () async -> Void) {
        _graduation = State(initialValue: graduation)
        _availableFrom = State(initialValue: availableFrom)
        self.onSaved = onSaved
    }

    var body: some View {
        SheetPage(title: "Your timeline") {
            StackField(label: "Expected graduation (YYYY-MM)", text: $graduation, placeholder: "2027-05", keyboard: .numbersAndPunctuation)
            StackField(label: "Available full-time from (YYYY-MM)", text: $availableFrom, placeholder: "Optional", keyboard: .numbersAndPunctuation)
            Text("Availability applies to full-time roles, not internships. Leave either date blank if it does not apply.")
                .font(Typeface.caption).foregroundStyle(Palette.muted)
            StoreMessages()
            StackButton(label: "Save graduation timeline", disabled: working) {
                working = true
                Task {
                    store.error = ""
                    do {
                        try await store.callAccount("save_timeline",
                                                    ["graduation_month": .string(graduation), "available_from": .string(availableFrom)])
                        await onSaved()
                    } catch { store.fail(error) }
                    working = false
                }
            }
        }
    }
}

@MainActor
struct JobSourcesSheet: View {
    @Environment(AppStore.self) private var store
    @State private var sources: [JSON] = []
    @State private var loading = true
    @State private var error = ""

    var body: some View {
        SheetPage(title: "Live sources", subtitle: "US coverage. Some sources may be unavailable.") {
            if loading { ProgressView().tint(Palette.muted) }
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                Card(spacing: 8) {
                    HStack {
                        Text(source["name"].string).font(Typeface.option).foregroundStyle(Palette.icon)
                        Spacer()
                        StatusPill(label: source["status"].string.capitalized,
                                   tone: ["ok", "ready", "complete", "healthy"].contains(source["status"].string) ? .done : .quiet)
                    }
                    if !source["message"].string.isEmpty {
                        Text(source["message"].string).font(Typeface.caption).foregroundStyle(Palette.text)
                    }
                    Text("\(source["unique_added"].int) new catalog entries").font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                .reveal(index)
            }
        }
        .task {
            do {
                let result = try await store.call("source_status")
                sources = result["sources"].array
            } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            loading = false
        }
    }
}

@MainActor
struct JobImportSheet: View {
    @Environment(AppStore.self) private var store
    let onQueued: (String) -> Void
    @State private var url = ""
    @State private var working = false
    @State private var error = ""

    var body: some View {
        SheetPage(title: "Import a job") {
            StackField(label: "Public job URL", text: $url, placeholder: "https://", keyboard: .URL, autocapitalization: .never)
            Text("Paste a public employer or job-board link. Unsupported pages will be flagged for review.")
                .font(Typeface.body).foregroundStyle(Palette.text)
            MessageLine(text: error).fadeSwitch(!error.isEmpty)
            StackButton(label: "Verify job link", disabled: working || url.isBlank) {
                working = true
                error = ""
                Task {
                    do {
                        let result = try await store.call("import_job_url", ["url": .string(url.trimmingCharacters(in: .whitespaces))])
                        onQueued(result["id"].string)
                    } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
                    working = false
                }
            }
        }
    }
}

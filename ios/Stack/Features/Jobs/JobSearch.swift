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

    var roleLabel: String {
        let roles = criteria["roles"].string
        return roles.isEmpty ? "All professions" : roles
    }

    var sortLabel: String { filters["sort"].string == "newest" ? "Newest first" : "Best match" }

    /// Names of the profile values this search overrides.
    var overrides: [String] {
        let names: [(String, String)] = [
            ("roles", "role"), ("location", "location"), ("modes", "work arrangement"),
            ("employment_types", "employment type"), ("salary_min", "pay"),
            ("exclude_companies", "hidden employers"), ("exclude_terms", "hidden terms"), ("soft", "nice-to-haves"),
        ]
        return names.filter { criteria["sources"][$0.0].string == "search" }.map(\.1)
    }
}

enum JobSheet: String, Identifiable {
    case filters, timeline, sources, importLink
    var id: String { rawValue }
}

/// Role, sort, timeline and source chips above the deck.
@MainActor
struct JobSearchBar: View {
    let search: JobSearch
    @Binding var sheet: JobSheet?
    let onUseProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Chip(label: search.roleLabel, selected: true) { sheet = .filters }
                    Chip(label: "Sort: \(search.sortLabel)") { sheet = .filters }
                    Chip(label: search.graduation.isEmpty ? "Set graduation timeline" : "Graduation: \(search.graduation)") { sheet = .timeline }
                    Chip(label: "Live sources") { sheet = .sources }
                    Chip(label: "Import a link") { sheet = .importLink }
                }
                .padding(.horizontal, Spacing.page)
            }
            if !search.overrides.isEmpty {
                HStack {
                    Text("This search changes your profile’s \(search.overrides.joined(separator: ", ")).")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Button("Use profile", action: onUseProfile)
                        .font(Typeface.caption.weight(.semibold))
                        .foregroundStyle(Palette.dark)
                        .accessibilityLabel("Use profile settings")
                }
                .padding(.horizontal, Spacing.page)
            }
        }
    }
}

@MainActor
struct JobFiltersSheet: View {
    let search: JobSearch
    let onApply: (String, JSON) async -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var query: String
    @State private var anyRole: Bool
    @State private var location: String
    @State private var modes: [String]
    @State private var occupation: String
    @State private var levels: [String]
    @State private var types: [String]
    @State private var minimum: String
    @State private var period: String
    @State private var confirmedOnly: Bool
    @State private var timelineMode: String
    @State private var order: String
    @State private var datedOnly: Bool
    @State private var age: String
    @State private var working = false

    /// Starts from the effective search: profile defaults plus this search's overrides.
    init(search: JobSearch, onApply: @escaping (String, JSON) async -> Void) {
        self.search = search
        self.onApply = onApply
        let c = search.criteria
        let f = search.filters
        _anyRole = State(initialValue: f["any_role"].bool)
        _query = State(initialValue: f["any_role"].bool ? "" : c["roles"].string)
        _location = State(initialValue: c["location"].string)
        _modes = State(initialValue: c["modes"].strings)
        _types = State(initialValue: c["employment_types"].strings)
        _levels = State(initialValue: c["levels"].strings)
        let pay = c["salary_min"].double
        _minimum = State(initialValue: pay > 0 ? c["salary_min"].string : "")
        let salaryPeriod = c["salary_period"].string
        _period = State(initialValue: salaryPeriod.isEmpty ? "year" : salaryPeriod)
        _confirmedOnly = State(initialValue: c["confirmed_only"].bool)
        let timeline = c["timeline"].string
        _timelineMode = State(initialValue: timeline.isEmpty ? "compatible" : timeline)
        let occupationValue = f["occupation"].string
        _occupation = State(initialValue: occupationValue.isEmpty ? "Any" : occupationValue)
        let days = f["posted_days"].int
        _age = State(initialValue: days > 0 ? String(days) : "Any")
        let sort = f["sort"].string
        _order = State(initialValue: sort.isEmpty ? "relevance" : sort)
        _datedOnly = State(initialValue: f["has_posting_date"].bool)
    }

    private var filters: JSON {
        [
            "country": "US",
            "location": .string(location),
            "modes": .array(modes.map { .string($0) }),
            "occupation": .string(occupation),
            "levels": .array(levels.map { .string($0) }),
            "employment_types": .array(types.map { .string($0) }),
            "salary_min": .number(Double(minimum) ?? 0),
            "salary_period": .string(period),
            "posted_days": .number(Double(age) ?? 0),
            "sort": .string(order),
            "has_posting_date": .bool(datedOnly),
            "timeline": .string(timelineMode),
            "confirmed_only": .bool(confirmedOnly),
            "any_role": .bool(anyRole),
        ]
    }

    var body: some View {
        SheetPage(title: "Filters") {
            VStack(alignment: .leading, spacing: 20) {
                StackField(label: "Role or job title", text: Binding(get: { query }, set: { query = $0; anyRole = false }),
                           placeholder: "Nurse, electrician, software engineer…")
                ToggleRow(label: "Search all professions", isOn: $anyRole)
                Text("Separate several roles with commas. Related titles must share an O*NET occupation.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                StackField(label: "City or state", text: $location, placeholder: "United States")
                group("Work arrangement") {
                    ChoiceChips(options: ["Any", "Remote", "Hybrid", "On-site"],
                                isSelected: { $0 == "Any" ? modes.isEmpty : modes.contains($0) },
                                onTap: { $0 == "Any" ? (modes = []) : (modes = modes.toggled($0)) })
                }
                if !search.occupations.isEmpty {
                    group("Occupation") {
                        ChoiceChips(options: ["Any"] + search.occupations, isSelected: { occupation == $0 }, onTap: { occupation = $0 })
                    }
                }
                group("Level") {
                    ChoiceChips(options: ["Any level", "Internship", "Entry-level", "Mid-level", "Senior", "Leadership"],
                                isSelected: { $0 == "Any level" ? levels.isEmpty : levels.contains($0) },
                                onTap: { $0 == "Any level" ? (levels = []) : (levels = levels.toggled($0)) })
                }
                group("Employment") {
                    ChoiceChips(options: ["Any type", "Full-time", "Part-time", "Contract", "Temporary", "Internship"],
                                isSelected: { $0 == "Any type" ? types.isEmpty : types.contains($0) },
                                onTap: { $0 == "Any type" ? (types = []) : (types = types.toggled($0)) })
                }
                StackField(label: "Minimum advertised pay (USD)", text: $minimum, keyboard: .decimalPad)
                ChoiceChips(options: ["hour", "year"], isSelected: { period == $0 }, onTap: { period = $0 })
                Text("Hourly and yearly pay are compared at 2,080 hours per year.").font(Typeface.caption).foregroundStyle(Palette.muted)
                group("Listings missing details") {
                    ChoiceChips(options: ["Show and flag them", "Confirmed matches only"],
                                isSelected: { ($0 == "Confirmed matches only") == confirmedOnly },
                                onTap: { confirmedOnly = $0 == "Confirmed matches only" })
                }
                group("Graduation timeline") {
                    ChoiceChips(options: ["compatible", "confirmed", "all"], isSelected: { timelineMode == $0 },
                                onTap: { timelineMode = $0 },
                                labelFor: { ["compatible": "Hide timeline mismatches", "confirmed": "Confirmed timeline matches only", "all": "All timelines"][$0] ?? $0 })
                }
                group("Sort jobs") {
                    ChoiceChips(options: ["relevance", "newest"], isSelected: { order == $0 }, onTap: { order = $0 },
                                labelFor: { $0 == "newest" ? "Newest first" : "Best match" })
                    Text("Best match ranks title fit and confirmed requirements first, then nice-to-haves, then posting date. Newest first puts unknown dates last.")
                        .font(Typeface.caption).foregroundStyle(Palette.muted)
                }
                group("Posting date") {
                    ChoiceChips(options: ["Include unknown dates", "Has posting date"],
                                isSelected: { ($0 == "Has posting date") == datedOnly },
                                onTap: { datedOnly = $0 == "Has posting date" })
                }
                group("Posted within days") {
                    ChoiceChips(options: ["Any", "1", "7", "30"], isSelected: { age == $0 }, onTap: { age = $0 })
                }
                Text("These choices apply to this search. Career stage, experience, education, exclusions and nice-to-haves come from your profile.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                StackButton(label: "Show opportunities", disabled: working) {
                    working = true
                    Task {
                        await onApply(anyRole ? "" : query, filters)
                        working = false
                    }
                }
                Text("Title aliases use O*NET 31.0 data · CC BY 4.0 · U.S. Department of Labor.")
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
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

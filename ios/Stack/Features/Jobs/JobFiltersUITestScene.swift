#if DEBUG
import SwiftUI

/// Offline UI-test host for the real job search bar and filter sheet. Excluded from Release builds.
/// It never signs in, calls the API or shows live jobs; "saving" is a local copy of the server's rule that
/// drops overrides equal to the profile, applied to fixture profile values.
@MainActor
struct JobFiltersUITestScene: View {
    private static let profile: JSON = ["roles": "Product designer", "location": "", "modes": [], "employment_types": ["Full-time"]]

    @State private var store = AppStore(api: APIClient(origin: URL(string: "https://stack.invalid")!))
    @State private var search = JobFiltersUITestScene.fresh()
    @State private var sheet: JobSheet?

    private static func fresh() -> JobSearch {
        var value = JobSearch()
        value.criteria = profile
        return value
    }

    private var summary: String {
        let c = search.criteria
        return "role=\(c["roles"].string) | levels=\(search.filters["levels"].strings.joined(separator: ",")) | "
            + "types=\(c["employment_types"].strings.joined(separator: ",")) | sort=\(search.filters["sort"].string)"
    }

    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.option) {
                Text("Offline job filter test").font(Typeface.title).padding(.horizontal, Spacing.page)
                JobSearchBar(search: search, sheet: $sheet,
                             onChange: { query, filters in save(query: query, filters: filters) },
                             onReset: { search = Self.fresh() })
                Text(summary)
                    .font(Typeface.caption).foregroundStyle(Palette.muted)
                    .padding(.horizontal, Spacing.page)
                    .accessibilityIdentifier("fixture-state")
                Spacer()
            }
            .padding(.top, 8)
        }
        .environment(store)
        .transaction { if ProcessInfo.processInfo.arguments.contains("--disable-draft-animations") { $0.animation = nil; $0.disablesAnimations = true } }
        .onAppear { store.phase = .ready }
        .sheet(item: $sheet) { value in
            if value == .filters {
                JobFiltersSheet(search: search) { query, filters in
                    save(query: query, filters: filters)
                    sheet = nil
                }
                .environment(store)
            } else {
                SheetPage(title: "Not part of this fixture") { EmptyView() }
            }
        }
    }

    private func save(query: String, filters: JSON) {
        let keys = ["location", "modes", "employment_types"]
        var stored = filters
        for key in keys where stored[key] == Self.profile[key] { stored[key] = .null }
        search.query = query == Self.profile["roles"].string ? "" : query
        search.filters = stored
        var criteria = Self.profile
        if !search.query.isEmpty { criteria["roles"] = .string(search.query) }
        for key in keys where !stored[key].isNull { criteria[key] = stored[key] }
        criteria["levels"] = stored["levels"]
        search.criteria = criteria
    }
}
#endif

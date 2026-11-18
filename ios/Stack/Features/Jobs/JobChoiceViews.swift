import SwiftUI
import MapKit

/// A fixed list from the same O*NET titles used by the server's role matcher.
enum JobRoleChoices {
    static let all: [String] = {
        guard let url = Bundle.main.url(forResource: "JobRoles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }()
}

/// The search field used by the role and location pickers.
@MainActor
struct JobSearchField: View {
    let prompt: String
    @Binding var text: String
    var capitalization: TextInputAutocapitalization = .never

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.body.weight(.medium)).foregroundStyle(Brand.muted)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundColor(Brand.muted))
                .foregroundStyle(Brand.ink).tint(Brand.accent)
                .textInputAutocapitalization(capitalization).autocorrectionDisabled()
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted).frame(width: 32, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.leading, 16).padding(.trailing, text.isEmpty ? 16 : 6)
        .frame(minHeight: 50)
        .background(Palette.field, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.rule, lineWidth: 1))
    }
}

/// A single-choice or multi-choice row: label, optional symbol, a checkmark when selected, a hairline below.
@MainActor
struct JobChoiceRow: View {
    let label: String
    var symbol = ""
    var selected = false
    var showsRule = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if !symbol.isEmpty {
                    Image(systemName: symbol).font(.body).foregroundStyle(Brand.accent).frame(width: 24)
                }
                Text(label).font(Typeface.body).foregroundStyle(Brand.ink).multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selected { Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Brand.accent) }
            }
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { if showsRule { Rectangle().fill(Brand.rule.opacity(0.7)).frame(height: 0.5) } }
        }
        .buttonStyle(.tap(scale: 0.985, dim: 1))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small print at the foot of a picker.
@MainActor
struct JobFootnote: View {
    let text: String
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Brand.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
    }
}

@MainActor
struct RoleChoiceView: View {
    let current: String
    let onSelect: (String) -> Void
    let onBack: () -> Void
    @State private var query = ""
    private var choices: [String] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? JobRoleChoices.all : JobRoleChoices.all.filter { $0.localizedCaseInsensitiveContains(words) }
    }
    var body: some View {
        SheetPage(title: "Role", closeLabel: "Back", onClose: onBack) {
            JobSearchField(prompt: "Search roles", text: $query)
            LazyVStack(spacing: 0) {
                if query.isBlank { choice("Any role", value: "") }
                ForEach(choices, id: \.self) { choice($0, value: $0) }
                if choices.isEmpty {
                    Text("No matches").font(Typeface.body).foregroundStyle(Brand.muted)
                        .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
            JobFootnote(text: "Job titles: O*NET 31.0, U.S. Department of Labor, CC BY 4.0")
        }
    }
    private func choice(_ label: String, value: String) -> some View {
        JobChoiceRow(label: label, selected: current == value) { onSelect(value) }
    }
}

/// Place suggestions use Apple Maps; selecting a result resolves it to a US city and state.
@MainActor
final class LocationSuggestions: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var error = ""
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init(); completer.delegate = self; completer.resultTypes = .address
        completer.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.5, longitude: -98.35), span: MKCoordinateSpan(latitudeDelta: 35, longitudeDelta: 65))
    }
    func search(_ value: String) { error = ""; completer.queryFragment = value; if value.isEmpty { results = [] } }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = completer.results }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { self.error = "Couldn\u{2019}t load locations. Try again."; results = [] }
    func resolve(_ result: MKLocalSearchCompletion) async throws -> String? {
        let request = MKLocalSearch.Request(completion: result)
        let response = try await MKLocalSearch(request: request).start()
        guard let place = response.mapItems.first?.placemark, place.isoCountryCode == "US", let state = place.administrativeArea else { return nil }
        if let city = place.locality, !city.isEmpty { return "\(city), \(state)" }
        return state
    }
}

@MainActor
struct LocationChoiceView: View {
    let onSelect: (String) -> Void
    let onBack: () -> Void
    @StateObject private var suggestions = LocationSuggestions()
    @State private var query = ""
    @State private var resolving = false
    var body: some View {
        SheetPage(title: "Location", closeLabel: "Back", onClose: onBack) {
            JobSearchField(prompt: "City or state", text: $query, capitalization: .words)
                .onChange(of: query) { _, value in suggestions.search(value) }
            VStack(spacing: 0) {
                if query.isBlank {
                    JobChoiceRow(label: "Anywhere", symbol: "globe.americas", showsRule: !suggestions.results.isEmpty) { onSelect("") }
                }
                ForEach(suggestions.results, id: \.self) { result in
                    Button {
                        resolving = true
                        Task {
                            defer { resolving = false }
                            do { if let place = try await suggestions.resolve(result) { onSelect(place) } else { suggestions.error = "Choose a US city or state" } }
                            catch { suggestions.error = "Couldn\u{2019}t load this location. Try again." }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(Brand.accent.opacity(0.85)).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title).font(Typeface.body).foregroundStyle(Brand.ink)
                                if !result.subtitle.isEmpty { Text(result.subtitle).font(.footnote).foregroundStyle(Brand.muted) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                        .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule.opacity(0.7)).frame(height: 0.5) }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.tap(scale: 0.985, dim: 1)).disabled(resolving)
                }
            }
            if resolving { ProgressView().tint(Brand.muted).frame(maxWidth: .infinity) }
            if !suggestions.error.isEmpty { MessageLine(text: suggestions.error) }
        }
    }
}

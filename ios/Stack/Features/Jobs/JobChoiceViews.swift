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
        SheetPage(title: "Choose a role", closeLabel: "Back", onClose: onBack) {
            TextField("Search roles", text: $query, prompt: Text("Search roles").foregroundColor(Brand.muted))
                .foregroundStyle(Brand.ink).tint(Brand.accent)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(16).background(Palette.field, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityLabel("Search roles")
            Text("Job titles: O*NET 31.0 · CC BY 4.0 · U.S. Department of Labor")
                .font(.caption2).foregroundStyle(Brand.muted)
            LazyVStack(spacing: 0) {
                choice("All professions", value: "")
                ForEach(choices, id: \.self) { choice($0, value: $0) }
                if choices.isEmpty { Text("No matching roles.").foregroundStyle(Brand.muted).padding(.vertical, 20) }
            }
        }
    }
    private func choice(_ label: String, value: String) -> some View {
        Button { onSelect(value) } label: {
            HStack { Text(label).foregroundStyle(Brand.ink).multilineTextAlignment(.leading); Spacer(); if current == value { Image(systemName: "checkmark").foregroundStyle(Brand.accent) } }
                .font(Typeface.body).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }.contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(current == value ? .isSelected : [])
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
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { self.error = "Could not load locations. Try again."; results = [] }
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
        SheetPage(title: "Choose a location", closeLabel: "Back", onClose: onBack) {
            TextField("City or state", text: $query, prompt: Text("City or state").foregroundColor(Brand.muted))
                .foregroundStyle(Brand.ink).tint(Brand.accent).autocorrectionDisabled().padding(16)
                .background(Palette.field, in: RoundedRectangle(cornerRadius: 14)).onChange(of: query) { _, value in suggestions.search(value) }
            Button("Anywhere in the US") { onSelect("") }.frame(minHeight: 44).foregroundStyle(Brand.accent)
            if resolving { ProgressView().tint(Brand.muted) }
            if !suggestions.error.isEmpty { Text(suggestions.error).font(Typeface.caption).foregroundStyle(Palette.danger) }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(suggestions.results, id: \.self) { result in
                    Button {
                        resolving = true
                        Task {
                            defer { resolving = false }
                            do { if let place = try await suggestions.resolve(result) { onSelect(place) } else { suggestions.error = "Choose a US city or state." } }
                            catch { suggestions.error = "Could not load this location. Try again." }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.title).foregroundStyle(Brand.ink)
                            if !result.subtitle.isEmpty { Text(result.subtitle).font(Typeface.caption).foregroundStyle(Brand.muted) }
                        }.frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                            .overlay(alignment: .bottom) { Rectangle().fill(Brand.rule).frame(height: 1) }.contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(resolving)
                }
            }
        }
    }
}

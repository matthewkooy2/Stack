import Foundation
import CryptoKit

/// The server's assignment wins. Legacy cached/feed rows can still use the same
/// reviewed city library until their media metadata arrives from the server.
enum JobPhoto {
    private struct City: Decodable {
        let id: String
        let names: [String]
        let regions: [String]
        let countries: [String]
        let boardNames: [String: [String]]?

        enum CodingKeys: String, CodingKey {
            case id, names, regions, countries
            case boardNames = "board_names"
        }
    }

    private static let cities: [City] = {
        guard let url = Bundle.main.url(forResource: "job_photos", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        guard let records = (try? JSONSerialization.jsonObject(with: data)) as? [String: [String: Any]] else { return [] }
        return records.compactMap { id, record in
            guard record["names"] != nil else { return nil }
            var value = record
            value["id"] = id
            guard let encoded = try? JSONSerialization.data(withJSONObject: value) else { return nil }
            return try? JSONDecoder().decode(City.self, from: encoded)
        }
    }()
    private static let nature = ["coast", "desert", "forest", "mountain-lake"]
    private static let ids = Set(cities.map(\.id) + nature)
    private static let qualified: [String: String] = {
        var result: [String: String] = [:]
        for city in cities {
            let countries = countryNames(city.countries)
            for name in city.names.map(key) {
                for region in city.regions.map(key) {
                    result[name + ", " + region] = city.id
                    for country in countries { result[name + ", " + region + ", " + country] = city.id }
                }
                if name != "new york" {
                    for country in countries { result[name + ", " + country] = city.id }
                }
            }
        }
        return result
    }()

    static func id(for job: Job, preferredLocation: String = "") -> String {
        let assigned = job.raw["photo_id"].string
        if ids.contains(assigned) { return assigned }
        let country = key(job.raw["country"].string)
        let board = job.raw["source_id"].string
        let supplied = job.raw["locations"].strings
        let labels = supplied.isEmpty ? [job.location] : supplied
        let parts = labels.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ";|•")) }
            .map(key).filter { !$0.isEmpty }
        let matches = parts.map { city($0, country: country, board: board) }
        let known = Set(matches.compactMap { $0 })
        if known.count == 1 && matches.allSatisfy({ $0 != nil }) { return known.first! }
        let preferredKey = key(preferredLocation)
        let preferred = city(preferredKey, country: country)
            ?? cities.first(where: { $0.names.map(key).contains(preferredKey) })?.id
        if let preferred, known.contains(preferred) { return preferred }
        let seed = job.id.isEmpty ? (job.url.isEmpty ? job.title : job.url) : job.id
        let digest = SHA256.hash(data: Data(seed.utf8))
        let index = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return nature[Int(index % UInt32(nature.count))]
    }

    private static func city(_ label: String, country: String, board: String = "") -> String? {
        if let found = qualified[label] { return found }
        // These labels name a city rather than a state or a remote region.
        let unambiguous: Set<String> = ["singapore", "new york city", "nyc", "mexico city", "cdmx", "taipei city", "washington dc", "washington, dc"]
        for city in cities where city.names.map(key).contains(label) && label != "new york" {
            if countryNames(city.countries).contains(country)
                || ((country.isEmpty || country == "unknown")
                    && (unambiguous.contains(label) || city.boardNames?[board]?.contains(label) == true)) { return city.id }
        }
        return nil
    }

    private static func countryNames(_ countries: [String]) -> Set<String> {
        var names = Set(countries.map(key))
        if names.contains("us") { names.formUnion(["usa", "united states", "united states of america"]) }
        return names
    }

    private static func key(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: ".", with: "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

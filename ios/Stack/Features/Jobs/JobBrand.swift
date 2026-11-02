import Foundation

/// Reviewed identities also work with cached pages from before the media feed contract.
enum JobBrand {
    private struct Brand: Decodable {
        let domain: String
        let domains: [String]
        let boards: [String]
    }

    private static let directory: [Brand] = {
        guard let url = Bundle.main.url(forResource: "employer_brands", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Brand].self, from: data)) ?? []
    }()

    static func domain(for job: Job) -> String? {
        let domain = job.raw["employer_domain"].string.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let board = job.raw["source_id"].string
        let byDomain = directory.first { $0.domains.contains(domain) }
        let byBoard = directory.first { $0.boards.contains(board) }
        // An explicit different employer cannot inherit its recruiter's or board owner's logo.
        guard let brand = domain.isEmpty ? byBoard : byDomain,
              byBoard == nil || byBoard?.domain == brand.domain else { return nil }
        return brand.domain
    }
}

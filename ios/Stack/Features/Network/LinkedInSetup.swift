import Foundation

enum LinkedInSetup {
    /// Add a scheme to the address entered in the flow.
    static func profileURL(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("://") ? value : "https://" + value
    }
}

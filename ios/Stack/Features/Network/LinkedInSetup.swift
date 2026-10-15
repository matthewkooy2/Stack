import Foundation

enum LinkedInSetup {
    static func modelName(_ selection: String) -> String {
        switch selection {
        case "codex-cli": return "Codex CLI"
        case "local": return "Local model"
        default: return selection
        }
    }

    /// Add a scheme to the address entered in the existing form.
    static func profileURL(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.contains("://") ? value : "https://" + value
    }
}

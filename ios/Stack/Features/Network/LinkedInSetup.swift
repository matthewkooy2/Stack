import Foundation

/// What LinkedIn review still needs. Built from the server's readiness checks plus the account's saved model
/// choice, so anything already configured is never shown again. Pure, so it is unit tested.
enum LinkedInSetup {
    enum Step: Equatable {
        /// The saved model choice isn't configured for this account, but another choice is configured here.
        case switchModel(selection: String, name: String, reason: String)
        /// Only the server's operator can connect a provider.
        case modelUnavailable(message: String)
        /// Only the server's operator can configure the browser worker.
        case browserUnavailable(message: String)
        case profile

        var title: String {
            switch self {
            case .switchModel: return "Choose a model"
            case .modelUnavailable: return "Connect a model"
            case .browserUnavailable: return "Browser worker"
            case .profile: return "Add your profile link"
            }
        }
    }

    static let profileURLMessage = "Enter your LinkedIn profile URL: https://www.linkedin.com/in/your-name/"

    /// Every unmet required step in the order to do them, always ending with `.profile`. Steps a person can finish
    /// come before steps only the operator can finish. `settings` is the `agent_settings` result, or null when it
    /// has not loaded, in which case the readiness checks decide.
    static func steps(feature: AgentFeature?, settings: JSON) -> [Step] {
        guard let feature else { return [.profile] }
        func unmet(_ key: String) -> FeatureCheck? { feature.checks.first { $0.key == key && !$0.ok } }
        var steps: [Step] = []

        // The saved selection's own status is fresher than the bootstrap snapshot the checks came from.
        let selected = settings["model_options"].array.first { $0["selection"].string == settings["model_selection"].string }
        var modelProblem: String?
        if let selected, !selected["selection"].string.isEmpty {
            if !selected["configured"].bool { modelProblem = selected["message"].string }
        } else if let model = unmet("model") {
            modelProblem = model.fix
        }
        let alternative = modelProblem == nil ? nil : configuredAlternative(settings)

        if let alternative {
            let selection = alternative["selection"].string
            steps.append(.switchModel(selection: selection, name: modelName(selection), reason: modelProblem ?? ""))
        }
        if let modelProblem, alternative == nil {
            steps.append(.modelUnavailable(message: modelProblem.isEmpty ? "No model provider is connected on this server." : modelProblem))
        }
        if let browser = unmet("browser") {
            steps.append(.browserUnavailable(message: browser.fix.isEmpty ? "The browser worker is not available on this server." : browser.fix))
        }
        steps.append(.profile)
        return steps
    }

    static func modelName(_ selection: String) -> String {
        switch selection {
        case "codex-cli": return "Codex CLI"
        case "local": return "Local model"
        default: return selection
        }
    }

    /// A model choice that passes server configuration checks and is not the one currently saved.
    /// CLI sign-in, provider limits, and local service availability are checked again when a task runs.
    static func configuredAlternative(_ settings: JSON) -> JSON? {
        let current = settings["model_selection"].string
        return settings["model_options"].array.first { $0["configured"].bool && $0["selection"].string != current }
    }

    /// The address to send, or nil when it is not a LinkedIn profile. A missing `https://` is added; the server
    /// stays the authority and canonicalizes the result.
    static func profileURL(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return nil }
        if !value.contains("://") { value = "https://" + value }
        guard let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https",
              parts.user == nil, parts.password == nil,
              ["linkedin.com", "www.linkedin.com"].contains(parts.host?.lowercased() ?? ""),
              parts.port == nil || parts.port == 443,
              parts.path.range(of: #"^/in/[A-Za-z0-9_%\-]+/?$"#, options: .regularExpression) != nil else { return nil }
        return value
    }
}

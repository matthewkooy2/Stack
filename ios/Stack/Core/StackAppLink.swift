import Foundation

enum StackAppLink {
    static let destinations = ["jobs", "applications", "resume", "network", "prep"]

    /// App links navigate only. They never carry or establish an authenticated session.
    static func destination(_ url: URL) -> String? {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              link.user == nil, link.password == nil, link.port == nil,
              link.query == nil, link.fragment == nil else { return nil }
        let path: String
        if link.scheme == "com.matthewkooy.stack", link.host == "open" { path = link.path }
        else if link.scheme == "https", ["stackmvp.top", "dev.stackmvp.top"].contains(link.host ?? ""),
                link.path == "/open" || link.path.hasPrefix("/open/") {
            path = String(link.path.dropFirst("/open".count))
        } else { return nil }
        if path.isEmpty || path == "/" { return "jobs" }
        let destination = String(path.dropFirst())
        return destinations.contains(destination) ? destination : nil
    }
}

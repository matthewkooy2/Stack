import SwiftUI

private struct ReplayTokenKey: EnvironmentKey { static let defaultValue = 0 }

extension EnvironmentValues {
    /// Bumped by the debug motion lab. Always 0 in Release builds.
    var replayToken: Int {
        get { self[ReplayTokenKey.self] }
        set { self[ReplayTokenKey.self] = newValue }
    }
}

private struct Replayable: ViewModifier {
    @Environment(\.replayToken) private var token
    func body(content: Content) -> some View { content.id(token) }
}

extension View {
    /// Marks a screen whose entrance animation the debug motion lab can replay: when "Replay screen" is tapped the
    /// screen is rebuilt, so its `onAppear` animations run again. Put it on every screen or sheet that animates in.
    func replayable() -> some View { modifier(Replayable()) }
}

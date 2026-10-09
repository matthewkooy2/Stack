#if DEBUG
import SwiftUI

/// Offline UI-test host for the real draft components. Excluded entirely from signed Release builds.
/// It never starts a login, adopts a token, sends an API request or publishes profile text.
@MainActor
struct LocalDraftUITestScene: View {
    @State private var store = AppStore(api: APIClient(origin: URL(string: "https://stack.invalid")!))
    @State private var showProfiles = false
    @State private var showRewrites = false
    private let rewrites: [JSON] = [["section": "headline", "text": "A test headline"],
                                    ["section": "about", "text": "A test about section"]]
    var body: some View {
        ZStack {
            Palette.page.ignoresSafeArea()
            Page {
                Text("Offline draft test").font(Typeface.title)
                StackButton(label: "Public profiles") { showProfiles = true }
                StackButton(label: "LinkedIn rewrites") { showRewrites = true }
            }
        }
        .environment(store)
        .environment(\.accessibilityReduceMotion, ProcessInfo.processInfo.arguments.contains("--reduce-motion-preview"))
        .onAppear { store.phase = .ready }
        .sheet(isPresented: $showProfiles) {
            PublicProfilesView().environment(store)
                .environment(\.accessibilityReduceMotion, ProcessInfo.processInfo.arguments.contains("--reduce-motion-preview"))
        }
        .sheet(isPresented: $showRewrites) {
            ZStack {
                Palette.page.ignoresSafeArea()
                Page {
                    BackButton(label: "Close") { showRewrites = false }
                    LinkedInRewriteEditor(taskID: "offline-test-task", rewrites: rewrites)
                }
            }.environment(store)
                .environment(\.accessibilityReduceMotion, ProcessInfo.processInfo.arguments.contains("--reduce-motion-preview"))
        }
    }
}
#endif

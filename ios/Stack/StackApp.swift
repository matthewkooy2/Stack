import SwiftUI
import UserNotifications

@main
@MainActor
struct StackApp: App {
    @UIApplicationDelegateAdaptor(StackAppDelegate.self) private var delegate
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--local-draft-ui-test") {
                LocalDraftUITestScene()
            } else {
                mainScene
            }
            #else
            mainScene
            #endif
        }
    }

    private var mainScene: some View {
        RootView()
                .environment(store)
                .tint(Palette.dark)
                .task { await store.start() }
    }
}

extension Notification.Name {
    /// A tapped reminder or agent notification. `userInfo` carries the notification's data.
    static let stackOpenTarget = Notification.Name("stack.open.target")
}

/// Shows reminders while the app is open and routes a tapped notification to its record.
final class StackAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// A tap that arrived before the account finished loading, handed over once it is ready.
    nonisolated(unsafe) static var pending: [String: String]?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let raw = response.notification.request.content.userInfo
        var info: [String: String] = [:]
        for (key, value) in raw {
            if let key = key as? String, let value = value as? String { info[key] = value }
        }
        guard info["target_id"] != nil else { return }
        await MainActor.run {
            Self.pending = info
            NotificationCenter.default.post(name: .stackOpenTarget, object: nil, userInfo: info)
        }
    }
}

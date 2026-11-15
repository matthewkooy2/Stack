import Foundation
import UserNotifications

/// Accountability reminders (#127): local notifications at fixed times through the day that each point at one
/// small job-search step. They repeat daily, so they keep arriving while the app is closed, and need no push
/// server or APNs setup. The settings live on this device, per account, because the notifications do too.
struct NudgeSettings: Codable, Equatable {
    var enabled = false
    /// Hours between reminders.
    var everyHours = 3
    /// First and last hour of the day a reminder may arrive (24-hour clock, inclusive).
    var startHour = 9
    var endHour = 21

    static let frequencies = [2, 3, 4, 6]

    /// The hours of the day a reminder is scheduled, from the start of the active window.
    var hours: [Int] {
        let start = min(max(startHour, 0), 23)
        let end = min(max(endHour, start), 23)
        let step = max(everyHours, 1)
        return Array(stride(from: start, through: end, by: step))
    }

    private static func key(_ owner: String) -> String { "stack.nudges.\(owner)" }

    static func load(for owner: String, from defaults: UserDefaults = .standard) -> NudgeSettings {
        guard !owner.isEmpty, let data = defaults.data(forKey: key(owner)),
              let saved = try? JSONDecoder().decode(NudgeSettings.self, from: data) else { return NudgeSettings() }
        return saved
    }

    func save(for owner: String, to defaults: UserDefaults = .standard) {
        guard !owner.isEmpty, let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key(owner))
    }

    static func remove(for owner: String, from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(owner))
    }
}

/// One scheduled reminder: when it arrives each day, what it says, and the tab it opens.
struct Nudge: Equatable {
    let hour: Int
    let title: String
    let body: String
    let destination: String

    static let prefix = "stack-nudge-"

    /// Today's reminders, one step per slot, rotating through jobs, applications, prep and network so a day
    /// covers each kind. Counts make the step concrete when there is something waiting.
    static func plan(_ settings: NudgeSettings, followUpsDue: Int, applications: Int) -> [Nudge] {
        guard settings.enabled else { return [] }
        let steps: [(String, String, String)] = [
            ("Find one role", "Swipe through today’s matches and save one worth applying to.", "jobs"),
            (followUpsDue > 0 ? "\(followUpsDue) follow-up\(followUpsDue == 1 ? "" : "s") due" : "Move one application forward",
             followUpsDue > 0 ? "Send one follow-up now. It takes two minutes."
                 : applications > 0 ? "Update a status or tailor a resume for one saved job." : "Apply to one saved job today.",
             "applications"),
            ("Practice one answer", "Five minutes: answer one interview question out loud and get coaching.", "prep"),
            ("Reach out to one person", "Message one contact or alum about their team.", "network"),
        ]
        return settings.hours.enumerated().map { index, hour in
            let step = steps[index % steps.count]
            return Nudge(hour: hour, title: step.0, body: step.1, destination: step.2)
        }
    }

    func request(owner: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "stack-nudges"
        content.userInfo = ["target_type": "tab", "target_id": destination, "user_id": owner]
        let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: hour, minute: 0), repeats: true)
        return UNNotificationRequest(identifier: "\(Self.prefix)\(owner)-\(hour)", content: content, trigger: trigger)
    }
}

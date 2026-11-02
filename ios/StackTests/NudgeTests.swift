import UserNotifications
import XCTest
@testable import Stack

final class NudgeTests: XCTestCase {
    func testHoursFollowTheActiveWindowAndFrequency() {
        XCTAssertEqual(NudgeSettings(enabled: true, everyHours: 3, startHour: 9, endHour: 21).hours, [9, 12, 15, 18, 21])
        XCTAssertEqual(NudgeSettings(enabled: true, everyHours: 4, startHour: 8, endHour: 18).hours, [8, 12, 16])
        XCTAssertEqual(NudgeSettings(enabled: true, everyHours: 2, startHour: 20, endHour: 20).hours, [20])
        // An end before the start, or out-of-range hours, never schedules outside the day.
        XCTAssertEqual(NudgeSettings(enabled: true, everyHours: 3, startHour: 22, endHour: 7).hours, [22])
        XCTAssertEqual(NudgeSettings(enabled: true, everyHours: 0, startHour: -4, endHour: 40).hours.last, 23)
    }

    func testOffSchedulesNothing() {
        XCTAssertTrue(Nudge.plan(NudgeSettings(), followUpsDue: 3, applications: 2).isEmpty)
    }

    func testEachSlotPointsAtOneStepAndRotates() {
        let plan = Nudge.plan(NudgeSettings(enabled: true, everyHours: 2, startHour: 9, endHour: 19), followUpsDue: 0, applications: 0)
        XCTAssertEqual(plan.map(\.hour), [9, 11, 13, 15, 17, 19])
        XCTAssertEqual(plan.map(\.destination), ["jobs", "applications", "prep", "network", "jobs", "applications"])
        XCTAssertEqual(plan[1].body, "Apply to one saved job today.")
    }

    func testDueFollowUpsAreNamed() {
        let one = Nudge.plan(NudgeSettings(enabled: true), followUpsDue: 1, applications: 4)
        XCTAssertEqual(one[1].title, "1 follow-up due")
        XCTAssertEqual(Nudge.plan(NudgeSettings(enabled: true), followUpsDue: 3, applications: 4)[1].title, "3 follow-ups due")
        XCTAssertEqual(Nudge.plan(NudgeSettings(enabled: true), followUpsDue: 0, applications: 4)[1].title, "Move one application forward")
    }

    func testRequestRepeatsDailyAndOpensItsTab() throws {
        let nudge = Nudge(hour: 15, title: "Practice one answer", body: "Five minutes.", destination: "prep")
        let request = nudge.request(owner: "user-1")
        XCTAssertEqual(request.identifier, "stack-nudge-user-1-15")
        XCTAssertTrue(request.identifier.hasPrefix(Nudge.prefix))
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertTrue(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.hour, 15)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        XCTAssertNil(trigger.dateComponents.day)
        XCTAssertEqual(request.content.userInfo["target_type"] as? String, "tab")
        XCTAssertEqual(request.content.userInfo["target_id"] as? String, "prep")
        XCTAssertEqual(request.content.userInfo["user_id"] as? String, "user-1")
    }

    func testSettingsAreSavedPerAccount() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "NudgeTests-\(UUID().uuidString)"))
        XCTAssertEqual(NudgeSettings.load(for: "a", from: defaults), NudgeSettings())
        let chosen = NudgeSettings(enabled: true, everyHours: 4, startHour: 10, endHour: 18)
        chosen.save(for: "a", to: defaults)
        XCTAssertEqual(NudgeSettings.load(for: "a", from: defaults), chosen)
        XCTAssertFalse(NudgeSettings.load(for: "b", from: defaults).enabled)
        chosen.save(for: "", to: defaults)
        XCTAssertFalse(NudgeSettings.load(for: "", from: defaults).enabled)
        NudgeSettings.remove(for: "a", from: defaults)
        XCTAssertFalse(NudgeSettings.load(for: "a", from: defaults).enabled)
    }

    func testHourLabels() {
        XCTAssertEqual(ProfileView.hourLabel(0), "12am")
        XCTAssertEqual(ProfileView.hourLabel(9), "9am")
        XCTAssertEqual(ProfileView.hourLabel(12), "12pm")
        XCTAssertEqual(ProfileView.hourLabel(21), "9pm")
    }
}

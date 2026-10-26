import ActivityKit
import Foundation
import UIKit

/// Starts, updates and ends the Dynamic Island / Lock Screen activity for a Prep answer. Everything here is best
/// effort: if Live Activities are off, or the system refuses, Prep works exactly the same without it.
@MainActor
final class PrepLiveActivity {
    private var activity: Activity<PrepActivityAttributes>?
    private var phase: PrepActivityAttributes.Phase?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var activeObserver: NSObjectProtocol?

    init() {
        // When the person comes back, a finished result has done its job and the island can clear.
        activeObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .ready || self.phase == .failed else { return }
                self.finish(after: 2)
            }
        }
    }

    deinit { if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) } }

    /// A new activity for `question`, recording from now (or from `elapsed` seconds ago).
    func startRecording(question: String, elapsed: Double = 0) {
        end()
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = PrepActivityAttributes.ContentState(phase: .recording, since: Date().addingTimeInterval(-elapsed), elapsed: elapsed)
        activity = try? Activity.request(attributes: PrepActivityAttributes(question: Self.short(question)),
                                         content: .init(state: state, staleDate: nil))
        phase = .recording
    }

    func setPaused(_ paused: Bool, elapsed: Double) {
        phase = paused ? .paused : .recording
        update(.init(phase: paused ? .paused : .recording, since: Date().addingTimeInterval(-elapsed), elapsed: elapsed),
               stale: nil)
    }

    /// The wait for coaching, started from a typed answer too. Calling it again keeps the original start time.
    /// It goes stale after two minutes without an update, which the widget says out loud.
    func setCoaching(question: String) {
        guard phase != .coaching else { return }
        if activity == nil {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            let state = PrepActivityAttributes.ContentState(phase: .coaching, since: Date(), elapsed: 0)
            activity = try? Activity.request(attributes: PrepActivityAttributes(question: Self.short(question)),
                                             content: .init(state: state, staleDate: Date().addingTimeInterval(120)))
        } else {
            update(.init(phase: .coaching, since: Date(), elapsed: 0), stale: Date().addingTimeInterval(120))
        }
        phase = .coaching
        keepRunningBriefly()
    }

    /// Coaching arrived. With the app on screen the activity clears at once. Otherwise it stays in the island as
    /// "ready" (an ended activity leaves the island immediately) and clears when the person returns.
    func setReady() {
        phase = .ready
        update(.init(phase: .ready, since: Date(), elapsed: 0), stale: nil)
        releaseGrace()
        if UIApplication.shared.applicationState == .active { finish(after: 2) }
    }

    func setFailed() {
        phase = .failed
        update(.init(phase: .failed, since: Date(), elapsed: 0), stale: nil)
        releaseGrace()
        if UIApplication.shared.applicationState == .active { finish(after: 2) }
    }

    func end() {
        releaseGrace()
        phase = nil
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Private

    private func update(_ state: PrepActivityAttributes.ContentState, stale: Date?) {
        guard let current = activity else { return }
        Task { await current.update(.init(state: state, staleDate: stale)) }
    }

    private func finish(after seconds: TimeInterval) {
        releaseGrace()
        guard let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .after(Date().addingTimeInterval(seconds))) }
    }

    /// Once recording stops, the app is suspended within seconds unless the system is asked for a little more time.
    /// That is enough for a short wait; for a longer one the activity goes stale until the person returns.
    private func keepRunningBriefly() {
        releaseGrace()
        grace = UIApplication.shared.beginBackgroundTask(withName: "stack.prep.coaching") { [weak self] in
            Task { @MainActor in self?.releaseGrace() }
        }
    }

    private func releaseGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private static func short(_ prompt: String) -> String {
        let lead = splitPrompt(prompt).lead
        return lead.count > 110 ? String(lead.prefix(107)) + "…" : lead
    }
}

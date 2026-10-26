import ActivityKit
import Foundation

/// What the Dynamic Island and Lock Screen show for a Prep answer: first the recording, then the wait for coaching.
/// Shared by the app (which starts and updates it) and the widget extension (which draws it).
struct PrepActivityAttributes: ActivityAttributes {
    enum Phase: String, Codable, Hashable {
        case recording, paused, coaching, ready, failed
    }

    struct ContentState: Codable, Hashable {
        var phase: Phase
        /// While recording, the moment the timer would have read 0:00 (so `Text(timerInterval:)` counts up by itself).
        /// While coaching, when the wait began.
        var since: Date
        /// While paused, the time on the clock.
        var elapsed: Double
    }

    /// The question being answered, shortened for the Lock Screen.
    var question: String
}

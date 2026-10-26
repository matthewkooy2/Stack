import ActivityKit
import SwiftUI
import WidgetKit

private let accent = Color(red: 0x25 / 255, green: 0x63 / 255, blue: 1)
private let page = Color(red: 0xF5 / 255, green: 0xF3 / 255, blue: 0xF0 / 255)

private extension PrepActivityAttributes.Phase {
    var symbol: String {
        switch self {
        case .recording: return "mic.fill"
        case .paused: return "pause.fill"
        case .coaching: return "sparkles"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    func title(stale: Bool) -> String {
        switch self {
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .coaching: return stale ? "Coaching is ready soon" : "Writing your coaching"
        case .ready: return "Your coaching is ready"
        case .failed: return "Couldn’t finish your coaching"
        }
    }
}

/// A running clock, or the frozen one while paused. After the wait for coaching it counts how long it has taken.
private struct ActivityClock: View {
    let state: PrepActivityAttributes.ContentState
    var body: some View {
        switch state.phase {
        case .recording, .coaching:
            Text(timerInterval: state.since...Date.distantFuture, countsDown: false)
                .monospacedDigit()
        case .paused:
            Text(Duration.seconds(state.elapsed).formatted(.time(pattern: .minuteSecond))).monospacedDigit()
        case .ready, .failed:
            EmptyView()
        }
    }
}

struct PrepActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PrepActivityAttributes.self) { context in
            LockScreen(context: context)
                .activityBackgroundTint(page)
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.phase.symbol).font(.title2).foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ActivityClock(state: context.state).font(.title2.weight(.semibold)).foregroundStyle(accent)
                        .frame(maxWidth: 90, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.state.phase.title(stale: context.isStale)).font(.headline)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.attributes.question).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            } compactLeading: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(accent)
            } compactTrailing: {
                ActivityClock(state: context.state).foregroundStyle(accent).frame(maxWidth: 52)
            } minimal: {
                Image(systemName: context.state.phase.symbol).foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

private struct LockScreen: View {
    let context: ActivityViewContext<PrepActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.phase.symbol)
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(accent, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.phase.title(stale: context.isStale)).font(.headline).foregroundStyle(.black)
                Text(context.attributes.question).font(.subheadline).foregroundStyle(.gray).lineLimit(2)
            }
            Spacer(minLength: 8)
            ActivityClock(state: context.state).font(.title2.weight(.semibold)).foregroundStyle(accent)
                .frame(maxWidth: 84, alignment: .trailing)
        }
        .padding(16)
    }
}

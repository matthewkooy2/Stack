import ActivityKit
import SwiftUI
import WidgetKit

private let accent = Color(uiColor: .systemBlue)
private let prepURL = URL(string: "com.matthewkooy.stack://open/prep")

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
        case .coaching: return stale ? "Open Prep for an update" : "Writing your coaching"
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
                .activityBackgroundTint(Color(uiColor: .secondarySystemBackground))
                .widgetURL(prepURL)
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
            .widgetURL(prepURL)
        }
    }
}

private struct LockScreen: View {
    let context: ActivityViewContext<PrepActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: context.state.phase.symbol)
                .font(.title3.weight(.semibold)).foregroundStyle(accent)
                .frame(width: 46, height: 46)
                .background(accent.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(context.state.phase.title(stale: context.isStale)).font(.headline).foregroundStyle(.primary)
                Text(context.attributes.question).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            ActivityClock(state: context.state).font(.title2.weight(.semibold)).foregroundStyle(accent)
                .frame(maxWidth: 84, alignment: .trailing)
        }
        .padding(16)
    }
}

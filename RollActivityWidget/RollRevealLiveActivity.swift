import ActivityKit
import WidgetKit
import SwiftUI

/// Countdown to a roll's reveal, on the lock screen and in the Dynamic Island. The countdown
/// itself never needs a push or a periodic update from the app — Text(timerInterval:) ticks on
/// its own, driven by the fixed revealAt date in the activity's content state.
struct RollRevealLiveActivity: Widget {
    /// Matches FlimTheme's default amber accent. The widget extension runs in its own process
    /// with its own UserDefaults, so it can't read the user's chosen in-app accent without an
    /// App Group this project doesn't have yet — a fixed color is the honest v1 rather than
    /// pretending to sync.
    private let accent = Color(red: 0.98, green: 0.74, blue: 0.36)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RollRevealAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "hourglass")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(context.attributes.rollName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(shotLabel(context.state.shotCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                Text(timerInterval: Date()...context.state.revealAt, countsDown: true)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
                    .frame(minWidth: 56)
            }
            .padding(16)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: Date()...context.state.revealAt, countsDown: true)
                        .monospacedDigit()
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.rollName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(shotLabel(context.state.shotCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: "hourglass")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(timerInterval: Date()...context.state.revealAt, countsDown: true)
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .frame(width: 40)
            } minimal: {
                Image(systemName: "hourglass")
                    .foregroundStyle(accent)
            }
        }
    }

    private func shotLabel(_ count: Int) -> String {
        count == 0 ? "Develops soon" : "\(count) shot\(count == 1 ? "" : "s") waiting"
    }
}

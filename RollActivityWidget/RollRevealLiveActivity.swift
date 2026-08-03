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
                    Text(RollRevealAttributes.shotLabel(context.state.shotCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 8)
                // Guarded range, see RollRevealAttributes.countdownRange. `Date()...revealAt`
                // traps the instant revealAt is in the past, which is the normal end of this
                // activity's life, and it is the crash we had on record.
                Group {
                    if RollRevealAttributes.hasRevealed(context.state.revealAt) {
                        Text("Ready")
                    } else {
                        Text(timerInterval: RollRevealAttributes.countdownRange(to: context.state.revealAt),
                             countsDown: true)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 15, weight: .semibold, design: .rounded))
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
                    // Same clipping risk as the compact region, with more room to work in.
                    Group {
                        if RollRevealAttributes.hasRevealed(context.state.revealAt) {
                            Text("Ready")
                        } else {
                            Text(timerInterval: RollRevealAttributes.countdownRange(to: context.state.revealAt),
                                 countsDown: true)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.rollName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(RollRevealAttributes.shotLabel(context.state.shotCount))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
            } compactLeading: {
                Image(systemName: "hourglass")
                    .foregroundStyle(accent)
            } compactTrailing: {
                // A 12-hour countdown renders as "11:59:32" — far wider than the 40pt this
                // used to be pinned to, so it truncated to "11:...". The compact region is
                // narrow by design, so scale the digits down to fit rather than clip them:
                // a truncated countdown is worse than a small one.
                Group {
                    if RollRevealAttributes.hasRevealed(context.state.revealAt) {
                        Text("Ready")
                    } else {
                        Text(timerInterval: RollRevealAttributes.countdownRange(to: context.state.revealAt),
                             countsDown: true)
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(accent)
                    .frame(maxWidth: 66)
            } minimal: {
                Image(systemName: "hourglass")
                    .foregroundStyle(accent)
            }
        }
    }
}

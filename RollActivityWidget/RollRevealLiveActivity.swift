import ActivityKit
import WidgetKit
import SwiftUI

/// A roll developing, on the lock screen and in the Dynamic Island.
///
/// Neither the countdown nor the progress bar needs a push or a periodic update from the app.
/// `Text(timerInterval:)` and `ProgressView(timerInterval:)` both tick on-device from the fixed
/// dates in the content state, so this card stays live and correct while the app is closed.
///
/// The card used to be a static hourglass, a name, and a number. It said how long was left and
/// nothing else: not how far along the roll was, not whether anyone had actually shot anything,
/// and not in the color the person had chosen for the app. All three are in the content state now.
struct RollRevealLiveActivity: Widget {

    /// The roll this card is about, as a link the app can parse. Falls back to the Rolls-adjacent
    /// darkroom link if the id is somehow not a UUID, so a tap always lands somewhere real.
    private func rollURL(_ rollId: String) -> URL? {
        guard let id = UUID(uuidString: rollId) else { return URL(string: WidgetLink.darkroom) }
        return URL(string: WidgetLink.reveal(id))
    }


    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RollRevealAttributes.self) { context in
            RollRevealCard(rollName: context.attributes.rollName,
                           rollId: context.attributes.rollId,
                           state: context.state)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
                // Tapping the card had no destination at all, so it opened the app to whichever
                // tab was last used — a card about one specific roll that went anywhere but that
                // roll. `reveal` is the right route rather than a plain rolls list: it opens the
                // roll itself, and RollDetailView already decides on its own whether a reveal is
                // owed (once per roll, `rollRevealSeen.<id>`), so a still-developing roll simply
                // opens.
                .widgetURL(rollURL(context.attributes.rollId))
        } dynamicIsland: { context in
            let accent = FlimAccentPalette.color(context.state.accent)
            let revealed = RollRevealAttributes.hasRevealed(context.state.revealAt)

            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RollRevealCard.icon(revealed: revealed)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    RollRevealCard.countdown(revealAt: context.state.revealAt)
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
                    VStack(spacing: 7) {
                        RollRevealCard.progress(state: context.state, revealed: revealed, accent: accent)
                        Text(RollRevealAttributes.statusLabel(shotCount: context.state.shotCount,
                                                              revealAt: context.state.revealAt))
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            } compactLeading: {
                RollRevealCard.icon(revealed: revealed)
                    .foregroundStyle(accent)
            } compactTrailing: {
                // A 12-hour countdown renders as "11:59:32", far wider than the 40pt this used to
                // be pinned to, so it truncated to "11:...". The compact region is narrow by
                // design, so scale the digits down rather than clip them: a truncated countdown
                // is worse than a small one.
                RollRevealCard.countdown(revealAt: context.state.revealAt)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundStyle(accent)
                    .frame(maxWidth: 66)
            } minimal: {
                RollRevealCard.icon(revealed: revealed)
                    .foregroundStyle(accent)
            }
        }
    }
}

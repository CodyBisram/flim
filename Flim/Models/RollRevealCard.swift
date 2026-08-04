import SwiftUI

/// The lock-screen card's contents, as a plain view over plain values.
///
/// Split out of `RollRevealLiveActivity` for one practical reason: a Live Activity is close to
/// unviewable while you are building it. It needs a real roll, on a real device, whose reveal is
/// far enough out to be worth rendering, and then you have to lock the phone. So the layout was
/// historically written blind and checked in production, which is how it shipped pinned to a 40pt
/// frame that truncated a twelve-hour countdown to "11:...".
///
/// Taking `ContentState` instead of `ActivityViewContext` means the same view the widget renders
/// can be put on screen anywhere, including a preview and the simulator. This file is a source of
/// BOTH targets (see project.yml), so there is no second copy to drift.
struct RollRevealCard: View {
    let rollName: String
    let state: RollRevealAttributes.ContentState
    /// Injectable so a preview can show the card at any point in a roll's life, and so the tests
    /// covering the copy are not racing the wall clock.
    var now: Date = .now

    private var accent: Color { FlimAccentPalette.color(state.accent) }
    private var revealed: Bool { RollRevealAttributes.hasRevealed(state.revealAt, now: now) }

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 12) {
                RollRevealCard.icon(revealed: revealed)
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rollName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(RollRevealAttributes.statusLabel(shotCount: state.shotCount,
                                                          revealAt: state.revealAt, now: now))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                RollRevealCard.countdown(revealAt: state.revealAt, now: now)
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(revealed ? .black : accent)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(minWidth: 58)
                    // Once it is ready the countdown slot stops being a number and becomes the
                    // thing to act on, so it is filled rather than tinted. This is the only card
                    // state that is asking for something.
                    .padding(.horizontal, revealed ? 11 : 0)
                    .padding(.vertical, revealed ? 5 : 0)
                    .background { if revealed { Capsule().fill(accent) } }
            }

            // The bar is the actual upgrade. "4h 12m" does not say whether that is nearly there
            // or barely started; a bar answers it at a glance, without being read.
            RollRevealCard.progress(state: state, revealed: revealed, accent: accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: - Pieces, shared with the Dynamic Island presentations

    /// Filmic rather than a kitchen timer, and it changes at the moment the roll is ready, so the
    /// card reads differently at a glance without anyone parsing the text.
    static func icon(revealed: Bool) -> some View {
        Image(systemName: revealed ? "sparkles" : "camera.aperture")
    }

    @ViewBuilder
    static func countdown(revealAt: Date, now: Date = .now) -> some View {
        if RollRevealAttributes.hasRevealed(revealAt, now: now) {
            Text("Ready")
        } else {
            // Guarded range, see RollRevealAttributes.countdownRange. `Date()...revealAt` traps
            // the instant revealAt is in the past, which is the normal end of this activity's
            // life, and it is the crash we had on record.
            Text(timerInterval: RollRevealAttributes.countdownRange(to: revealAt, now: now),
                 countsDown: true)
                .monospacedDigit()
        }
    }

    @ViewBuilder
    static func progress(state: RollRevealAttributes.ContentState,
                         revealed: Bool, accent: Color) -> some View {
        if revealed {
            // A completed bar, not a live one: a timer interval that has already elapsed has
            // nothing left to animate, and the same inverted-range trap applies here as to Text.
            Capsule()
                .fill(accent)
                .frame(height: 3)
                .frame(maxWidth: .infinity)
        } else {
            ProgressView(timerInterval: RollRevealAttributes.developRange(from: state.developFrom,
                                                                          to: state.revealAt),
                         countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(accent)
            .frame(height: 3)
        }
    }
}

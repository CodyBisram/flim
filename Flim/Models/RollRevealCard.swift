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
    /// Only used to pick the cover's hue, so a roll looks the same colour here as in the app.
    /// Defaulted so existing previews and tests that only care about copy keep compiling.
    var rollId: String = ""
    let state: RollRevealAttributes.ContentState
    /// Injectable so a preview can show the card at any point in a roll's life, and so the tests
    /// covering the copy are not racing the wall clock.
    var now: Date = .now

    private var accent: Color { FlimAccentPalette.color(state.accent) }
    private var revealed: Bool { RollRevealAttributes.hasRevealed(state.revealAt, now: now) }

    var body: some View {
        HStack(spacing: 11) {
            cover
            VStack(alignment: .leading, spacing: 1) {
                Text(revealed ? "\(rollName) is ready" : "\(rollName) is developing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(RollRevealAttributes.statusLabel(shotCount: state.shotCount,
                                                      revealAt: state.revealAt, now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(WidgetTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            RollRevealCard.countdown(revealAt: state.revealAt, now: now)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .foregroundStyle(revealed ? .black : accent)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(minWidth: 58)
                // Once it is ready the countdown slot stops being a number and becomes the thing
                // to act on, so it is filled rather than tinted. This is the only card state that
                // is asking for something.
                .padding(.horizontal, revealed ? 11 : 0)
                .padding(.vertical, revealed ? 5 : 0)
                .background { if revealed { Capsule().fill(accent) } }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
    }

    /// The roll's cover, with its develop progress drawn AROUND it rather than as a bar beneath
    /// the row.
    ///
    /// The bar it replaces answered the same question ("nearly there, or barely started?") and
    /// cost a whole row to do it, on a surface where vertical space is the scarcest thing there
    /// is. Wrapped around the cover it costs nothing and reads faster, because the thing filling
    /// up is visibly the thing being waited on.
    ///
    /// The cover is a generated gradient, not a photograph: a Live Activity has no App Group, so
    /// the extension cannot reach a thumbnail even in principle. The hue comes from the roll's id
    /// with the same formula `AvatarView` uses, so a roll is the same colour here as it is in the
    /// Rolls list.
    private var cover: some View {
        RollHueTile(seed: rollId, corner: 10)
            .frame(width: 38, height: 38)
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .trim(from: 0, to: revealed ? 1 : progressValue)
                    .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(-3)
            }
    }

    private var progressValue: Double {
        // Floored so a roll that has only just started still shows a mark rather than nothing at
        // all, which would be indistinguishable from a ring that failed to draw.
        max(0.02, RollRevealAttributes.developProgress(from: state.developFrom,
                                                       to: state.revealAt, now: now))
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

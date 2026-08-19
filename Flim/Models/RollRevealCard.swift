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
                // The name gets the whole line, and the state moves down to the second one.
                //
                // The mock reads "Roommates 🏠 is developing" on one line, which works for a
                // short name and does not survive a real one: between a 38pt cover and a
                // countdown, "Summer road trip is developing" had room for "Summer…". Splitting
                // the Text kept the state visible but spent the name to do it. Given the two
                // lines already there, the fix is to use them — the name is the thing being
                // identified, so it gets the line, and "Developing" joins the shot count below,
                // where there is room for both.
                Text(rollName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(RollRevealCard.subtitle(state: state, revealed: revealed, now: now))
                    .font(.system(size: 11.5))
                    .foregroundStyle(WidgetTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
        RollHueTile(seed: rollId, corner: 10, initial: RollHueTile.initial(of: rollName))
            .frame(width: 38, height: 38)
            .overlay {
                ZStack {
                    // The TRACK. Without it a roll that has barely started draws a two-percent
                    // arc floating in space, which does not read as a progress ring at all — it
                    // reads as a rendering artifact, and that is how it looked on device an hour
                    // into a twelve-hour develop. The Rolls list already specifies a track at
                    // white 10%; this is the same ring, so it is the same track.
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 2)
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .trim(from: 0, to: revealed ? 1 : progressValue)
                        .stroke(accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .padding(-3)
            }
    }

    private var progressValue: Double {
        // Floored so a roll that has only just started still shows a mark rather than nothing at
        // all, which would be indistinguishable from a ring that failed to draw.
        max(0.02, RollRevealAttributes.developProgress(from: state.developFrom,
                                                       to: state.revealAt, now: now))
    }

    /// The second line: what is happening, and how much is in it.
    ///
    /// `statusLabel` alone said "No shots yet", which is true and does not say the roll is
    /// developing — the word the mock puts on the first line. Prefixed here it costs nothing,
    /// because this line had room and the first line did not.
    static func subtitle(state: RollRevealAttributes.ContentState,
                         revealed: Bool, now: Date = .now) -> String {
        let status = RollRevealAttributes.statusLabel(shotCount: state.shotCount,
                                                      revealAt: state.revealAt, now: now)
        return revealed ? status : "Developing \u{00B7} " + status.lowercasedFirst
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


private extension String {
    /// Lowercases only the first character, so "No shots yet" reads correctly after a separator
    /// while "12 shots so far" and any name inside it are left alone.
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

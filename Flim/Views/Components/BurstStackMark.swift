import SwiftUI

/// The small mark a burst stack draws over its grid cell, in the same film-edge language as
/// `FrameNumberLabel`/the roll invite code: mono, small, tracked, the roll's own accent, on a dark
/// scrim so it reads over any photograph. `.count` sits on a collapsed stack's cover cell; tapping
/// it fans the stack open. `.collapse` sits on the FIRST frame of an already-fanned-open stack;
/// tapping it folds the stack back. Purely presentational, the tap itself is wired by whichever
/// `Button` wraps this at the call site.
///
/// `interactive: false` is the reveal's use: the same mark, in the same corner of the frame, on
/// the sharpest frame of a burst, where the deck is frozen and there is nothing to fan open. It
/// says "this stands for N" without a button trait or a tap hint, and without taking a line of
/// the credit below the photograph, which is where this used to live as text and where one extra
/// line moved the reaction row on every burst frame and only there.
struct BurstStackMark: View {
    @Environment(\.flimAccent) private var accent

    enum Kind: Equatable {
        case count(Int)
        case collapse
    }

    let kind: Kind
    var interactive: Bool = true

    var body: some View {
        Group {
            switch kind {
            case .count(let n):
                Text("×\(n)")
            case .collapse:
                Image(systemName: "rectangle.compress.vertical")
                    .font(.system(size: 9, weight: .semibold))
            }
        }
        .flimFont(10, weight: .semibold, design: .monospaced, relativeTo: .caption2)
        .tracking(0.5)
        .foregroundStyle(accent)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.black.opacity(0.55), in: Capsule())
        .padding(5)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(interactive ? .isButton : [])
    }

    private var accessibilityLabel: String {
        switch kind {
        case .count(let n):
            return interactive
                ? "Burst of \(n) photos, tap to show them all"
                : "Sharpest of a burst of \(n) photos; the rest are in the roll's grid"
        case .collapse: return "Collapse this burst"
        }
    }
}

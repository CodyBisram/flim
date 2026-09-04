import SwiftUI

/// The small mark a burst stack draws over its grid cell, in the same film-edge language as
/// `FrameNumberLabel`/the roll invite code: mono, small, tracked, the roll's own accent, on a dark
/// scrim so it reads over any photograph. `.count` sits on a collapsed stack's cover cell; tapping
/// it fans the stack open. `.collapse` sits on the FIRST frame of an already-fanned-open stack;
/// tapping it folds the stack back. Purely presentational, the tap itself is wired by whichever
/// `Button` wraps this at the call site.
struct BurstStackMark: View {
    @Environment(\.flimAccent) private var accent

    enum Kind: Equatable {
        case count(Int)
        case collapse
    }

    let kind: Kind

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
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabel: String {
        switch kind {
        case .count(let n): return "Burst of \(n) photos, tap to show them all"
        case .collapse: return "Collapse this burst"
        }
    }
}

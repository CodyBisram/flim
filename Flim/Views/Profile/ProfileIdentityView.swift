import SwiftUI

/// The permanent signup number, set like an edge number on film stock: small, monospaced,
/// tabular figures, low contrast. It must never read as tappable or editable, unlike Lapse's
/// signup-number chip sitting next to "Star sign" and "School/College" as one more editable
/// field, so this is plain `Text`, not a button or a capsule.
struct FrameNumberLabel: View {
    let number: Int

    var body: some View {
        Text("No \(number)")
            .flimFont(11, design: .monospaced, relativeTo: .caption)
            .tracking(0.5)
            .foregroundStyle(FlimTheme.textTertiary)
            .accessibilityLabel("Member number \(number)")
    }
}

/// Splits up to four displayed badges into the two columns that flank the avatar (see
/// `UserPageView.pageHeader`). Both self and stranger profiles pass the exact same list here —
/// there is no longer a wider "everything you've earned" set to choose from at this call site,
/// that full collection only ever lives in `BadgePickerSheet` now.
///
/// The odd-count cases matter more than the even one: `UserPageView` already caps this at four,
/// so 0 through 4 are the only counts that ever reach this, and the risk called out explicitly is
/// a single pill stranded on one side with nothing opposite reading like a layout bug rather than
/// a deliberate choice. Alternating right-then-left as badges are added avoids that: the very
/// first (and, for a one-badge profile, only) pill always lands on the right, alone, which reads
/// as a small decoration beside the avatar — the same place a verified checkmark sits in other
/// apps — rather than a stray fragment with an empty gap on the other side. From a second badge
/// on, both sides always carry at least one pill, so an odd total (three) still splits 2-and-1
/// rather than ever leaving one side bare.
enum ProfileBadgeFlank {
    static func split(_ badges: [ProfileBadge]) -> (left: [ProfileBadge], right: [ProfileBadge]) {
        var left: [ProfileBadge] = []
        var right: [ProfileBadge] = []
        for (index, badge) in badges.enumerated() {
            if index.isMultiple(of: 2) { right.append(badge) } else { left.append(badge) }
        }
        return (left, right)
    }
}

/// One side of the flanking pair. `alignment` is `.trailing` for the column to the LEFT of the
/// avatar and `.leading` for the column to the RIGHT of it, so every pill's edge nearest the
/// avatar lines up and the ragged far edge falls outward instead. That alignment is what stops
/// the two sides reading as broken: "Founding 100" is roughly twice the width of "Shared", so the
/// two columns rarely land on the same width, and without this they'd leave an uneven gap around
/// the photo instead of a deliberate, outward-falling ragged edge.
///
/// Renders nothing (an empty `VStack`, zero width) when `badges` is empty, which is the common
/// case for whichever side didn't get the odd badge out — see `ProfileBadgeFlank`.
struct ProfileBadgeColumn: View {
    let badges: [ProfileBadge]
    let alignment: HorizontalAlignment
    /// The signed-in account's own earned badge kind ids, so a pill for a badge the viewer
    /// doesn't hold can add "how to earn this" to its popover; see `ProfileBadgePill`.
    var viewerBadgeKindIds: Set<String> = []

    var body: some View {
        // 18pt between two stacked pills on the same side matches each pill's own 9pt tap-target
        // expansion (see `ProfileBadgePill`): 9 down from the one above plus 9 up from the one
        // below meets exactly at the midpoint rather than overlapping, the same rule
        // `expandTapTarget`'s own doc comment gives for any two tappable neighbours this close.
        VStack(alignment: alignment, spacing: 18) {
            ForEach(badges) { badge in
                ProfileBadgePill(badge: badge, viewerBadgeKindIds: viewerBadgeKindIds)
            }
        }
    }
}

/// One earned badge, printed as a small capsule pill in the same visual family as the "friend"
/// tag in `FollowingList` (accent text on a faint accent wash), not the dated stamp this replaced.
/// No earned date anywhere on it: eleven dated stamps were the bulk of what made the old grid read
/// as busy, and with the count now capped at four, the pill can just be a name.
///
/// Locked badges never appear anywhere in the app, so someone seeing a pill has no other way to
/// learn what it means beyond tapping it; that popover is now the ONLY place any explanation of a
/// badge lives outside `BadgePickerSheet`'s own list, so it matters more than it used to, not
/// less. The visible pill stays small on purpose, so the tap target is grown to Apple's 44pt
/// minimum without changing what's on screen.
struct ProfileBadgePill: View {
    let badge: ProfileBadge
    var viewerBadgeKindIds: Set<String> = []
    @Environment(\.flimAccent) private var accent
    @State private var showExplanation = false

    /// "How to earn this" only makes sense for a badge the viewer doesn't already hold; showing
    /// it under a badge they have too would just be noise under their own pill.
    private var howToEarn: String? {
        viewerBadgeKindIds.contains(badge.kind.rawValue) ? nil : badge.kind.howToEarn
    }

    var body: some View {
        Button {
            Haptics.tap()
            showExplanation = true
        } label: {
            Text(badge.kind.label.uppercased())
                .flimFont(10, weight: .semibold, relativeTo: .caption2)
                .tracking(1.0)
                // Every label in the catalog now fits, but this is the general fix rather than a
                // per-label one: "Brought Someone" used to truncate to "BROUGHT SO…" at this same
                // pill size before it was renamed to "Plus One", and a scale-down instead of an
                // ellipsis is what stops the NEXT long label doing the same thing silently.
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(accent)
                .frame(maxWidth: 84)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(accent.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain)
        .expandTapTarget(by: 9)   // visual pill is ~26pt tall, +9 either side = 44
        // `arrowEdge: .top` is explicit here for the same reason it was on the old stamp: a pill
        // that's actually on screen (never off past a clipped edge, see the module comment above)
        // has real room above/below it, so the system keeps the vertical arrow instead of
        // flipping sideways into the avatar or the opposite column.
        .popover(isPresented: $showExplanation, arrowEdge: .top) {
            BadgeExplanationPopover(explanation: badge.kind.explanation, howToEarn: howToEarn)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(FlimTheme.bgElevated)
        }
        .accessibilityLabel("\(badge.kind.label) badge")
        .accessibilityHint("Double tap to hear what this badge means")
    }
}

/// The badge popover's content, factored out so it can be sized correctly and previewed on its
/// own without a live tap.
///
/// Two things were wrong before this existed: the text truncated with an ellipsis, and the box
/// could point sideways into a neighbouring stamp (fixed at each `.popover` call site via
/// `arrowEdge: .top`). The truncation was purely a sizing bug, not a text-length one — `Text` had
/// no `lineLimit` set, but a `maxWidth` alone leaves the popover free to first collapse toward a
/// single-line ideal size and clip whatever didn't fit, rather than actually measuring the wrapped
/// height. Giving it a concrete, fixed width instead of a flexible max is what makes the `Text`s
/// below wrap in the first place, and `.fixedSize(horizontal: false, vertical: true)` then forces
/// this view to report ITS true wrapped height back to the popover container instead of an
/// ambiguous guess.
struct BadgeExplanationPopover: View {
    let explanation: String
    let howToEarn: String?

    var body: some View {
        VStack(spacing: 10) {
            Text(explanation)
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
            if let howToEarn {
                Text(howToEarn)
                    .flimFont(12, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(width: 220)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}

// MARK: - Previews

/// Mirrors the exact composition `UserPageView.pageHeader` builds: left column, avatar, right
/// column, all vertically centred in one row. A stand-in avatar circle since these previews live
/// outside `UserPageView` and have no real photo to load.
private struct FlankPreview: View {
    let badges: [ProfileBadge]
    var viewerBadgeKindIds: Set<String> = []
    @Environment(\.flimAccent) private var accent

    var body: some View {
        let split = ProfileBadgeFlank.split(badges)
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            HStack(alignment: .center, spacing: 14) {
                ProfileBadgeColumn(badges: split.left, alignment: .trailing, viewerBadgeKindIds: viewerBadgeKindIds)
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 88, height: 88)
                    .overlay(Text("C").flimFont(32, weight: .thin, relativeTo: .title3).foregroundStyle(accent))
                    .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 4))
                    .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
                ProfileBadgeColumn(badges: split.right, alignment: .leading, viewerBadgeKindIds: viewerBadgeKindIds)
            }
            .padding(.vertical, 50)
        }
    }
}

private func previewBadge(_ id: String, _ kind: ProfileBadgeKind) -> ProfileBadge {
    ProfileBadge(id: id, kind: kind, earnedAt: .now)
}

#Preview("Flanking: zero badges (just the avatar)") {
    FlankPreview(badges: [])
}

#Preview("Flanking: one badge (right only, reads like a verified mark)") {
    FlankPreview(badges: [previewBadge("founding_100", .founding100)])
}

#Preview("Flanking: two badges (one each side)") {
    FlankPreview(badges: [
        previewBadge("founding_100", .founding100),
        previewBadge("shared", .shared),
    ])
}

#Preview("Flanking: three badges (2 right, 1 left, neither side stranded)") {
    FlankPreview(badges: [
        previewBadge("founding_100", .founding100),
        previewBadge("shared", .shared),
        previewBadge("darkroom", .darkroom),
    ])
}

#Preview("Flanking: four badges (full 2-and-2 split, the common case)") {
    FlankPreview(badges: [
        previewBadge("founding_100", .founding100),
        previewBadge("shared", .shared),
        previewBadge("darkroom", .darkroom),
        previewBadge("roll_maker", .rollMaker),
    ])
}

#Preview("Flanking: renamed 'Plus One' pill, plus how-to-earn state") {
    // `broughtSomeone` used to truncate to "BROUGHT SO…" at this size under its old label; also
    // exercises the how-to-earn line, since `viewerBadgeKindIds` here is empty.
    FlankPreview(badges: [
        previewBadge("brought_someone", .broughtSomeone),
        previewBadge("founding_100", .founding100),
    ])
}

#Preview("Flanking: four badges, largest Dynamic Type, narrowest device") {
    FlankPreview(badges: [
        previewBadge("founding_crew", .foundingCrew),   // the longest label in the catalog
        previewBadge("shared", .shared),
        previewBadge("darkroom", .darkroom),
        previewBadge("chipped_in", .chippedIn),
    ])
    .frame(width: 375)   // iPhone SE width, the narrowest device FLIM still supports
    .dynamicTypeSize(FlimTypeScale.maximum)
}

#Preview("Badge explanation popover: longest copy, largest Dynamic Type, narrowest device") {
    // `fullRoll` carries both the longest explanation AND the longest how-to line in the
    // catalog, the worst case for the popover's height, checked on the narrowest device FLIM
    // still supports at the largest type size the app allows.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        BadgeExplanationPopover(
            explanation: ProfileBadgeKind.fullRoll.explanation,
            howToEarn: ProfileBadgeKind.fullRoll.howToEarn
        )
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 14))
        .padding(20)
    }
    .frame(width: 375)
    .dynamicTypeSize(FlimTypeScale.maximum)
}

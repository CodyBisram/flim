import SwiftUI
import UIKit

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
/// `UserPageView` caps this at four, so 0 through 4 are the only counts that ever reach here, and
/// the four slots read like text: top left, top right, bottom left, bottom right.
///
///     [0]  (avatar)  [1]
///     [2]            [3]
///
/// So the left column takes the even indices and the right column the odd ones, and a lone badge
/// sits top LEFT where the eye starts rather than opposite it.
///
/// An earlier version filled right-first and alternated, on the theory that a single pill alone on
/// the right reads as a deliberate mark beside a photo (where a verified checkmark usually sits).
/// Cody wanted plain reading order instead, which is also the rule that needs no explaining: the
/// display order the picker saves is the order they appear in, scanned the way everything else on
/// the page is scanned.
///
/// Which side a badge lands on cannot move the avatar. See `AvatarBadgeFlanking`, where the avatar
/// holds its own fixed frame and the columns are overlaid beside it, and
/// `AvatarBadgeCenteringTests`, which asserts that across every count.
enum ProfileBadgeFlank {
    static func split(_ badges: [ProfileBadge]) -> (left: [ProfileBadge], right: [ProfileBadge]) {
        var left: [ProfileBadge] = []
        var right: [ProfileBadge] = []
        for (index, badge) in badges.enumerated() {
            if index.isMultiple(of: 2) { left.append(badge) } else { right.append(badge) }
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

/// The width every pill in one group should render at: the widest natural label among them.
///
/// Pills used to size to their own text, which read as objects rather than form fields but left
/// four medals of four different widths flanking an avatar, and that reads as untidy rather than
/// characterful. Neither a global constant nor per-label hugging is right: a constant has to be
/// wide enough for the longest label in the whole catalogue, so most pills carry dead space for a
/// word they will never show, and hugging gives up on alignment entirely.
///
/// This is the third answer. Each pill reports its own natural width, the enclosing group keeps
/// the maximum, and every pill in that group renders at it. So a profile showing FOUNDER,
/// FOUNDING 100, OPEN DOOR and PATRON sizes all four to FOUNDING 100 and no wider, and a profile
/// showing four short labels gets four compact pills. Uniform where it shows, never padded for a
/// label that is not on screen.
struct BadgePillWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct UniformBadgePillWidth: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    /// Set by a group that has measured its pills; `nil` means "size to your own label", which is
    /// what any lone pill outside such a group does.
    var uniformBadgePillWidth: CGFloat? {
        get { self[UniformBadgePillWidth.self] }
        set { self[UniformBadgePillWidth.self] = newValue }
    }
}

extension View {
    /// Collects the widest pill inside this view and feeds it back down so they all match.
    func uniformBadgePillWidths() -> some View {
        modifier(UniformBadgePillWidths())
    }
}

private struct UniformBadgePillWidths: ViewModifier {
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .environment(\.uniformBadgePillWidth, width > 0 ? width : nil)
            .onPreferenceChange(BadgePillWidthKey.self) { measured in
                // Only ever grows within a group's lifetime. Letting it shrink as rows appear and
                // disappear during a sheet's load would make every pill twitch.
                if measured > width { width = measured }
            }
    }
}

/// A single slow highlight travelling across a pill, once, shortly after it appears.
///
/// This exists for exactly one badge. `founder` has one possible holder in the entire history of
/// the app, and the question was how to mark that without inventing a sixth rung for it. A
/// platinum or diamond tier is the obvious answer and the wrong one: those are cool white-blues,
/// silver is already a cool blue-grey (deliberately, because neutral grey against near-black reads
/// as disabled), and at ten points a platinum pill lands in silver's neighbourhood and reads as
/// LOWER than gold rather than higher. That spends the top of the ladder on a colour that looks
/// like the middle of it.
///
/// Motion says "singular" without touching the colour system at all. Nothing else in FLIM moves
/// like this, so one sweep is legible as "this is not like the others" while `founder` stays
/// unmistakably on the founding rung.
///
/// Once, not looping: a pill that shimmers forever is a casino, and this has to sit on a
/// photographer's profile without becoming the thing you look at. Skipped entirely under Reduce
/// Motion, where the pill keeps its gradient and rim and simply does not animate.
private struct SpecularSweep: View {
    @State private var travelled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let band = max(width * 0.42, 18)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.7), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: band)
                .rotationEffect(.degrees(18))
                // Travels from fully clear of the leading edge to fully clear of the trailing one,
                // so neither end of the sweep is ever parked visible on the pill.
                .offset(x: travelled ? width + band : -band)
                .onAppear {
                    guard !reduceMotion else { return }
                    // The delay lets the page settle first: a sweep that fires during the
                    // navigation transition is just noise competing with the push animation.
                    withAnimation(.easeInOut(duration: 1.15).delay(0.45)) { travelled = true }
                }
        }
        .allowsHitTesting(false)
        .blendMode(.plusLighter)
    }
}

/// The bare pill visual: a badge's label on its tier-appropriate fill (see `ProfileBadgeTier`).
/// Factored out of `ProfileBadgePill` so tier colour is decided in exactly one view, then reused,
/// muted, for the locked catalog rows in `BadgePickerSheet`.
///
/// Pills size to their own label rather than to a shared fixed width. That was tried both ways:
/// a fixed 84pt frame, then 96pt when four labels turned out to overflow it. Both were wrong for
/// the same reason. A row of identical capsules reads as a set of form fields, and these are
/// meant to read as things a person was given. An object earned is not the same width as every
/// other object earned. The flanking columns were built for ragged widths from the start (see
/// `ProfileBadgeColumn`: each side aligns on its inner edge so the ragged edge falls outward), so
/// nothing about the layout needed the fixed frame in the first place, and hugging also retires
/// the overflow problem permanently: a pill that sizes to its text can never clip it.
///
/// What makes it read as struck rather than printed, in the order the eye picks them up:
///  - a vertical gradient, lighter above darker, so the surface looks lit from above;
///  - a bright hairline rim, which is the single detail doing most of the work;
///  - dark ink on metal, the same treatment every solid-accent control in the app already uses;
///  - and, on the founding rung only, a soft coloured glow beneath. Reserved to the top rung on
///    purpose: if every metal tier glowed, the founding pills would stop being what your eye
///    lands on first.
///
/// `accent` is deliberately none of that. It keeps the tinted wash it always had, because it is
/// the rung for ordinary use and should not be dressed as a medal.
struct BadgePillLabel: View {
    let kind: ProfileBadgeKind
    /// Locked/not-yet-earned rows in `BadgePickerSheet`'s catalogue render the same rung in a
    /// washed-out, outlined form: full strength would read as already earned, and no colour at
    /// all would lose the rung signal the tier exists to carry.
    var muted: Bool = false
    @Environment(\.flimAccent) private var accent

    private var tier: ProfileBadgeTier { kind.tier }
    private var hue: Color { tier.hue(accent: accent) }
    @Environment(\.uniformBadgePillWidth) private var uniformWidth

    var body: some View {
        Text(kind.label.uppercased())
            .flimFont(10, weight: .semibold, relativeTo: .caption2)
            .tracking(0.6)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(muted ? hue.opacity(0.75) : tier.foreground(accent: accent))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            // Report this label's natural width, then take the group's. A hidden copy at natural
            // size is what gets measured, so applying the group width below can never feed back
            // into the measurement and oscillate.
            .background(alignment: .center) {
                Text(kind.label.uppercased())
                    .flimFont(10, weight: .semibold, relativeTo: .caption2)
                    .tracking(0.6)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: BadgePillWidthKey.self, value: geo.size.width)
                    })
                    .hidden()
            }
            .frame(width: uniformWidth)
            .background {
                if muted {
                    Capsule()
                        .fill(hue.opacity(0.08))
                        .overlay(Capsule().strokeBorder(hue.opacity(0.35), lineWidth: 1))
                } else {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: tier.gradient(accent: accent),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        // Clipped to the capsule and sitting UNDER the rim, so the highlight
                        // travels across the metal rather than over the pill's own edge.
                        .overlay {
                            if kind == .founder, !muted {
                                SpecularSweep().clipShape(Capsule())
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(tier.rim(accent: accent), lineWidth: 0.75)
                        )
                        .shadow(color: tier.glow(accent: accent), radius: 5, y: 1)
                }
            }
    }
}

/// One earned badge, printed as a small capsule pill whose fill/hue reads its tier at a glance
/// (see `ProfileBadgeTier`), not the dated stamp this replaced. No earned date anywhere on it:
/// eleven dated stamps were the bulk of what made the old grid read as busy, and with the count
/// now capped at four, the pill can just be a name.
///
/// Locked badges never appear anywhere on a profile, so someone seeing a pill has no other way to
/// learn what it means beyond tapping it; that popover is now the ONLY place any explanation of a
/// badge lives outside `BadgePickerSheet`'s own catalog list, so it matters more than it used to,
/// not less. The visible pill stays small on purpose, so the tap target is grown to Apple's 44pt
/// minimum without changing what's on screen.
struct ProfileBadgePill: View {
    let badge: ProfileBadge
    var viewerBadgeKindIds: Set<String> = []
    @State private var showExplanation = false
    @Environment(\.flimAccent) private var accent

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
            BadgePillLabel(kind: badge.kind)
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
                // Lifted off the page and tinted by the badge's own rung. `bgElevated` alone is
                // barely a shade above the profile behind it, so a short explanation read as a
                // dark smear with no edge; the lighter base plus a whisper of the rung's hue is
                // what gives it a boundary without dressing it up as a second badge.
                .presentationBackground {
                    ZStack {
                        Color(white: 0.16)
                        badge.kind.tier.hue(accent: accent).opacity(0.10)
                    }
                }
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

    /// A concrete width is still required (see the type comment: a flexible max lets the popover
    /// collapse to a single-line ideal and clip), but 220 for everything made "Built FLIM." sit in
    /// a box built for a sentence three times its length. This measures the longest string at the
    /// size it will actually render and clamps the result, so a short explanation gets a short
    /// box and a long one still wraps at a readable measure.
    private var width: CGFloat {
        let font = UIFont.systemFont(ofSize: 13)
        let widest = ([explanation] + [howToEarn].compactMap { $0 })
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }
            .max() ?? 0
        return min(max(widest.rounded(.up), 120), 220)
    }

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
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .padding(16)
    }
}

/// Centres arbitrary avatar content on the page with up to two flanking badge columns. Used by
/// `UserPageView.pageHeader` for the real, tappable avatar, and by this file's own `FlankPreview`
/// (and `AvatarBadgeCenteringTests`) for a stand-in one, so the fix and everything that checks it
/// can never structurally drift apart.
///
/// Each column is an OVERLAY on `avatar`'s own frame, not a sibling in a shared HStack: a shared
/// HStack centres the whole row as a group, so a single badge on one side (nothing opposite it)
/// visibly shoves the avatar off-centre, worse the wider that one label is. An overlay's content
/// never contributes to the base view's reported size, so the avatar's centre is fixed by
/// `avatar`'s own frame alone regardless of badge count or label width; the `alignmentGuide`
/// overrides below just push each column's near edge out past the avatar's edge by `gap`, so a
/// column only ever grows outward, never inward toward the avatar's centre.
struct AvatarBadgeFlanking<Avatar: View>: View {
    let leftBadges: [ProfileBadge]
    let rightBadges: [ProfileBadge]
    var viewerBadgeKindIds: Set<String> = []
    /// Matches the old HStack's `spacing: 14` this replaced.
    var gap: CGFloat = 14
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        // Both columns are measured as ONE group, so the left pair and the right pair match each
        // other rather than only matching within their own column.
        avatar()
            .uniformBadgePillWidths()
            .overlay(alignment: .leading) {
                ProfileBadgeColumn(badges: leftBadges, alignment: .trailing, viewerBadgeKindIds: viewerBadgeKindIds)
                    .alignmentGuide(.leading) { d in d[.trailing] + gap }
            }
            .overlay(alignment: .trailing) {
                ProfileBadgeColumn(badges: rightBadges, alignment: .leading, viewerBadgeKindIds: viewerBadgeKindIds)
                    .alignmentGuide(.trailing) { d in d[.leading] - gap }
            }
    }
}

// MARK: - Previews

/// Mirrors the exact composition `UserPageView.pageHeader` builds via `AvatarBadgeFlanking`: a
/// vertical guide line is drawn through the avatar's centre so a shifted avatar is visible at a
/// glance rather than requiring a ruler; see `AvatarBadgeCenteringTests` for the actual
/// pixel-identical assertion this preview can only eyeball. A stand-in avatar circle since these
/// previews live outside `UserPageView` and have no real photo to load.
private struct FlankPreview: View {
    let badges: [ProfileBadge]
    var viewerBadgeKindIds: Set<String> = []
    @Environment(\.flimAccent) private var accent

    var body: some View {
        let split = ProfileBadgeFlank.split(badges)
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            AvatarBadgeFlanking(leftBadges: split.left, rightBadges: split.right, viewerBadgeKindIds: viewerBadgeKindIds) {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 88, height: 88)
                    .overlay(Text("C").flimFont(32, weight: .thin, relativeTo: .title3).foregroundStyle(accent))
                    .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 4))
                    .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
                    .overlay {
                        // 1pt centre guide: the avatar's frame is exactly what this preview should
                        // never move, so this line must sit on it at every badge count.
                        Rectangle().fill(Color.red.opacity(0.6)).frame(width: 1)
                            .frame(width: 88, alignment: .center)
                    }
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
        previewBadge("cover_to_cover", .coverToCover),   // the longest label in the catalog
        previewBadge("shared", .shared),
        previewBadge("darkroom", .darkroom),
        previewBadge("chipped_in", .chippedIn),
    ])
    .frame(width: 375)   // iPhone SE width, the narrowest device FLIM still supports
    .dynamicTypeSize(FlimTypeScale.maximum)
}

#Preview("Flanking: uniform pill width at 1 through 4 badges") {
    // The regression this guards: an earlier version capped each pill at `maxWidth: 84`, a
    // ceiling rather than a fixed width, so only "Founding 100" (the widest label at the time)
    // ever actually reached it — every shorter pill sized to its own content instead, and the
    // two flanking columns read visibly uneven widths against each other. `BadgePillLabel` now
    // renders every pill at the same fixed 84pt regardless of label length, so a short label like
    // "Shared" and a long one like "Founding 100" produce identically sized pills, checked here
    // at every count `ProfileBadgeFlank` can actually produce.
    VStack(spacing: 24) {
        FlankPreview(badges: [previewBadge("shared", .shared)])
        FlankPreview(badges: [
            previewBadge("shared", .shared),
            previewBadge("founding_100", .founding100),
        ])
        FlankPreview(badges: [
            previewBadge("shared", .shared),
            previewBadge("founding_100", .founding100),
            previewBadge("darkroom", .darkroom),
        ])
        FlankPreview(badges: [
            previewBadge("shared", .shared),
            previewBadge("founding_100", .founding100),
            previewBadge("darkroom", .darkroom),
            previewBadge("front_row", .frontRow),
        ])
    }
    .padding(.vertical, 20)
    .background(FlimTheme.bg)
}

#Preview("Badge tiers: all four side by side") {
    // One representative badge per tier (see `ProfileBadgeTier`): gold solid (hand-granted),
    // gold tinted (era), accent solid (hard-earned), accent tinted (common) — reading left to
    // right should show hue (gold vs accent) and fill weight (solid vs tinted) as two
    // independent, legible signals rather than four arbitrary colours.
    VStack(spacing: 20) {
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                BadgePillLabel(kind: .founder)
                Text("Gold · solid").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
            VStack(spacing: 6) {
                BadgePillLabel(kind: .founding100)
                Text("Gold · tinted").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
        }
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                BadgePillLabel(kind: .frontRow)
                Text("Accent · solid").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
            VStack(spacing: 6) {
                BadgePillLabel(kind: .shared)
                Text("Accent · tinted").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
        }
        HStack(spacing: 14) {
            VStack(spacing: 6) {
                BadgePillLabel(kind: .founder, muted: true)
                Text("Locked, gold").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
            VStack(spacing: 6) {
                BadgePillLabel(kind: .frontRow, muted: true)
                Text("Locked, accent").flimFont(10, relativeTo: .caption2).foregroundStyle(FlimTheme.textTertiary)
            }
        }
    }
    .padding(30)
    .background(FlimTheme.bg)
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

import SwiftUI
import UIKit

/// The permanent signup number, set like an edge number on film stock: small, monospaced,
/// tabular figures, low contrast. It must never read as tappable or editable, unlike Lapse's
/// signup-number chip sitting next to "Star sign" and "School/College" as one more editable
/// field, so this is plain `Text`, not a button or a capsule.
struct FrameNumberLabel: View {
    let number: Int

    var body: some View {
        // The numero sign, not a letter o: the design writes the frame number as film-edge
        // marking, and "No 12" reads as the word no beside a digit.
        Text("\u{2116} \(number)")
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
    /// The badge whose explanation currently owns the page's handle line, if any. The matching
    /// pill lifts; every other pill steps back. See `UserPageView`'s swap-in.
    var liftedBadgeId: String? = nil
    /// The page's swap-in handler. Optional so previews and layout tests can render pills
    /// without wiring the whole interaction.
    var onBadgeTap: ((ProfileBadge) -> Void)? = nil

    var body: some View {
        // 18pt between two stacked pills on the same side matches each pill's own 9pt tap-target
        // expansion (see `ProfileBadgePill`): 9 down from the one above plus 9 up from the one
        // below meets exactly at the midpoint rather than overlapping, the same rule
        // `expandTapTarget`'s own doc comment gives for any two tappable neighbours this close.
        VStack(alignment: alignment, spacing: 18) {
            ForEach(badges) { badge in
                ProfileBadgePill(
                    badge: badge,
                    lifted: liftedBadgeId == badge.id,
                    dimmed: liftedBadgeId != nil && liftedBadgeId != badge.id,
                    onTap: onBadgeTap
                )
            }
        }
    }
}

/// The width every pill in one group renders at: the widest label among them, measured directly.
///
/// Pills used to size to their own text, which read as objects rather than form fields but left
/// four medals of four different widths flanking an avatar, and that reads as untidy. Neither a
/// global constant nor per-label hugging is right: a constant has to be wide enough for the
/// longest label in the whole catalogue, so most pills carry dead space for a word they will never
/// show, and hugging gives up on alignment entirely. The answer is per-GROUP uniformity: whatever
/// four badges a profile is showing, all four match the widest of those four and no wider.
///
/// The first attempt collected widths through a `PreferenceKey` and fed the maximum back down
/// through the environment. It shipped a truncated FOUNDING 100 on a real profile, because the
/// flanking columns are `.overlay`s attached AFTER the modifier that was supposed to be measuring
/// them: the pills sat outside the subtree doing the collecting, so the group settled on a width
/// derived from an incomplete set. That is a genuinely fiddly failure mode, invisible in a
/// preview, and the lesson is that layout feedback loops are the wrong tool when the answer can
/// simply be computed.
///
/// So it is computed. `NSAttributedString` measures the same string, at the same weight, with the
/// same tracking, which is exactly what CoreText will lay out; the only thing that has to be kept
/// in step by hand is the horizontal padding, named once here and used by `BadgePillLabel`.
/// `UIFontMetrics` applies the same Dynamic Type curve `flimFont(_:relativeTo: .caption2)` applies,
/// so this does not silently clip at larger text sizes, which is the obvious way a measured-width
/// approach goes wrong.
enum BadgePillMetrics {
    /// Base point size and tracking, matching `BadgePillLabel`'s own `flimFont`/`tracking` call.
    static let pointSize: CGFloat = 10
    static let tracking: CGFloat = 0.6
    /// Padding either side of the label inside the capsule.
    static let horizontalPadding: CGFloat = 12

    /// The width that fits the widest of `kinds`, including padding. `nil` for an empty set, which
    /// callers pass straight through to mean "size to your own label".
    static func uniformWidth(for kinds: [ProfileBadgeKind]) -> CGFloat? {
        guard !kinds.isEmpty else { return nil }
        let scaled = UIFontMetrics(forTextStyle: .caption2).scaledValue(for: pointSize)
        let font = UIFont.systemFont(ofSize: scaled, weight: .semibold)
        let widest = kinds
            .map { kind -> CGFloat in
                let text = kind.label.uppercased() as NSString
                return text.size(withAttributes: [.font: font, .kern: tracking]).width
            }
            .max() ?? 0
        // `size(withAttributes:)` adds the trailing kern after the final glyph; keeping it is the
        // safe direction to be wrong in, since a point of slack cannot truncate anything.
        return widest.rounded(.up) + horizontalPadding * 2
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
    /// Sizes every `BadgePillLabel` inside this view to fit the widest of `kinds`.
    func uniformBadgePillWidths(for kinds: [ProfileBadgeKind]) -> some View {
        environment(\.uniformBadgePillWidth, BadgePillMetrics.uniformWidth(for: kinds))
    }
}

/// A slow highlight travelling across a pill, on a long loop, for the founding rung.
///
/// It exists because that rung is closed: `founder`, `foundingCrew` and `founding100` are the only
/// badges nothing new can ever join, and the question was how to mark that without inventing a
/// sixth tier. A platinum or diamond rung was the obvious answer and the wrong one: those are cool
/// white-blues, silver is already a cool blue-grey (deliberately, because neutral grey against
/// near-black reads as disabled), and at ten points a platinum pill lands in silver's neighbourhood
/// and reads as LOWER than gold rather than higher. That spends the top of the ladder on a colour
/// that looks like the middle of it. Motion says "singular" without touching the colour system.
///
/// It started as one sweep on appear, on `founder` alone, on the reasoning that a pill which
/// shimmers forever is a casino. Widened to the whole rung and put on a loop at the owner's
/// request, with two things kept from the original argument: the resting gap is far longer than
/// the sweep (roughly eight seconds against one), so the pill is still and unremarkable almost all
/// of the time; and each pill carries its own offset, so two founding badges on one profile never
/// fire together. Simultaneous sweeps read as a screen effect washing over the page, which is
/// exactly the casino version; staggered ones read as two separate objects catching the light.
///
/// Skipped entirely under Reduce Motion, where the pill keeps its gradient and rim and never
/// animates. The loop lives in `.task`, so it is cancelled the moment the pill leaves the screen
/// rather than ticking on behind a pushed view.
private struct SpecularSweep: View {
    /// Seconds this pill waits before its first sweep, so a profile's founding pills stagger
    /// instead of flashing in unison. Derived from the badge, so it is stable across redraws.
    let phaseOffset: Double
    /// True while this pill is lifted by the swap-in: a highlight travelling across a pill that
    /// is also scaled up and glowing is two effects fighting over one object. Pausing restarts
    /// the loop from its phase offset on resume, which is indistinguishable from any other rest.
    var paused: Bool = false

    @State private var travelled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// One pass across the pill.
    private static let sweepDuration: Double = 1.15
    /// Still time between passes. Long on purpose: this is chrome, not a progress indicator.
    private static let restDuration: Double = 8

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
                .task(id: paused) {
                    // Restarted whenever `paused` flips. On pause the band snaps home FIRST, so a
                    // pass that was mid-flight when the lift landed is not left frozen across the
                    // pill; on resume the loop starts over from its phase offset.
                    var reset = Transaction()
                    reset.disablesAnimations = true
                    withTransaction(reset) { travelled = false }
                    guard !reduceMotion, !paused else { return }
                    // Lets the page settle before the first pass: a sweep firing during the
                    // navigation transition is noise competing with the push animation.
                    try? await Task.sleep(for: .seconds(0.45 + phaseOffset))
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: Self.sweepDuration)) { travelled = true }
                        try? await Task.sleep(for: .seconds(Self.sweepDuration))
                        // Snapped back, and the transaction is what GUARANTEES that. A bare
                        // assignment is only unanimated if nothing ambient is in flight, and a
                        // profile has plenty in flight: any `withAnimation` running on a parent
                        // when this fires would adopt the change and drag the highlight backwards
                        // across the pill, so each cycle would read as two sweeps rather than one.
                        var reset = Transaction()
                        reset.disablesAnimations = true
                        withTransaction(reset) { travelled = false }
                        try? await Task.sleep(for: .seconds(Self.restDuration))
                    }
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
    /// Freezes the founding sweep while this pill is lifted by the swap-in; see `SpecularSweep`.
    var sweepPaused: Bool = false
    @Environment(\.flimAccent) private var accent

    private var tier: ProfileBadgeTier { kind.tier }
    private var hue: Color { tier.hue(accent: accent) }
    @Environment(\.uniformBadgePillWidth) private var uniformWidth

    var body: some View {
        Text(kind.label.uppercased())
            .flimFont(BadgePillMetrics.pointSize, weight: .semibold, relativeTo: .caption2)
            .tracking(BadgePillMetrics.tracking)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .foregroundStyle(muted ? hue.opacity(0.75) : tier.foreground(accent: accent))
            .padding(.horizontal, BadgePillMetrics.horizontalPadding)
            .padding(.vertical, 6)
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
                            if tier == .founding, !muted {
                                SpecularSweep(phaseOffset: kind.sweepPhaseOffset, paused: sweepPaused)
                                    .clipShape(Capsule())
                            }
                        }
                        .overlay(
                            Capsule().strokeBorder(tier.rim(accent: accent), lineWidth: 0.75)
                        )
                        .shadow(color: tier.glow(accent: accent), radius: 5, y: 1)
                }
            }
            // A pill states its own size and refuses to be compressed into whatever its container
            // proposes. Belt and braces next to the group width above: if that width is ever nil
            // again, for any reason, the worst case is a ragged row of correct pills rather than a
            // truncated label. Horizontal only, so Dynamic Type can still grow the height.
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// One earned badge, printed as a small capsule pill whose fill/hue reads its tier at a glance
/// (see `ProfileBadgeTier`), not the dated stamp this replaced. No earned date anywhere on it:
/// eleven dated stamps were the bulk of what made the old grid read as busy, and with the count
/// now capped at four, the pill can just be a name.
///
/// Tapping no longer opens a popover. The old bubble anchored to the pill and sat straight over
/// the name and handle it was supposed to be annotating; the explanation now swaps INTO the
/// page's own handle line instead, owned by `UserPageView`. This view only reports the tap
/// upward and renders the two states the swap-in gives a pill: LIFTED (this pill's explanation
/// owns the line) and DIMMED (some other pill's does). The visible pill stays small on purpose,
/// so the tap target is grown to Apple's 44pt minimum without changing what's on screen.
///
/// Under VoiceOver the swap-in is skipped entirely upstream (a timed visual swap is hostile to
/// a screen reader); the pill carries the explanation as its hint so nothing is lost.
struct ProfileBadgePill: View {
    let badge: ProfileBadge
    /// This pill's explanation currently owns the handle line: lift it off the page a touch.
    var lifted: Bool = false
    /// Another pill's explanation owns the line: step back so the lifted one reads as chosen.
    var dimmed: Bool = false
    /// The page's swap-in handler. Optional so previews and layout tests can render pills
    /// without wiring the whole interaction; with no handler a tap does nothing visible.
    var onTap: ((ProfileBadge) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one spring the whole swap-in shares: the lift, the sibling dim, and the drop on
    /// revert all trade on it, so the pills read as one system settling rather than three
    /// effects firing.
    static let spring: Animation = .spring(response: 0.32, dampingFraction: 0.78)

    var body: some View {
        Button {
            Haptics.tap()
            onTap?(badge)
        } label: {
            BadgePillLabel(kind: badge.kind, sweepPaused: lifted)
        }
        .buttonStyle(.plain)
        .expandTapTarget(by: 9)   // visual pill is ~26pt tall, +9 either side = 44
        // Reduce Motion keeps the shadow and the dim (static emphasis) and drops the lift
        // (movement). The spec's own rule: no translate, no pill lift, sibling dim stays.
        .scaleEffect(lifted && !reduceMotion ? 1.06 : 1)
        .offset(y: lifted && !reduceMotion ? -2 : 0)
        .shadow(color: lifted ? FlimTheme.badgeGold.opacity(0.5) : .clear, radius: 5, y: 1)
        .opacity(dimmed ? 0.4 : 1)
        .animation(Self.spring, value: lifted)
        .animation(Self.spring, value: dimmed)
        .accessibilityLabel("badge, \(badge.kind.label)")
        .accessibilityHint(badge.kind.explanation)
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
    /// See `ProfileBadgeColumn`: which pill is lifted by the swap-in, and the tap handler.
    /// Defaulted so previews and `AvatarBadgeCenteringTests` construct layout without behavior.
    var liftedBadgeId: String? = nil
    var onBadgeTap: ((ProfileBadge) -> Void)? = nil
    /// Matches the old HStack's `spacing: 14` this replaced.
    var gap: CGFloat = 14
    @ViewBuilder let avatar: () -> Avatar

    var body: some View {
        avatar()
            .overlay(alignment: .leading) {
                ProfileBadgeColumn(badges: leftBadges, alignment: .trailing,
                                   liftedBadgeId: liftedBadgeId, onBadgeTap: onBadgeTap)
                    .alignmentGuide(.leading) { d in d[.trailing] + gap }
            }
            .overlay(alignment: .trailing) {
                ProfileBadgeColumn(badges: rightBadges, alignment: .leading,
                                   liftedBadgeId: liftedBadgeId, onBadgeTap: onBadgeTap)
                    .alignmentGuide(.trailing) { d in d[.leading] - gap }
            }
            // AFTER both overlays, not before. Attached to `avatar()` alone, the environment
            // value never reaches the pills: overlay content is not a child of the view the
            // overlay is attached to, so it inherits from out here instead. That was the second
            // time this exact ordering broke the pill width, the first through a PreferenceKey
            // that collected nothing and this time through an environment value that arrived nil,
            // and a pill with no imposed width takes the overlay's proposal, which is the avatar's
            // 88 points. FOUNDING 100 truncated inside it.
            //
            // Both columns are one group on purpose, so the left pair matches the right rather
            // than each column only matching itself.
            .uniformBadgePillWidths(for: (leftBadges + rightBadges).map(\.kind))
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
    @Environment(\.flimAccent) private var accent

    var body: some View {
        let split = ProfileBadgeFlank.split(badges)
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
            AvatarBadgeFlanking(leftBadges: split.left, rightBadges: split.right) {
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

#Preview("Flanking: renamed 'Plus One' pill") {
    // `broughtSomeone` used to truncate to "BROUGHT SO…" at this size under its old label.
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


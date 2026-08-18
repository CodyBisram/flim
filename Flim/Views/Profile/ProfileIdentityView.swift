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

/// The stamp row that anchors a profile's identity below the name/handle.
///
/// This used to also carry a film-stats line ("128 frames · 9 rolls · since Aug 2026") beneath
/// the stamps. That line is gone: it duplicated the social counts row `UserPageView` already
/// renders just below this strip ("40 shared · 47 followers · 47 following" already says how
/// much this account has shared), so it told an overlapping fact twice. `ProfileFilmStats` and
/// `FeedService.fetchProfileFilmStats` still exist for a future caller, they're just not fetched
/// here anymore, see `UserPageView.load()`.
///
/// Renders NOTHING when a profile has no badges: that's the brand-new-account case, and it must
/// not read as an empty grid the way Lapse's "0 friends 😢" does. The signup number above this
/// (see `FrameNumberLabel`) is the one thing a new account already has, so it carries the empty
/// state instead of a placeholder here.
struct ProfileIdentityStrip: View {
    let identity: ProfileIdentity
    /// Badge ids earned but never shown to their owner yet. Only ever non-empty when this strip
    /// is rendering the SIGNED-IN account's own profile: `UserPageView` never fetches this for
    /// anyone else, so a stranger's profile always passes the default empty set and nothing here
    /// ever animates on it, regardless of what the server would say.
    var unseenBadgeIds: Set<String> = []
    /// Fired exactly once, after every unseen stamp has actually finished pressing onto the
    /// page, never merely on fetch. `UserPageView` calls `FeedService.markOwnBadgesSeen()` from
    /// here, which is the only moment that's safe: a load that gets backgrounded, or a view that
    /// never finishes appearing, must not be able to burn the ceremony, see that call site.
    var onUnseenBadgesRevealed: (() -> Void)?
    /// The signed-in account's own earned badge kind ids (see `FeedService.viewerBadgeKindIds`),
    /// so a tapped stamp for a badge the viewer doesn't hold can add "how to earn this" to its
    /// popover. On the viewer's own profile every badge shown here is already one they hold, so
    /// `UserPageView` passes this profile's own badge kinds right back in that case and the line
    /// never shows.
    var viewerBadgeKindIds: Set<String> = []
    /// Non-nil ONLY when this strip is rendering the SIGNED-IN account's own profile. Its own
    /// row always returns every earned badge (see `identity.badges`), which is exactly the
    /// asymmetry this exists to make legible: without it, an owner with a dozen badges has no
    /// way to learn that a stranger's copy of this same profile only ever shows four of them.
    /// `UserPageView` is the only call site that ever sets this, and only for `isSelf`.
    var ownVisibility: OwnBadgeVisibility? = nil
    @Environment(\.flimAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stagger between one stamp pressing in and the next, and how long a single press animates.
    /// Both feed `body`'s `.task` below so the completion callback fires exactly once the last
    /// stamp has actually landed, not a fixed guess independent of how many are animating.
    private static let stampStagger: Double = 0.16
    private static let stampPressDuration: Double = 0.5

    var body: some View {
        VStack(spacing: 14) {
            if !identity.badges.isEmpty {
                if let ownVisibility {
                    ownContent(entries: unseenOrderedBadges, visibility: ownVisibility)
                } else {
                    stampRow(unseenOrderedBadges)
                }
            }
        }
        // Keyed on the unseen set itself: it's set once, together with `identity`, when
        // `UserPageView.load()` first resolves (see that method), so this fires once per profile
        // visit, never again on a later pull-to-refresh that leaves the set unchanged.
        .task(id: unseenBadgeIds) {
            let unseenCount = identity.badges.filter { unseenBadgeIds.contains($0.id) }.count
            guard unseenCount > 0 else { return }
            let pressDuration = reduceMotion ? 0.05 : Self.stampPressDuration
            let totalDuration = Double(unseenCount - 1) * Self.stampStagger + pressDuration
            try? await Task.sleep(for: .seconds(totalDuration))
            onUnseenBadgesRevealed?()
        }
    }

    /// Every badge paired with its position among the UNSEEN ones only (`nil` for an already-seen
    /// badge), so the stagger counts stamps that are actually animating rather than the whole row
    /// including ones that just sit there.
    private var unseenOrderedBadges: [(badge: ProfileBadge, unseenIndex: Int?)] {
        var nextUnseenIndex = 0
        return identity.badges.map { badge in
            guard unseenBadgeIds.contains(badge.id) else { return (badge, nil) }
            let index = nextUnseenIndex
            nextUnseenIndex += 1
            return (badge, index)
        }
    }

    /// The plain wrapping row of stamps, unchanged from before `ownVisibility` existed. Used
    /// as-is for a stranger's profile, and reused (on subsets) for the owner's own split below.
    private func stampRow(_ entries: [(badge: ProfileBadge, unseenIndex: Int?)]) -> some View {
        // A wrapping layout, not an `HStack`: see `ProfileStampFlowLayout` for why an
        // unconstrained row here used to widen every ancestor up to the `ScrollView`.
        ProfileStampFlowLayout {
            ForEach(entries, id: \.badge.id) { entry in
                ProfileStampView(
                    badge: entry.badge,
                    isUnseen: entry.unseenIndex != nil,
                    revealDelay: Double(entry.unseenIndex ?? 0) * Self.stampStagger,
                    viewerBadgeKindIds: viewerBadgeKindIds
                )
            }
        }
        .padding(.horizontal, 24)
    }

    /// The owner's own view of their badges: split into what a stranger actually sees and
    /// everything else, or an honest "we can't say exactly which" banner when nobody has chosen
    /// yet. See `OwnBadgeVisibility.split(entries:)` for what each branch means and why the
    /// automatic case can't be split the same way the explicit one can.
    @ViewBuilder
    private func ownContent(entries: [(badge: ProfileBadge, unseenIndex: Int?)], visibility: OwnBadgeVisibility) -> some View {
        if let split = OwnBadgeVisibility.split(entries: entries, selection: visibility.selection) {
            VStack(spacing: 14) {
                if split.shown.isEmpty {
                    // Deliberately chosen to show none (`displayed_badges = '{}'`), not the
                    // absence of a choice — see `OwnBadgeVisibility.split` for how this is told
                    // apart from the automatic case below.
                    Text("You’ve chosen not to show any of these. Only you can see the \(split.hidden.count) you’ve earned.")
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                } else {
                    stampRow(split.shown)
                }
                if !split.hidden.isEmpty {
                    VStack(spacing: 10) {
                        sectionHeading("Also earned")
                        stampRow(split.hidden)
                    }
                }
                manageLink(visibility.onManage, title: split.shown.isEmpty ? "Choose some to show" : "Change what shows here")
            }
        } else {
            // No choice made: the server leads with the four rarest automatically, and there is
            // no path for the owner's own row to learn WHICH four that resolves to (see
            // `profile_badges`'s owner branch, which always returns everything regardless of who
            // asks) — so this deliberately does not try to split the row, only says so plainly.
            // Skipped entirely once there's nothing to hide (4 or fewer badges total means the
            // automatic default already shows every one of them).
            VStack(spacing: 10) {
                if entries.count > 4 {
                    Text("You’ve earned \(entries.count). Only 4 show here for everyone else, picked automatically for now.")
                        .flimFont(12, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                    manageLink(visibility.onManage, title: "Choose which ones show")
                }
                stampRow(entries)
            }
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text.uppercased())
            .flimFont(11, weight: .medium, relativeTo: .caption)
            .tracking(2.5)
            .foregroundStyle(FlimTheme.textTertiary)
    }

    private func manageLink(_ action: @escaping () -> Void, title: String) -> some View {
        Button(action: action) {
            Text(title)
                .flimFont(12, weight: .semibold, relativeTo: .caption)
                .foregroundStyle(accent)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
    }
}

/// What the signed-in account's own profile knows about the split between what a stranger sees
/// and everything else, passed down from `UserPageView` (the only place that reads
/// `AuthService.currentUser?.displayedBadges`, which only ever arrives for the signed-in account
/// itself).
struct OwnBadgeVisibility {
    /// The raw `displayed_badges` value: `nil` (no choice made), `[]` (chosen to show none), or
    /// an explicit ordered list. See `AppUser.displayedBadges` for why these three are kept
    /// distinct rather than collapsed.
    let selection: [String]?
    /// Opens `BadgePickerSheet`.
    let onManage: () -> Void

    /// Splits `entries` into what a stranger sees (`shown`, in the caller's own chosen order)
    /// and everything else (`hidden`, in whatever order `entries` already carries), or `nil` when
    /// `selection` is `nil` — there is no such split to compute client-side for the automatic
    /// default: it depends on how many OTHER accounts hold each badge, data this profile's own
    /// row has no access to (`profile_badges`'s rarity ranking is computed entirely server-side,
    /// see that migration's PART 2). Defensive against a `selection` id that doesn't match
    /// anything in `entries` (shouldn't happen, `earned_badges` never un-earns, but this is a
    /// read path, not the write path that already enforces that).
    static func split(
        entries: [(badge: ProfileBadge, unseenIndex: Int?)],
        selection: [String]?
    ) -> (shown: [(badge: ProfileBadge, unseenIndex: Int?)], hidden: [(badge: ProfileBadge, unseenIndex: Int?)])? {
        guard let selection else { return nil }
        let selectedIds = Set(selection)
        let shown = selection.compactMap { id in entries.first { $0.badge.id == id } }
        let hidden = entries.filter { !selectedIds.contains($0.badge.id) }
        return (shown, hidden)
    }
}

/// Wraps stamps onto as many centred lines as needed instead of one ever-widening row.
///
/// A plain `HStack` reports the sum of every stamp's width as ITS size, and once that's wider
/// than the screen the overflow doesn't just clip in place: a `VStack` is exactly as wide as its
/// widest child, so that oversized width propagates back down through every ancestor up to the
/// `ScrollView`. That's what the six-badge overflow bug actually was, not three separate bugs:
/// the trailing-pinned signup number and the purple invite button both live in siblings of this
/// row, and once the page's own content measured wider than the device, everything anchored to a
/// trailing edge got pushed off past the right side of the screen while the row itself clipped at
/// both edges (`ScrollView` clips its content to its own bounds by default).
///
/// This layout caps itself at whatever width its parent proposes and wraps instead, so it can
/// never widen an ancestor again regardless of how many badges a profile earns.
private struct ProfileStampFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 18
    var verticalSpacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let maxWidth = proposal.width ?? .infinity
        let rows = rows(for: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        // Never wider than what was proposed — that's the entire fix. Only falls back to the
        // widest row's own width when the parent proposed an unbounded width in the first place
        // (e.g. a preview with no bounding container).
        let width = maxWidth.isFinite ? maxWidth : (rows.map(\.width).max() ?? 0)
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = rows(for: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX + (bounds.width - row.width) / 2
            for item in row.items {
                item.subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(item.size))
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }

    /// Greedily fills a row until the next stamp would push it past `maxWidth`, then starts a new
    /// one. Every stamp reports a fixed size regardless of what's proposed to it (see
    /// `ProfileStampView`'s own `.frame(width: 92)`), so `.unspecified` here just asks each one
    /// for that fixed size rather than trying to shrink it — the same reason this grows at large
    /// Dynamic Type sizes by wrapping sooner (each stamp gets taller, never wider) instead of by
    /// compressing anything.
    private func rows(for subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var items: [Item] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let widthIfAdded = items.isEmpty ? size.width : rowWidth + horizontalSpacing + size.width
            if maxWidth.isFinite, !items.isEmpty, widthIfAdded > maxWidth {
                rows.append(Row(items: items, width: rowWidth, height: rowHeight))
                items = []
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth = items.isEmpty ? size.width : rowWidth + horizontalSpacing + size.width
            rowHeight = max(rowHeight, size.height)
            items.append(Item(subview: subview, size: size))
        }
        if !items.isEmpty {
            rows.append(Row(items: items, width: rowWidth, height: rowHeight))
        }
        return rows
    }
}

/// One earned badge, printed like a stamp on a photograph: uppercase label with generous
/// tracking, the earned month below flanked by middots, a hairline rule underneath. Muted by
/// default, no accent, no trophy chrome.
///
/// Locked badges never appear anywhere in the app, so someone seeing a stranger's stamp has no
/// other way to learn what it means; tapping it reveals a low-chrome popover with one line of
/// explanation. The visible stamp itself stays small (it must not compete with the signup
/// number's quietness), so the tap target is grown to Apple's 44pt minimum without changing
/// what's on screen.
private struct ProfileStampView: View {
    let badge: ProfileBadge
    var isUnseen: Bool = false
    var revealDelay: Double = 0
    /// The viewer's own earned badge kind ids; see `ProfileIdentityStrip.viewerBadgeKindIds`.
    var viewerBadgeKindIds: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showExplanation = false
    /// Whether the stamp has finished landing. Starts `true` (nothing to animate) for every
    /// already-seen badge, so this view only ever plays the press for one nobody has watched
    /// land yet.
    @State private var pressed: Bool

    init(badge: ProfileBadge, isUnseen: Bool = false, revealDelay: Double = 0, viewerBadgeKindIds: Set<String> = []) {
        self.badge = badge
        self.isUnseen = isUnseen
        self.revealDelay = revealDelay
        self.viewerBadgeKindIds = viewerBadgeKindIds
        _pressed = State(initialValue: !isUnseen)
    }

    /// "How to earn this" only makes sense for a badge the viewer doesn't already hold; showing
    /// it under a badge they have too would just be noise under their own stamp.
    private var howToEarn: String? {
        viewerBadgeKindIds.contains(badge.kind.rawValue) ? nil : badge.kind.howToEarn
    }

    var body: some View {
        Button {
            Haptics.tap()
            showExplanation = true
        } label: {
            VStack(spacing: 5) {
                Text(badge.kind.label.uppercased())
                    .flimFont(10, weight: .semibold, relativeTo: .caption2)
                    .tracking(1.6)
                    .foregroundStyle(FlimTheme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(monthText)
                    .flimFont(9, relativeTo: .caption2)
                    .tracking(0.5)
                    .foregroundStyle(FlimTheme.textTertiary)
                Rectangle()
                    .fill(FlimTheme.stroke)
                    .frame(height: 1)
            }
            .frame(width: 92)
        }
        .buttonStyle(.plain)
        .expandTapTarget(by: 9)
        // Pressed onto the page: an unseen stamp starts lifted, tilted and faint, like it's still
        // in the air, then lands at rest with a firm, slightly overshooting spring. An
        // already-seen stamp starts (and stays) at rest, so this costs it nothing.
        .scaleEffect(pressed ? 1 : 1.4)
        .rotationEffect(.degrees(pressed ? 0 : -9))
        .opacity(pressed ? 1 : 0)
        .task {
            guard isUnseen else { return }
            try? await Task.sleep(for: .seconds(revealDelay))
            if reduceMotion {
                pressed = true
            } else {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.62)) { pressed = true }
            }
            Haptics.reveal()   // the same soft-knock-then-success cue as a roll finishing developing
        }
        // `arrowEdge: .top` is already the default, stated explicitly here: the point is to keep
        // it, rather than let the system reach for a sideways edge to force the popover onto
        // screen. That only used to happen because the anchoring stamp itself could be
        // off-screen (see the overflow bug above) or crowded against a neighbour by the same
        // unconstrained row; a wrapped, on-screen stamp has real room above/below it, so the
        // system keeps the vertical arrow instead of flipping sideways into a neighbouring stamp.
        .popover(isPresented: $showExplanation, arrowEdge: .top) {
            BadgeExplanationPopover(explanation: badge.kind.explanation, howToEarn: howToEarn)
                .presentationCompactAdaptation(.popover)
                .presentationBackground(FlimTheme.bgElevated)
        }
        .accessibilityLabel(isUnseen ? "\(badge.kind.label), new, earned \(monthText)" : "\(badge.kind.label), earned \(monthText)")
        .accessibilityHint("Double tap to hear what this stamp means")
    }

    private var monthText: String {
        "·\(badge.earnedAt.formatted(.dateTime.month(.abbreviated).year()))·".uppercased()
    }
}

/// The stamp popover's content, factored out of `ProfileStampView.body` so it can be sized
/// correctly and previewed on its own without a live tap.
///
/// Two things were wrong before: the text truncated with an ellipsis, and the box could point
/// sideways into a neighbouring stamp (fixed at the `.popover` call site via `arrowEdge: .top`).
/// The truncation was purely a sizing bug, not a text-length one — `Text` had no `lineLimit` set,
/// but a `maxWidth` alone leaves the popover free to first collapse toward a single-line ideal
/// size and clip whatever didn't fit, rather than actually measuring the wrapped height. Giving
/// it a concrete, fixed width instead of a flexible max is what makes the `Text`s below wrap in
/// the first place, and `.fixedSize(horizontal: false, vertical: true)` then forces this view to
/// report ITS true wrapped height back to the popover container instead of an ambiguous guess.
private struct BadgeExplanationPopover: View {
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

#Preview("With stamps, stranger's profile (how-to state)") {
    // Mirrors what UserPageView passes while looking at someone else's profile for badges the
    // viewer doesn't hold: tapping any of these three adds "how to earn this" under the
    // explanation. See `viewerBadgeKindIds` below, deliberately empty here.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 37)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(
                    signupNumber: 37,
                    badges: [
                        ProfileBadge(id: "1", kind: .fullRoll, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 2).date ?? .now),
                        ProfileBadge(id: "2", kind: .darkroom, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 14).date ?? .now),
                        ProfileBadge(id: "3", kind: .firstIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 9, day: 1).date ?? .now),
                    ]
                ),
                viewerBadgeKindIds: []
            )
        }
        .padding(.vertical, 40)
    }
}

#Preview("With stamps, badge already held (no how-to line)") {
    // Same three stamps, but the viewer already holds Full Roll and Darkroom themselves (e.g.
    // their own profile, or a stranger's where they've separately earned those two). Tapping
    // either shows only the explanation; tapping First In still adds the how-to line.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 37)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(
                    signupNumber: 37,
                    badges: [
                        ProfileBadge(id: "1", kind: .fullRoll, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 2).date ?? .now),
                        ProfileBadge(id: "2", kind: .darkroom, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 14).date ?? .now),
                        ProfileBadge(id: "3", kind: .firstIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 9, day: 1).date ?? .now),
                    ]
                ),
                viewerBadgeKindIds: [ProfileBadgeKind.fullRoll.rawValue, ProfileBadgeKind.darkroom.rawValue]
            )
        }
        .padding(.vertical, 40)
    }
}

#Preview("Brand new profile") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 4108)
            }
            .padding(.horizontal, 28)
            // No badges: this view renders nothing below the number, on purpose.
            ProfileIdentityStrip(identity: ProfileIdentity(signupNumber: 4108, badges: []))
        }
        .padding(.vertical, 40)
    }
}

#Preview("Newly earned badge (reveal)") {
    // Mirrors what UserPageView passes on your own profile the first time you see a badge you
    // just earned: two already-seen stamps sit still, the newest one presses onto the page.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 37)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(
                    signupNumber: 37,
                    badges: [
                        ProfileBadge(id: "1", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 2).date ?? .now),
                        ProfileBadge(id: "2", kind: .darkroom, earnedAt: DateComponents(calendar: .current, year: 2026, month: 7, day: 14).date ?? .now),
                        ProfileBadge(id: "3", kind: .fullRoll, earnedAt: .now),
                    ]
                ),
                unseenBadgeIds: ["3"],
                // Own profile: every badge shown is one the viewer already holds, so no how-to
                // line ever shows here, matching what `UserPageView.load()` passes for `isSelf`.
                viewerBadgeKindIds: [ProfileBadgeKind.firstLight.rawValue, ProfileBadgeKind.darkroom.rawValue, ProfileBadgeKind.fullRoll.rawValue]
            )
        }
        .padding(.vertical, 40)
    }
}

// MARK: - Wrap-layout regression coverage (one, six, fourteen badges)
//
// These exist specifically so the row-overflow bug can't come back silently: one badge must
// still read as deliberate rather than a stray fragment, six is the exact count from the device
// report that started this, and fourteen is the full catalog (all twelve automatic kinds plus
// the two hand-granted ones) now that `joined_in`, `chipped_in`, `shared`, `well_met`, and
// `full_house` are real cases rather than a queued five.

#Preview("Wrap: one badge") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 4108)
            }
            .padding(.horizontal, 28)
            // A single stamp should still read as deliberate, centred typography, not like a
            // one-cell grid with a dangling remainder.
            ProfileIdentityStrip(
                identity: ProfileIdentity(
                    signupNumber: 4108,
                    badges: [
                        ProfileBadge(id: "1", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 2).date ?? .now),
                    ]
                ),
                viewerBadgeKindIds: [ProfileBadgeKind.firstLight.rawValue]
            )
        }
        .padding(.vertical, 40)
    }
}

#Preview("Wrap: six badges (device parity)") {
    // The exact count from the on-device report, Founding 100 first (the stamp that was clipped
    // by the left edge): must wrap onto multiple centred lines, never overflow the screen.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 37)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(
                    signupNumber: 37,
                    badges: [
                        ProfileBadge(id: "1", kind: .founding100, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 2).date ?? .now),
                        ProfileBadge(id: "2", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 3).date ?? .now),
                        ProfileBadge(id: "3", kind: .fullRoll, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 20).date ?? .now),
                        ProfileBadge(id: "4", kind: .darkroom, earnedAt: DateComponents(calendar: .current, year: 2026, month: 7, day: 1).date ?? .now),
                        ProfileBadge(id: "5", kind: .firstIn, earnedAt: DateComponents(calendar: .current, year: 2026, month: 7, day: 14).date ?? .now),
                        ProfileBadge(id: "6", kind: .rollMaker, earnedAt: DateComponents(calendar: .current, year: 2026, month: 8, day: 1).date ?? .now),
                    ]
                ),
                viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue))
            )
        }
        .padding(.vertical, 40)
    }
}

/// Every `ProfileBadgeKind`, one stamp each, for the wrap-layout stress previews below: the full
/// fourteen-badge catalog is now a realistic count (twelve automatic, plus the two hand-granted
/// ones a founding/test account could also hold), not a padded fixture the way the old
/// eleven-badge version was before these five kinds existed for real.
private let allCatalogStampBadges: [ProfileBadge] = ProfileBadgeKind.allCases
    .enumerated()
    .map { index, kind in
        ProfileBadge(
            id: "\(index)",
            kind: kind,
            earnedAt: DateComponents(calendar: .current, year: 2026, month: 1 + (index % 12), day: 1).date ?? .now
        )
    }

#Preview("Wrap: fourteen badges (full catalog)") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 12)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(signupNumber: 12, badges: allCatalogStampBadges),
                viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue))
            )
        }
        .padding(.vertical, 40)
    }
}

#Preview("Wrap: fourteen badges, largest Dynamic Type, narrowest device") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        VStack(spacing: 20) {
            HStack {
                Spacer()
                FrameNumberLabel(number: 12)
            }
            .padding(.horizontal, 28)
            ProfileIdentityStrip(
                identity: ProfileIdentity(signupNumber: 12, badges: allCatalogStampBadges),
                viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue))
            )
        }
        .padding(.vertical, 40)
    }
    .frame(width: 375)   // iPhone SE width, the narrowest device FLIM still supports
    .dynamicTypeSize(FlimTypeScale.maximum)
}

#Preview("Stamp explanation popover: longest copy, largest Dynamic Type, narrowest device") {
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

// MARK: - Owner's own-profile visibility split
//
// `ownVisibility` only ever appears on the signed-in account's own profile (see `UserPageView`).
// These cover the three states `displayed_badges` can actually be, plus the two edges called out
// explicitly in the brief: nothing to hide (<=4 badges under the automatic default), and a
// deliberate "show none" with a non-empty explicit hidden group.
//
// `id` here is set to the KIND's raw value, matching real production rows
// (`FeedService.fetchProfileBadges` sets `id: row.badge_id`, and `badge_id` IS the raw value) —
// unlike `allCatalogStampBadges` above (index-as-id, fine for THAT preview, which never compares
// ids against a selection), `OwnBadgeVisibility.split` matches on `id`, so these fixtures need
// the real string or every preview below would show an empty "shown" group.
private let ownVisibilityPreviewBadges: [ProfileBadge] = ProfileBadgeKind.allCases
    .filter { $0 != .foundingCrew && $0 != .testRoll }   // hand-granted, not earnable, kept out
    .enumerated()
    .map { index, kind in
        ProfileBadge(
            id: kind.rawValue,
            kind: kind,
            earnedAt: DateComponents(calendar: .current, year: 2026, month: 1 + (index % 12), day: 1).date ?? .now
        )
    }

#Preview("Own profile: automatic default, twelve badges (asymmetry banner)") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        ProfileIdentityStrip(
            identity: ProfileIdentity(signupNumber: 37, badges: ownVisibilityPreviewBadges),
            viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue)),
            ownVisibility: OwnBadgeVisibility(selection: nil, onManage: {})
        )
        .padding(.vertical, 40)
    }
}

#Preview("Own profile: automatic default, three badges (no asymmetry, no banner)") {
    // Fewer than the cap: the automatic default already shows every badge, so there is nothing
    // to disclose and the banner must not appear.
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        ProfileIdentityStrip(
            identity: ProfileIdentity(signupNumber: 4108, badges: [
                ProfileBadge(id: "first_light", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 2).date ?? .now),
                ProfileBadge(id: "shared", kind: .shared, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 20).date ?? .now),
                ProfileBadge(id: "well_met", kind: .wellMet, earnedAt: DateComponents(calendar: .current, year: 2026, month: 7, day: 1).date ?? .now),
            ]),
            viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue)),
            ownVisibility: OwnBadgeVisibility(selection: nil, onManage: {})
        )
        .padding(.vertical, 40)
    }
}

#Preview("Own profile: explicit selection, four shown, rest grouped") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        ProfileIdentityStrip(
            identity: ProfileIdentity(signupNumber: 37, badges: ownVisibilityPreviewBadges),
            viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue)),
            ownVisibility: OwnBadgeVisibility(
                selection: ["darkroom", "founding_100", "first_in", "full_house"],
                onManage: {}
            )
        )
        .padding(.vertical, 40)
    }
}

#Preview("Own profile: chosen to show none") {
    ZStack {
        FlimTheme.bg.ignoresSafeArea()
        ProfileIdentityStrip(
            identity: ProfileIdentity(signupNumber: 37, badges: [
                ProfileBadge(id: "first_light", kind: .firstLight, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 2).date ?? .now),
                ProfileBadge(id: "shared", kind: .shared, earnedAt: DateComponents(calendar: .current, year: 2026, month: 6, day: 20).date ?? .now),
            ]),
            viewerBadgeKindIds: Set(ProfileBadgeKind.allCases.map(\.rawValue)),
            ownVisibility: OwnBadgeVisibility(selection: [], onManage: {})
        )
        .padding(.vertical, 40)
    }
}

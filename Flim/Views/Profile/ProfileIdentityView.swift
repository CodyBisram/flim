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

/// The stamp row + film-stats line that anchor a profile's identity below the name/handle.
/// Renders NOTHING when a profile has no badges and no stats: that's the brand-new-account case,
/// and it must not read as an empty grid the way Lapse's "0 friends 😢" does. The signup number
/// above this (see `FrameNumberLabel`) is the one thing a new account already has, so it carries
/// the empty state instead of a placeholder here.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Stagger between one stamp pressing in and the next, and how long a single press animates.
    /// Both feed `body`'s `.task` below so the completion callback fires exactly once the last
    /// stamp has actually landed, not a fixed guess independent of how many are animating.
    private static let stampStagger: Double = 0.16
    private static let stampPressDuration: Double = 0.5

    var body: some View {
        VStack(spacing: 14) {
            if !identity.badges.isEmpty {
                HStack(alignment: .top, spacing: 18) {
                    ForEach(unseenOrderedBadges, id: \.badge.id) { entry in
                        ProfileStampView(
                            badge: entry.badge,
                            isUnseen: entry.unseenIndex != nil,
                            revealDelay: Double(entry.unseenIndex ?? 0) * Self.stampStagger,
                            viewerBadgeKindIds: viewerBadgeKindIds
                        )
                    }
                }
            }
            if identity.hasStats {
                Text(statsLine)
                    .flimFont(12, relativeTo: .caption)
                    .foregroundStyle(FlimTheme.textTertiary)
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

    private var statsLine: String {
        let frames = "\(identity.frameCount) frame\(identity.frameCount == 1 ? "" : "s")"
        let rolls = "\(identity.rollCount) roll\(identity.rollCount == 1 ? "" : "s")"
        guard let shootingSince = identity.shootingSince else { return "\(frames) · \(rolls)" }
        let since = "since \(shootingSince.formatted(.dateTime.month(.abbreviated).year()))"
        return "\(frames) · \(rolls) · \(since)"
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
        .popover(isPresented: $showExplanation) {
            VStack(spacing: 10) {
                Text(badge.kind.explanation)
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
            .padding(16)
            .frame(maxWidth: 240)
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
                    ],
                    frameCount: 128,
                    rollCount: 9,
                    shootingSince: DateComponents(calendar: .current, year: 2026, month: 8, day: 1).date ?? .now
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
                    ],
                    frameCount: 128,
                    rollCount: 9,
                    shootingSince: DateComponents(calendar: .current, year: 2026, month: 8, day: 1).date ?? .now
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
            // No badges, no stats: this view renders nothing below the number, on purpose.
            ProfileIdentityStrip(identity: ProfileIdentity(
                signupNumber: 4108,
                badges: [],
                frameCount: 0,
                rollCount: 0,
                shootingSince: nil
            ))
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
                    ],
                    frameCount: 42,
                    rollCount: 4,
                    shootingSince: DateComponents(calendar: .current, year: 2026, month: 6, day: 1).date ?? .now
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

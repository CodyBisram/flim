import SwiftUI

/// A user's public page, profile header + their shared photos grouped into monthly chapters.
struct UserPageView: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let userId: UUID
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    @State private var profile: UserProfile?
    @State private var identity: ProfileIdentity?
    /// Whether the signed-in account has any earned badge it hasn't seen revealed yet, only ever
    /// fetched for `isSelf`. Drives the small "new badge" pill below the bio (see `pageHeader`),
    /// which is now the only place this reveal is announced: the profile itself shows just the
    /// four badges a stranger sees (`displayedBadges` below), so a newly earned badge outside
    /// that four would never appear here even if this view tried to animate it in directly. The
    /// actual reveal — and the `markOwnBadgesSeen()` call that clears both this and the tab dot —
    /// happens in `BadgePickerSheet`, the one place the owner's full collection is ever shown.
    /// How many badges this account has earned but never been shown. A count rather than a flag
    /// because the pill has to say "New badge" or "3 new badges", and a Bool throws away the one
    /// fact the copy needs before the view ever sees it.
    @State private var unseenBadgeCount = 0
    /// The signed-in account's own resolved "what a stranger sees right now" badge ids, own
    /// profile only, in display order. `nil` until fetched or on any failure, in which case
    /// `displayedBadges` below shows nothing rather than falling back to the full earned set. See
    /// `FeedService.fetchOwnEffectiveDisplayedBadgeIds`.
    @State private var effectiveDisplayedBadgeIds: [String]?
    @State private var posts: [Post] = []
    /// Signed URLs for the grid's thumbnails, keyed by `displayPath` (matching `PostThumb`'s own
    /// cache key), minted in one batched call per page-load rather than one round trip per
    /// cell. `PostThumb` still falls back to its own per-cell mint for anything a batch missed
    /// (a straggler post that arrived after the batch already resolved).
    @State private var postThumbURLs: [String: URL] = [:]
    @State private var avatarURL: URL?
    @State private var coverURL: URL?
    @State private var followers = 0
    @State private var following = 0
    /// The "shared" stat. Distinct from `posts.count`, which is zero until the grid's own fetch
    /// lands and made the whole stats row flash 0 on every open; this seeds from the session
    /// cache (see `FeedService.profileStatsCache`) and settles to the real count when posts do.
    @State private var sharedCount = 0
    /// Whether the stats row has ANY real numbers to show (session cache or a completed
    /// load). Until then the row shows placeholders rather than confident zeroes: 0 / 0 / 0
    /// is a claim about a person, and for a first visit it was almost always false.
    @State private var statsKnown = false
    @State private var loaded = false
    @State private var followList: FollowList?
    @State private var showSettings = false
    @State private var showEditProfile = false
    @State private var showBadgePicker = false
    /// The storage path behind `coverURL`, whichever of its three sources produced it. See load().
    @State private var coverPath: String?

    // MARK: Badge swap-in

    /// The badge whose explanation currently owns the handle line; nil whenever the handle is
    /// (or is returning to being) the thing shown. Driving the pill lift/dim from this and the
    /// text from `lastShown` below is what lets the two part ways during a fade-out.
    @State private var shownBadge: ProfileBadge?
    /// The badge whose text is actually rendered, kept through the fade-out. Without it, a
    /// revert would clear the model and the line would fall back to a DIFFERENT badge's copy
    /// (or nothing) while still visible mid-fade, which reads as a flicker of the wrong words.
    @State private var lastShown: ProfileBadge?
    /// Layer visibility, separate per side because each direction has its own curve: the spec's
    /// OUT/IN pair on show, and the deliberately slower pair on revert.
    @State private var handleLineVisible = true
    @State private var badgeLineVisible = false
    /// The hold-then-revert clock. Cancelled and replaced on every interrupt: same pill (early
    /// dismiss), other pill (crossfade and restart), scroll, or leaving the screen.
    @State private var swapRevertTask: Task<Void, Never>?
    /// Until this instant, the page refuses to believe the server about unseen badges.
    ///
    /// Set when the picker closes, because closing marks everything seen. A one-shot flag was
    /// tried first and only covered the FIRST reload after closing; the save-time reload, the
    /// dismiss-time reload, and any refresh the page does can all be in flight at once, land in
    /// any order, and each can carry a count read before the server-side mark committed. A time
    /// window covers every one of them regardless of order or number. Fifteen seconds is far
    /// beyond any plausible propagation, and when it expires the server is trusted again, which
    /// is what lets a genuinely new badge raise the pill next time.
    @State private var badgesLocallySeenUntil: Date?
    @State private var showInvite = false
    @State private var showAvatarViewer = false
    @Environment(\.dismiss) private var dismiss

    private var isSelf: Bool { userId == auth.currentUser?.id }
    private var isFollowing: Bool { feed.isFollowing(userId) }
    private var isBlocked: Bool { feed.isBlocked(userId) }
    private var followsMe: Bool { feed.followsMe(userId) }

    /// Exactly what a stranger sees on this profile right now, at most four, oldest-fetched
    /// order preserved. `identity.badges` for a stranger's own row is already this list
    /// (`profile_badges`'s non-owner branch resolves it server-side), but for `isSelf` that same
    /// row returns EVERY earned badge — the picker's own source list, not this page's — so this
    /// re-derives the profile's four from `effectiveDisplayedBadgeIds` instead. A failed round
    /// trip there degrades to showing nothing, never to falling back to the full earned set: this
    /// page must never show the owner more than a stranger would see.
    private var displayedBadges: [ProfileBadge] {
        // Matches the old strip's own `!isBlocked` check: a blocked account's page shows the
        // dedicated `blockedState` panel below instead of the post grid, badges shouldn't linger
        // above it either.
        guard !isBlocked, let identity else { return [] }
        guard isSelf else { return identity.badges }
        guard let effectiveDisplayedBadgeIds else { return [] }
        let byId = Dictionary(uniqueKeysWithValues: identity.badges.map { ($0.id, $0) })
        return effectiveDisplayedBadgeIds.compactMap { byId[$0] }
    }

    /// The badges the header actually shows, off the front of `displayedBadges`.
    ///
    /// TWO, not four (owner call 2026-08-29, kept when the left-aligned layout was reverted): the
    /// brief was to quiet the top down. The order it takes them in is already correct and must
    /// not be re-sorted here. `displayedBadges` is the owner's own chosen order when they have
    /// picked, and RAREST-first when they have not, so the front of the list is the scarcest pair
    /// either way; sorting by anything else would silently override a choice made in the picker.
    ///
    /// Two costs discovery, since a stranger's pill is the only way anyone learns a badge exists.
    /// That is the trade, and it is why which two matters.
    private var visibleBadges: [ProfileBadge] {
        Array(displayedBadges.prefix(Self.headerBadgeLimit))
    }

    /// How many badges the header shows. The picker enforces the same number; see
    /// `BadgePickerSheet`, which also explains why STORAGE stays at four.
    static let headerBadgeLimit = 2

    /// `visibleBadges` split into the two columns that flank the avatar; see `ProfileBadgeFlank`.
    /// At two badges this is one a side, which is exactly the case the split was written for.
    private var badgeFlanks: (left: [ProfileBadge], right: [ProfileBadge]) {
        ProfileBadgeFlank.split(visibleBadges)
    }


    var body: some View {
        GeometryReader { geo in
            ZStack {
                FlimTheme.bg.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                        pageHeader(topInset: geo.safeAreaInsets.top)
                        if isBlocked {
                            blockedState
                        } else if loaded && profile == nil {
                            // No profile came back, so the page has nothing real on it. Offer a
                            // retry instead of an empty grid under a blank header.
                            ErrorState(message: "Couldn't load this profile.") { await load() }
                                .padding(.top, 30)
                        } else if !loaded && posts.isEmpty {
                            // First visit this session, nothing seeded from `profilePostsCache`:
                            // a shimmer grid instead of the blank void under the header while
                            // the real fetch is still in flight.
                            skeletonGrid
                        } else if posts.isEmpty && loaded {
                            emptyState
                        } else {
                            ForEach(monthlySections, id: \.key) { section in
                                monthSection(label: section.key, posts: section.posts)
                            }
                        }
                    }
                    .padding(.bottom, 30)
                }
                .ignoresSafeArea(edges: .top)   // cover bleeds up under the back/gear buttons
                .refreshable { await load() }
                // A finger on the page ends the swap-in at once: an explanation that rides the
                // scroll pins attention to a line the person has already moved past.
                .onScrollPhaseChange { _, newPhase in
                    // `.tracking` is the finger landing, `.interacting` is it moving; either one
                    // means attention left the header.
                    if newPhase == .tracking || newPhase == .interacting { dismissSwapInstantly() }
                }
                .onDisappear { dismissSwapInstantly() }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)   // let the cover show under the back/gear
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isSelf {
                    Button { showSettings = true } label: {
                        Image(systemName: "gearshape").foregroundStyle(accent)
                    }
                    .accessibilityLabel("Settings")
                } else {
                    Menu {
                        Button { reportAccount() } label: { Label("Report", systemImage: "flag") }
                        if feed.isBlocked(userId) {
                            Button {
                                guard let uid = auth.currentUser?.id else { return }
                                Task { await feed.unblock(userId, from: uid) }
                            } label: { Label("Unblock", systemImage: "hand.raised.slash") }
                        } else {
                            Button(role: .destructive) { blockAccount() } label: { Label("Block", systemImage: "hand.raised") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(accent)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .task { await load() }
        .sheet(item: $followList) { list in
            FollowListView(userId: userId, mode: list)
        }
        .sheet(isPresented: $showSettings, onDismiss: { Task { await load() } }) {
            ProfileView()
        }
        .sheet(isPresented: $showEditProfile, onDismiss: { Task { await load() } }) {
            EditProfileView()
        }
        // The reload starts at SAVE (behind the sheet's cover), not at dismissal: refreshed on
        // dismiss, the new pill set and the vanished "new badges" pill landed a beat after the
        // profile was already back on screen, a pop and reflow right where the eye was resting.
        // The onDismiss reload stays as the Cancel path's refresh and as the catch-all.
        .sheet(isPresented: $showBadgePicker, onDismiss: { Task { await load() } }) {
            BadgePickerSheet(onSaved: { Task { await load() } })
        }
        .onChange(of: showBadgePicker) { _, showing in
            guard showing else {
                // Arm the clamp window at dismissal START, not in onDismiss. dismiss() flips
                // this flag immediately and then the slide-down plays for ~0.4s before onDismiss
                // fires; the save-time reload lands inside exactly that crack, and with the
                // window armed only at the end, it trusted a stale server count and flashed the
                // pill one more time. The flag flipping false IS the moment of knowledge.
                badgesLocallySeenUntil = Date().addingTimeInterval(15)
                return
            }
            // Once the sheet fully covers the page, retire the "new badges to see" pill where
            // nobody can watch it vanish. Dismissing the picker marks everything seen no matter
            // how it closes, so this is early knowledge, not a guess; if the app dies mid-sheet
            // the server was never told and the pill honestly returns next launch.
            guard unseenBadgeCount > 0 else { return }
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                guard showBadgePicker else { return }   // already closed: let load() decide
                withAnimation(.easeInOut(duration: 0.25)) { unseenBadgeCount = 0 }
            }
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
        }
        .fullScreenCover(isPresented: $showAvatarViewer) {
            ImageViewer(url: avatarURL, cacheKey: profile?.avatarPath)
        }
    }

    // Undo-first (confirmations redesign rule 1): commit optimistically, stage the server
    // call behind the shared undo capsule. Closures capture services and plain values only.

    private func reportAccount() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        let handle = profile?.handle ?? "this account"
        let targetId = userId
        let feedService = feed
        UndoCenter.shared.stage(
            title: "Reported \(handle)",
            failureText: "Couldn't send that report",
            commit: { await feedService.reportUser(targetId, from: uid) })
    }

    private func blockAccount() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.warning()
        let handle = profile?.handle ?? "this account"
        let targetId = userId
        let feedService = feed
        // The page stays put during the window (undo would have nothing to come back to
        // otherwise); it only closes once the block has actually landed, same rule as before.
        let leave = dismiss
        UndoCenter.shared.stage(
            title: "Blocked \(handle), and unfollowed them",
            subtitle: "Reversible in Blocked accounts",
            failureText: "Couldn't block \(handle)",
            commit: {
                await feedService.block(targetId, from: uid)
                guard feedService.isBlocked(targetId) else { return false }
                feedService.feed.removeAll { $0.author.id == targetId }
                leave()
                return true
            })
    }

    private func pageHeader(topInset: CGFloat) -> some View {
        VStack(spacing: 12) {
            // Cover banner extends up behind the nav bar (topInset), so the back/gear overlap it.
            ZStack(alignment: .bottom) {
                Rectangle()
                    .fill(FlimTheme.bgElevated)
                    .frame(height: 150 + topInset)
                    .overlay {
                        if let coverURL {
                            CachedImage(url: coverURL, maxPixel: 1000, cacheKey: coverPath) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                        }
                    }
                    // Darken the top (under the status bar) + fade into the page at the bottom,
                    // with EXPLICIT stops so there is a real band of untouched photograph between
                    // the two.
                    //
                    // Three bare colours spaced themselves evenly, which put "clear" at exactly the
                    // halfway line: the top half was progressively darkened and the bottom half
                    // progressively swallowed, so the cover was only ever at full strength along a
                    // single hairline and every photo read as washed out. The scrim also did not
                    // need to be that broad. The back and gear buttons carry their own circular
                    // scrims, so the only thing genuinely relying on this is the status bar text
                    // across the top few points.
                    .overlay(LinearGradient(
                        stops: [
                            .init(color: .black.opacity(0.5), location: 0),
                            .init(color: .clear,              location: 0.30),
                            .init(color: .clear,              location: 0.62),
                            .init(color: FlimTheme.bg,        location: 1.0),
                        ],
                        startPoint: .top, endPoint: .bottom))
                    .clipped()
                // Earned badges flank the avatar, two per side at most: see `ProfileBadgeFlank`
                // for how an odd count is split so neither side ever reads as a stray, empty gap.
                // Both `isSelf` and a stranger's profile pass the exact same `displayedBadges`
                // list here, there is no wider "everything you've earned" view left on this page,
                // that now lives only in `BadgePickerSheet`.
                //
                // Each column is an OVERLAY on the avatar's own frame, not a sibling in a shared
                // HStack: a shared HStack centres the whole row as a group, so a single badge on
                // one side (nothing opposite it) visibly shoves the avatar off-centre, worse the
                // wider that one label is. See `AvatarBadgeFlanking` for why an overlay keeps the
                // avatar's centre fixed regardless of badge count or label width.
                AvatarBadgeFlanking(leftBadges: badgeFlanks.left, rightBadges: badgeFlanks.right,
                                    liftedBadgeId: shownBadge?.id,
                                    onBadgeTap: { badgeTapped($0) }) {
                    Button { if avatarURL != nil { showAvatarViewer = true } } label: {
                        avatarCircle
                    }
                    .buttonStyle(.plain)
                }
                .offset(y: 44)
            }
            .padding(.bottom, 44)

            VStack(spacing: 4) {
                Text(profile?.name ?? "…")
                    .flimFont(22, weight: .light, relativeTo: .title3).foregroundStyle(.white)
                // The handle stays visually centered; the signup number is pinned to the
                // trailing edge of the same row instead of its own line, quiet enough that it
                // reads like an edge number on film stock rather than a second headline.
                //
                // This row is also the badge swap-in's target: tap a pill and the whole line
                // (handle AND number together) gives way to that badge's explanation, then
                // returns. Both layers are permanently in the tree at the same single-line text
                // size, so the ZStack's height is identical whichever is visible and the page
                // below never shifts. The old design was a popover anchored to the pill, which
                // sat exactly on top of the name it was annotating.
                //
                // ONE line is a copy constraint, not a layout accident: `BadgeSwapLineTests`
                // fails the build if any badge's explanation cannot fit here at full size, so
                // new copy gets shortened rather than the layout getting taller. Two earlier
                // attempts to solve it in layout instead (scaling the longest copy to 0.52, then
                // reserving a two-line box) each produced their own bug on device, an illegible
                // squint and then a handle drifting away from its name.
                ZStack {
                    ZStack {
                        Text(profile?.handle ?? "@…")
                            .flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                        if let identity {
                            HStack {
                                Spacer()
                                FrameNumberLabel(number: identity.signupNumber)
                            }
                        }
                    }
                    .opacity(handleLineVisible ? 1 : 0)
                    .offset(y: handleLineVisible || reduceMotion ? 0 : 4)
                    badgeSwapLine
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 28)
                // A transparency disclosure, not a vanity badge: FLIM's feed is private and
                // follow-gated, so this literally means "this person can see what you post".
                // Neutral tone/colour on purpose, it isn't a stat to be proud of.
                if !isSelf && !isBlocked && FeedService.FollowRelationship.showsFollowsYouBadge(followsMe: followsMe) {
                    Text("Follows you")
                        .flimFont(11, weight: .medium, relativeTo: .caption)
                        .foregroundStyle(FlimTheme.textTertiary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.white.opacity(0.08), in: Capsule())
                }
            }

            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }

            // The only place left on the profile that announces a new badge: the badges
            // themselves no longer animate in here (this page shows just the two a stranger
            // sees, and a newly earned badge may not even be among them). Tapping through opens
            // the picker, the one place the full collection — and the actual reveal — lives; see
            // `BadgePickerSheet`.
            if isSelf, unseenBadgeCount > 0 {
                Button {
                    Haptics.tap()
                    showBadgePicker = true
                } label: {
                    // Singular stays wordless rather than "1 new badge to see": a leading "1"
                    // reads as a counter on something that is really an invitation. Past one, the
                    // number is worth saying, because how many are waiting changes whether you
                    // open it now or later.
                    Label(unseenBadgeCount == 1
                          ? "New badge to see"
                          : "\(unseenBadgeCount) new badges to see",
                          systemImage: "sparkles")
                        .flimFont(12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .expandTapTarget(by: 8)   // visual pill is ~28pt tall, +8 either side = 44
            }

            HStack(spacing: 26) {
                stat(statsKnown ? "\(sharedCount)" : "–", "shared")
                Button { followList = .followers } label: { stat(statsKnown ? "\(followers)" : "–", "followers") }
                Button { followList = .following } label: { stat(statsKnown ? "\(following)" : "–", "following") }
            }

            // No follow affordance on a blocked account, the dedicated blocked-state panel
            // below (with its own Unblock) replaces it.
            if !isSelf && !isBlocked {
                Button { toggleFollow() } label: {
                    Text(FeedService.FollowRelationship.buttonLabel(following: isFollowing, followsMe: followsMe))
                        .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(isFollowing ? .white : .black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(isFollowing ? Color.white.opacity(0.12) : accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(isFollowing ? Color.white.opacity(0.2) : .clear, lineWidth: 1))
                }
                .padding(.horizontal, 40)
                .padding(.top, 2)
            } else if isSelf {
                // Editing your identity happens here, on your profile, not inside the settings
                // sheet. Invite friends sits beside it as the accent action, since bringing your
                // circle in is the point of an invite-only app.
                HStack(spacing: 10) {
                    Button { showEditProfile = true } label: {
                        Text("Edit profile")
                            .flimFont(14, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(Color.white.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    Button { showInvite = true } label: {
                        Label("Invite", systemImage: "person.badge.plus")
                            .flimFont(14, weight: .semibold).foregroundStyle(.black)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(accent, in: Capsule())
                    }
                }
                .padding(.horizontal, 40)
                .padding(.top, 2)
            }
        }
    }

    private var avatarCircle: some View {
        Circle()
            .fill(accent.opacity(0.18))
            .frame(width: 88, height: 88)
            .overlay {
                if let avatarURL {
                    CachedImage(url: avatarURL, maxPixel: 220, cacheKey: profile?.avatarPath) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(String((profile?.username ?? "?").prefix(1)).uppercased())
                        .flimFont(32, weight: .thin, relativeTo: .title3).foregroundStyle(accent)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 4))
            .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
    }

    /// What the "new badges to see" pill may show, given what the page knows locally.
    ///
    /// The server's count races the picker. Dismissing the picker marks every badge seen, but
    /// that write and this page's reloads are separate round trips, and any reload whose read
    /// predates the mark carries the old count. While the picker is up, and for the window after
    /// it closes (`badgesLocallySeenUntil`), the count is clamped to zero: the page KNOWS those
    /// badges are seen or about to be, and local knowledge outranks a stale read.
    private func unseenBadgeCount(from fetched: Int) -> Int {
        if showBadgePicker { return 0 }
        if let until = badgesLocallySeenUntil, Date() < until { return 0 }
        return fetched
    }

    // MARK: - Badge swap-in    // MARK: - Badge swap-in

    /// The line that takes the handle's place while a badge is explaining itself.
    ///
    /// Renders from `lastShown`, never from `shownBadge`: during a revert the model is already
    /// nil (that is what drops the pill and undims its siblings) while this text is still fading
    /// out, and it must keep fading out as the SAME words. Present in the tree even before any
    /// tap, at zero opacity, so showing it never inserts a view mid-animation.
    private var badgeSwapLine: some View {
        let kind = lastShown?.kind
        let text = kind.map { "\($0.emoji) \($0.explanation)" } ?? ""
        return Text(text)
            .flimFont(BadgeSwapMetrics.pointSize, relativeTo: .footnote)
            .lineLimit(1)
            .minimumScaleFactor(BadgeSwapMetrics.minimumScale)
            .foregroundStyle(kind.map { badgeSwapColor(for: $0) } ?? .clear)
            // The 250ms in-place crossfade for tap-another-pill and for the second beat: the
            // words and colour trade without the layer itself moving.
            .contentTransition(.opacity)
            .opacity(badgeLineVisible ? 1 : 0)
            .offset(y: badgeLineVisible || reduceMotion ? 0 : -3)
            // Sharpening in from a slight blur is the film-develop cue, deliberate, and dropped
            // wholesale under Reduce Motion.
            .blur(radius: badgeLineVisible || reduceMotion ? 0 : 2)
            .allowsHitTesting(false)
    }

    /// The swapped line's colour: the metal the badge is struck from, or the viewer's accent for
    /// the accent rung. Founding and gold share the LIGHT gold, not the mid gold the pill
    /// gradient uses, because 13pt text against the near-black page needs the brighter cut of
    /// the same metal to stay legible.
    private func badgeSwapColor(for kind: ProfileBadgeKind) -> Color {
        switch kind.tier {
        case .founding, .gold: return FlimTheme.badgeGoldLight
        case .silver:          return FlimTheme.badgeSilver
        case .bronze:          return FlimTheme.badgeBronze
        case .accent:          return accent
        }
    }

    private func badgeTapped(_ badge: ProfileBadge) {
        // VoiceOver gets the words and none of the theatre: a timed visual swap a screen-reader
        // user cannot see would just be state churn under their focus. The pill's own hint
        // already carries the explanation; activating announces it and nothing else happens.
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: badge.kind.explanation)
            return
        }
        if let current = shownBadge {
            if current.id == badge.id {
                // Same pill: dismiss early. Revert now, clock cancelled.
                swapRevertTask?.cancel()
                revertSwap()
            } else {
                // Other pill: trade the words and colour in place, no bounce back to the handle
                // in between. The lift and dim move to the new pill on the shared spring via
                // `shownBadge`; the clock starts over for the new badge.
                withAnimation(.easeInOut(duration: 0.25)) {
                    shownBadge = badge
                    lastShown = badge
                }
                scheduleSwapRevert()
            }
            return
        }
        shownBadge = badge
        lastShown = badge
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                handleLineVisible = false
                badgeLineVisible = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { handleLineVisible = false }
            withAnimation(.easeOut(duration: 0.45).delay(0.1)) { badgeLineVisible = true }
        }
        scheduleSwapRevert()
    }

    /// The clock. 2.75s from the tap covers the show (the IN beat lands at 0.55s) plus the 2.2s
    /// hold, then the revert runs.
    ///
    /// One beat, deliberately. A second beat used to follow for a badge the viewer did not hold:
    /// the line crossfaded from the explanation to `howToEarn`. It was cut on 2026-08-21 because
    /// it turned one clear sentence about the person whose profile you are on into two, and the
    /// second one was about YOU. The place to learn how to earn a badge is the picker, which
    /// prints `howToEarn` plainly and is still the only surface that does.
    private func scheduleSwapRevert() {
        swapRevertTask?.cancel()
        swapRevertTask = Task {
            try? await Task.sleep(for: .seconds(2.75))
            guard !Task.isCancelled else { return }
            revertSwap()
        }
    }

    /// The full revert, deliberately the slowest beat: the page settling back matters more than
    /// it snapping back. `shownBadge` clears on the pills' own shared spring so the lift and the
    /// sibling dim let go together; `lastShown` is left alone so the departing words stay THESE
    /// words all the way out.
    private func revertSwap() {
        withAnimation(ProfileBadgePill.spring) { shownBadge = nil }
        if reduceMotion {
            withAnimation(.easeInOut(duration: 0.3)) {
                badgeLineVisible = false
                handleLineVisible = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.6)) { badgeLineVisible = false }
            withAnimation(.easeInOut(duration: 0.55).delay(0.12)) { handleLineVisible = true }
        }
    }

    /// Scroll or navigation: the explanation must not ride down the page or linger behind a
    /// pushed view, so everything settles in one plain fade with no travel.
    private func dismissSwapInstantly() {
        guard shownBadge != nil || badgeLineVisible else { return }
        swapRevertTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            shownBadge = nil
            badgeLineVisible = false
            handleLineVisible = true
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).flimFont(16, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.28), value: value)
            Text(label).flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
        }
    }

    private func monthSection(label: String, posts: [Post]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(label.uppercased())
                    .flimFont(12, weight: .medium, relativeTo: .caption).tracking(2)
                    .foregroundStyle(FlimTheme.textSecondary)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            }
            .padding(.horizontal, 16)

            // Film, not a grid: rows of frames on a perforated road, the way the Darkroom
            // reads. The month is the strip, so a month of eight photographs ends its last
            // strip after two frames rather than ruling a line out to the margin.
            FilmStripGrid(items: posts) { post in
                Group {
                    if let author = profile {
                        // DO NOT add a zoom transition here. This grid opened the wrong photo
                        // through four attempted fixes, and the only thing the broken versions
                        // ever had in common was the `matchedTransitionSource` +
                        // `navigationTransition(.zoom:)` pair added on top of this link. Three
                        // different navigation forms were tried underneath it (eager destination,
                        // value-based, item-based) and every one misbehaved while those two
                        // modifiers were present: it pushed the detail view built for a
                        // previously-opened post, carrying that instance's state, so a tap could
                        // land on the earlier photo already showing its full-screen viewer.
                        //
                        // This is the plain push the screen shipped with and used correctly for
                        // the app's entire life before that commit. The zoom is a cosmetic upgrade
                        // and was not worth the cost; the Darkroom and roll grids still have
                        // theirs, and they are fine because they present via fullScreenCover(item:)
                        // rather than a navigation push.
                        NavigationLink { PostDetailView(item: FeedItem(post: post, author: author)) } label: {
                            PostThumb(path: post.displayPath, resolvedURL: postThumbURLs[post.displayPath])
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 3)
        }
    }

    /// Twelve shimmer frames on the same perforated road `monthSection` draws, so the page does
    /// not reflow when the real posts replace it. Twelve is four full strips, which means the
    /// skeleton never shows a SHORT last strip and so never promises a month that ends where this
    /// one happens to.
    private var skeletonGrid: some View {
        FilmStripGrid(items: (0..<12).map(SkeletonFrame.init)) { _ in
            Color.clear
                .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
                .overlay { ShimmerPlaceholder(cornerRadius: 3) }
        }
        .padding(.horizontal, 3)
    }

    /// `FilmStripGrid` lays out identified items; the skeleton has none, so this stands in.
    private struct SkeletonFrame: Identifiable { let id: Int }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
            Text(isSelf ? "You haven't posted anything yet" : "No posts yet")
                .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
        }
        .padding(.top, 40)
    }

    /// Replaces the post grid + follow affordance for a blocked account, mirrors
    /// BlockedUsersSheet's language and Unblock pill so the undo path stays consistent.
    private var blockedState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised.slash")
                .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
            Text("You blocked \(profile?.handle ?? "this account")")
                .flimFont(15, weight: .medium, relativeTo: .body).foregroundStyle(.white)
            Text("You won't see their posts, and they won't see yours.")
                .flimFont(13, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button {
                guard let uid = auth.currentUser?.id else { return }
                Haptics.tap()
                Task { await feed.unblock(userId, from: uid) }
            } label: {
                Text("Unblock")
                    .flimFont(13, weight: .semibold, relativeTo: .subheadline).foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(accent, in: Capsule())
            }
            .padding(.top, 6)
        }
        .padding(.top, 40)
    }

    private var monthlySections: [(key: String, posts: [Post])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: posts) { cal.dateComponents([.year, .month], from: $0.takenAt) }
        return groups.keys
            .sorted { ($0.year ?? 0, $0.month ?? 0) > ($1.year ?? 0, $1.month ?? 0) }
            .compactMap { comp in
                guard let date = cal.date(from: comp) else { return nil }
                let label = date.formatted(.dateTime.month(.wide).year())
                return (label, (groups[comp] ?? []).sorted { $0.takenAt > $1.takenAt })
            }
    }

    private func load() async {
        // The app usually already knows who this is: the feed unit or tag the tap came from
        // carries the whole profile. Seeding it paints the real handle, name and avatar
        // initial in the first frame, and the avatar's signed URL is almost always already
        // in the session cache (the feed's little band avatar signed the same path), so the
        // picture itself follows immediately rather than after four racing fetches.
        if profile == nil, let known = feed.knownProfile(id: userId) {
            profile = known
            if let path = known.avatarPath { avatarURL = await feed.signedURL(for: path) }
        }
        // Stale-while-revalidate for the stats row: the last counts this session saw go on
        // screen in the FIRST frame, before a single round trip, and the fetches below quietly
        // correct anything that moved. Without this, every visit flashed 0 / 0 / 0 while four
        // requests raced back, which read as the page forgetting who you are.
        if sharedCount == 0, followers == 0, following == 0,
           let cached = feed.profileStatsCache[userId] {
            (sharedCount, followers, following) = cached
            statsKnown = true
        }
        // Same contract for the grid itself: paint the posts this session last saw here in the
        // first frame (their images are already in DiskImageCache, so the whole page appears at
        // once), then let the fetch below quietly reconcile. Deliberately NOT a skip-if-cached:
        // the fetch still runs every visit, because visibility can change with no new post.
        if posts.isEmpty, let cachedPosts = feed.profilePostsCache[userId] {
            posts = cachedPosts
            // Fire-and-forget: this must not delay the `async let`s kicked off right after it.
            Task { await mintThumbURLs(for: cachedPosts) }
        }
        // Captured before any `await` below so the one write it guards (`effectiveDisplayedBadgeIds`,
        // see below) can't land after an account switch mid-flight: this is a pure read with
        // nothing else in this function to protect for correctness, so nothing else here needs it.
        let epoch = AccountEpoch.current
        async let p = feed.fetchProfile(id: userId)
        async let ps = feed.fetchUserPosts(userId: userId)
        async let fr = feed.followerCount(userId)
        async let fg = feed.followingCount(userId)
        async let bd = feed.fetchProfileBadges(userId)
        // Own profile only, one more round trip alongside everything else here rather than a
        // serial follow-up; see `displayedBadges` for how it turns into the actual four shown.
        async let eb: [String]? = {
            guard isSelf else { return nil }
            return await feed.fetchOwnEffectiveDisplayedBadgeIds()
        }()
        // Own profile only, backs the small "new badge" pill; see `unseenBadgeCount`. Cheap and
        // idempotent to re-check on every load (pull-to-refresh, a sheet's `onDismiss`), unlike
        // the old per-stamp reveal this replaced, there's no animation-timing state here to
        // protect from being refetched mid-flight.
        async let ub: Int = {
            guard isSelf else { return 0 }
            return await feed.fetchOwnUnseenBadgeIds().count
        }()
        profile = await p
        // nil is a FAILED fetch (see `fetchUserPosts`): keep whatever the grid is showing,
        // cached or empty, rather than collapsing it into "no posts yet". Mirrors loadFeed's
        // leave-in-place rule for a failed refresh.
        if let fetchedPosts = await ps {
            posts = fetchedPosts
            // Epoch-guarded because this cache is on the shared service and outlives this view:
            // a fetch that lands after an account switch must not seed the next account's pages.
            if AccountEpoch.isCurrent(epoch) { feed.profilePostsCache[userId] = fetchedPosts }
            await mintThumbURLs(for: fetchedPosts)
        }
        followers = await fr
        following = await fg
        sharedCount = posts.count
        statsKnown = true
        feed.profileStatsCache[userId] = (sharedCount, followers, following)
        let badges = await bd
        let unseen = await ub
        let effectiveIds = await eb
        // Guarded on its own, unlike the writes below it: an account switch mid-flight must not
        // let a stale account's resolved badge order land on the new account's profile. Nothing
        // else in this function reads `effectiveDisplayedBadgeIds` afterward, so skipping the
        // write here (rather than returning early) is enough, the rest of `load()` still runs.
        // Animated because these writes reflow the header (pills swap, the "new badges" pill
        // comes or goes). They usually land while a sheet still covers the page, where animation
        // is moot; when one lands late, after the sheet is gone, easing beats popping.
        withAnimation(.easeInOut(duration: 0.25)) { unseenBadgeCount = unseenBadgeCount(from: unseen) }
        if AccountEpoch.isCurrent(epoch) {
            withAnimation(.easeInOut(duration: 0.25)) { effectiveDisplayedBadgeIds = effectiveIds }
        }
        // The signup number lives on the profile row itself and never depends on
        // `profile_badges`, so a profile still shows a clean number (and nothing else) if that
        // RPC fails, e.g. offline, or before this migration is deployed. Nothing renders at all
        // if `signupOrdinal` itself is missing (a profile row from before that column existed):
        // see `UserProfile.signupOrdinal`.
        if let signupNumber = profile?.signupOrdinal {
            identity = ProfileIdentity(
                signupNumber: signupNumber,
                badges: badges
            )
        } else {
            identity = nil
        }
        if feed.followingIds.isEmpty, let uid = auth.currentUser?.id { await feed.loadFollowing(userId: uid) }
        if feed.followerIds.isEmpty, let uid = auth.currentUser?.id { await feed.loadFollowers(userId: uid) }
        if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
        if let path = profile?.avatarPath { avatarURL = await feed.signedURL(for: path) }
        // Recorded beside the URL because the cover has three possible sources; a cache key that
        // guessed wrong would file one source's bytes under another's name.
        // Cover = chosen cover, else the newest shared shot, else the avatar. The newest-shot
        // fallback uses cardPath (the ~1400px feed rendition), not storagePath (the full ~2048px
        // stored image): the cover renders at maxPixel 1000, so downloading the full file for it
        // is ~3x the bytes for no visible gain.
        if let cover = profile?.coverPath { coverURL = await feed.signedURL(for: cover); coverPath = cover }
        else if let newest = posts.first?.cardPath { coverURL = await feed.signedURL(for: newest); coverPath = newest }
        else { coverURL = avatarURL; coverPath = profile?.avatarPath }
        loaded = true
    }

    /// One batched `signedURLs` call for the whole page's grid rather than one round trip per
    /// cell, mirroring `DayContactSheet`'s pattern. Only asks for paths not already resolved,
    /// so the cached-then-fetched double call in `load()` never re-signs the same object twice.
    private func mintThumbURLs(for posts: [Post]) async {
        let unresolved = Set(posts.map(\.displayPath)).subtracting(postThumbURLs.keys)
        guard !unresolved.isEmpty else { return }
        let resolved = await feed.signedURLs(for: Array(unresolved))
        for (path, url) in resolved { postThumbURLs[path] = url }
    }

    private func toggleFollow() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            // The count only moves if the write landed: the service already reverts the BUTTON
            // on failure (via followingIds), and a count bumped unconditionally here drifted one
            // off from that reverted button until the next full load.
            if isFollowing {
                if await feed.unfollow(userId, from: uid) { followers = max(0, followers - 1) }
            } else {
                if await feed.follow(userId, from: uid) { followers += 1 }
            }
        }
    }
}

// MARK: - Post thumbnail

struct PostThumb: View {
    let path: String
    /// Minted once, batched, by the page's own `mintThumbURLs` for the whole grid at once. Nil
    /// for a straggler (a post that arrived after the batch already resolved), in which case
    /// this cell falls back to minting its own.
    var resolvedURL: URL? = nil
    @Environment(FeedService.self) private var feed
    @State private var fallbackURL: URL?

    private var url: URL? { resolvedURL ?? fallbackURL }

    var body: some View {
        Color.clear
            .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
            .overlay {
                if let url {
                    CachedImage(url: url, maxPixel: 400, cacheKey: path) { $0.resizable().scaledToFill() } placeholder: { ShimmerPlaceholder(cornerRadius: 3) }
                } else { ShimmerPlaceholder(cornerRadius: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .task {
                guard resolvedURL == nil else { return }
                fallbackURL = await feed.signedURL(for: path)
            }
    }
}

// MARK: - Discover people

struct DiscoverPeopleView: View {
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(\.dismiss) private var dismiss

    @State private var profiles: [UserProfile] = []
    @State private var results: [UserProfile] = []
    @State private var searchText = ""
    @State private var loaded = false

    private var shown: [UserProfile] { searchText.isEmpty ? profiles : results }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    PeopleSearchField(query: $searchText, prompt: "Search by username")

                    if shown.isEmpty && loaded {
                        Spacer()
                        Text(searchText.isEmpty
                             ? "No one else here yet. Invite some friends!"
                             : "No one matches “\(searchText)”")
                            .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                if searchText.isEmpty && !profiles.isEmpty {
                                    Text("SUGGESTED")
                                        .flimFont(11, weight: .medium, relativeTo: .caption).tracking(2)
                                        .foregroundStyle(FlimTheme.textTertiary)
                                        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
                                }
                                ForEach(shown) { profile in
                                    NavigationLink { UserPageView(userId: profile.id) } label: {
                                        PersonRow(profile: profile)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle("Find friends")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                if let uid = auth.currentUser?.id {
                    await feed.loadFollowing(userId: uid)
                    await feed.loadFollowers(userId: uid)
                    await feed.loadBlocked(userId: uid)
                    profiles = await feed.discoverProfiles(excluding: uid)
                }
                loaded = true
            }
            .task(id: searchText) {
                // Debounced server-side search so it scales past a scrollable list.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, !searchText.isEmpty, let uid = auth.currentUser?.id else { return }
                results = await feed.searchProfiles(query: searchText, excluding: uid)
            }
        }
        .flimSheetSurface()
    }

}

/// A reusable person row (avatar + handle + bio + follow button) for people lists.
struct PersonRow: View {
    let profile: UserProfile
    @Environment(AuthService.self) private var auth

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(path: profile.avatarPath, name: profile.username, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.handle).flimFont(15, weight: .medium, relativeTo: .body).foregroundStyle(.white)
                if let bio = profile.bio, !bio.isEmpty {
                    Text(bio).flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary).lineLimit(1)
                }
            }
            Spacer()
            // Never a follow button on your own row, this list can legitimately include you
            // (you can be your own suggestion source's neighbor, or appear in someone else's
            // followers/following), and following yourself isn't a real action.
            if profile.id != auth.currentUser?.id {
                FollowButton(userId: profile.id)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 8)
    }
}

// MARK: - Followers / following list

enum FollowList: Identifiable {
    case followers, following
    var id: Int { self == .followers ? 0 : 1 }
}

struct FollowListView: View {
    let userId: UUID
    let mode: FollowList
    @Environment(\.dismiss) private var dismiss
    @Environment(FeedService.self) private var feed
    @Environment(AuthService.self) private var auth

    @State private var profiles: [UserProfile] = []
    @State private var loaded = false
    @State private var query = ""

    /// The people actually shown, once search narrows the loaded list.
    private var shown: [UserProfile] { profiles.filter { personMatches($0, query: query) } }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    PeopleSearchField(query: $query)

                    if shown.isEmpty && loaded {
                        Spacer()
                        // Two different emptys: nobody here at all, versus nobody matching the
                        // search. Reusing the "no followers yet" copy while a search is active
                        // would tell someone with 40 followers that they have none.
                        Text(profiles.isEmpty
                             ? (mode == .followers ? "No followers yet" : "Not following anyone yet")
                             : "No one matches “\(query)”")
                            .flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textTertiary)
                            .multilineTextAlignment(.center).padding(40)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 4) {
                                ForEach(shown) { profile in
                                    NavigationLink { UserPageView(userId: profile.id) } label: {
                                        PersonRow(profile: profile)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .flimInlineTitle(mode == .followers ? "Followers" : "Following")
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(.white)
                }
            }
            .task {
                if let uid = auth.currentUser?.id {
                    await feed.loadFollowing(userId: uid)
                    await feed.loadFollowers(userId: uid)   // so rows can offer "Follow back"
                    await feed.loadBlocked(userId: uid)   // so the list below filters blocked users
                }
                profiles = mode == .followers
                    ? await feed.fetchFollowers(of: userId)
                    : await feed.fetchFollowingProfiles(of: userId)
                loaded = true
            }
        }
        .flimSheetSurface()
    }
}

/// A compact follow/unfollow pill used in lists.
struct FollowButton: View {
    @Environment(\.flimAccent) private var accent
    let userId: UUID
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed

    var body: some View {
        let following = feed.isFollowing(userId)
        Button {
            guard let uid = auth.currentUser?.id else { return }
            Haptics.tap()
            Task {
                if following { await feed.unfollow(userId, from: uid) }
                else { await feed.follow(userId, from: uid) }
            }
        } label: {
            Text(FeedService.FollowRelationship.buttonLabel(following: following, followsMe: feed.followsMe(userId)))
                .flimFont(13, weight: .semibold, relativeTo: .subheadline)
                .foregroundStyle(following ? .white : .black)
                .padding(.horizontal, 16).padding(.vertical, 7)
                .background(following ? Color.white.opacity(0.12) : accent, in: Capsule())
        }
    }
}

/// The swapped-in line's type metrics, named so the fit test measures exactly what ships.
///
/// The acceptance is that EVERY badge's explanation fits ONE line at FULL size on a 393pt
/// device. `BadgeSwapLineTests` measures each with CoreText at these numbers; a new badge whose
/// copy does not fit fails the build, and the fix is to shorten the copy, never to grow the
/// line. That rule is the conclusion of three attempts, two of which shipped and were rejected
/// on device: scaling the longest copy to 0.52 made it an illegible squint, and reserving a
/// two-line box left a hole under one-line copy and pushed the handle off its name.
enum BadgeSwapMetrics {
    /// Matches `.footnote`'s base size; the Text uses `relativeTo: .footnote` so Dynamic Type
    /// still scales it.
    static let pointSize: CGFloat = 13
    /// The floor under `minimumScaleFactor`. A safety net for Dynamic Type and for narrower
    /// hardware than the 393pt the test measures, NOT a design allowance: every shipped
    /// explanation is expected to render at full size, and the fit test is what keeps that true.
    /// 0.85 is roughly 11pt, the smallest this line stays comfortably legible at.
    static let minimumScale: CGFloat = 0.85
    /// The handle row's own horizontal padding in `pageHeader`.
    static let horizontalPadding: CGFloat = 28
}

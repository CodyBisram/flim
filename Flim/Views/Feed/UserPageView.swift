import SwiftUI

/// A user's public page, profile header + their shared photos grouped into monthly chapters.
struct UserPageView: View {
    @Environment(\.flimAccent) private var accent
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
    @State private var hasUnseenBadges = false
    /// The signed-in account's own earned badge kind ids, for "how to earn this" in the popover
    /// on someone else's pill; see `ProfileBadgeColumn` and `ProfileBadgeKind.howToEarn`. On your
    /// own profile this is just this profile's own badges, no extra fetch needed since every
    /// badge shown here is already one you hold.
    @State private var viewerBadgeKindIds: Set<String> = []
    /// The signed-in account's own resolved "what a stranger sees right now" badge ids, own
    /// profile only, in display order. `nil` until fetched or on any failure, in which case
    /// `displayedBadges` below shows nothing rather than falling back to the full earned set. See
    /// `FeedService.fetchOwnEffectiveDisplayedBadgeIds`.
    @State private var effectiveDisplayedBadgeIds: [String]?
    @State private var posts: [Post] = []
    @State private var avatarURL: URL?
    @State private var coverURL: URL?
    @State private var followers = 0
    @State private var following = 0
    @State private var loaded = false
    @State private var followList: FollowList?
    @State private var showSettings = false
    @State private var showEditProfile = false
    @State private var showBadgePicker = false
    @State private var showInvite = false
    @State private var showBlockConfirm = false
    @State private var showReportConfirm = false
    @State private var reportedToast = false
    /// Separate from `reportedToast` rather than an enum: mirrors FeedView's toast shape.
    @State private var reportFailedToast = false
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

    /// `displayedBadges` split into the two columns that flank the avatar; see `ProfileBadgeFlank`.
    private var badgeFlanks: (left: [ProfileBadge], right: [ProfileBadge]) {
        ProfileBadgeFlank.split(displayedBadges)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

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
                        Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
                        if feed.isBlocked(userId) {
                            Button {
                                guard let uid = auth.currentUser?.id else { return }
                                Task { await feed.unblock(userId, from: uid) }
                            } label: { Label("Unblock", systemImage: "hand.raised.slash") }
                        } else {
                            Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block", systemImage: "hand.raised") }
                        }
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(accent)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported, thanks for keeping \(AppInfo.appName) safe", systemImage: "checkmark.circle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if reportFailedToast {
                Label("Couldn't report. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog("Block \(profile?.handle ?? "this user")?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Haptics.warning()
                Task {
                    await feed.block(userId, from: uid)
                    // `feed.block` rolls its optimistic state back on a failed write, only leave
                    // this page once the block actually took, this page IS the blocked-state
                    // affordance, and it's still reachable to retry from if it stays put.
                    if feed.isBlocked(userId) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and they'll be unfollowed.")
        }
        .confirmationDialog("Report \(profile?.handle ?? "this user")?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Task {
                    if await feed.reportUser(userId, from: uid) {
                        Haptics.success()   // the report went through, matching the toast
                        withAnimation { reportedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { reportedToast = false }
                    } else {
                        Haptics.error()
                        withAnimation { reportFailedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { reportFailedToast = false }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flag this account for review.")
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
        .sheet(isPresented: $showBadgePicker, onDismiss: { Task { await load() } }) {
            BadgePickerSheet()
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
        }
        .fullScreenCover(isPresented: $showAvatarViewer) {
            ImageViewer(url: avatarURL)
        }
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
                            CachedImage(url: coverURL, maxPixel: 1000) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
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
                HStack(alignment: .center, spacing: 14) {
                    ProfileBadgeColumn(badges: badgeFlanks.left, alignment: .trailing, viewerBadgeKindIds: viewerBadgeKindIds)
                    Button { if avatarURL != nil { showAvatarViewer = true } } label: {
                        avatarCircle
                    }
                    .buttonStyle(.plain)
                    ProfileBadgeColumn(badges: badgeFlanks.right, alignment: .leading, viewerBadgeKindIds: viewerBadgeKindIds)
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
            // themselves no longer animate in here (this page shows just the four a stranger
            // sees, and a newly earned badge may not even be among them). Tapping through opens
            // the picker, the one place the full collection — and the actual reveal — lives; see
            // `BadgePickerSheet`.
            if isSelf, hasUnseenBadges {
                Button {
                    Haptics.tap()
                    showBadgePicker = true
                } label: {
                    Label("New badge to see", systemImage: "sparkles")
                        .flimFont(12, weight: .semibold, relativeTo: .caption)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
                .expandTapTarget(by: 8)   // visual pill is ~28pt tall, +8 either side = 44
            }

            HStack(spacing: 26) {
                stat("\(posts.count)", "shared")
                Button { followList = .followers } label: { stat("\(followers)", "followers") }
                Button { followList = .following } label: { stat("\(following)", "following") }
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
                    CachedImage(url: avatarURL, maxPixel: 220) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(String((profile?.username ?? "?").prefix(1)).uppercased())
                        .flimFont(32, weight: .thin, relativeTo: .title3).foregroundStyle(accent)
                }
            }
            .clipShape(Circle())
            .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 4))
            .overlay(Circle().stroke(accent.opacity(0.5), lineWidth: 1))
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

            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(posts) { post in
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
                            PostThumb(path: post.displayPath)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 3)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 26, weight: .ultraLight)).foregroundStyle(FlimTheme.textTertiary)
            Text(isSelf ? "You haven't shared anything yet" : "No shared photos yet")
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
        // Own profile only, backs the small "new badge" pill; see `hasUnseenBadges`. Cheap and
        // idempotent to re-check on every load (pull-to-refresh, a sheet's `onDismiss`), unlike
        // the old per-stamp reveal this replaced, there's no animation-timing state here to
        // protect from being refetched mid-flight.
        async let ub: Bool = {
            guard isSelf else { return false }
            return await !feed.fetchOwnUnseenBadgeIds().isEmpty
        }()
        // Only fetched (and cached) for someone else's profile; on your own, every badge shown
        // is already one you hold, see `viewerBadgeKindIds`'s own comment above.
        async let vb: Set<String> = {
            guard !isSelf, let uid = auth.currentUser?.id else { return [] }
            return await feed.fetchViewerBadgeKindIds(uid)
        }()
        profile = await p
        posts = await ps
        followers = await fr
        following = await fg
        let badges = await bd
        hasUnseenBadges = await ub
        let viewerHeld = await vb
        let effectiveIds = await eb
        // Guarded on its own, unlike the writes below it: an account switch mid-flight must not
        // let a stale account's resolved badge order land on the new account's profile. Nothing
        // else in this function reads `effectiveDisplayedBadgeIds` afterward, so skipping the
        // write here (rather than returning early) is enough, the rest of `load()` still runs.
        if AccountEpoch.isCurrent(epoch) {
            effectiveDisplayedBadgeIds = effectiveIds
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
            viewerBadgeKindIds = isSelf ? Set(badges.map { $0.kind.rawValue }) : viewerHeld
        } else {
            identity = nil
        }
        if feed.followingIds.isEmpty, let uid = auth.currentUser?.id { await feed.loadFollowing(userId: uid) }
        if feed.followerIds.isEmpty, let uid = auth.currentUser?.id { await feed.loadFollowers(userId: uid) }
        if let uid = auth.currentUser?.id { await feed.loadBlocked(userId: uid) }
        if let path = profile?.avatarPath { avatarURL = await feed.signedURL(for: path) }
        // Cover = chosen cover, else the newest shared shot, else the avatar. The newest-shot
        // fallback uses cardPath (the ~1400px feed rendition), not storagePath (the full ~2048px
        // stored image): the cover renders at maxPixel 1000, so downloading the full file for it
        // is ~3x the bytes for no visible gain.
        if let cover = profile?.coverPath { coverURL = await feed.signedURL(for: cover) }
        else if let newest = posts.first?.cardPath { coverURL = await feed.signedURL(for: newest) }
        else { coverURL = avatarURL }
        loaded = true
    }

    private func toggleFollow() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        Task {
            if isFollowing {
                await feed.unfollow(userId, from: uid)
                followers = max(0, followers - 1)
            } else {
                await feed.follow(userId, from: uid)
                followers += 1
            }
        }
    }
}

// MARK: - Post thumbnail

struct PostThumb: View {
    let path: String
    @Environment(FeedService.self) private var feed
    @State private var url: URL?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url {
                    CachedImage(url: url, maxPixel: 400) { $0.resizable().scaledToFill() } placeholder: { ShimmerPlaceholder(cornerRadius: 3) }
                } else { ShimmerPlaceholder(cornerRadius: 3) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .task { url = await feed.signedURL(for: path) }
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
                FlimTheme.bg.ignoresSafeArea()
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
        .presentationBackground(FlimTheme.bg)
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
                FlimTheme.bg.ignoresSafeArea()
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
        .presentationBackground(FlimTheme.bg)
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

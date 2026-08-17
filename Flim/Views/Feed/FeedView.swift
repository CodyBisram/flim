import SwiftUI
import UIKit

struct FeedView: View {
    @Environment(\.flimAccent) private var accent
    var scrollToTop: Int = 0
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    @State private var showDiscover = false
    @State private var showActivity = false
    @State private var myAvatarURL: URL?
    @State private var hasNewPosts = false
    @State private var didLoad = false
    /// A pull-to-refresh that genuinely failed while the feed already had content on screen.
    /// `loadFeed` deliberately leaves the existing posts in place on a failed refresh (see its
    /// own comment), which is right for not blanking the screen, but a failure that touches
    /// nothing on screen also needs to say SOMETHING, or a real outage looks like "nothing
    /// happened" instead of "try again". `feed.feedError`'s own full-screen `ErrorState` only
    /// ever shows for an empty feed, so a refresh of a populated one needs this instead.
    @State private var refreshFailedToast = false
    @State private var unreadActivity = 0
    /// The previous `lastActivitySeen`, handed to Activity so it can show a "New" section.
    @State private var activitySeenBefore: Date?
    @AppStorage("lastActivitySeen") private var lastActivitySeen: Double = 0

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if feed.feed.isEmpty {
                    if feed.isLoadingFeed || !didLoad {
                        // Show skeletons until the first load actually completes, never flash
                        // the "quiet" empty state before we know whether the feed is empty.
                        ScrollView {
                            VStack(spacing: 20) {
                                ForEach(0..<3, id: \.self) { _ in FeedCardSkeleton() }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 16)
                        }
                        .disabled(true)
                    } else if let error = feed.feedError {
                        // A failed load is not an empty feed, don't tell someone with no signal
                        // that nobody they follow has posted.
                        ErrorState(message: error) { await reload() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        emptyState
                    }
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 20) {
                                Color.clear.frame(height: 0).id("top")
                                // Consecutive posts by the same author collapse into one
                                // swipeable card (`FeedGrouping`, pinned by `FeedGroupingTests`).
                                // This only changes presentation: `feed.feed` itself keeps its
                                // server order, untouched, and a group of one renders exactly as
                                // a lone card always has.
                                let groups = FeedGrouping.grouped(feed.feed)
                                ForEach(groups) { group in
                                    FeedPostCard(group: group)
                                        .scrollTransition { content, phase in
                                            content
                                                .opacity(phase.isIdentity ? 1 : 0.55)
                                                .scaleEffect(phase.isIdentity ? 1 : 0.96)
                                        }
                                        .onAppear {
                                            // Near the bottom → load the next page + warm its
                                            // images. Checked against the last GROUP, not the last
                                            // raw post: a trailing burst from one author collapses
                                            // into one card, but its last post is still exactly
                                            // `feed.feed.last`, so this fires once, the same as it
                                            // always did, regardless of how many photos that last
                                            // card holds.
                                            if group.id == groups.last?.id, let uid = auth.currentUser?.id {
                                                Task {
                                                    // Where the new page will start, captured
                                                    // before loading so only its cards are warmed.
                                                    let alreadyLoaded = feed.feed.count
                                                    await feed.loadMoreFeed(currentUserId: uid)
                                                    await prefetchFeedImages(from: alreadyLoaded)
                                                }
                                            }
                                        }
                                }
                                if feed.isLoadingMoreFeed {
                                    ProgressView().tint(FlimTheme.textTertiary).padding(.vertical, 8)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                        }
                        .refreshable { await reload() }
                        // Swiping the feed puts the keyboard away. Without this there was no way
                        // out of a comment composer at all: nothing here dismissed the keyboard,
                        // so tapping "Add a comment" or Reply and changing your mind left you
                        // stuck with it up and only the send button reachable. Interactively
                        // rather than immediately, so the keyboard tracks the drag and a small
                        // scroll to read the rest of a card doesn't yank it away mid-sentence.
                        .scrollDismissesKeyboard(.interactively)
                        // This ScrollViewReader only mounts once feed.feed goes non-empty (the
                        // sibling branch above is the skeleton/empty state), a fresh view
                        // identity, so its very first layout pass. Reported: that first pass can
                        // land scrolled slightly below "top" (LazyVStack items still settling
                        // their real heights as async images load in changes the content's
                        // effective size out from under the scroll view's initial offset), and
                        // double-tapping the Feed tab, which calls this exact scrollTo, fixes
                        // it instantly. Firing it once on appear applies that same proven fix
                        // automatically instead of requiring the user to find it, with no
                        // animation since this is a silent correction before anything settles,
                        // not a visible user-triggered reset like the double-tap is.
                        .task { proxy.scrollTo("top", anchor: .top) }
                        .onChange(of: scrollToTop) {
                            withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
                        }
                        .overlay(alignment: .top) {
                            if hasNewPosts {
                                Button {
                                    hasNewPosts = false
                                    Haptics.tap()
                                    Task {
                                        await reload()
                                        withAnimation { proxy.scrollTo("top", anchor: .top) }
                                    }
                                } label: {
                                    Label("New posts", systemImage: "arrow.up")
                                        .flimFont(13, weight: .semibold)
                                        .foregroundStyle(.black)
                                        .padding(.horizontal, 16).padding(.vertical, 8)
                                        .background(accent, in: Capsule())
                                        .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                                }
                                .padding(.top, 8)
                                .transition(.move(edge: .top).combined(with: .opacity))
                            } else if refreshFailedToast {
                                Label("Couldn't refresh", systemImage: "wifi.exclamationmark")
                                    .flimFont(13, weight: .semibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .padding(.top, 8)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                    }
                }
            }
        }
        .navigationBarHidden(true)
        .task {
            if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
            if feed.feed.isEmpty { await reload() } else { didLoad = true; await checkNewPosts() }
        }
        // Batched, and re-fires whenever the loaded set grows (first load, "New posts", or
        // paging to the next page): `fetchSuggestedEmoji` itself skips anything already cached,
        // so this only ever asks about the cards that just appeared.
        .task(id: feed.feed.count) {
            await photos.fetchSuggestedEmoji(photoIds: feed.feed.map(\.post.photoId))
        }
        // The feed refreshes reactions on RETURN to the foreground rather than on a timer. The
        // detail view polls because attention is on one photo there; here the same pacing would
        // mean repeatedly refetching a screenful of posts the user is scrolling past, for the one
        // in ten that changed. Coming back to the app is the moment stale counts are noticeable.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !feed.feed.isEmpty else { return }
            Task {
                await feed.refreshReactions(
                    postIds: LiveRefresh.postsToRefresh(feed.feed).map(\.post.id))
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPeopleView()
        }
        .sheet(isPresented: $showActivity) {
            ActivityFeedView(seenBefore: activitySeenBefore)
        }
    }

    private var timeGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Action icons on their own top row (right-aligned).
            HStack(spacing: 12) {
                Spacer()
                #if DEBUG
                Button {
                    Task { if let uid = auth.currentUser?.id { await feed.seedFeedDemo(userId: uid, photoService: photos) } }
                } label: {
                    Image(systemName: "ladybug")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(FlimTheme.textTertiary)
                }
                .accessibilityLabel("Seed demo feed")
                #endif
                Button {
                    // Capture the PREVIOUS visit before stamping this one, so Activity can put
                    // what you haven't looked at under "New". Stamping first (which this has
                    // always done, to clear the badge immediately) would otherwise leave the
                    // sheet with nothing to compare against.
                    activitySeenBefore = lastActivitySeen > 0
                        ? Date(timeIntervalSince1970: lastActivitySeen)
                        : nil
                    lastActivitySeen = Date().timeIntervalSince1970
                    unreadActivity = 0
                    showActivity = true
                } label: {
                    Image(systemName: unreadActivity > 0 ? "bell.badge" : "bell")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                        .symbolEffect(.bounce, value: unreadActivity)   // bounces when new activity lands
                        .frame(width: 38, height: 38)
                        .glassCapsule(interactive: true)
                        .overlay(alignment: .topTrailing) {
                            if unreadActivity > 0 {
                                Text(unreadActivity > 9 ? "9+" : "\(unreadActivity)")
                                    .flimFont(10, weight: .bold, relativeTo: .caption)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Color.red, in: Capsule())
                                    .offset(x: 4, y: -2)
                            }
                        }
                }
                .accessibilityLabel(unreadActivity > 0 ? "Activity, \(unreadActivity) new" : "Activity")

                Button { showDiscover = true } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(accent)
                        .frame(width: 38, height: 38)
                        .glassCapsule(interactive: true)
                        .expandTapTarget(by: 3)   // 38 + 3 either side = 44
                }
                .accessibilityLabel("Find friends")

                // Your avatar → your own page.
                if let uid = auth.currentUser?.id {
                    NavigationLink {
                        UserPageView(userId: uid)
                    } label: {
                        Circle()
                            .fill(accent.opacity(0.18))
                            .frame(width: 34, height: 34)
                            .overlay {
                                if let myAvatarURL {
                                    CachedImage(url: myAvatarURL, maxPixel: 100) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                } else {
                                    Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                        .flimFont(14, weight: .thin, relativeTo: .subheadline).foregroundStyle(accent)
                                }
                            }
                            .clipShape(Circle())
                            .overlay(Circle().stroke(accent.opacity(0.4), lineWidth: 1))
                    }
                    .accessibilityLabel("Your page")
                }
            }

            // Greeting on its own line, the name gets full width and shrinks if it's long.
            VStack(alignment: .leading, spacing: 1) {
                Text("\(timeGreeting),")
                    .flimFont(14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text(auth.currentUser?.friendlyName ?? "there")
                    .flimFont(28, weight: .light, relativeTo: .title3)
                    .tracking(0.5)
                    .foregroundStyle(FlimTheme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .ultraLight))
                .foregroundStyle(accent)
            Text("It's quiet in here")
                .flimFont(19, weight: .thin, relativeTo: .body)
                .foregroundStyle(.white)
            Text("Follow friends to see what they share, or take the first shot yourself.")
                .flimFont(13, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 50)
            HStack(spacing: 10) {
                Button { showDiscover = true } label: {
                    Text("Find friends")
                        .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(accent, in: Capsule())
                }
                Button { NotificationCenter.default.post(name: .openCamera, object: nil) } label: {
                    Text("Take a shot")
                        .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 20).padding(.vertical, 11)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
            }
            .padding(.top, 4)
            #if DEBUG
            Button {
                Task { if let uid = auth.currentUser?.id { await feed.seedFeedDemo(userId: uid, photoService: photos) } }
            } label: {
                Text(feed.isSeeding ? "Seeding…" : "Seed demo feed (DEBUG)")
                    .flimFont(13, relativeTo: .subheadline)
                    .foregroundStyle(FlimTheme.textTertiary)
            }
            .disabled(feed.isSeeding)
            .padding(.top, 8)
            #endif
            Spacer()
            Spacer()
        }
    }

    private func reload() async {
        guard let uid = auth.currentUser?.id else { didLoad = true; return }
        // Captured before the load: `loadFeed` leaves an already-populated `feed` untouched on a
        // genuine failure (so a flaky refresh doesn't blank the screen), which means `feed.feed`
        // staying non-empty afterward can't by itself say whether this refresh worked. Only a feed
        // that already had something on screen needs the toast below; an empty one falls through
        // to `feed.feedError`'s own full-screen `ErrorState` instead.
        let hadContent = !feed.feed.isEmpty
        await feed.loadFeed(currentUserId: uid)
        didLoad = true
        hasNewPosts = false
        if hadContent, feed.feedError != nil {
            Haptics.error()
            withAnimation { refreshFailedToast = true }
            Task { try? await Task.sleep(for: .seconds(2)); withAnimation { refreshFailedToast = false } }
        }
        if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
        unreadActivity = await feed.unreadActivityCount(
            userId: uid, since: Date(timeIntervalSince1970: lastActivitySeen))
        await prefetchFeedImages()
    }

    /// Warm the image cache for the loaded posts so they appear instantly as you scroll.
    ///
    /// Signs the whole page in ONE batched call. This used to loop `signedURL(for:)` one post at
    /// a time, and each miss is a round-trip, so on a cold cache (first launch, or after the
    /// signed-URL TTL lapses) a 15-post page spent fifteen sequential round-trips before the
    /// first image byte was requested. `signedURLs(for:)` now mints every miss in a single
    /// `createSignedURLs` request instead of one `createSignedURL` per photo.
    /// Warms the cards that just arrived, not the whole feed again.
    ///
    /// This used to prefetch `feed.feed` entire on every page load, so five pages queued 15 then
    /// 30 then 45 then 60 then 75 items: 225 lookups to warm 75 cards. It was never re-downloading
    /// (both the image fetch and the signed URLs are cache-backed), so this is redundant work
    /// rather than redundant bytes — but it grows quadratically with how far someone scrolls, and
    /// it is the one place in the feed that does.
    private func prefetchFeedImages(from startIndex: Int = 0) async {
        let paths = feed.feed.dropFirst(startIndex).map(\.post.cardPath)
        guard !paths.isEmpty else { return }
        let urls = await feed.signedURLs(for: Array(Set(paths)))
        let items = paths.compactMap { path -> (url: URL, cacheKey: String?)? in
            urls[path].map { ($0, path) }
        }
        ImageLoader.prefetch(items, maxPixel: 1400, scale: displayScale)
    }

    private func checkNewPosts() async {
        guard let uid = auth.currentUser?.id else { return }
        let fresh = await feed.peekFeed(currentUserId: uid)
        if let newTop = fresh.first?.id, newTop != feed.feed.first?.id {
            withAnimation { hasNewPosts = true }
        }
    }
}

// MARK: - Post card

/// Whether "View N comments" has anything to offer beyond what `commentPreview` already shows in
/// full. `commentPreview` can equal every comment there is (one or two total, or a third for "your
/// own latest" alongside them), and the row would just repeat what's already on screen.
func hasCommentsBeyondPreview(total: Int, shownInPreview: Int) -> Bool {
    total > shownInPreview
}

struct FeedPostCard: View {
    @Environment(\.flimAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let group: FeedGroup
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(PhotoService.self) private var photos

    /// Which post in `group` is currently showing. Only meaningful (and only ever moved by the
    /// user) when `group.count > 1`; a single-post group never leaves 0.
    @State private var currentIndex = 0
    /// Live horizontal offset while a multi-post card's swipe is in flight; always settles back
    /// to 0. See `swipeGesture`.
    @State private var dragX: CGFloat = 0
    @State private var urlByPost: [UUID: URL] = [:]
    @State private var avatarURL: URL?
    /// Keyed per post rather than one shared field, so switching photos mid-draft doesn't lose
    /// what was typed for the one you swiped away from: the composer belongs to whichever photo
    /// is showing, but coming back to an earlier photo in the same card should find its draft
    /// exactly as it was left.
    @State private var draftByPost: [UUID: String] = [:]
    @State private var showComments = false
    @State private var route: ProfileRoute?
    /// A profile chosen inside the comment sheet, opened once that sheet has closed.
    @State private var pendingProfile: ProfileRoute?
    @State private var heartBurst = false
    @State private var showDeleteConfirm = false
    @State private var showReportConfirm = false
    @State private var showBlockConfirm = false
    @State private var showEditCaption = false
    @State private var captionDraft = ""
    /// What a caption edit didn't manage to save, so reopening "Edit caption" starts from the
    /// attempted text rather than the unchanged server value it was never able to replace.
    /// `nil` once there's nothing outstanding, either because nothing has been tried yet or the
    /// last attempt saved.
    @State private var pendingCaptionRetry: String?
    @State private var captionFailedToast = false
    /// A delete that didn't reach the server. The card stays in the feed either way, since only
    /// a successful `deletePost` removes it from `feed`, so this just says why it's still here.
    @State private var deleteFailedToast = false
    @State private var showEditTags = false
    @State private var editingTags: [PendingTag] = []
    @State private var reportedToast = false
    /// Separate from `reportedToast` rather than an enum: this file already tracks toasts as
    /// plain flags, so a failure gets the same shape instead of a new vocabulary.
    @State private var reportFailedToast = false
    @State private var shareItem: ShareImage?
    @FocusState private var commentFocused: Bool

    /// `currentIndex` clamped into `group.items`. A separate step from `item` below so the clamp
    /// only has to be reasoned about once, e.g. after the currently-shown post is deleted out from
    /// under a still-mounted card and `group.count` shrinks.
    private var safeIndex: Int { min(max(currentIndex, 0), group.count - 1) }
    /// The post currently on screen: index 0 for a single-post group, and everything below (the
    /// reaction bar, the comment preview, the composer, the caption, the ••• menu) reads from
    /// this rather than from `group` directly, so it all tracks the swipe.
    /// Indexes `group.rest` directly rather than going through `group.items` (`[first] + rest`),
    /// which would reallocate that concatenation on every read of `item`/`post` — and this is read
    /// many times per render, more so on the large groups (dozens of posts from one author in one
    /// sitting) this feature exists for.
    private var item: FeedItem { safeIndex == 0 ? group.first : (group.rest[safe: safeIndex - 1] ?? group.first) }
    private var post: Post { item.post }
    private var isOwn: Bool { post.isOwned(by: auth.currentUser?.id) }
    // Reactions + comments live in the batch-loaded FeedService cache (one fetch per page, not
    // per card). Reading them here keeps every card in sync as it recycles.
    // Filtered again here (on top of FeedService's own filtering) as defense-in-depth: cards can
    // recycle against a cache that predates a block landing.
    private var reactions: [PostReaction] {
        (feed.reactionsByPost[post.id] ?? []).filter { !feed.blockedIds.contains($0.userId) }
    }
    private var comments: [CommentInfo] {
        (feed.commentsByPost[post.id] ?? []).filter { !feed.blockedIds.contains($0.comment.userId) }
    }
    /// The top-ranked couple of comments, plus your own latest so it always shows after you post.
    private var commentPreview: [CommentInfo] {
        var shown = Array(comments.prefix(2))
        if let uid = auth.currentUser?.id,
           let mine = comments.last(where: { $0.comment.userId == uid }),
           !shown.contains(where: { $0.id == mine.id }) {
            shown.append(mine)
        }
        return shown
    }
    private var iLiked: Bool { reactions.contains { $0.emoji == "❤️" && $0.userId == auth.currentUser?.id } }
    /// The composer's draft, scoped to the currently-showing post (see `draftByPost`).
    private var draft: Binding<String> {
        Binding(get: { draftByPost[post.id] ?? "" }, set: { draftByPost[post.id] = $0 })
    }
    private var canSend: Bool { !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Author row, handle/time on the left, options ••• on the right.
            HStack(spacing: 10) {
                Button { route = ProfileRoute(id: item.author.id) } label: {
                    HStack(spacing: 10) {
                        avatar
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.author.handle)
                                .flimFont(14, weight: .semibold, relativeTo: .subheadline)
                                .foregroundStyle(.white)
                            Text(post.createdAt.formatted(.relative(presentation: .named)))
                                .flimFont(11, relativeTo: .caption)
                                .foregroundStyle(FlimTheme.textTertiary)
                        }
                    }
                }
                Spacer()
                Menu {
                    postActions
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(FlimTheme.textSecondary)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Post options")
            }

            // The print, shown at its native aspect (no square crop). Single tap opens it,
            // double tap likes it (with a heart burst). A 3:4 default sizes the placeholder so
            // there's no layout jump before the image resolves.
            //
            // A group of one renders exactly this, nothing more: no TabView, no indicator, no
            // extra state churn, so the overwhelming common case (a lone post) is unchanged from
            // before grouping existed.
            if group.count > 1 {
                // Multiple posts from the same run: swipeable, with a position indicator so the
                // reaction/comment counts changing underneath you as you swipe reads as "a
                // different post", not a glitch. The haptic and the numeric readout below both
                // firing only once a swipe actually completes is what makes that read as
                // deliberate rather than accidental.
                //
                // Deliberately NOT `TabView(.page)`, which is what this branch used until this
                // fix. PhotoPagerView and RollCarouselView (see their own comments, on `pager`
                // and on this same ZStack respectively) each hit the identical defect — a swipe
                // settling with the next photo's dead space sliced into frame — three separate
                // times, from three different root causes, and both abandoned TabView(.page) for
                // plain state advancing a single mounted photo. This follows RollCarouselView's
                // shape: there is no swipe-to-dismiss to disambiguate against here (that only
                // exists in a full-screen viewer), so the swipe gesture below is the only thing
                // this needs, and it never mounts a neighbouring photo for a desynced TabView to
                // leak into frame in the first place.
                //
                // What neither of those two views had to solve: this card sits inside the feed's
                // own vertical `ScrollView`. `.simultaneousGesture`, not `.gesture` — a plain
                // `.gesture` would compete for every touch that starts on the card, including a
                // vertical scroll, and freeze the feed's own pan the instant a finger goes down on
                // a photo. Attached alongside the ScrollView's pan recognizer instead, both get to
                // see every touch; `swipeGesture` only ever acts (moves the photo, or counts as a
                // completed swipe) when the horizontal component actually dominates, so a vertical
                // drag on the card is left entirely to the ScrollView, exactly as it is over a
                // single-post card.
                //
                // No forced aspect ratio either, unlike the old TabView branch: that only existed
                // because a paging TabView needs a fixed frame to swipe cleanly between pages.
                // Mounting one photo at a time has no such requirement, so this sizes exactly the
                // way a single-post card's `photoContent` already does, and a multi-post card
                // presents each photo identically to how a lone card would.
                photoContent(for: item)
                    .id(item.post.id)
                    .transition(.opacity)
                    .offset(x: dragX)
                    .simultaneousGesture(swipeGesture)
                    .overlay(alignment: .topTrailing) { positionIndicator }
                    // Deleting the currently-shown post (or any post before it) shifts everything
                    // after it down by one and shrinks `group.count`; without this, `currentIndex`
                    // itself would keep pointing past the new end until the next swipe, which is a
                    // valid index for nothing. `safeIndex` already guards every READ of
                    // `item`/`post`, this keeps `currentIndex` itself in sync with the same bound.
                    .onChange(of: group.count) { _, newCount in
                        currentIndex = min(currentIndex, newCount - 1)
                    }
            } else {
                photoContent(for: item)
            }

            if let caption = post.caption, !caption.isEmpty {
                Text(caption).flimFont(14, relativeTo: .subheadline).foregroundStyle(FlimTheme.textSecondary)
            }

            // Emoji reactions (inline picker). Comment access lives in the preview + composer below.
            ReactionBar(
                defaults: photos.reactionDefaults(for: post.photoId),
                counts: Dictionary(grouping: reactions, by: \.emoji).mapValues(\.count),
                mine: Set(reactions.filter { $0.userId == auth.currentUser?.id }.map(\.emoji))
            ) { toggleReaction($0) }

            // Comment preview → @handle taps to their page, the body opens the comments sheet,
            // and so does "View N comments" when there's more than the preview already shows.
            if !commentPreview.isEmpty {
                // Touch targets here are honest, not 44pt: every direction is boxed in by another
                // tappable view (ReactionBar above, "View N comments" below it, the comment text
                // across the Spacer from the like button), so a control can only grow into the
                // dead space between it and a neighbour, never past the midpoint, or the
                // later-declared view would silently steal the earlier one's taps. The insets
                // below are half the MEASURED gap to each neighbour: 14pt row spacing halves to
                // 7, the outer VStack's 12pt spacing to ReactionBar halves to 6, and the 8pt gap
                // between the comment text and the like button halves to 4. If any of those
                // spacings change, these insets must move with them.
                VStack(alignment: .leading, spacing: 14) {
                    // Only rendered when it actually offers something the preview below doesn't
                    // already show in full; with every comment already visible (the common case
                    // for one or two comments) it would just repeat what's on screen.
                    if hasCommentsBeyondPreview(total: comments.count, shownInPreview: commentPreview.count) {
                        Button { showComments = true } label: {
                            Text("View all \(comments.count) comments")
                                .flimFont(12, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                                .contentTransition(.numericText())
                                .animation(.snappy(duration: 0.28), value: comments.count)
                        }
                        .expandTapTarget(top: 6, leading: 4, bottom: 7, trailing: 4)
                    }
                    ForEach(commentPreview) { info in
                        // firstTextBaseline, not top. The comment is 14pt and the trailing
                        // controls are 11 and 12, so aligning top EDGES parks the smaller cluster
                        // against the top of the bigger text's line box and it reads as floating
                        // high. Baseline alignment sits them on the same line as the words. It
                        // still does the job .top was picked for, keeping the controls on the
                        // FIRST line when the comment wraps to two, because the baseline in
                        // question is the first line's.
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            // Handle and body in one Text (handle bold, linked to the profile)
                            // rather than a handle Button beside a separate MentionText: a wrapped
                            // second line returns to the leading edge this way instead of
                            // indenting under where the body happened to start. Tapping the body
                            // itself opens the comments sheet, same destination as "View N
                            // comments" above; mentions keep resolving to their own profile.
                            MentionText(
                                text: info.comment.body,
                                handle: info.handle,
                                onHandleTap: { route = ProfileRoute(id: info.comment.userId) },
                                onBodyTap: { showComments = true }
                            ) { username in
                                Haptics.tap()
                                Task {
                                    if let profile = await feed.fetchProfile(username: username) {
                                        route = ProfileRoute(id: profile.id)
                                    }
                                }
                            }
                            .lineLimit(2).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            // Reply lives in the comments sheet now, not here: this preview is
                            // read-only apart from the like, matching Instagram's own inline
                            // preview. The comment's own text already opens that sheet, where
                            // Reply is one tap away.
                            Button { likeComment(info) } label: {
                                // Baseline here too, so the count and the heart sit on the row's
                                // baseline rather than this pair centring on its own.
                                HStack(alignment: .firstTextBaseline, spacing: 3) {
                                    if info.likeCount > 0 {
                                        Text("\(info.likeCount)").flimFont(11, relativeTo: .caption).foregroundStyle(FlimTheme.textTertiary)
                                            .contentTransition(.numericText())
                                    }
                                    Image(systemName: info.likedByMe ? "heart.fill" : "heart")
                                        .font(.system(size: 12))
                                        .foregroundStyle(info.likedByMe ? accent : FlimTheme.textTertiary)
                                        .symbolEffect(.bounce, value: info.likedByMe)
                                        .frame(width: 16, alignment: .trailing)
                                }
                                // No fixed minWidth here anymore: that existed only so "Reply"
                                // landed at the same x on every row regardless of the like
                                // count's digit width. With Reply gone this is the only trailing
                                // control, right-aligned by the Spacer above with nothing to its
                                // right to stay level with, so a row with a two-digit count and
                                // one without can differ in width without anything looking
                                // misaligned.
                            }
                            // Leading neighbour is always the comment text across the Spacer now
                            // (Reply used to sit between them); that Spacer enforces an 8pt
                            // minimum gap, so 4 leading still holds. Trailing edge is the card's
                            // own padding, genuinely dead space, so it takes the full gap to the
                            // card edge.
                            .expandTapTarget(top: 7, leading: 4, bottom: 7, trailing: 14)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Inline comment composer. Reply lives in the comments sheet, not this card, so
            // there's never a reply target to show here.
            CommentComposer(draft: draft, style: .inlineCard, replyTarget: .constant(nil),
                            focus: $commentFocused) { sendComment() }
        }
        .padding(14)
        .background(FlimTheme.bgElevated, in: RoundedRectangle(cornerRadius: 20))
        // Author avatar is shared by the whole run (same author throughout the card), so this
        // fetches it once regardless of how many photos the card holds or how far you swipe.
        // reactions + comments already loaded in the feed batch, no per-card query.
        .task {
            if let path = group.first.author.avatarPath { avatarURL = await feed.signedURL(for: path) }
        }
        // Re-fires as the swipe moves to a different post, 1400px rendition (falls back to full).
        // Guarded so a post already resolved (including one you've swiped back to) isn't
        // re-fetched; `signedURL` itself is cache-backed too, but this skips the async hop
        // entirely on top of that.
        .task(id: item.post.id) {
            guard urlByPost[item.post.id] == nil else { return }
            urlByPost[item.post.id] = await feed.signedURL(for: item.post.cardPath)
        }
        // onDismiss, not inline: pushing the profile while the comment sheet is still on screen
        // is what put it inside the sheet. The id is parked here and acted on once the sheet is
        // actually gone.
        .sheet(isPresented: $showComments, onDismiss: {
            if let pending = pendingProfile { pendingProfile = nil; route = pending }
        }) {
            CommentsSheet(post: post) { pendingProfile = ProfileRoute(id: $0) }
        }
        .navigationDestination(item: $route) { UserPageView(userId: $0.id) }
        .sheet(item: $shareItem) { SharePreviewSheet(photo: $0.image) }
        .sheet(isPresented: $showEditTags) {
            TagPhotoSheet(url: urlByPost[post.id], tags: $editingTags) {
                let postId = post.id
                Task { await feed.setTags(editingTags, on: postId) }
            }
        }
        .sheet(isPresented: $showEditCaption) {
            EditCaptionSheet(caption: $captionDraft) {
                guard let uid = auth.currentUser?.id else { return }
                let postId = post.id
                let trimmed = captionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                let newCaption = trimmed.isEmpty ? nil : trimmed
                Task {
                    let saved = await feed.updatePostCaption(postId: postId, caption: newCaption, userId: uid)
                    if saved == true {
                        pendingCaptionRetry = nil
                    } else if saved == false {
                        // Keep what was typed so reopening "Edit caption" starts from the
                        // attempted text, not the caption that failed to change.
                        pendingCaptionRetry = trimmed
                        Haptics.error()
                        withAnimation { captionFailedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { captionFailedToast = false }
                    }
                    // saved == nil: cancelled, not a failure, nothing to say.
                }
            }
        }
        .overlay(alignment: .top) {
            if reportedToast {
                Label("Reported, thanks", systemImage: "checkmark.circle.fill")
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
            } else if captionFailedToast {
                Label("Couldn't save caption. Try again.", systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            } else if deleteFailedToast {
                Label("Couldn't delete that. Check your connection and try again.", systemImage: "exclamationmark.triangle.fill")
                    .flimFont(13, weight: .medium).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .confirmationDialog("Delete this post?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.warning()
                // Captured now, not read again inside the Task: this is the post the dialog was
                // raised for, and it should stay the one deleted even though `post` itself would
                // keep tracking the swipe if a page redraw happened to land in between.
                let postId = post.id
                Task {
                    let deleted = await feed.deletePost(id: postId)
                    if deleted == false {
                        // Still here (`deletePost` only removes it from `feed` on success), so
                        // say why rather than leave the card looking untouched.
                        Haptics.error()
                        withAnimation { deleteFailedToast = true }
                        try? await Task.sleep(for: .seconds(2)); withAnimation { deleteFailedToast = false }
                    }
                    // deleted == true: gone from `feed`, so gone from `group` too on the next
                    // render. A single-post group's card disappears entirely; a multi-post one
                    // reflows around the gap and clamps `currentIndex` back into range (see its
                    // declaration), landing on whichever post is now in that spot. deleted == nil:
                    // cancelled, not a failure, stay silent.
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It's removed from your page and feed. The photo stays in your Darkroom.")
        }
        .confirmationDialog("Report this photo?", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("Report", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                let reportedPost = post
                Task {
                    if await feed.reportPost(reportedPost, from: uid) {
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
            Text("Flag this for review. Thanks for keeping \(AppInfo.appName) safe.")
        }
        .confirmationDialog("Block \(item.author.handle)?", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("Block", role: .destructive) {
                guard let uid = auth.currentUser?.id else { return }
                Haptics.warning()
                let targetId = post.userId
                Task {
                    await feed.block(targetId, from: uid)
                    // `feed.block` rolls its optimistic state back on a failed write, so this
                    // reflects whether it actually landed rather than assuming it always does.
                    // Stripping the cards here regardless would leave the feed looking blocked for
                    // someone it hadn't actually taken effect for.
                    if feed.isBlocked(targetId) {
                        withAnimation { feed.feed.removeAll { $0.author.id == targetId } }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You won't see each other's posts, and they'll be unfollowed.")
        }
    }

    /// Declared once and used by both the ••• menu and the photo's long-press menu, so the two
    /// can't drift apart as actions are added.
    @ViewBuilder
    private var postActions: some View {
        if isOwn {
            Button { captionDraft = pendingCaptionRetry ?? post.caption ?? ""; showEditCaption = true } label: { Label("Edit caption", systemImage: "pencil") }
            Button { beginEditingTags() } label: {
                Label(tagCount == 0 ? "Tag people" : "Edit tags", systemImage: "person.crop.circle.badge.plus")
            }
            Button { saveToCameraRoll() } label: { Label("Save to Camera Roll", systemImage: "square.and.arrow.down") }
            Button(role: .destructive) { showDeleteConfirm = true } label: { Label("Delete post", systemImage: "trash") }
        } else {
            // Only offered when you're actually in the photo. Withdrawing your own tag is allowed
            // by RLS regardless of who posted it (2026-08-01_tag_self_removal.sql).
            if let uid = auth.currentUser?.id, feed.isTagged(uid, in: post.id) {
                Button { removeMyTag() } label: { Label("Remove me from this photo", systemImage: "person.crop.circle.badge.xmark") }
            }
            Button { showReportConfirm = true } label: { Label("Report", systemImage: "flag") }
            Button(role: .destructive) { showBlockConfirm = true } label: { Label("Block \(item.author.handle)", systemImage: "hand.raised") }
        }
    }

    private var tagCount: Int { (feed.tagsByPost[post.id] ?? []).count }

    /// Seeds the tag editor from what's already on the post, so editing starts from the current
    /// state rather than a blank slate that would wipe existing tags on save.
    private func beginEditingTags() {
        editingTags = (feed.tagsByPost[post.id] ?? []).compactMap { tag in
            feed.tagProfiles[tag.taggedUserId].map { PendingTag(user: $0, x: tag.x, y: tag.y) }
        }
        showEditTags = true
    }

    private func removeMyTag() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        let postId = post.id
        Task { await feed.removeMyTag(from: postId, userId: uid) }
    }

    private func saveToCameraRoll() {
        // Captured now: the download below can outlast a quick swipe away from this photo.
        let storagePath = post.storagePath
        Task {
            guard let full = await feed.signedURL(for: storagePath),
                  let (data, _) = try? await URLSession.shared.data(from: full),
                  let image = UIImage(data: data) else { return }
            shareItem = ShareImage(image: image)
        }
    }

    /// One photo of the card: the image itself plus everything drawn on top of it (grain, tags,
    /// the double-tap heart). Shared by the single-post card and a multi-post one, so a
    /// swipeable card's current photo looks and behaves exactly like a lone card's photo does.
    ///
    /// Only ever called with `item`, the CURRENT photo: unlike the `TabView(.page)` this replaced,
    /// which mounted every page in the group at once and needed `isCurrent` to tell them apart, a
    /// multi-post card now mounts this exactly once, swapped by `currentIndex` (see the multi-post
    /// branch above), so there is never a second, off-screen instance of this for anything inside
    /// it to be ambiguous about.
    @ViewBuilder
    private func photoContent(for groupItem: FeedItem) -> some View {
        Group {
            if let photoURL = urlByPost[groupItem.post.id] {
                CachedImage(url: photoURL, maxPixel: 1400, cacheKey: groupItem.post.cardPath) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ShimmerPlaceholder(cornerRadius: 12).aspectRatio(3.0 / 4.0, contentMode: .fit)
                }
            } else {
                ShimmerPlaceholder(cornerRadius: 12).aspectRatio(3.0 / 4.0, contentMode: .fit)
            }
        }
            .frame(maxWidth: .infinity)
            .overlay { GrainOverlay().opacity(0.5) }
            .overlay {
                Image(systemName: "heart.fill")
                    .font(.system(size: 90))
                    .foregroundStyle(.white)
                    .shadow(radius: 8)
                    .scaleEffect(heartBurst ? 1 : 0.4)
                    .opacity(heartBurst ? 0.9 : 0)
                    .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.55), value: heartBurst)
            }
            .overlay {
                PhotoTags(tags: feed.tagsByPost[groupItem.post.id] ?? [], profiles: feed.tagProfiles) { route = ProfileRoute(id: $0) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Two fingers lift the print off the feed; one finger still likes it and opens
            // it. Applied after the clip so the lifted snapshot has the card's own corners.
            .pinchToZoom()
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapLike() }
            // The same actions as the ••• button above, on the photo itself. Long-press is
            // where people already reach for these, and it puts them on the thing being
            // acted on instead of a 34pt target in the corner.
            .contextMenu { postActions }
            .accessibilityElement()
            .accessibilityLabel("Photo by \(groupItem.author.handle)")
            .accessibilityHint("Double-tap to like, or react below")
    }

    /// "N of M", the thing that keeps a multi-post card's changing reaction/comment counts from
    /// reading as a glitch: it says plainly that a swipe just moved to a different post.
    private var positionIndicator: some View {
        Text("\(safeIndex + 1) of \(group.count)")
            .flimFont(12, weight: .semibold, relativeTo: .caption)
            .foregroundStyle(.white)
            .contentTransition(.numericText())
            .animation(.snappy(duration: 0.22), value: currentIndex)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(10)
    }

    private var avatar: some View {
        Circle()
            .fill(accent.opacity(0.18))
            .frame(width: 34, height: 34)
            .overlay {
                if let avatarURL {
                    CachedImage(url: avatarURL, maxPixel: 100) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                } else {
                    Text(String(item.author.handle.dropFirst().prefix(1)).uppercased())
                        .flimFont(14, weight: .thin, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                }
            }
            .clipShape(Circle())
    }

    /// Advances between a multi-post card's photos on a horizontal swipe, following the finger
    /// and resisting at the first/last post the same way `PhotoPagerView` and `RollCarouselView`
    /// do (same free functions, same feel). See the multi-post branch above for why this is
    /// `simultaneousGesture` rather than `gesture`: both `onChanged` and `onEnded` bail out
    /// whenever the drag's vertical component dominates, so a vertical drag never nudges the
    /// photo and is left entirely to the feed's own `ScrollView`.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragX = pagingDragOffset(width: value.translation.width, index: safeIndex, count: group.count)
            }
            .onEnded { value in
                withAnimation(.easeOut(duration: 0.18)) { dragX = 0 }
                guard abs(value.translation.width) > abs(value.translation.height),
                      let delta = pagingStep(forDragWidth: value.translation.width) else { return }
                step(delta)
            }
    }

    private func step(_ delta: Int) {
        let next = safeIndex + delta
        guard group.items.indices.contains(next) else { return }
        Haptics.tap()
        withAnimation(.easeOut(duration: 0.22)) { currentIndex = next }
    }

    private func doubleTapLike() {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        if !reduceMotion {
            heartBurst = true
            Task { try? await Task.sleep(for: .milliseconds(650)); heartBurst = false }
        }
        if !iLiked {
            // Captured now: a double tap can be immediately followed by a swipe, and this must
            // still land on the post that was actually tapped, not whatever is showing once the
            // request completes.
            let postId = post.id
            Task { await feed.reactToPost(postId, emoji: "❤️", userId: uid) }
        }
    }

    private func toggleReaction(_ emoji: String) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        let postId = post.id
        Task { await feed.reactToPost(postId, emoji: emoji, userId: uid) }
    }

    private func likeComment(_ info: CommentInfo) {
        guard let uid = auth.currentUser?.id else { return }
        Haptics.tap()
        let postId = post.id
        Task { await feed.toggleCommentLike(info, postId: postId, userId: uid) }
    }

    private func sendComment() {
        guard let uid = auth.currentUser?.id, canSend else { return }
        // Captured now, including `draft` itself: sending is async, and a swipe mid-flight must
        // not move where the comment lands, nor overwrite a DIFFERENT post's draft if the failure
        // path below has to restore it.
        let postId = post.id
        let body = draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        draftByPost[postId] = ""
        commentFocused = false
        Haptics.tap()
        Task {
            let ok = await feed.commentOnPost(postId, body: body, userId: uid)
            if !ok {
                draftByPost[postId] = body   // restore instead of silently losing the comment
                Haptics.error()
            }
        }
    }
}

// MARK: - Skeleton

/// Placeholder card shown while the feed is loading for the first time.
struct FeedCardSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(FlimTheme.bgElevated).frame(width: 34, height: 34).shimmering()
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 110, height: 12)
                Spacer()
            }
            ShimmerPlaceholder(cornerRadius: 12).aspectRatio(1, contentMode: .fit)
            ShimmerPlaceholder(cornerRadius: 4).frame(width: 180, height: 12)
            HStack(spacing: 18) {
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 22, height: 14)
                ShimmerPlaceholder(cornerRadius: 4).frame(width: 22, height: 14)
                Spacer()
            }
        }
        .padding(14)
        .background(FlimTheme.bgElevated.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

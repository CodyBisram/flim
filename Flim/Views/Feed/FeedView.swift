import SwiftUI
import UIKit

/// The feed: one unit per author per 04:00-bounded day (`FeedUnit`), rendered edge-to-edge
/// on the ground with hairline seams, replacing the one-card-per-post list that let a
/// 14-shot day fill every follower's catch-up before anyone else appeared.
///
/// The header carries no count (2026-09-26). The feed is newest first, so everything new sits
/// together at the top, each day's pill says what is new in it, and the caught-up block marks
/// the end of what is NEW, not the end of the scroll: on this archive feed the days already
/// seen continue below it.
struct FeedView: View {
    @Environment(\.flimAccent) private var accent
    var scrollToTop: Int = 0
    /// Whether the Feed tab is the one showing. The tab stays mounted behind the others, and a
    /// card that was on screen when you left still reads as visible, so without this a reload
    /// run from another tab (the 04:00 one on foreground) could mark the new top day seen before
    /// you ever came back to look at it. Marking waits for the tab; returning opens the gate and
    /// the cards on screen mark then.
    var isFrontmost: Bool = true
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
    @Environment(TabSignals.self) private var signals
    @Environment(PhotoService.self) private var photos
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase

    private let seenStore = FeedSeenStore.shared

    /// How far into the UNITS the prefetch window currently reaches. Reset with the feed
    /// itself: a pull-to-refresh replaces the list, so a cursor into the old one would skip
    /// warming the new top.
    /// Whether this account can still let anyone in, so the empty state's invite button is not
    /// offered once the invites are spent. `.unknown` until read, which deliberately still offers
    /// the button: a failed lookup must never hide a code that works.
    @State private var inviteQuota: AuthService.InviteQuota = .unknown
    @State private var prefetchedThrough = 0
    @State private var showDiscover = false
    @State private var showActivity = false
    @State private var myAvatarURL: URL?
    @State private var hasNewPosts = false
    /// The part of `hasNewPosts` the tab dot may use: a newer post by someone else, not
    /// already loaded and not already seen. Your own post also brings up "New posts" (page one
    /// does not hold it until a reload) but must never light your own dot.
    @State private var newPostsFromOthers = false
    /// Reloads between their start and their own snapshot. Marking waits while any is running,
    /// so a card on screen cannot mark its new shots before the reload places the caught-up
    /// line. Separate from `ledgerSnapshotted`, which still means "the first snapshot ran".
    @State private var reloadsInFlight = 0
    @State private var didLoad = false
    /// The account generation the loaded feed belongs to, so a mark made under the next
    /// account never recomputes the dot from the previous account's units.
    @State private var loadedEpoch: Int?
    /// A pull-to-refresh that genuinely failed while the feed already had content on screen;
    /// see `reload()`. A failure that touches nothing on screen still needs to say something.
    @State private var refreshFailedToast = false
    /// A one-line notice from a notification tap whose target is gone, posted by `MainTabView`
    /// as `.feedNotice`; shown in the same top slot as the refresh failure, for the same two
    /// seconds. Text rather than a flag because the tab view chooses the words.
    @State private var feedNotice: String?
    @State private var unreadActivity = 0
    /// The previous `lastActivitySeen`, handed to Activity so it can show a "New" section.
    @State private var activitySeenBefore: Date?
    /// Per account, through `ActivitySeenMark`; read only inside actions, so no observation needed.
    private var lastActivitySeen: Double {
        get { ActivitySeenMark.value(userId: auth.currentUser?.id) }
        nonmutating set { ActivitySeenMark.set(newValue, userId: auth.currentUser?.id) }
    }
    /// The container width, which every unit needs up front: the pager's height is derived
    /// from it before any image arrives, so nothing reflows when one does.
    @State private var containerWidth: CGFloat = 0
    /// The day key (`FeedUnit.dayKey`) at the moment this view's scene last left `.active`.
    /// Compared against the current day key on return to `.active` so a genuine 04:00 boundary
    /// crossed while backgrounded can be told apart from an ordinary foregrounding mid-scroll;
    /// see the scenePhase `onChange` below.
    @State private var backgroundedDayKey: Date?
    /// Bumped once a 04:00-boundary-triggered background reload resolves, consumed by
    /// `feedList`'s own `ScrollViewReader` the same way `scrollToTop` is: a reader who was
    /// scrolled deep into yesterday's archive when the app backgrounded overnight would otherwise
    /// come back to a completely different page one (content page one replaced under them) at
    /// whatever offset they left it, which reads as a jump or a blank region. This is the
    /// morning-reset semantic: after a genuine boundary crossing, land back at the top exactly
    /// the way the very first load does. Ordinary foregrounding and pull-to-refresh are
    /// unaffected, neither one bumps this.
    @State private var boundaryReloadGeneration = 0
    /// Gates the cards' seen-marking until the first snapshot exists, so snapshot-then-mark
    /// is an ordering guarantee rather than a race against the first visibility event: the
    /// caught-up block must be placed from what was unseen at load, before the first card
    /// on screen marks itself.
    @State private var ledgerSnapshotted = false
    /// Bumped by every EXPLICIT catch-up (initial load, pull-to-refresh, the New-posts
    /// button, and a 04:00 boundary crossed while backgrounded), telling living unit cards to
    /// re-open on their first unseen shot. A unit's
    /// opening frame is otherwise computed only at view birth, so a fresh launch opened on a
    /// friend's new shot while a session that watched it arrive stayed parked on frame one.
    /// Only explicit actions bump this: a background refresh must never move a pager someone
    /// is mid-read on.
    @State private var catchUpGeneration = 0
    /// Where the caught-up block sits, SNAPSHOTTED at load, because it marks the seam between new and old at the catch-up moment. Derived live,
    /// reading a unit moved the "last unseen" boundary backwards and the block crawled UP
    /// the feed as you scrolled, surfacing under the first unit whose deeper frames you had
    /// not swiped to. A seam that moves while you read is not a seam.
    private enum CaughtUpSeam: Equatable {
        case pending          // nothing loaded yet, show no block
        case top              // nothing anywhere was unseen at load: block above the archive
        case after(String)    // below this unit id, above the already-seen days
    }
    @State private var caughtUp: CaughtUpSeam = .pending

    // MARK: Spotlight strip
    //
    // The strip is NOT a unit and never enters `feed.feed` or `units`. Its place is decided by
    // `SpotlightPlacement` / `SpotlightSlot` and SNAPSHOTTED here at the same moments as the
    // caught-up seam (a reload, the 04:00 boundary reload, "New posts"), never derived live: a strip
    // that moved while someone read would be the seam crawling up the feed all over again.
    // Paging only fills in a place that was waiting on an unloaded page, and a slot whose
    // anchor unit left (a delete, a block) is re-placed rather than dropped.
    @State private var spotlightSlots: [String: SpotlightSlot] = [:]
    /// Weeks this account has seen in the feed (the "new" pill). Marked by scroll visibility.
    @State private var seenSpotlight: Set<String> = []
    @State private var spotlightSheet: SpotlightSheetRoute?
    @State private var spotlightRoute: SpotlightPostRoute?
    /// In-flight guard for a strip frame being fetched before it opens.
    @State private var openingSpotlightFrame: UUID?

    /// The strip's weeks this viewer may see: blocks filter frames, and a week with nothing
    /// left is hidden.
    private var visibleSpotlightWeeks: [SpotlightWeek] {
        SpotlightWeek.visible(feed.spotlightStripWeeks, blocked: feed.blockedIds)
    }

    // RETENTION CLEARING WAS REMOVED HERE (2026-08-28). The feed no longer takes anything away.
    //
    // The rule was: a unit whose every shot had been reached before the last 04:00 boundary left
    // the feed. It could not survive per-author grouping, and the failure was invisible. A shot
    // is marked seen only when the pager lands on it (`FeedUnitCard.maybeMarkReached`), one shot
    // at a time, while clearing demanded a mark on EVERY shot in the unit. So a ten-shot day
    // cleared only if you swiped all ten frames, and since a unit reopens on its first unseen
    // shot, it took ten separate scroll-pasts to retire one day.
    //
    // What that produced, all at once and all "correct": single-shot days vanished at 4am on
    // schedule, multi-shot days accumulated for the whole seven, and the feed was empty one
    // morning and endless the next afternoon. Two spec rules were in direct contradiction under
    // grouping ("nothing unseen expires" against "seen units clear at the next boundary"), and a
    // day that is one-tenth read is neither.
    //
    // The seam already says "you are caught up" without deleting anything, so seen state now
    // drives only the pill, the tab dot, the seam, and where a unit opens. The consequence of any
    // future seen-state bug is a wrong pill rather than a feed that empties or never ends.
    // Scrolling stays bounded by `FeedUnit.retentionWindow`, server-side, which is what actually
    // bounded it all along.

    /// Cached `FeedUnit` grouping, the fix for the same
    /// scroll hitch `DarkroomView.cachedDayUnits` names (its own doc is the worked example): the
    /// `feedList` `ForEach`'s row closure reads `units.count` PER ROW (`index < units.count - 1`,
    /// deciding whether to draw a seam or the caught-up block), and `units` used to be a computed
    /// property re-running `FeedUnit.units(from:)` — a `Dictionary(grouping:)` + a sort over the
    /// whole loaded feed — on every one of those per-row reads, not once per body pass.
    ///
    /// Recomputed via `recomputeUnits()`, called explicitly from `snapshotLedger` (synchronous
    /// code in THAT function reads `units` again immediately afterward, before SwiftUI's own
    /// `.onChange` below would ever fire) and via `.onChange(of: feed.feed)` as the safety net
    /// for `feed.feed` changing OUTSIDE this view's own reload path (a photo deleted from the
    /// Darkroom calls `feed.dropPosts(forDeletedPhotoIds:)` directly on the shared service, with
    /// no call back into this view at all).
    ///
    /// ANTI-PATTERN, do not reintroduce: `FeedUnit.units(from:)` (or anything that calls it) read
    /// from inside the `ForEach` row closure, or any other per-row path.
    @State private var cachedUnits: [FeedUnit] = []

    private var units: [FeedUnit] { cachedUnits }

    /// Every unit the fetch returned, in order. Nothing is filtered out: what the server sent is
    /// what the reader sees.
    private func recomputeUnits() {
        cachedUnits = FeedUnit.units(from: feed.feed)
    }

    /// One-time, per account: seed the pre-1.5 backlog as already-seen so an UPGRADING user does
    /// not open the redesigned feed into a wall of lit pills for content they saw days ago in an
    /// older build. See `FeedSeenSeed` for the decision and why a fresh signup is left unseeded.
    ///
    /// Runs at the top of `snapshotLedger`, so the seam and pills computed just after it reflect
    /// the seed. It does NOT call back into `snapshotLedger` (that would recurse), and the flag is
    /// set on EVERY outcome, a skip included, so a seed can never re-run on a later launch and mark
    /// posts that have since aged past the cutoff as seen.
    ///
    /// It seeds only what is loaded when it first runs. The feed's first page covers the retention
    /// window, which is the whole visible backlog, so at this scale that is the whole job; a
    /// date watermark would be the upgrade if a much longer feed ever made a later page matter.
    private func seedFeedBacklogIfNeeded() {
        guard let user = auth.currentUser else { return }
        let key = "feedBacklogSeeded.\(user.id.uuidString)"
        guard !UserDefaults.standard.bool(forKey: key) else { return }

        let decision = FeedSeenSeed.decide(
            alreadySeeded: false,
            keepFullyUnseen: FeedSeenSeed.keptFullyUnseen.contains(user.id),
            storeHasMarks: !seenStore.seenAt.isEmpty,
            accountAge: Date().timeIntervalSince(user.createdAt),
            now: .now)

        if case .seedOlderThan(let cutoff) = decision {
            let backlog = feed.feed
                .filter { $0.post.createdAt < cutoff }
                .map { (id: $0.post.id, seenAt: $0.post.createdAt) }
            seenStore.seedBacklog(backlog)
        }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// Whether a friend's shot on the loaded pages is still unseen: the feed's half of the tab
    /// dot. Page one is the newest posts, so nothing unseen there is a fair "nothing new".
    private var anythingUnseen: Bool {
        FeedUnit.hasUnseen(units: units, currentUserId: auth.currentUser?.id, isSeen: { seenStore.isSeen($0) })
    }

    /// Re-lights or clears the Feed tab's dot from what is loaded here and in Activity. A post
    /// newer than page one ("New posts") counts too: it is not loaded, so no card can say so,
    /// and marking the loaded ones must not clear a dot that post lit.
    private func updateFeedDot() {
        signals.feedHasUnread = TabSignals.feedDot(unseen: anythingUnseen || newPostsFromOthers,
                                                   unreadActivity: unreadActivity)
    }
    /// First run: nobody followed and nothing to show. Not "caught up", which describes a
    /// feed that ran out rather than one that has not started.
    private var followsNobody: Bool {
        didLoad && feed.feed.isEmpty && feed.feedError == nil && feed.followingIds.isEmpty
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()
                // On the always-mounted background, and `initial`, so it also runs when the
                // entry arrives before the feed's list mounts: someone who uses Spotlight before
                // reading the 1.6.0 line never needs it, even after taking the frame down.
                .onChange(of: spotlightAlreadyUsed, initial: true) { _, used in
                    if used, let uid = auth.currentUser?.id { NewAccountIntro.markSeen(.spotlight, userId: uid) }
                }

            VStack(spacing: 0) {
                header

                if feed.feed.isEmpty {
                    if feed.isLoadingFeed || !didLoad {
                        loadingState
                    } else if let error = feed.feedError {
                        // A failed load is not an empty feed; don't tell someone with no
                        // signal that nobody they follow has posted.
                        ErrorState(message: error) { await reload() }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if followsNobody {
                        // A newcomer who follows nobody still meets Spotlight: it is the one
                        // place other people's photographs reach them.
                        if visibleSpotlightWeeks.isEmpty {
                            firstRunState
                        } else {
                            // Padded, not stretched to the screen: the strip above must not push
                            // "Find your friends" below the fold.
                            ScrollView {
                                VStack(spacing: 0) {
                                    allSpotlightStrips
                                    firstRunState
                                        .padding(.top, 28)
                                        .padding(.bottom, 40)
                                }
                            }
                            .refreshableToCompletion { await reload() }
                        }
                    } else {
                        // Followed people, none of whom have ever posted: the caught-up
                        // block is the whole screen, since there is nothing older either.
                        ScrollView {
                            allSpotlightStrips
                            caughtUpBlock
                                .padding(.top, visibleSpotlightWeeks.isEmpty ? 120 : 24)
                        }
                        .refreshableToCompletion { await reload() }
                    }
                } else if units.isEmpty {
                    // Posts were FETCHED (feed.feed is non-empty) but every unit has cleared:
                    // the whole feed was seen and the 4am boundary passed. Without this branch
                    // the screen fell through to `feedList`, whose ForEach over zero units
                    // painted nothing, and the caught-up seam sat parked in `.pending`, so the
                    // first fully-caught-up morning rendered as a bare black page with a
                    // header. The block IS the screen here, same as the never-posted case.
                    ScrollView {
                        allSpotlightStrips
                        caughtUpBlock
                            .padding(.top, visibleSpotlightWeeks.isEmpty ? 120 : 24)
                    }
                    .refreshableToCompletion { await reload() }
                } else {
                    feedList
                }
            }
        }
        .background(GeometryReader { proxy in
            Color.clear.onChange(of: proxy.size.width, initial: true) { _, width in
                containerWidth = width
            }
        })
        // `cachedUnits`'s safety net for `feed.feed` changing outside this
        // view's own reload path; see that property's own doc for why `snapshotLedger` ALSO calls
        // `recomputeUnits()` explicitly rather than relying on this alone.
        .onChange(of: feed.feed) { _, _ in
            recomputeUnits()
            // A delete can take away the unit a strip was placed against; re-place only those.
            if spotlightSlotsHaveOrphans { snapshotSpotlight(growOnly: true) }
        }
        // A card marked itself seen: the dot clears once nothing loaded is new. Only after the
        // first load, so a launch never clears a dot the server lit before the feed arrived.
        .onChange(of: seenStore.marksVersion) {
            if didLoad, AccountEpoch.current == loadedEpoch { updateFeedDot() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .feedNotice)) { note in
            guard let text = note.object as? String else { return }
            withAnimation { feedNotice = text }
            Task { try? await Task.sleep(for: .seconds(2.4)); withAnimation { feedNotice = nil } }
        }
        .navigationBarHidden(true)
        .task {
            // `feed_viewed` semantics: once per time this view genuinely appears (initial
            // mount plus every later switch back to the Feed tab); see the tab-content
            // appearance note on `CameraViewModel.start()`. Riding `.task` keeps it from
            // firing on re-renders or scene-phase changes.
            Usage.log(.feedViewed)
            // A cohort-code arrival's first feed is one person's photos (the code's maker, whom
            // they follow by default) and nobody they know. Find friends opens by itself, once,
            // so the first visit is about finding their people rather than reading a stranger
            // (v2 batch 4; the September cohort numbers are why: ten of thirteen code arrivals
            // followed nobody else and never shot).
            if NewAccountIntro.shouldOfferDiscover(userId: auth.currentUser?.id, createdAt: auth.currentUser?.createdAt),
               let uid = auth.currentUser?.id {
                NewAccountIntro.markDiscoverOffered(userId: uid)
                try? await Task.sleep(for: .milliseconds(600))   // let the feed paint first
                showDiscover = true
            }
            // Only the empty state reads this, and it fails soft to `.unknown`, which still
            // offers the invite. Cheap enough to ride the existing appear rather than earn a
            // task of its own.
            inviteQuota = await auth.ownInviteQuota()
            if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
            // The account's seen-marks must be here before the first snapshot; see
            // `FeedSeenStore.awaitPull`.
            if !ledgerSnapshotted { await seenStore.awaitPull() }
            seenSpotlight = SpotlightSeenMark.seen(userId: auth.currentUser?.id)
            if feed.feed.isEmpty {
                await reload()
            } else {
                didLoad = true
                loadedEpoch = AccountEpoch.current
                if !ledgerSnapshotted { snapshotLedger() }
                await checkNewPosts()
            }
        }
        // Batched, and re-fires whenever the loaded set grows; `fetchSuggestedEmoji` skips
        // anything already cached, so this only ever asks about what just appeared.
        .task(id: feed.feed.count) {
            await photos.fetchSuggestedEmoji(photoIds: feed.feed.map(\.post.photoId))
        }
        // Refresh reactions on RETURN to the foreground rather than on a timer; coming back
        // to the app is the moment stale counts are noticeable. This view stays mounted inside
        // the TabView even when Feed isn't the frontmost tab, so this fires (and, below, can
        // trigger a background reload) whether or not Feed is on screen; that mirrors
        // `checkNewPosts`, which already tolerates running unseen.
        //
        // A 04:00 boundary crossed while backgrounded is an EXPLICIT catch-up moment, same as
        // launch or pull-to-refresh: the person was almost certainly asleep, not mid-scroll, so
        // the seam and the Spotlight strips are allowed to recompute. An ordinary foregrounding
        // that never crosses a boundary must never reshape the feed, so it keeps doing only the
        // reactions refresh this onChange already did.
        .onChange(of: scenePhase) { previous, phase in
            guard phase == .active else {
                // Stamp only on a genuine departure FROM .active. The return trip also
                // passes through .inactive, and stamping there overwrote the overnight
                // stamp with the current morning's day key one instant before the
                // comparison below could see it — which made the boundary reload
                // unreachable from any foregrounding, ever.
                if previous == .active { backgroundedDayKey = FeedUnit.dayKey(for: .now) }
                return
            }
            // `didLoad` false means the initial `.task` load hasn't landed yet (or there's no
            // signed-in user); that path owns the first load, so this one no-ops rather than
            // racing it with a second, redundant reload.
            if didLoad, let backgroundedDayKey, FeedUnit.dayKey(for: .now) != backgroundedDayKey {
                self.backgroundedDayKey = nil
                Task {
                    await reload()
                    // The reload just replaced page one out from under whatever scroll offset was
                    // left overnight; see `boundaryReloadGeneration`'s own doc.
                    boundaryReloadGeneration += 1
                }
                return
            }
            // The bell's count, and the activity half of the tab dot, were only as fresh as the
            // last reload: a comment made while the app was away showed on neither, and the next
            // seen-mark recomputed the dot from the stale zero and cleared it.
            if didLoad { Task { await refreshUnreadActivity() } }
            guard !feed.feed.isEmpty else { return }
            // A friend may have posted while the app was away. The feed is not reloaded (that
            // would reshape it under the reader), but "New posts" can say so, and the tab dot
            // stays lit for it.
            Task { await checkNewPosts() }
            Task {
                await feed.refreshReactions(
                    postIds: LiveRefresh.postsToRefresh(feed.feed).map(\.post.id))
            }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverPeopleView()
        }
        .sheet(item: $spotlightSheet) { route in
            SpotlightWeeksSheet(focusWeek: route.focusWeek)
        }
        .navigationDestination(item: $spotlightRoute) { route in
            PostDetailView(item: route.item, spotlightWeekKey: route.weekKey)
        }
        .sheet(isPresented: $showActivity) {
            ActivityFeedView(seenBefore: activitySeenBefore) { queriedAt in
                // Never moves the watermark backwards: a refresh inside the sheet reports its
                // own (later) query time, and an earlier one can't undo it.
                lastActivitySeen = max(lastActivitySeen, queriedAt.timeIntervalSince1970)
                unreadActivity = 0
                updateFeedDot()
            }
        }
    }

    // MARK: - Header

    /// The screen's name and its three buttons. No count: the new days are the ones at the
    /// top, and each says how many of its shots are new.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Feed")
                .flimFont(17, weight: .light, relativeTo: .body)
                .tracking(0.5)
                .foregroundStyle(FlimTheme.textSecondary)
            Spacer(minLength: 8)

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
                // what you haven't looked at under "New".
                activitySeenBefore = lastActivitySeen > 0
                    ? Date(timeIntervalSince1970: lastActivitySeen)
                    : nil
                // The watermark moves only once Activity has actually shown its content (its
                // `onLoaded`), so a failed load or a sheet dismissed mid-spinner keeps the unread
                // signal for next time instead of silently consuming it.
                showActivity = true
            } label: {
                Image(systemName: unreadActivity > 0 ? "bell.badge" : "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .symbolEffect(.bounce, value: unreadActivity)
                    .frame(width: 44, height: 44)
                    .glassCapsule(interactive: true)
                    .overlay(alignment: .topTrailing) {
                        if unreadActivity > 0 {
                            Text(unreadActivity > 9 ? "9+" : "\(unreadActivity)")
                                .flimFont(11, weight: .bold, relativeTo: .caption2)
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
                    // On first run this is THE follow affordance, so the empty state glows
                    // it rather than duplicating it as a second control somewhere else; the
                    // reader who comes back tomorrow already knows where the action lives.
                    .shadow(color: followsNobody ? accent.opacity(0.62) : .clear, radius: 7)
                    .frame(width: 44, height: 44)
                    .glassCapsule(interactive: true)
                    .expandTapTarget(by: 3)   // 38 + 3 either side = 44
            }
            .accessibilityLabel("Find friends")

            // Your avatar → your own page; also where an unseen badge gets flagged.
            if let uid = auth.currentUser?.id {
                NavigationLink {
                    UserPageView(userId: uid)
                } label: {
                    Circle()
                        .fill(accent.opacity(0.18))
                        .frame(width: 34, height: 34)
                        .overlay {
                            if let myAvatarURL {
                                CachedImage(url: myAvatarURL, maxPixel: 100, cacheKey: auth.currentUser?.avatarPath) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                            } else {
                                Text(String((auth.currentUser?.username ?? "?").prefix(1)).uppercased())
                                    .flimFont(14, weight: .thin, relativeTo: .subheadline).foregroundStyle(accent)
                            }
                        }
                        .clipShape(Circle())
                        .overlay(Circle().stroke(accent.opacity(0.4), lineWidth: 1))
                        .overlay(alignment: .topTrailing) {
                            if feed.unseenBadgeCount > 0 {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 11, height: 11)
                                    .overlay(Circle().stroke(FlimTheme.bg, lineWidth: 1.5))
                            }
                        }
                }
                .accessibilityLabel(
                    feed.unseenBadgeCount == 0 ? "Your page"
                    : feed.unseenBadgeCount == 1 ? "Your page, new badge earned"
                    : "Your page, \(feed.unseenBadgeCount) new badges earned"
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    /// The account has put a frame up this week or has one waiting on a closed week: it knows
    /// Spotlight, and the 1.6.0 announcement is not for it. Only from an entry loaded for the
    /// account signed in now (`ownSpotlightEntryIsCurrent`), never the previous account's.
    /// `ownSpotlightChosen` is left out on purpose: it loads only with the own profile's shelf,
    /// carries no account stamp, and nobody chosen can have missed the line (no week had been
    /// published when 1.6.0 shipped).
    private var spotlightAlreadyUsed: Bool {
        guard feed.ownSpotlightEntryIsCurrent, let entry = feed.ownSpotlightEntry else { return false }
        return entry.postId != nil || !entry.pending.isEmpty
    }

    // MARK: - The feed

    private var feedList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    Color.clear.frame(height: 0).id("top")

                    // Standing nudge for anyone who never turned notifications on. It gates and
                    // hides itself; here it just needs to be the first thing on the feed so it is
                    // seen on landing and scrolls away as you browse. See NotificationNudgeBanner.
                    NotificationNudgeBanner()
                    // One sentence, once, for a brand-new account: see NewAccountIntro. A cohort
                    // code arrival gets the honest version: nobody here knows them yet.
                    FirstVisitLine(surface: .feed,
                                   text: NewAccountIntro.inviter(for: auth.currentUser?.id ?? UUID())?.isCampaign == true
                                       ? NewAccountIntro.campaignFeedLine : nil)
                    // What's new, once per account, for members who were here before it:
                    // Spotlight in 1.6.0. Waits out the first-visit line above, and skips anyone
                    // who has already put a frame up or been chosen.
                    AnnouncementLine(
                        announcement: .spotlight,
                        usageKnown: feed.ownSpotlightEntryIsCurrent,
                        firstVisitLineShowing: NewAccountIntro.lineToShow(
                            .feed, userId: auth.currentUser?.id, createdAt: auth.currentUser?.createdAt) != nil,
                        alreadyUsed: spotlightAlreadyUsed)
                    // A thin feed (under three follows) gets three people it knows, with the
                    // reason, at the top; it goes away by itself once the feed has people in it.
                    if !followsNobody {
                        PeopleYouKnowRow { showDiscover = true }
                    }

                    // A Spotlight strip placed above everything (an unseen one lifted over a
                    // caught-up block at the top, or the only thing when no unit is older).
                    spotlightStrips(in: .top, seamBefore: false)

                    // Nothing anywhere was unseen at load: the block sits at the top of the
                    // scroll with the days already seen below it.
                    if caughtUp == .top {
                        caughtUpBlock
                    }

                    ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                        // The strip rides inside its neighbouring unit's row, never as a row
                        // of its own in `units`.
                        spotlightStrips(in: .beforeUnit(unit.id), seamBefore: false)

                        FeedUnitCard(
                            unit: unit,
                            width: containerWidth,
                            opening: unit.openingIndex(isSeen: { seenStore.isSeen($0) }),
                            seenStore: seenStore,
                            markingEnabled: ledgerSnapshotted && reloadsInFlight == 0 && isFrontmost,
                            catchUpGeneration: catchUpGeneration,
                            // growOnly: blocking an author must not re-place the seam or the
                            // strips, the same ratchet paging already obeys.
                            onAuthorBlocked: { snapshotLedger(growOnly: true) }
                        )
                        .id(unit.id)
                        .onAppear { unitAppeared(index: index) }

                        // An unseen strip whose place fell on the seen side of the seam sits
                        // just above the caught-up block instead: it is new.
                        spotlightStrips(in: .aboveCaughtUpBlock(afterUnit: unit.id), seamBefore: true)

                        // The seam between new and old: the caught-up block below the last
                        // unit that held anything unseen AT LOAD, unless more pages could
                        // still bring new below it. Otherwise a hairline, ink not a card.
                        if showsCaughtUpBlock(after: unit, at: index) {
                            caughtUpBlock
                        } else if index < units.count - 1 {
                            seam
                        }

                        if index == units.count - 1 {
                            spotlightStrips(in: .afterLast, seamBefore: true)
                        }
                    }

                    if feed.isLoadingMoreFeed {
                        ProgressView().tint(FlimTheme.textTertiary).padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshableToCompletion { await reload() }
            // Swiping the feed puts the keyboard away (the comments sheet's composer can
            // leave one up); interactively, so it tracks the drag.
            .scrollDismissesKeyboard(.interactively)
            // First layout can land slightly below "top" while heights settle; apply the
            // proven double-tap fix automatically, without animation.
            .task { proxy.scrollTo("top", anchor: .top) }
            .onChange(of: scrollToTop) {
                withAnimation(.snappy) { proxy.scrollTo("top", anchor: .top) }
            }
            // The boundary-triggered reload replaced page one while the reader's scroll offset
            // was still wherever it was left; land back at the top exactly like the initial
            // load, unanimated (this fires with the app likely still backgrounded, not mid-
            // gesture, so there's no scroll to animate away from).
            .onChange(of: boundaryReloadGeneration) {
                proxy.scrollTo("top", anchor: .top)
            }
            .overlay(alignment: .top) {
                if hasNewPosts {
                    Button {
                        hasNewPosts = false
                        newPostsFromOthers = false
                        Haptics.tap()
                        Task {
                            await reload()
                            withAnimation { proxy.scrollTo("top", anchor: .top) }
                        }
                    } label: {
                        Label("New posts", systemImage: "arrow.up")
                            .flimFont(13.5, weight: .semibold, relativeTo: .subheadline)
                            .foregroundStyle(.black)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(accent, in: Capsule())
                            .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                    }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                } else if refreshFailedToast {
                    Label("Couldn't refresh", systemImage: "wifi.exclamationmark")
                        .flimFont(13.5, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else if let feedNotice {
                    Text(feedNotice)
                        .flimFont(13.5, weight: .semibold, relativeTo: .subheadline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    /// The separator between two units: a hairline that fades out 48pt from each edge, 14pt
    /// of air above, and the next author's title-weight handle below. A rule that stops
    /// cleanly draws a box, and a box is the card this design removed to give the
    /// photographs their width.
    private var seam: some View {
        LinearGradient(
            stops: seamStops,
            startPoint: .leading, endPoint: .trailing
        )
        .frame(height: 1)
        // 24 above, 12 below (the next band brings its own 10): the original 14/0 read as
        // two days shoulder-to-shoulder, per the owner on the first live scroll-through.
        // A 1px line with air around it also reads quieter than the same line without.
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var seamStops: [Gradient.Stop] {
        let fade = containerWidth > 0 ? min(0.45, 48 / containerWidth) : 0.12
        let stroke = Color(red: 0.14, green: 0.14, blue: 0.14)
        return [
            .init(color: .clear, location: 0),
            .init(color: stroke, location: fade),
            .init(color: stroke, location: 1 - fade),
            .init(color: .clear, location: 1),
        ]
    }

    /// The end of what is NEW, not the end of the scroll: on this archive feed the days
    /// already seen continue below it, and it never claims there is nothing under it.
    private var caughtUpBlock: some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(accent)
                .frame(width: 24, height: 2)
            Text("You're caught up")
                .flimFont(19, weight: .light, relativeTo: .body)
                .tracking(0.4)
                .foregroundStyle(FlimTheme.textPrimary)
            Text(caughtLine)
                .flimFont(12.5, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
            Button {
                NotificationCenter.default.post(name: .openCamera, object: nil)
            } label: {
                Label("Shoot something", systemImage: "camera.aperture")
                    .flimFont(14, weight: .medium, relativeTo: .subheadline)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 40)
    }

    private var caughtLine: String { "Nothing new until someone shoots something." }

    // MARK: - First run, loading

    /// An account with no follows is not an account that is caught up, so none of the
    /// caught-up block appears here: no accent mark, no "Shoot something". It states the
    /// reason and offers the two things that exist. FLIM is invite-only, so there is no
    /// suggested-strangers rail, no discovery surface, and no list of people you have not
    /// followed yet: a guilt list ranks people, which this design refuses everywhere else.
    private var firstRunState: some View {
        VStack(spacing: 11) {
            Spacer()
            Text("You don't follow anyone yet")
                .flimFont(19, weight: .light, relativeTo: .body)
                .tracking(0.4)
                .foregroundStyle(FlimTheme.textPrimary)
            Text("Follow someone and their shots show up here, a day at a time.")
                .flimFont(13.5, relativeTo: .subheadline)
                .foregroundStyle(FlimTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 46)
            VStack(spacing: 9) {
                // One destination with the header's person-plus, not two: the button
                // teaches where that action lives afterwards.
                Button { showDiscover = true } label: {
                    Label("Find your friends", systemImage: "person.badge.plus")
                        .flimFont(14, weight: .medium, relativeTo: .subheadline)
                        .foregroundStyle(accent)
                        .frame(width: 212, height: 38)
                        .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                }
                // Not a screen: the system share sheet carrying an invite link, which keeps
                // invites out of the app rather than growing a referrals surface.
                // Gated on quota, the same way InviteSheet is. Without this, someone who has
                // spent all three invites keeps being offered a share button that sends a friend
                // a code which now fails, and neither of them can tell why. This empty state is
                // exactly where that happens: it stays on screen while a new person invites their
                // circle BEFORE they have posted anything, so it is the likeliest place in the
                // app to hand out a dead code. `.unknown` and `.unlimited` both still offer it:
                // never hide a working code because a lookup failed.
                if inviteQuota != .remaining(0), let code = auth.currentUser?.inviteCode {
                    ShareLink(item: AppInfo.personalInviteMessage(code: code)) {
                        Label("Invite someone", systemImage: "paperplane")
                            .flimFont(14, weight: .medium, relativeTo: .subheadline)
                            .foregroundStyle(FlimTheme.textPrimary)
                            .frame(width: 212, height: 38)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
                    }
                    .simultaneousGesture(TapGesture().onEnded {
                        Activation.log(.inviteSent); Usage.log(.inviteSharedFeed)
                    })
                }
            }
            .padding(.top, 9)
            Text("Find someone you know, or invite a friend. The feed is the people you follow, newest first.")
                .flimFont(12.5, relativeTo: .footnote)
                .foregroundStyle(FlimTheme.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 46)
                .padding(.top, 13)
            Spacer()
            Spacer()
        }
    }

    /// The unit's own geometry at rest: band, the photograph's exact well, the reaction
    /// slots, all at 6% white. Only the band's bars breathe; motion on a screen-filling
    /// rectangle is a spinner by another name. The strip is NOT reserved: the shot count is
    /// unknown until the page lands, and a placeholder strip would have to invent one, which
    /// is the filler-slot problem arriving one step earlier.
    private var loadingState: some View {
        ScrollView {
            FeedUnitSkeleton()
        }
        .disabled(true)
    }

    // MARK: - Loading & paging

    private func unitAppeared(index: Int) {
        advancePrefetch(reaching: index)
        guard index == units.count - 1, let uid = auth.currentUser?.id else { return }
        Task {
            let alreadyLoaded = units.count
            await feed.loadMoreFeed(currentUserId: uid)
            await feed.completeStraddlingDays(currentUserId: uid)
            snapshotLedger(growOnly: true)
            await prefetchUnitHeroes(from: alreadyLoaded)
        }
    }

    private func reload() async {
        guard let uid = auth.currentUser?.id else { didLoad = true; return }
        // No card marks itself until this load's caught-up line is placed. The page can render
        // while the Spotlight reads below are still in flight, and a card on screen marking its
        // new shots in that gap would put the line above a card still reading "N new". Every
        // path below reaches the decrement just before this reload's own snapshot.
        reloadsInFlight += 1
        // Captured before the first await: several round trips sit between here and the dot
        // write below, and an account switch mid-flight must not let a stale answer light the
        // NEW account's tab dot; same pattern as `OptimisticToggle`.
        let epoch = AccountEpoch.current
        // Captured before the load: `loadFeed` leaves an already-populated `feed` untouched
        // on a genuine failure, so `feed.feed` staying non-empty can't by itself say whether
        // this refresh worked.
        let hadContent = !feed.feed.isEmpty
        // The account's copy of the seen-marks goes up first, so the tab dot's server check
        // on the next foreground agrees with what this phone has already read.
        await seenStore.flushPending()
        // Beside the feed, not after it: the strip must be in hand before the first snapshot
        // below places it, or it would pop in above a feed that was already drawn.
        async let spotlightStrip: Void = feed.loadSpotlightStrip()
        // Same reason for the account's own entry: it decides whether "Spotlight is new." shows
        // (1.6.0), and fetched after the feed it popped the line in over drawn cards.
        async let ownSpotlightEntry: Void = feed.refreshOwnSpotlightEntry()
        await feed.loadFeed(currentUserId: uid)
        await spotlightStrip
        await ownSpotlightEntry
        if AccountEpoch.isCurrent(epoch) { seenSpotlight = SpotlightSeenMark.seen(userId: uid) }
        // A stale reload (the account switched while `loadFeed` was in flight) must not write
        // the two flags that say the load finished: the reload for the new account that
        // follows would find `didLoad` already true and never restart its own loading state.
        if AccountEpoch.isCurrent(epoch) {
            didLoad = true
            loadedEpoch = epoch
            hasNewPosts = false
            newPostsFromOthers = false
        }
        // Snapshotted from page one, BEFORE the straddle completion's extra round trips: the
        // units render the moment the page lands, and the caught-up block waiting on the
        // completion appeared a beat after them, popping in at the top of an already-drawn
        // feed. The completion below then re-snapshots grow-only, the same way paging does.
        reloadsInFlight -= 1
        snapshotLedger()
        // After the snapshot, so the re-opened frames' seen-marks land under an already
        // placed seam, the same order every other mark obeys.
        catchUpGeneration += 1
        await feed.completeStraddlingDays(currentUserId: uid)
        snapshotLedger(growOnly: true)
        if hadContent, feed.feedError != nil {
            Haptics.error()
            withAnimation { refreshFailedToast = true }
            Task { try? await Task.sleep(for: .seconds(2)); withAnimation { refreshFailedToast = false } }
        }
        // Three independent round trips — the avatar, the unread-activity count, and the unseen
        // badge refresh — none of which reads or writes what either of the others touches, so
        // they run concurrently instead of one after another. `prefetchUnitHeroes()` below still
        // waits on all three landing (`await`s in sequence, not itself parallelized in): it reads
        // `units`, not any of these, so there's no ordering requirement, it's just the natural
        // place for the function to end.
        async let avatarTask = resolveAvatarURL()
        async let unreadTask = feed.unreadActivityCount(
            userId: uid, since: Date(timeIntervalSince1970: lastActivitySeen))
        async let badgeTask: Void = feed.refreshUnseenBadgeCount()
        // The own-post menu's Spotlight state: refetched on every reload.
        async let spotlightOwnTask: Void = feed.refreshOwnSpotlight(userId: uid)
        if let resolved = await avatarTask { myAvatarURL = resolved }
        unreadActivity = await unreadTask
        // After the snapshot and the unread count, from this account's own answers only.
        if AccountEpoch.isCurrent(epoch) { updateFeedDot() }
        _ = await badgeTask
        _ = await spotlightOwnTask
        prefetchedThrough = 0
        await prefetchUnitHeroes()
    }

    /// `nil` when there's no avatar path to resolve at all (skip the assignment in `reload()`
    /// entirely, keep-last-known); `.some(possiblyNil)` when a path existed and a fetch was
    /// attempted, matching `reload()`'s original `if let path { myAvatarURL = await ... }` shape
    /// exactly: a path that resolves to no URL still overwrites `myAvatarURL`, only a MISSING path
    /// leaves it alone.
    private func resolveAvatarURL() async -> URL?? {
        guard let path = auth.currentUser?.avatarPath else { return nil }
        return await feed.signedURL(for: path)
    }

    /// The load-time snapshot: runs the backlog seed, rebuilds the units, and places the
    /// caught-up seam and the Spotlight strips. The name is older than the header count's
    /// removal (2026-09-26); what it snapshots now is the seam and the strips.
    ///
    /// `growOnly` is the paging case: an older page can bring an unseen day below the seam, but
    /// reading in the meantime must not pull the seam or a strip back up the feed.
    private func snapshotLedger(growOnly: Bool = false) {
        // Before the units are built and the seam placed: on an upgrader's first pass this seeds
        // the backlog seen, so what is computed below already reflects it. One-shot and guarded,
        // a cheap no-op every time after.
        seedFeedBacklogIfNeeded()
        // Explicit, not left to the `.onChange(of: feed.feed)` safety net: everything below this
        // line reads `units` (the cache) synchronously, in the same function call, before
        // SwiftUI's own change-tracking would ever have a chance to fire. See `cachedUnits`'s own
        // doc.
        recomputeUnits()
        ledgerSnapshotted = true
        snapshotSeam(growOnly: growOnly)
        // After the seam: an unseen strip's slot depends on where the seam now sits.
        snapshotSpotlight(growOnly: growOnly)
    }

    // MARK: - Spotlight strip

    /// Places every strip week. A full snapshot re-places all of them; `growOnly` (paging, a
    /// straddle completion, a block, a delete) keeps every slot that still has its anchor and
    /// only places the ones that were waiting on an unloaded page or lost their unit, at their
    /// own place, never lifted over the seam. See `SpotlightSlot.snapshot`.
    private func snapshotSpotlight(growOnly: Bool) {
        let seam: SpotlightSeam
        switch caughtUp {
        case .pending: seam = .none
        case .top: seam = .top
        case .after(let id): seam = .after(id)
        }
        spotlightSlots = SpotlightSlot.snapshot(
            previous: spotlightSlots, weeks: feed.spotlightStripWeeks, units: units, seam: seam,
            hasMoreFeed: feed.hasMoreFeed, seen: seenSpotlight, growOnly: growOnly)
    }

    private var spotlightSlotsHaveOrphans: Bool {
        let unitIds = units.map(\.id)
        return spotlightSlots.values.contains { slot in
            switch slot {
            case .beforeUnit(let id), .aboveCaughtUpBlock(let id): return !unitIds.contains(id)
            default: return false
            }
        }
    }

    /// The strips snapshotted into `slot`, each with a hairline on the side facing the unit
    /// it sits against.
    @ViewBuilder
    private func spotlightStrips(in slot: SpotlightSlot, seamBefore: Bool) -> some View {
        ForEach(visibleSpotlightWeeks.filter { spotlightSlots[$0.weekKey] == slot }) { week in
            if seamBefore { seam }
            spotlightStrip(week)
            if !seamBefore { seam }
        }
    }

    /// Every strip week at the top, for the screens with no units to place them against
    /// (first run, nobody has posted).
    private var allSpotlightStrips: some View {
        ForEach(visibleSpotlightWeeks) { week in
            spotlightStrip(week)
            seam
        }
    }

    private func spotlightStrip(_ week: SpotlightWeek) -> some View {
        SpotlightStrip(
            week: week,
            isNew: !seenSpotlight.contains(week.weekKey),
            openingId: openingSpotlightFrame,
            onOpenWeeks: {
                Usage.log(.spotlightWeeksOpen)
                spotlightSheet = SpotlightSheetRoute(focusWeek: week.weekKey)
            },
            onOpenFrame: { openSpotlightFrame($0, weekKey: week.weekKey) }
        )
        // Seen by VISIBILITY, never `onAppear`: the LazyVStack builds rows ahead of the
        // viewport, and a strip nobody scrolled to must keep its pill. Marking never moves it;
        // its slot was snapshotted.
        .onScrollVisibilityChange(threshold: 0.5) { visible in
            guard visible else { return }
            markSpotlightSeen(week.weekKey)
        }
    }

    private func markSpotlightSeen(_ weekKey: String) {
        guard !seenSpotlight.contains(weekKey) else { return }
        seenSpotlight.insert(weekKey)
        SpotlightSeenMark.mark(weekKey, userId: auth.currentUser?.id)
    }

    /// Fetches the post first, like a `.post` push, so a frame deleted or hidden since the
    /// week was read says so instead of opening.
    private func openSpotlightFrame(_ frame: SpotlightFrame, weekKey: String) {
        guard openingSpotlightFrame == nil else { return }
        Usage.log(.spotlightStripOpen)
        openingSpotlightFrame = frame.postId
        Task {
            let result = await feed.openSpotlightFrame(frame)
            openingSpotlightFrame = nil
            switch result {
            case .item(let item):
                spotlightRoute = SpotlightPostRoute(item: item, weekKey: weekKey)
            case .gone:
                Haptics.error()
                UndoCenter.shared.showNotice(SpotlightRefusal.gone)
            case .failed:
                Haptics.error()
                UndoCenter.shared.showNotice(SpotlightRefusal.openNetwork)
            }
        }
    }

    private func showsCaughtUpBlock(after unit: FeedUnit, at index: Int) -> Bool {
        guard case .after(let id) = caughtUp, id == unit.id else { return false }
        // More pages could still bring new below this; the claim waits until they cannot.
        return !(feed.hasMoreFeed && index == units.count - 1)
    }

    /// The seam only ever moves DOWN between reloads: paging can reveal an older unseen day
    /// that belongs above the block, but reading must never pull the block back up the feed.
    /// A pull-to-refresh is a new catch-up moment and re-places it outright.
    private func snapshotSeam(growOnly: Bool) {
        let freshIndex = FeedUnit.caughtUpIndex(units: units, isSeen: { seenStore.isSeen($0) })
        if growOnly {
            switch caughtUp {
            case .after(let currentID):
                guard let current = units.firstIndex(where: { $0.id == currentID }) else {
                    // The unit the seam pointed at is gone (blocking its author is the only
                    // way that happens mid-session): re-derive against the CURRENT units
                    // instead of leaving a reference to nothing, which silently dropped the
                    // block for the rest of the session.
                    caughtUp = freshIndex.map { .after(units[$0].id) } ?? (units.isEmpty ? .pending : .top)
                    return
                }
                if let freshIndex, freshIndex > current {
                    caughtUp = .after(units[freshIndex].id)
                }
            case .top, .pending:
                if let freshIndex {
                    caughtUp = .after(units[freshIndex].id)
                }
            }
        } else if let freshIndex {
            caughtUp = .after(units[freshIndex].id)
        } else {
            caughtUp = units.isEmpty ? .pending : .top
        }
    }

    /// Warms each unit's OPENING frame, not every post: the strip's thumbnails are tiny and
    /// load on demand, and the pager only renders the selected page and its neighbours, so
    /// the hero is the one image a unit needs the moment it scrolls in. This is the egress
    /// shape the grouping buys: a page of units costs a handful of heroes, not a page of
    /// full-size cards.
    private func prefetchUnitHeroes(from startUnit: Int = 0) async {
        let slice = units.dropFirst(startUnit).prefix(Self.prefetchWindow)
        let paths = slice.map { unit in
            unit.items[unit.openingIndex(isSeen: { seenStore.isSeen($0) })].post.cardPath
        }
        guard !paths.isEmpty else { return }
        prefetchedThrough = max(prefetchedThrough, startUnit + paths.count)
        let urls = await feed.signedURLs(for: Array(Set(paths)))
        let items = paths.compactMap { path -> (url: URL, cacheKey: String?)? in
            urls[path].map { ($0, path) }
        }
        ImageLoader.prefetch(items, maxPixel: 1400, scale: displayScale)
    }

    /// How many units ahead to warm; roughly one hero is visible at a time, so this is
    /// several screens of runway.
    private static let prefetchWindow = 6

    private func advancePrefetch(reaching index: Int) {
        guard index >= prefetchedThrough - 2, prefetchedThrough < units.count else { return }
        Task { await prefetchUnitHeroes(from: prefetchedThrough) }
    }

    private func refreshUnreadActivity() async {
        guard let uid = auth.currentUser?.id else { return }
        let epoch = AccountEpoch.current
        let seenMark = lastActivitySeen
        let count = await feed.unreadActivityCount(userId: uid, since: Date(timeIntervalSince1970: seenMark))
        // Activity opened during the round trip zeroed the count and moved the mark; this answer
        // predates that and would light the bell again for what was just read.
        guard AccountEpoch.isCurrent(epoch), lastActivitySeen == seenMark else { return }
        // Only ever raised here. A failed count reads as 0 (offline on return), and the count
        // only really falls when Activity is opened, which zeroes it itself.
        unreadActivity = max(unreadActivity, count)
        if didLoad, loadedEpoch == epoch { updateFeedDot() }
    }

    private func checkNewPosts() async {
        guard let uid = auth.currentUser?.id else { return }
        let epoch = AccountEpoch.current
        let fresh = await feed.peekFeed(currentUserId: uid)
        guard AccountEpoch.isCurrent(epoch) else { return }
        if let newTop = fresh.first?.id, newTop != feed.feed.first?.id {
            withAnimation { hasNewPosts = true }
            let loaded = Set(feed.feed.map(\.post.id))
            let loadedTop = feed.feed.first?.post.createdAt ?? .distantPast
            newPostsFromOthers = fresh.contains {
                $0.post.userId != uid && !loaded.contains($0.post.id)
                    && $0.post.createdAt > loadedTop && !seenStore.isSeen($0.post.id)
            }
            if didLoad, loadedEpoch == epoch { updateFeedDot() }
        }
    }
}

/// Whether "View N comments" has anything to offer beyond what the preview already shows in
/// full; with every comment already visible it would just repeat what's on screen.
func hasCommentsBeyondPreview(total: Int, shownInPreview: Int) -> Bool {
    total > shownInPreview
}

// MARK: - Skeleton

/// One unit's geometry at rest, shown while the first page loads. The bars breathe at 1.6s;
/// the photograph's well deliberately does not.
struct FeedUnitSkeleton: View {
    @State private var breathing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Circle().fill(Color.white.opacity(0.06)).frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 6) {
                    bar(width: 84, height: 11)
                    bar(width: 134, height: 8)
                }
                Spacer()
            }
            .padding(.top, 10)
            .padding(.leading, 16)
            .padding(.bottom, 6)

            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
                .aspectRatio(3 / 4, contentMode: .fit)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { _ in
                    Circle().fill(Color.white.opacity(0.06)).frame(width: 30, height: 30)
                }
                Spacer()
                Circle().fill(Color.white.opacity(0.06)).frame(width: 30, height: 30)
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
        }
        .onAppear { breathing = true }
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.06))
            .frame(width: width, height: height)
            .opacity(breathing ? 1 : 0.5)
            .animation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true), value: breathing)
    }
}

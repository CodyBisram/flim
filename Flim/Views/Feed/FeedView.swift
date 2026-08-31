import SwiftUI
import UIKit

/// The feed: one unit per author per 04:00-bounded day (`FeedUnit`), rendered edge-to-edge
/// on the ground with hairline seams, replacing the one-card-per-post list that let a
/// 14-shot day fill every follower's catch-up before anyone else appeared.
///
/// What arrived sits in the header BESIDE the screen's name, as a notification rather than a
/// title: it states what arrived, never ticks down as you read, and goes when the last mark
/// clears. The caught-up block marks the end of what is NEW, not the end of the scroll: on
/// this archive feed the days already seen continue below it.
struct FeedView: View {
    @Environment(\.flimAccent) private var accent
    var scrollToTop: Int = 0
    @Environment(AuthService.self) private var auth
    @Environment(FeedService.self) private var feed
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
    @State private var didLoad = false
    /// A pull-to-refresh that genuinely failed while the feed already had content on screen;
    /// see `reload()`. A failure that touches nothing on screen still needs to say something.
    @State private var refreshFailedToast = false
    @State private var unreadActivity = 0
    /// The previous `lastActivitySeen`, handed to Activity so it can show a "New" section.
    @State private var activitySeenBefore: Date?
    @AppStorage("lastActivitySeen") private var lastActivitySeen: Double = 0
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
    /// The header ledger, SNAPSHOTTED at load rather than derived live: it counts what
    /// arrived, not what is left, so reading a shot must not tick it down. It disappears
    /// (rather than recomputing) when the last mark clears.
    @State private var ledger: (shots: Int, friends: Int)?
    /// What the ledger is made of, per unit id, so grow-only refreshes ratchet by MERGING
    /// units rather than taking a component-wise max of two totals (which paired shot and
    /// friend counts from different snapshots into a line that was never true of any
    /// moment). `ledger` is always `FeedUnit.ledgerTotal` of this.
    @State private var ledgerContributions: [String: FeedUnit.LedgerContribution] = [:]
    /// Gates the cards' seen-marking until the ledger snapshot exists, so snapshot-then-mark
    /// is an ordering guarantee rather than a race against the first visibility event.
    @State private var ledgerSnapshotted = false
    /// Bumped by every EXPLICIT catch-up (initial load, pull-to-refresh, the New-posts
    /// button, and a 04:00 boundary crossed while backgrounded), telling living unit cards to
    /// re-open on their first unseen shot. A unit's
    /// opening frame is otherwise computed only at view birth, so a fresh launch opened on a
    /// friend's new shot while a session that watched it arrive stayed parked on frame one.
    /// Only explicit actions bump this: a background refresh must never move a pager someone
    /// is mid-read on.
    @State private var catchUpGeneration = 0
    /// Where the caught-up block sits, SNAPSHOTTED at load like the ledger and for the same
    /// reason: it marks the seam between new and old at the catch-up moment. Derived live,
    /// reading a unit moved the "last unseen" boundary backwards and the block crawled UP
    /// the feed as you scrolled, surfacing under the first unit whose deeper frames you had
    /// not swiped to. A seam that moves while you read is not a seam.
    private enum CaughtUpSeam: Equatable {
        case pending          // nothing loaded yet, show no block
        case top              // nothing anywhere was unseen at load: block above the archive
        case after(String)    // below this unit id, above the already-seen days
    }
    @State private var caughtUp: CaughtUpSeam = .pending

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
    // drives only the pill, the ledger, the seam, and where a unit opens. The consequence of any
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
    /// Runs at the top of `snapshotLedger`, so the ledger and pills computed just after it reflect
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

    /// Whether the header ledger still has anything to stand for. Mirrors the ledger's own
    /// author exclusion (you are not your own friend): the ledger must go out when the last
    /// FRIEND mark clears. Counting your own units here kept a stale friend count lit
    /// indefinitely — your own deeper frames stay honestly unseen unless you swipe your own
    /// day, and those are exactly the posts the ledger refuses to count.
    private var anythingUnseen: Bool {
        let uid = auth.currentUser?.id
        return units.contains {
            $0.author.id != uid && $0.unseenCount(isSeen: { seenStore.isSeen($0) }) > 0
        }
    }
    /// First run: nobody followed and nothing to show. Not "caught up", which describes a
    /// feed that ran out rather than one that has not started.
    private var followsNobody: Bool {
        didLoad && feed.feed.isEmpty && feed.feedError == nil && feed.followingIds.isEmpty
    }

    var body: some View {
        ZStack {
            FlimTheme.bg.ignoresSafeArea()

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
                        firstRunState
                    } else {
                        // Followed people, none of whom have ever posted: the caught-up
                        // block is the whole screen, since there is nothing older either.
                        ScrollView {
                            caughtUpBlock
                                .padding(.top, 120)
                        }
                        .refreshable { await reload() }
                    }
                } else if units.isEmpty {
                    // Posts were FETCHED (feed.feed is non-empty) but every unit has cleared:
                    // the whole feed was seen and the 4am boundary passed. Without this branch
                    // the screen fell through to `feedList`, whose ForEach over zero units
                    // painted nothing, and the caught-up seam sat parked in `.pending`, so the
                    // first fully-caught-up morning rendered as a bare black page with a
                    // header. The block IS the screen here, same as the never-posted case.
                    ScrollView {
                        caughtUpBlock
                            .padding(.top, 120)
                    }
                    .refreshable { await reload() }
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
        .onChange(of: feed.feed) { _, _ in recomputeUnits() }
        .navigationBarHidden(true)
        .task {
            // `feed_viewed` semantics: once per time this view genuinely appears (initial
            // mount plus every later switch back to the Feed tab); see the tab-content
            // appearance note on `CameraViewModel.start()`. Riding `.task` keeps it from
            // firing on re-renders or scene-phase changes.
            Usage.log(.feedViewed)
            // Only the empty state reads this, and it fails soft to `.unknown`, which still
            // offers the invite. Cheap enough to ride the existing appear rather than earn a
            // task of its own.
            inviteQuota = await auth.ownInviteQuota()
            if let path = auth.currentUser?.avatarPath { myAvatarURL = await feed.signedURL(for: path) }
            if feed.feed.isEmpty {
                await reload()
            } else {
                didLoad = true
                if ledger == nil { snapshotLedger() }
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
        // the ledger, seam and cleared set are allowed to recompute. An ordinary foregrounding
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
            guard !feed.feed.isEmpty else { return }
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

    // MARK: - Header

    /// The compact bar: the screen's own name, then what arrived BESIDE it after a small
    /// dot, in the accent with a soft glow and no fill and no border. As a row in the flow
    /// the count cost 90pt and pushed the first shot's reactions off the fold; as the title
    /// it could never disappear. Beside the title it is a notification: true right now, gone
    /// when the last mark clears, never a zero.
    private var header: some View {
        HStack(spacing: 10) {
            Text("Feed")
                .flimFont(17, weight: .light, relativeTo: .body)
                .tracking(0.5)
                .foregroundStyle(FlimTheme.textSecondary)
            if let ledger, anythingUnseen {
                Text("·")
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(FlimTheme.textTertiary)
                Text(ledgerLabel(ledger))
                    .flimFont(12.5, relativeTo: .footnote)
                    .foregroundStyle(accent)
                    .shadow(color: accent.opacity(0.55), radius: 6)
                    .lineLimit(1)
                    .transition(.opacity)
            }
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
                lastActivitySeen = Date().timeIntervalSince1970
                unreadActivity = 0
                showActivity = true
            } label: {
                Image(systemName: unreadActivity > 0 ? "bell.badge" : "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(accent)
                    .symbolEffect(.bounce, value: unreadActivity)
                    .frame(width: 38, height: 38)
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
                    .frame(width: 38, height: 38)
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
        .animation(.easeOut(duration: 0.4), value: anythingUnseen)
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 6)
    }

    private func ledgerLabel(_ ledger: (shots: Int, friends: Int)) -> String {
        let shots = "\(ledger.shots) shot\(ledger.shots == 1 ? "" : "s")"
        let friends = "\(ledger.friends) friend\(ledger.friends == 1 ? "" : "s")"
        return "\(shots) from \(friends)"
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

                    // Nothing anywhere was unseen at load: the block sits at the top of the
                    // scroll with the days already seen below it.
                    if caughtUp == .top {
                        caughtUpBlock
                    }

                    ForEach(Array(units.enumerated()), id: \.element.id) { index, unit in
                        FeedUnitCard(
                            unit: unit,
                            width: containerWidth,
                            opening: unit.openingIndex(isSeen: { seenStore.isSeen($0) }),
                            seenStore: seenStore,
                            markingEnabled: ledgerSnapshotted,
                            catchUpGeneration: catchUpGeneration,
                            onAuthorBlocked: { snapshotLedger() }
                        )
                        .onAppear { unitAppeared(index: index) }

                        // The seam between new and old: the caught-up block below the last
                        // unit that held anything unseen AT LOAD, unless more pages could
                        // still bring new below it. Otherwise a hairline, ink not a card.
                        if showsCaughtUpBlock(after: unit, at: index) {
                            caughtUpBlock
                        } else if index < units.count - 1 {
                            seam
                        }
                    }

                    if feed.isLoadingMoreFeed {
                        ProgressView().tint(FlimTheme.textTertiary).padding(.vertical, 12)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await reload() }
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
                    .frame(height: 38)
                    .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 38)
        .padding(.horizontal, 40)
    }

    /// "All seen" is a live claim, never the snapshot's: the block's position is pinned at
    /// load, but a reader can scroll to it with frames still unreached inside a group above
    /// (their pills say so), and the copy must not contradict the ledger still lit in the
    /// header.
    private var caughtLine: String {
        let closer = "Nothing new until someone shoots something."
        guard let ledger else { return closer }
        return anythingUnseen
            ? "\(ledgerLabel(ledger)).\n\(closer)"
            : "\(ledgerLabel(ledger)), all seen.\n\(closer)"
    }

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
            Text("\(AppInfo.appName) is invite only. Nobody is suggested to you, and nobody is ranked.")
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
        // Captured before the load: `loadFeed` leaves an already-populated `feed` untouched
        // on a genuine failure, so `feed.feed` staying non-empty can't by itself say whether
        // this refresh worked.
        let hadContent = !feed.feed.isEmpty
        await feed.loadFeed(currentUserId: uid)
        didLoad = true
        hasNewPosts = false
        // Snapshotted from page one, BEFORE the straddle completion's extra round trips: the
        // units render the moment the page lands, and the caught-up block waiting on the
        // completion appeared a beat after them, popping in at the top of an already-drawn
        // feed. The completion below then re-snapshots grow-only, the same way paging does.
        snapshotLedger()
        // After the snapshot, so the re-opened frames' seen-marks land under an already
        // computed ledger, the same order every other mark obeys.
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
        if let resolved = await avatarTask { myAvatarURL = resolved }
        unreadActivity = await unreadTask
        _ = await badgeTask
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

    /// Re-derived at each load, then held: the number states what arrived and must not
    /// shrink as marks clear. Visibility is separate (`anythingUnseen`), which is what lets
    /// it fade rather than count down.
    ///
    /// `growOnly` is the paging case: an older page can bring unseen units into the list
    /// (they arrived, so the ledger should say so), but units read in the meantime must not
    /// pull the number back down, so the held value only ever ratchets upward between
    /// genuine reloads.
    private func snapshotLedger(growOnly: Bool = false) {
        // Before the units are built and the ledger read: on an upgrader's first pass this seeds
        // the backlog seen, so what is computed below already reflects it. One-shot and guarded,
        // a cheap no-op every time after.
        seedFeedBacklogIfNeeded()
        // Explicit, not left to the `.onChange(of: feed.feed)` safety net: everything below this
        // line reads `units` (the cache) synchronously, in the same function call, before
        // SwiftUI's own change-tracking would ever have a chance to fire. See `cachedUnits`'s own
        // doc.
        recomputeUnits()

        // You are not your own friend: see `FeedUnit.ledgerContributions`'s own doc for why
        // this and `anythingUnseen` are the only seen-state derivations that exclude your
        // own posts (unit rendering, seen pills, `caughtUpIndex`, and retention all keep
        // counting them normally).
        let fresh = FeedUnit.ledgerContributions(units: units, isSeen: { seenStore.isSeen($0) },
                                                 excludingAuthor: auth.currentUser?.id)
        ledgerContributions = growOnly
            ? FeedUnit.mergedLedgerContributions(counted: ledgerContributions, fresh: fresh)
            : fresh
        ledger = FeedUnit.ledgerTotal(ledgerContributions)
        ledgerSnapshotted = true
        snapshotSeam(growOnly: growOnly)
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

    private func checkNewPosts() async {
        guard let uid = auth.currentUser?.id else { return }
        let fresh = await feed.peekFeed(currentUserId: uid)
        if let newTop = fresh.first?.id, newTop != feed.feed.first?.id {
            withAnimation { hasNewPosts = true }
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

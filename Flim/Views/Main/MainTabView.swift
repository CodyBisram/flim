import SwiftUI

/// Whether the post about to be pushed at `pushedPostId` should land with the comment composer
/// already focused, and what `focusCommentsPostId` becomes once that focus has been consumed.
///
/// Pure so the one-shot rule is structural rather than a claim in a comment: a stray keyboard
/// popping on a post you were only looking at (a feed card, a profile grid, an Activity row)
/// happened because the flag that armed the FIRST focus was never cleared, so SwiftUI re-evaluating
/// the same `navigationDestination` closure for a later, ordinary push of the SAME post re-armed it
/// too. Consuming this decision's `nextFocusPostId` (see `MainTabView`'s use, from
/// `PostDetailView`'s own consumed callback, not synchronously after the push) is what makes the
/// arm-and-clear atomic from the caller's point of view.
func focusCommentsDecision(currentFocusPostId: UUID?, pushedPostId: UUID) -> (shouldFocus: Bool, nextFocusPostId: UUID?) {
    let shouldFocus = currentFocusPostId == pushedPostId
    return (shouldFocus, shouldFocus ? nil : currentFocusPostId)
}

/// Whether `maybeShowNotifPrimer` should present the soft primer again on this launch.
///
/// Not yet decided (most often a swipe-away, which is not a decision): may retry, but only up to
/// `maxPresentations` times ever, so an interrupted presentation can't turn into nagging on every
/// single launch.
///
/// Decided ("Turn on notifications" or "Not now" was tapped) is normally a permanent no. But
/// `decided == true` together with `osStatusIsUndetermined == true` proves iOS was demonstrably
/// NEVER asked on this install: had "Turn on" actually run `requestAuthorizationIfNeeded()`, iOS
/// would now report `.authorized` or `.denied`, never `.notDetermined`. That combination is
/// exactly what the old dismiss-driven bug left behind (every swipe-away used to be recorded as a
/// decision), plus anyone who tapped "Not now" and never got the real system prompt. That group
/// gets re-asked exactly once, tracked by `didRetryUnaskedPrimer` and wholly independent of
/// `maxPresentations`/`timesShown`, so the two mechanisms can't feed each other. `.authorized` and
/// `.denied` never re-present: iOS already has a real answer, and for `.denied` a second system
/// prompt is not even possible.
///
/// Pure so both rules are structural rather than a claim in a comment, the way `shouldTreatAsDeleted`
/// and `resolvedCaption` pin `FeedService`'s rules.
func shouldPresentNotifPrimer(
    decided: Bool,
    timesShown: Int,
    osStatusIsUndetermined: Bool,
    didRetryUnaskedPrimer: Bool,
    maxPresentations: Int = 3
) -> Bool {
    if !decided {
        return timesShown < maxPresentations
    }
    return osStatusIsUndetermined && !didRetryUnaskedPrimer
}

struct MainTabView: View {
    @Environment(\.flimAccent) private var accent
    @State private var selected = 0
    /// Per-tab counter, bumped when you re-tap the tab you're already on, so that tab scrolls to top.
    @State private var scrollSignal: [Int: Int] = [:]
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @AppStorage("accentColor") private var accentColor = "amber"   // re-tints on change
    /// True only once the person has genuinely decided (tapped "Turn on notifications" or "Not
    /// now"), never merely because the sheet was shown. A swipe-away leaves this false, see
    /// `shouldPresentNotifPrimer` and the `.sheet` below.
    @AppStorage("didShowNotifPrimer") private var didDecideNotifPrimer = false
    /// How many times the primer has been presented (shown, not necessarily decided), across all
    /// launches. Caps retries after a swipe-away so an undecided primer can't nag forever.
    @AppStorage("notifPrimerPresentationCount") private var notifPrimerPresentationCount = 0
    /// Whether the one-time "decided, but iOS was never actually asked" recovery presentation has
    /// already happened. Separate from `notifPrimerPresentationCount` on purpose: the two caps
    /// must never be able to feed each other, see `shouldPresentNotifPrimer`.
    @AppStorage("didRetryUnaskedNotifPrimer") private var didRetryUnaskedNotifPrimer = false
    @State private var showNotifPrimer = false
    @State private var inviteCode: String?
    @Environment(NotificationService.self) private var notifications
    @Environment(NetworkMonitor.self) private var network
    @Environment(AuthService.self) private var auth
    @Environment(RollService.self) private var rolls
    @Environment(FeedService.self) private var feed
    /// Owned here (not in RollsView) so a `reveal` push destination, and `-openRollId` in DEBUG,
    /// can push straight into a roll's detail without the Rolls tab needing to already be open.
    @State private var rollsPath = NavigationPath()
    /// Owned here (not in FeedView) so `profile` and `post` push destinations can push straight
    /// into a page or a post without the Feed tab needing to already be open.
    @State private var feedPath = NavigationPath()
    /// Set alongside a `.post` push destination's `feedPath.append`, so a "someone commented"
    /// notification can land the comment composer already focused. Not part of `feedPath` itself:
    /// a `NavigationPath` element only carries what makes it Hashable, and a focus flag isn't part
    /// of a post's identity.
    ///
    /// Cleared, not just read, by `PostDetailView`'s `onCommentsFocusConsumed` callback once that
    /// post has actually set focus, via `focusCommentsDecision` above. The `navigationDestination`
    /// closure below is re-evaluated by SwiftUI every time a `FeedItem` for ANY post is pushed
    /// (including this same one again later, through an ordinary route like a feed card or a
    /// profile grid), so leaving this set after the first, intended focus would re-arm the
    /// keyboard on every later, unrelated visit to the same post.
    @State private var focusCommentsPostId: UUID?
    #if DEBUG
    @Environment(PhotoService.self) private var photos
    /// Drives `-openPhotoFullscreen`: presents the same full-screen viewer used from the
    /// darkroom/roll grids, without needing a tap to get there.
    @State private var debugFullscreenPhoto: Photo?
    #endif

    /// Selection binding that adds a haptic on tab change and a scroll-to-top on re-tap.
    private var selection: Binding<Int> {
        Binding(
            get: { selected },
            set: { newValue in
                if newValue == selected {
                    scrollSignal[newValue, default: 0] += 1
                } else {
                    Haptics.tap()
                }
                selected = newValue
            }
        )
    }

    var body: some View {
        TabView(selection: selection) {
            Tab("Camera", systemImage: "camera.aperture", value: 0) {
                CameraView()
            }
            Tab("Darkroom", systemImage: "photo.stack", value: 1) {
                NavigationStack {
                    DarkroomView(scrollToTop: scrollSignal[1, default: 0])
                }
            }
            Tab("Rolls", systemImage: "film.stack", value: 2) {
                // A real path (not a plain stack) so a `reveal` push destination, and `-openRollId`
                // in DEBUG, can push a roll's detail programmatically. RollsView declares its own
                // `.navigationDestination(for: Roll.self)`, which this path pushes onto.
                NavigationStack(path: $rollsPath) {
                    RollsView(scrollToTop: scrollSignal[2, default: 0])
                }
            }
            Tab("Feed", systemImage: "house", value: 3) {
                // Both destinations are declared INSIDE the stack, on its content, not on the
                // NavigationStack itself. Hung on the stack they are outside the navigation
                // hierarchy, so a value appended to `feedPath` has no destination visible from
                // where it is pushed: SwiftUI logs "no matching navigationDestination
                // declaration" and renders its own yellow placeholder, which is a pushed screen
                // that is blank apart from a back button. That is what tapping a reaction
                // notification did. The Rolls tab never had the bug because RollsView declares
                // its own destination inside itself.
                NavigationStack(path: $feedPath) {
                    FeedView(scrollToTop: scrollSignal[3, default: 0])
                        .navigationDestination(for: ProfileRoute.self) { UserPageView(userId: $0.id) }
                        .navigationDestination(for: FeedItem.self) { item in
                            let decision = focusCommentsDecision(currentFocusPostId: focusCommentsPostId, pushedPostId: item.id)
                            PostDetailView(
                                item: item,
                                focusCommentsOnAppear: decision.shouldFocus,
                                onCommentsFocusConsumed: { focusCommentsPostId = decision.nextFocusPostId }
                            )
                        }
                }
            }
        }
        // Tint via the OBSERVED accentColor (not the static accent) so the tab bar
        // re-tints the moment the user picks a new accent, the static read never invalidates
        // this view, which left the old color until a relaunch.
        .tint((FlimAccent(rawValue: accentColor) ?? .amber).color)
        // The environment accent is injected at the app root (see FlimApp), so it covers the
        // auth screens too. Nothing extra is needed here.
        .overlay(alignment: .top) {
            if !network.isConnected {
                Label("No connection", systemImage: "wifi.slash")
                    .flimFont(13, weight: .medium)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: network.isConnected)
        .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { _ in })) {
            OnboardingView()
        }
        #if DEBUG
        // `-openPhotoFullscreen`, the same unified viewer the darkroom/roll grids use.
        .fullScreenCover(item: $debugFullscreenPhoto) { photo in
            PhotoPagerView(photos: [photo], signedURLs: [:])
        }
        #endif
        // No `onDismiss` here on purpose: a swipe-away must not count as a decision. Only the
        // sheet's own buttons report a decision, via `onDecision`, see `NotificationPrimerSheet`.
        .sheet(isPresented: $showNotifPrimer) {
            NotificationPrimerSheet(onDecision: { didDecideNotifPrimer = true })
        }
        .sheet(isPresented: Binding(get: { inviteCode != nil }, set: { if !$0 { inviteCode = nil } })) {
            JoinRollView(initialCode: inviteCode ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .openRollInvite)) { note in
            selected = 2   // Rolls tab
            inviteCode = note.object as? String
            // This view was alive to catch it, so the written copy is redundant. Leaving it would
            // re-open the join sheet on the next launch, for a roll already joined.
            PendingRollInvite.clear()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDarkroom)) { _ in
            selected = 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .openCamera)) { _ in
            selected = 0
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPushDestination)) { note in
            if let destination = note.object as? PushDestination {
                route(to: destination)
            }
            // This view was alive to catch it, so the written copy is redundant, matching
            // `.openRollInvite` just above. Leaving it would route the same tap again on the next
            // cold launch.
            PendingPushDestination.clear()
        }
        // Show the soft primer once, after onboarding, with context, instead of a cold
        // system prompt on first launch (which gets denied far more often).
        .onChange(of: hasOnboarded) { _, done in if done { maybeShowNotifPrimer() } }
        .onAppear {
            // This view only exists once there's an authenticated, fully-resolved session (see
            // ContentView), so this is "reached the main UI", not process start. Firing here
            // (rather than in FlimApp's init) is the whole point: init runs before sign-in.
            Activation.log(.firstLaunch)
            Usage.log(.appOpen)
            // Once per launch, not on every feed reload: this ratchets twelve predicates
            // server-side, and badges are not time critical. This is also the only reliable path
            // that lights the tab dot for a badge earned since the last launch, see
            // `FeedService.refreshOwnBadges`.
            Task { await feed.refreshOwnBadges() }
            // Same once-per-launch slot, same reasoning: the widget's answer changes when a frame
            // is shot or reacted to, neither of which is urgent enough to re-derive more often.
            WidgetSync.refresh()
            // A roll link that opened the app from cold arrives before this view exists, so the
            // notification finds nobody. The code is on disk; collect it here.
            if let held = PendingRollInvite.take() {
                selected = 2
                inviteCode = held
            }
            // A notification tap that arrived before this view existed (cold start), or before
            // anyone was signed in, left its destination on disk rather than losing it. See
            // `PendingPushDestination` and `.openPushDestination` above.
            if let pending = PendingPushDestination.take() {
                route(to: pending)
            }
            maybeShowNotifPrimer()
            DiskImageCache.trim()   // keep the on-disk image cache bounded

            #if DEBUG
            let args = ProcessInfo.processInfo.arguments
            // Deterministic Simulator verification (no camera in the sim):
            //   -seedDemo : jump to the Darkroom, which auto-seeds personal photos.
            //   -seedRoll : jump to Rolls and seed the first roll (for cover thumbnails).
            if args.contains("-seedDemo") { selected = 1 }
            if args.contains("-tabFeed") { selected = 3 }   // jump to Feed for screenshots
            if args.contains("-seedRoll") {
                selected = 2
                Task {
                    guard let uid = auth.currentUser?.id else { return }
                    try? await rolls.fetchRolls(for: uid)
                    if let first = rolls.rolls.first {
                        await photos.seedDemoPhotos(userId: uid, rollId: first.id)
                        try? await rolls.fetchRolls(for: uid)   // refresh coverPaths
                    }
                }
            }
            //   -openRollId <uuid>          : push straight into that roll's detail.
            //   -openPhotoFullscreen <uuid> : present the full-screen viewer for that photo.
            // Both are for screenshotting screens the sim can't tap into; a roll/photo the
            // account can't see is a graceful no-op, not a crash.
            if let rollIdArg = Self.launchArgValue("-openRollId", in: args),
               let rollId = UUID(uuidString: rollIdArg) {
                selected = 2
                Task {
                    guard let uid = auth.currentUser?.id else { return }
                    try? await rolls.fetchRolls(for: uid)
                    if let roll = rolls.rolls.first(where: { $0.id == rollId }) {
                        rollsPath.append(roll)
                    }
                }
            }
            if let photoIdArg = Self.launchArgValue("-openPhotoFullscreen", in: args),
               let photoId = UUID(uuidString: photoIdArg) {
                Task {
                    debugFullscreenPhoto = await photos.fetchPhoto(id: photoId)
                }
            }
            #endif
        }
    }

    #if DEBUG
    /// Reads the value following a `-flag value` launch argument pair (Xcode scheme launch
    /// arguments come through as separate elements of `ProcessInfo.arguments`).
    private static func launchArgValue(_ flag: String, in args: [String]) -> String? {
        guard let i = args.firstIndex(of: flag), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }
    #endif

    /// Executes a decoded notification tap. Called once from the live `.openPushDestination`
    /// broadcast, and once from `onAppear` for whatever a cold start (or a start with nobody yet
    /// signed in) left on disk.
    ///
    /// Every fetch below is scoped to the account signed in RIGHT NOW, and the id from the payload
    /// is used only to look up content, never to decide whose it is. The payload has no way to say
    /// who a push was really for (a token can outlive an account switch, and this device may not
    /// be signed into the account the push was even sent to), so there is nothing to compare it
    /// against. Instead this trusts the same row-level security every other screen already relies
    /// on to answer "can THIS session see that id": if it can, the fetch returns the content and
    /// this opens it; if it can't (wrong account, signed out and still not signed back in, or the
    /// content is gone entirely — deleted, hidden, moderated, or a roll left) the fetch comes back
    /// empty and this does nothing further, leaving whichever tab it already switched to as a
    /// real, populated screen rather than a blank one.
    private func route(to destination: PushDestination) {
        switch destination {
        case .camera:
            selected = 0

        case .darkroom:
            selected = 1

        case .feed:
            selected = 3

        case .reveal(let rollId):
            selected = 2
            Task {
                guard let uid = auth.currentUser?.id else { return }
                let epoch = AccountEpoch.current
                try? await rolls.fetchRolls(for: uid)
                guard AccountEpoch.isCurrent(epoch) else { return }
                // Not a member (any more), or the roll is gone: RollsView is still showing a real,
                // current list, so this is a graceful no-op rather than a dead end.
                guard let roll = rolls.rolls.first(where: { $0.id == rollId }) else { return }
                // RollDetailView's own `onAppear` decides whether to play the reveal: it only does
                // that once per roll (`rollRevealSeen.<id>`), so a roll whose reveal already played
                // opens the roll itself here, never a replay. See RollDetailView.
                rollsPath.append(roll)
            }

        case .post(let postId, let comments):
            selected = 3
            Task {
                let epoch = AccountEpoch.current
                let post = await feed.fetchPosts(ids: [postId])[postId]
                guard let post else { return }   // deleted, moderated, or blocked either way
                let author = await feed.fetchProfile(id: post.userId)
                guard AccountEpoch.isCurrent(epoch) else { return }
                guard let author else { return }
                focusCommentsPostId = comments ? postId : nil
                feedPath.append(FeedItem(post: post, author: author))
            }

        case .profile(let userId):
            // UserPageView loads and fails safely on its own (a blocked or vanished account shows
            // its own real state, see `UserPageView.load()`), so there's nothing to pre-check here.
            selected = 3
            feedPath.append(ProfileRoute(id: userId))
        }
    }

    private func maybeShowNotifPrimer() {
        guard hasOnboarded else { return }
        Task {
            // Read the real, live OS status rather than trusting stored state: `didDecideNotifPrimer`
            // alone can't tell a genuine decision from the old dismiss-driven bug, only iOS's own
            // answer can, see `shouldPresentNotifPrimer`.
            let osStatusIsUndetermined = await notifications.isUndetermined()
            guard shouldPresentNotifPrimer(
                decided: didDecideNotifPrimer,
                timesShown: notifPrimerPresentationCount,
                osStatusIsUndetermined: osStatusIsUndetermined,
                didRetryUnaskedPrimer: didRetryUnaskedNotifPrimer
            ) else {
                // Not decided yet here, but iOS already has a real answer (granted or denied
                // through some other route, e.g. the Profile settings row): treat that as the
                // decision so this stops asking, matching how a genuine "Turn on"/"Not now" would.
                if !didDecideNotifPrimer, !osStatusIsUndetermined {
                    didDecideNotifPrimer = true
                }
                return
            }
            try? await Task.sleep(for: .seconds(1))   // let them land on the app first
            if didDecideNotifPrimer {
                // The one-time recovery presentation: `decided` is true but iOS was demonstrably
                // never asked. Marked BEFORE presenting, not on dismissal, so a swipe-away here
                // still can't reopen this recovery a second time.
                didRetryUnaskedNotifPrimer = true
            } else {
                notifPrimerPresentationCount += 1
            }
            showNotifPrimer = true
        }
    }
}

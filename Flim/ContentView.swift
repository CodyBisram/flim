import SwiftUI

struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rolls
    @Environment(TabSignals.self) private var tabSignals
    @Environment(ChapterService.self) private var chapters
    @Environment(NotificationService.self) private var notifications
    @Environment(VersionGateService.self) private var versionGate
    @Environment(NetworkMonitor.self) private var network
    @Environment(\.scenePhase) private var scenePhase

    /// Debounces the reconnect retry below so a flapping connection (a subway platform, a weak
    /// Wi-Fi handoff) doesn't fire `retryFailedUploads()` once per flap.
    @State private var reconnectRetryTask: Task<Void, Never>?

    /// The `latest_version` a person already dismissed the nudge for. Compared, not a plain
    /// bool, so dismissing 1.5.0's nudge doesn't swallow a later, genuinely newer 1.6.0 nudge.
    /// See `shouldPresentVersionNudge`.
    @AppStorage("dismissedVersionGateNudge") private var dismissedNudgeVersion = ""
    @State private var showVersionNudge = false

    var body: some View {
        Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-badgePickerDemo") {
                // Simulator-only harness for the badge reveal, which is otherwise unwatchable
                // without a signed-in account holding unseen badges: the sheet as a 22-badge
                // account with everything unseen sees it. See BadgePickerDemoHost.
                BadgePickerDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-feedPreviewDemo") {
                // Same idea for the per-author feed: sign-in is OTP-only, so the redesign is
                // unwatchable without this. Fixture units + cache-planted images, no network.
                FeedPreviewDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-spotlightPreviewDemo") {
                // The feed fixture plus Spotlight: the strip, the sheet of past weeks, the
                // shelves and a stranger's view of a chosen frame. See SpotlightPreviewDemoHost.
                SpotlightPreviewDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-chaptersPreviewDemo") {
                // Same idea again, for the Chapters shelf + recap: fixture months + cache-planted
                // covers, no network, no account. See ChapterPreviewDemoHost.
                ChapterPreviewDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-chromePreviewDemo") {
                // The tab bar, the Camera controls and the Feed and Rolls headers, on the real
                // MainTabView with fixture data and no account. See ChromePreviewDemoHost.
                ChromePreviewDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-pagerPreviewDemo") {
                // The full-screen viewer's top controls on fixture frames. See PagerPreviewDemoHost.
                PagerPreviewDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-chapterStatsPickerDemo") {
                // Same idea, for the chapter-stats visibility picker. See ChapterStatsPickerDemoHost.
                ChapterStatsPickerDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-darkroomEmptyMonthDemo") {
                // The Darkroom's month rung on an empty month with an older month to step into.
                // See DarkroomEmptyMonthDemoHost.
                DarkroomEmptyMonthDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-rollDetailDemo") {
                // A developed roll's detail screen on fixture frames. See RollDetailDemoHost.
                RollDetailDemoHost()
            } else if ProcessInfo.processInfo.arguments.contains("-waitlistPreviewDemo") {
                // The sign-in screen with the waitlist sheet open over it and a stubbed server.
                // See WaitlistPreviewDemoHost.
                WaitlistPreviewDemoHost()
            } else {
                authGate
            }
            #else
            authGate
            #endif
        }
    }

    private var authGate: some View {
        Group {
            if auth.isLoading {
                SplashView()
            } else if !auth.isAuthenticated {
                NavigationStack {
                    EmailAuthView()
                }
                .transition(.opacity)
                // Nobody is signed in, so a held push destination naming one account's roll,
                // post or photo would otherwise be routed for whoever signs in next. Dropped on
                // arrival here (a tap stored before this screen existed) and on every tap made
                // while it is showing; the delegate stores before it broadcasts.
                .onAppear { PendingPushDestination.dropAccountScoped() }
                .onReceive(NotificationCenter.default.publisher(for: .openPushDestination)) { _ in
                    PendingPushDestination.dropAccountScoped()
                }
            } else if auth.isResolvingProfile {
                // Signed in, still fetching the profile, hold on the splash so existing
                // users never see a flash of the username screen.
                SplashView()
            } else if auth.profileUnavailable {
                // Signed in, but the profile could not be FETCHED. Falling through to the
                // username screen here is what locked people out: an existing user was shown
                // sign-up, and the name they already owned came back as taken.
                ErrorState(
                    title: "Couldn't reach your account",
                    message: "Check your connection and try again. You're still signed in."
                ) {
                    await auth.retryProfileLoad()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if auth.currentUser?.username == nil {
                NavigationStack {
                    UsernameView()
                }
                .transition(.opacity)
            } else {
                MainTabView()
                    .transition(.opacity)
            }
        }
        // The single app-level install of "tap anywhere to dismiss the keyboard". Every screen
        // with a text field gets it for free; `.keyboardDismissExempt()` is the only opt-out, used
        // by mention suggestions so picking one doesn't also close the keyboard. See
        // KeyboardDismiss.swift for why this observes taps instead of capturing them.
        .dismissesKeyboardOnBackgroundTap()
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.id)
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.username)
        .animation(.easeInOut(duration: 0.35), value: auth.isLoading)
        .animation(.easeInOut(duration: 0.35), value: auth.isResolvingProfile)
        .animation(.easeInOut(duration: 0.35), value: auth.profileUnavailable)
        // Neither app launch nor sign-in ever asks iOS for a device token on its own; that only
        // happens in response to `registerForRemoteNotifications()`, which today is called from
        // `requestAuthorizationIfNeeded()` (post-capture, an undeveloped roll, or the primer) and
        // nowhere else. A device that already granted permission in an earlier session can
        // therefore go a whole launch, and a whole sign-in, without the app ever re-claiming the
        // live token for whoever is signed in now, leaving it attached to whichever account last
        // triggered one of those three call sites. This re-asks WITHOUT ever requesting
        // authorization (see `shouldRegisterForRemote`), so a first-run user who hasn't seen the
        // primer yet sees no change at all.
        .task { await notifications.registerForRemoteIfAlreadyAuthorized() }
        // Every service cache is keyed by post, photo or roll id, never by account, so none of it
        // invalidates itself when the account changes. Signing out cleared the session and the
        // profile and left all of it populated.
        //
        // Runs once per distinct account, including the one already present at first render (a
        // launch from the cached profile, C-6, sets `currentUser` before this view draws). Without
        // that a warm relaunch activated nothing per account: the seen store stayed signed out
        // (every card "N new", nothing marked), first-time events stayed queued, rolls were not
        // restored, pending captures never came back, the device token was not reclaimed. The
        // activated account is held for the process, so a rebuilt scene never re-runs this for
        // the same account. See `AccountScopeHook`.
        .modifier(AccountScopeHook(accountId: auth.currentUser?.id) { previousId, newId in
            // Before any cache reset below: a pending undoable action belongs to the departing
            // account and its commit closure captures that account's ids, so it commits now,
            // against state that still matches it.
            UndoCenter.shared.flush()
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
            chapters.resetForAccountChange()
            tabSignals.resetForAccountChange()
            // Restored synchronously, right here, rather than waiting for RollsView's own
            // `fetchRolls` call: this runs before MainTabView (and so RollsView) ever mounts for
            // the new account, so the Rolls tab's very first render already has cover paths to
            // paint instead of a blank tile through the whole first network round trip. Named
            // for `newId` only, never the departing `previousId`.
            if let newId { rolls.restore(for: newId) }
            // Covers launch with a restored session (previousId starts nil), sign-in, and a
            // straight account-to-account switch; see FeedSeenStore's own doc for why marks
            // must be namespaced by whoever is actually signed in.
            FeedSeenStore.shared.activeUserId = newId
            Activation.activeUserId = newId
            // Develop reminders and Live Activities are scoped to a ROLL, not an account, so they
            // outlive a sign-out. Only clear them when there WAS a previously-activated account
            // in this process, i.e. a real switch (including straight to signed-out): the very
            // first resolve after launch also lands here (the activated account starts nil), and
            // that one must NOT cancel the account that is simply continuing to be signed in.
            if previousId != nil {
                Task { await NotificationService.cancelAllRollDevelopNotifications() }
                RollLiveActivity.endAll()
                // Anything still held was tapped for the departing account.
                PendingPushDestination.clear()
            }
            // Captures that never reached the server are kept on disk per account, so this is
            // where they come back: on launch, and on signing back in. Without it the files
            // would accumulate forever and nobody would ever be offered the retry.
            if let newId {
                Task {
                    let retryable = await photos.restorePendingCaptures(userId: newId)
                    await photos.restoreFailedUploads(userId: newId, only: retryable)
                }
            }
            // Signing in does not prompt iOS for a new APNs token, so this device would stay
            // registered to whoever was signed in last. Re-asking here too (not just once at
            // launch, in the `.task` above) covers the race where the account resolves before the
            // launch-time `registerForRemoteNotifications()` call has come back with a token: by
            // the time THIS runs, the session this device needs to claim under is guaranteed to be
            // in hand. Registering is a no-op if the token hasn't changed; iOS dedupes. Claiming is
            // what stops one phone from collecting several accounts' notifications.
            if newId != nil {
                Task {
                    await notifications.registerForRemoteIfAlreadyAuthorized()
                    await RemotePush.reclaimForCurrentAccount()
                }
            }
        })
        .onReceive(NotificationCenter.default.publisher(for: .flimAccountDidChange)) { _ in
            // Sign-out posts this. currentUser goes to nil (signOut's `defer` always clears it),
            // which the hook above also catches; the notification is the explicit departure, so
            // always clear the departing account's reminders and Live Activities, not just the
            // caches.
            AccountScopeHook.activatedAccountId = nil
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
            chapters.resetForAccountChange()
            tabSignals.resetForAccountChange()
            FeedSeenStore.shared.activeUserId = nil
            // A notification tapped for the departing account must not route for the next one.
            PendingPushDestination.clear()
            Activation.activeUserId = nil
            Task { await NotificationService.cancelAllRollDevelopNotifications() }
            RollLiveActivity.endAll()
            // The departing account's tiles must not keep showing on the home screen for
            // whoever uses this device next.
            WidgetSync.clear()
        }
        // The capture chip promises "It will send when you're back online," but until now
        // nothing acted on that beyond the next foreground or a manual Retry tap: a shot taken
        // in a dead zone and left alone (app stays open, connection comes back on its own) sat
        // queued indefinitely. Debounced 2 seconds so a flapping connection retries once, not
        // once per flap, and routed through the exact same entry point the foreground handler
        // below uses.
        .onChange(of: network.isConnected) { wasConnected, isConnected in
            guard !wasConnected, isConnected else { return }
            reconnectRetryTask?.cancel()
            reconnectRetryTask = Task {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                // A launch the network interrupted (a cached profile on screen, or the retry
                // state) finishes now: the token refreshes and the profile is read again. Its own
                // task, so a slow answer never holds up the upload retry below. The account's
                // seen-marks follow it, with the fresh token: a launch offline from the cached
                // profile never pulled them, and every card it reads would say "N new" until the
                // next foreground.
                Task {
                    await auth.resyncIfNeeded()
                    FeedSeenStore.shared.retryPullIfNeeded()
                }
                // A reveal finished offline is waiting on this same connection, and an app that
                // stays open never passes through the foreground flush below.
                rolls.flushPendingRevealCompletions()
                guard photos.hasFailedUploads else { return }
                await photos.retryFailedUploads()
            }
        }
        // Attached to the outer Group, not inside any one branch, so it covers whichever of
        // auth/onboarding/MainTabView is showing right now: a blocked build must not be able to
        // reach sign-in either. `set` is a no-op — there is no way to dismiss this; it only
        // closes once a later, passing `check()` moves `decision` off `.blocked`.
        .fullScreenCover(isPresented: Binding(get: { versionGate.decision == .blocked }, set: { _ in })) {
            VersionGateBlockingView(message: versionGate.message)
        }
        .sheet(isPresented: $showVersionNudge, onDismiss: {
            // Recorded on dismissal, not presentation, and for every way the sheet closes (the
            // sheet's own buttons, or a swipe-away): unlike the notification primer, there's no
            // OS-level side effect a swipe needs to be told apart from, so any dismissal is a
            // real one. See `VersionGateNudgeSheet`.
            dismissedNudgeVersion = versionGate.latestVersion
        }) {
            VersionGateNudgeSheet(message: versionGate.message)
        }
        .task { await refreshVersionGate() }
        // Mirrors ProfileView's notification-status re-check: cheap, side-effect-free, and the
        // one moment a stale "you're on the latest version" is actually noticeable.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else {
                // A staged undoable action must not ride out its window in the background: an
                // app killed there would silently lose an action the person watched happen.
                // Leaving the foreground commits it now; see `UndoCenter`. Held under a
                // background assertion (taken here, before suspension can begin) so the commit,
                // or one whose window closed a moment earlier, lands before iOS suspends us.
                let undoKeepAlive = BackgroundKeepAlive.begin("undo commit")
                Task {
                    await UndoCenter.shared.flushAndWait()
                    BackgroundKeepAlive.end(undoKeepAlive)
                }
                // Seen-marks made this session go to the account now, not on the next debounce
                // an app suspended in the background never reaches: the disk copy first
                // (synchronous), then the server mirror.
                FeedSeenStore.shared.flushPersistNow()
                Task { await FeedSeenStore.shared.flushPending() }
                return
            }
            Task { await refreshVersionGate() }
            // The foreground is the other moment the network most likely came back; free when
            // the launch already finished, see `resyncIfNeeded`.
            Task { await auth.resyncIfNeeded() }
            // A reveal finished while offline (or killed before its RPC returned) is retried on
            // every foreground, as `flushPendingRevealCompletions` documents. It used to run in
            // the branch above, on the way INTO the background, where its bare tasks could be
            // suspended mid-request and nothing retried until the next sign-in.
            rolls.flushPendingRevealCompletions()
            // A seen-marks pull that failed at launch (offline) tries again here rather than
            // leaving this phone without the account's reads for the whole session.
            FeedSeenStore.shared.retryPullIfNeeded()
            // The tab dots: a friend may have posted or a roll developed while the app was away.
            if let uid = auth.currentUser?.id {
                Task { await tabSignals.refresh(feed: feed, rolls: rolls, userId: uid, lastActivitySeen: ActivitySeenMark.value(userId: uid)) }
                // The Spotlight menu's state: the week may have turned over, or a frame gone up
                // or down from another phone, while the app was away.
                Task { await feed.refreshOwnSpotlight(userId: uid) }
                // And the strip's frames: their signed URLs may have lapsed while away.
                Task { await feed.refreshSpotlightURLs() }
            }
            // Save-on-develop, not save-on-capture: this is the one place that decides "the app
            // just came to the foreground", which is exactly when a photo shot earlier may have
            // developed since. No background execution, ever; the sweep only ever runs from here
            // (foreground) or MainTabView's own once-per-launch `onAppear` (cold start, which
            // this `onChange` does not itself catch since scenePhase already reads `.active` by
            // the time this view first appears). Single-flight inside the sweep makes firing from
            // both harmless.
            if let uid = auth.currentUser?.id {
                Task { await CameraRollAutoSave.shared.sweep(userId: uid, photoService: photos) }
            }
            // Shots that never reached the server exist only on this phone until they do, and a
            // delete-and-reinstall takes them with it. Coming back to the foreground is the
            // moment the network most likely came back too, so try again without waiting for
            // the person to find the red pill on the camera. One attempt per foreground; a
            // failure lands back in `failedUploads` exactly as a tapped retry would.
            if photos.hasFailedUploads {
                Task { await photos.retryFailedUploads() }
            }
        }
    }

    /// Re-checks `app_release_gate` and recomputes whether the nudge should be showing. Called on
    /// launch and on return to the foreground; `VersionGateService` itself never polls.
    private func refreshVersionGate() async {
        await versionGate.check()
        showVersionNudge = shouldPresentVersionNudge(
            decision: versionGate.decision,
            latestVersion: versionGate.latestVersion,
            dismissedVersion: dismissedNudgeVersion
        )
    }
}

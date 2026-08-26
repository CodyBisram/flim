import SwiftUI

struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rolls
    @Environment(NotificationService.self) private var notifications
    @Environment(VersionGateService.self) private var versionGate
    @Environment(\.scenePhase) private var scenePhase

    /// The account the caches currently belong to. Compared against the live one so a SWITCH is
    /// detected, not just a sign-out: signing out and straight back in as someone else is exactly
    /// the case that leaves one person's photos and feed on another person's screen.
    @State private var cachedAccountId: UUID?

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
        .onChange(of: auth.currentUser?.id) { _, newId in
            guard newId != cachedAccountId else { return }
            let previousId = cachedAccountId
            cachedAccountId = newId
            // Before any cache reset below: a pending undoable action belongs to the departing
            // account and its commit closure captures that account's ids, so it commits now,
            // against state that still matches it.
            UndoCenter.shared.flush()
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
            // Covers launch with a restored session (previousId starts nil), sign-in, and a
            // straight account-to-account switch; see FeedSeenStore's own doc for why marks
            // must be namespaced by whoever is actually signed in.
            FeedSeenStore.shared.activeUserId = newId
            // Develop reminders and Live Activities are scoped to a ROLL, not an account, so they
            // outlive a sign-out. Only clear them when there WAS a previously-cached account in
            // this session, i.e. a real switch (including straight to signed-out): the very first
            // resolve after launch also lands here (cachedAccountId starts nil), and that one must
            // NOT cancel the account that is simply continuing to be signed in.
            if previousId != nil {
                Task { await notifications.cancelAllRollDevelopNotifications() }
                RollLiveActivity.endAll()
            }
            // Captures that never reached the server are kept on disk per account, so this is
            // where they come back: on launch, and on signing back in. Without it the files
            // would accumulate forever and nobody would ever be offered the retry.
            if let newId { Task { await photos.restoreFailedUploads(userId: newId) } }
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
        }
        .onReceive(NotificationCenter.default.publisher(for: .flimAccountDidChange)) { _ in
            // Sign-out posts this. currentUser goes to nil, which the onChange above also catches,
            // but the notification covers the case where sign-out fails partway and leaves the
            // profile untouched. Always an actual departure, so always clear the departing
            // account's reminders and Live Activities, not just the caches.
            cachedAccountId = nil
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
            FeedSeenStore.shared.activeUserId = nil
            Task { await notifications.cancelAllRollDevelopNotifications() }
            RollLiveActivity.endAll()
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
                // Leaving the foreground commits it now; see `UndoCenter`.
                UndoCenter.shared.flush()
                return
            }
            Task { await refreshVersionGate() }
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

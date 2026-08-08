import SwiftUI

struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rolls
    @Environment(NotificationService.self) private var notifications

    /// The account the caches currently belong to. Compared against the live one so a SWITCH is
    /// detected, not just a sign-out: signing out and straight back in as someone else is exactly
    /// the case that leaves one person's photos and feed on another person's screen.
    @State private var cachedAccountId: UUID?

    var body: some View {
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
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.id)
        .animation(.easeInOut(duration: 0.35), value: auth.currentUser?.username)
        .animation(.easeInOut(duration: 0.35), value: auth.isLoading)
        .animation(.easeInOut(duration: 0.35), value: auth.isResolvingProfile)
        .animation(.easeInOut(duration: 0.35), value: auth.profileUnavailable)
        // Every service cache is keyed by post, photo or roll id, never by account, so none of it
        // invalidates itself when the account changes. Signing out cleared the session and the
        // profile and left all of it populated.
        .onChange(of: auth.currentUser?.id) { _, newId in
            guard newId != cachedAccountId else { return }
            let previousId = cachedAccountId
            cachedAccountId = newId
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
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
            // registered to whoever was signed in last. Claiming it here is what stops one
            // phone from collecting several accounts' notifications.
            if newId != nil { Task { await RemotePush.reclaimForCurrentAccount() } }
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
            Task { await notifications.cancelAllRollDevelopNotifications() }
            RollLiveActivity.endAll()
        }
    }
}

import SwiftUI

struct ContentView: View {
    @Environment(AuthService.self) private var auth
    @Environment(PhotoService.self) private var photos
    @Environment(FeedService.self) private var feed
    @Environment(RollService.self) private var rolls

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
        // Every service cache is keyed by post, photo or roll id, never by account, so none of it
        // invalidates itself when the account changes. Signing out cleared the session and the
        // profile and left all of it populated.
        .onChange(of: auth.currentUser?.id) { _, newId in
            guard newId != cachedAccountId else { return }
            cachedAccountId = newId
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .flimAccountDidChange)) { _ in
            // Sign-out posts this. currentUser goes to nil, which the onChange above also catches,
            // but the notification covers the case where sign-out fails partway and leaves the
            // profile untouched.
            cachedAccountId = nil
            photos.resetForAccountChange()
            feed.resetForAccountChange()
            rolls.resetForAccountChange()
        }
    }
}

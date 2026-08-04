import SwiftUI

@main
struct FlimApp: App {
    // Registered so APNs token callbacks are handled once Push Notifications is enabled.
    // Inert until RemotePush.register() is called, see RemotePush.swift.
    @UIApplicationDelegateAdaptor(FlimAppDelegate.self) private var appDelegate

    init() {
        // MetricKit crash/hang diagnostics, see CrashReporter for why this exists alongside
        // Xcode Organizer's automatic crash reports. Must be added on every launch, not just
        // the first, to receive payloads queued since the previous session.
        CrashReporter.shared.start()

        // In-app tips, shown once, contextually, then remembered as seen.
        #if DEBUG
        #endif
    }

    @State private var auth = AuthService()
    @State private var photos = PhotoService()
    @State private var rolls = RollService()
    @State private var notifications = NotificationService()
    @State private var feed = FeedService()
    @State private var network = NetworkMonitor()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(photos)
                .environment(rolls)
                .environment(notifications)
                .environment(feed)
                .environment(network)
                .preferredColorScheme(.dark)
                // Text scales with the user's Dynamic Type setting, up to the ceiling declared in
                // FlimTypeScale. The ceiling exists because several surfaces here are
                // fixed-geometry (the camera's 38x38 control row, the story-style reveal, capsule
                // chips holding a roll name) and break rather than reflow past it. See FlimFont.
                .flimDynamicTypeCeiling()
                .onOpenURL { url in
                    // Personal invites are checked FIRST. They and roll invites are different
                    // things — one gets you into the app, the other into a roll — and they live
                    // on different paths so a link can never mean both.
                    if let code = FlimApp.routePersonalInviteCode(from: url) {
                        PendingInvite.store(code)
                        NotificationCenter.default.post(name: .openPersonalInvite, object: code)
                    } else if let code = FlimApp.routeInviteCode(from: url) {
                        NotificationCenter.default.post(name: .openRollInvite, object: code)
                    } else {
                        Task { await auth.handle(url: url) }
                    }
                }
        }
    }

    /// A PERSONAL invite code from a link, i.e. the code that gets someone into the app at all.
    ///
    /// Deliberately on `/i/`, not `/join/`. `/join/` already means "join this roll", and a roll
    /// invite is only meaningful to someone who is already a user; conflating them would send a
    /// brand new person to a roll they cannot see yet.
    ///
    /// Accepts the universal link (https://flim-app.com/i/CODE) and the custom scheme
    /// (com.lapse.app://i/CODE). Returns nil for anything else, including auth callbacks.
    static func routePersonalInviteCode(from url: URL) -> String? {
        let isUniversal = url.host == "flim-app.com" && url.pathComponents.dropFirst().first == "i"
        guard url.host == "i" || isUniversal else { return nil }
        let code = url.lastPathComponent
        guard !code.isEmpty, code != "/", code != "i" else { return nil }
        return code
    }

    /// Two invite URL shapes: the custom scheme (…//join/CODE) and the universal link
    /// (https://flim-app.com/join/CODE). Returns the invite code, or `nil` if `url` isn't a
    /// recognized invite link (e.g. an auth callback) or the invite link carries no real code.
    static func routeInviteCode(from url: URL) -> String? {
        let isUniversalJoin = url.host == "flim-app.com" && url.pathComponents.dropFirst().first == "join"
        guard url.host == "join" || isUniversalJoin else { return nil }
        let code = url.lastPathComponent
        guard !code.isEmpty, code != "/", code != "join" else { return nil }
        return code
    }
}

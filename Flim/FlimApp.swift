import SwiftUI

@main
struct FlimApp: App {
    /// Observed here, at the root, so the accent reaches EVERYTHING: the auth and onboarding
    /// screens live above MainTabView, so injecting it there alone would have left every
    /// pre-sign-in surface stuck on the default amber.
    @AppStorage(FlimTheme.accentKey) private var accentColor = FlimAccent.amber.rawValue

    // Registered so APNs token callbacks are handled once Push Notifications is enabled.
    // Inert until RemotePush.register() is called, see RemotePush.swift.
    @UIApplicationDelegateAdaptor(FlimAppDelegate.self) private var appDelegate

    init() {
        // MetricKit crash/hang diagnostics, see CrashReporter for why this exists alongside
        // Xcode Organizer's automatic crash reports. Must be added on every launch, not just
        // the first, to receive payloads queued since the previous session.
        CrashReporter.shared.start()

        // One-shot cache purge. Builds 255 through 261 could file the wrong photograph's
        // bytes under another post's cache keys (the feed's index-keyed URL bug), and a
        // poisoned entry is indistinguishable from an honest one afterwards, so every
        // affected device serves wrong images from cache until the whole thing is cleared
        // once. Keyed by flag, not build number, so it runs exactly once per device and
        // never again.
        let purgeFlag = "purgedPoisonedImageCache_2026_08_24"
        if !UserDefaults.standard.bool(forKey: purgeFlag) {
            DiskImageCache.purgeAll()
            UserDefaults.standard.set(true, forKey: purgeFlag)
        }
    }

    @State private var auth = AuthService()
    @State private var photos = PhotoService()
    @State private var rolls = RollService()
    @State private var notifications = NotificationService()
    @State private var feed = FeedService()
    @State private var network = NetworkMonitor()
    @State private var versionGate = VersionGateService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.flimAccent, (FlimAccent(rawValue: accentColor) ?? .amber).color)
                .environment(auth)
                .environment(photos)
                .environment(rolls)
                .environment(notifications)
                .environment(feed)
                .environment(network)
                .environment(versionGate)
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
                    // Widget taps. Checked before the invite routes because they are the links
                    // with no code in them at all, so they can be recognised outright rather than
                    // by failing to parse as something else. `parse(url:)` only answers for our
                    // own scheme, so an https invite link can never be caught here.
                    if let destination = PushDestination.parse(url: url) {
                        // Written down AND broadcast, for the same reason the invite routes are:
                        // a tap on a widget is usually a COLD launch, and on a cold launch
                        // MainTabView does not exist yet to hear the notification.
                        PendingPushDestination.store(destination)
                        NotificationCenter.default.post(name: .openPushDestination,
                                                        object: destination)
                    } else if let code = FlimApp.routePersonalInviteCode(from: url) {
                        PendingInvite.store(code)
                        NotificationCenter.default.post(name: .openPersonalInvite, object: code)
                    } else if let code = FlimApp.routeInviteCode(from: url) {
                        // Written down AND broadcast: on a cold launch this fires before
                        // MainTabView exists, and a notification with no listener is just lost.
                        PendingRollInvite.store(code)
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

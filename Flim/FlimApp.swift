import SwiftUI
import TipKit

@main
struct FlimApp: App {
    // Registered so APNs token callbacks are handled once Push Notifications is enabled.
    // Inert until RemotePush.register() is called — see RemotePush.swift.
    @UIApplicationDelegateAdaptor(FlimAppDelegate.self) private var appDelegate

    init() {
        // In-app tips — shown once, contextually, then remembered as seen.
        try? Tips.configure([.displayFrequency(.immediate), .datastoreLocation(.applicationDefault)])
        #if DEBUG
        // Clean screenshots: -noTips suppresses TipKit overlays in the Simulator.
        if ProcessInfo.processInfo.arguments.contains("-noTips") { Tips.hideAllTipsForTesting() }
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
                .onOpenURL { url in
                    // Two invite shapes: the custom scheme (…//join/CODE) and the universal
                    // link (https://flim-app.com/join/CODE). Everything else is an auth callback.
                    let isUniversalJoin = url.host == "flim-app.com" && url.pathComponents.dropFirst().first == "join"
                    if url.host == "join" || isUniversalJoin {
                        let code = url.lastPathComponent
                        if !code.isEmpty, code != "/", code != "join" {
                            NotificationCenter.default.post(name: .openRollInvite, object: code)
                        }
                    } else {
                        Task { await auth.handle(url: url) }
                    }
                }
        }
    }
}

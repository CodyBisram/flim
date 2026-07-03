import SwiftUI

@main
struct FlimApp: App {
    // Registered so APNs token callbacks are handled once Push Notifications is enabled.
    // Inert until RemotePush.register() is called — see RemotePush.swift.
    @UIApplicationDelegateAdaptor(FlimAppDelegate.self) private var appDelegate

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
                    // …//join/CODE opens the join flow; everything else is an auth callback.
                    if url.host == "join" {
                        let code = url.lastPathComponent
                        if !code.isEmpty, code != "/" {
                            NotificationCenter.default.post(name: .openRollInvite, object: code)
                        }
                    } else {
                        Task { await auth.handle(url: url) }
                    }
                }
        }
    }
}

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

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(photos)
                .environment(rolls)
                .environment(notifications)
                .preferredColorScheme(.dark)
                .onOpenURL { url in
                    Task { await auth.handle(url: url) }
                }
        }
    }
}

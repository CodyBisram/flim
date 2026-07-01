import Supabase
import UIKit
import UserNotifications

/// Remote (APNs) push.
///
/// App-side wiring is DONE: the "Push Notifications" capability (aps-environment) is in
/// `Flim/Flim.entitlements`, and `register()` is called from NotificationService once the
/// user grants notification permission. On success the device token is upserted into
/// `device_tokens` for the signed-in user.
///
/// What still requires YOUR credentials (can't be done in code):
///   1. Create an APNs auth key in the Apple Developer portal.
///   2. Add it + the key/team/bundle IDs as secrets in Supabase and deploy
///      `supabase/push/` (the `device_tokens.sql` migration + `send-develop-push`
///      Edge Function). See `supabase/push/README.md`.
///
/// Until those server steps are done, registration + token upload still succeed; there's
/// simply nothing sending pushes yet. Local develop notifications work regardless.
enum RemotePush {
    /// Ask iOS for an APNs device token. Safe to call repeatedly; iOS dedupes.
    @MainActor
    static func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Upserts an APNs token for the signed-in user into `device_tokens`.
    static func uploadToken(_ token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        guard let session = try? await supabase.auth.session else { return }

        struct Row: Encodable {
            let user_id: UUID
            let token: String
            let platform: String
        }
        _ = try? await supabase
            .from("device_tokens")
            .upsert(Row(user_id: session.user.id, token: hex, platform: "ios"))
            .execute()
    }
}

extension Notification.Name {
    /// Posted when a develop notification is tapped, so the UI can jump to the Darkroom.
    static let openDarkroom = Notification.Name("openDarkroom")
}

/// App delegate: forwards the APNs token to `RemotePush`, and handles notification
/// presentation (show develop reminders even while the app is open) + taps (open Darkroom).
final class FlimAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Task { await RemotePush.uploadToken(deviceToken) }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("APNs registration failed: \(error.localizedDescription)")
    }

    // Show develop notifications as a banner even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Tapping a develop notification jumps to the Darkroom.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NotificationCenter.default.post(name: .openDarkroom, object: nil)
        completionHandler()
    }
}

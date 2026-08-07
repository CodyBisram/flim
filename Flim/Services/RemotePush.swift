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
    /// The last APNs token iOS handed us, kept so sign-out can detach this device
    /// without waiting for another registration callback that may never come.
    private static let tokenKey = "apnsDeviceToken"

    /// Ask iOS for an APNs device token. Safe to call repeatedly; iOS dedupes.
    @MainActor
    static func register() {
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Claims an APNs token for the signed-in user.
    ///
    /// Goes through `register_device_token` rather than upserting the table directly.
    /// `device_tokens` is keyed on the token alone, so claiming a device that another
    /// account still holds is an UPDATE of someone else's row, and the "own tokens"
    /// RLS policy checks its USING clause against that existing row and filters the
    /// write out. The client would see no error and the device would stay attached to
    /// the previous account, which is exactly the bug this replaced: every account
    /// that had ever signed in on a phone kept receiving its pushes there.
    static func uploadToken(_ token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: tokenKey)
        await claim(hex)
    }

    /// Re-claims the cached token for whoever is signed in now.
    ///
    /// Signing in does not make iOS hand us a new token, so without this the device
    /// would stay registered to the previous account until iOS next rotated it.
    static func reclaimForCurrentAccount() async {
        guard let hex = UserDefaults.standard.string(forKey: tokenKey) else { return }
        await claim(hex)
    }

    private static func claim(_ hex: String) async {
        guard (try? await supabase.auth.session) != nil else { return }
        _ = try? await supabase
            .rpc("register_device_token", params: ["p_token": hex, "p_platform": "ios"])
            .execute()
    }

    /// Detaches this device from the signed-in account.
    ///
    /// Must run while the session is still alive, since the row is only deletable by
    /// the account that owns it. The cached token is deliberately kept: the device
    /// still has it, and the next sign-in needs it to re-claim.
    static func unregisterCurrentDevice() async {
        guard let hex = UserDefaults.standard.string(forKey: tokenKey) else { return }
        guard (try? await supabase.auth.session) != nil else { return }
        _ = try? await supabase
            .from("device_tokens")
            .delete()
            .eq("token", value: hex)
            .execute()
    }
}

extension Notification.Name {
    /// Posted when a develop notification is tapped, so the UI can jump to the Darkroom.
    static let openDarkroom = Notification.Name("openDarkroom")
    /// Posted to jump to the Camera tab (e.g. from the empty-Darkroom CTA).
    static let openCamera = Notification.Name("openCamera")
    /// Posted with a roll invite code (String) when a `…//join/CODE` deep link is opened.
    static let openRollInvite = Notification.Name("openRollInvite")
    /// Posted with the just-created Roll so the camera defaults to shooting into it, without
    /// forcing a tab switch, CameraView's own selectedRoll is view-local @State (persisted to
    /// UserDefaults on change, restored once on appear), so a roll created elsewhere has no other
    /// way to reach an already-mounted CameraView.
    static let selectCameraRoll = Notification.Name("selectCameraRoll")
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

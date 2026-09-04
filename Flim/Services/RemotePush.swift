import Supabase
import UIKit
import UserNotifications
import os

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

    /// A token `unregisterCurrentDevice()` couldn't confirm was detached, persisted so a later
    /// chance to finish the job isn't lost when the app quits before it can retry in-process.
    private static let pendingDetachTokenKey = "apnsPendingDetachToken"
    /// The account `pendingDetachTokenKey` belongs to. `device_tokens` is keyed on the token
    /// alone, so without this a retry would have no way to tell "the account this was meant to
    /// detach happens to be signed in again" from "some other account is signed in now", and
    /// firing a delete in the second case would take down a DIFFERENT account's live push
    /// registration.
    private static let pendingDetachOwnerKey = "apnsPendingDetachOwner"

    /// Background plumbing, not a user-facing failure: nothing here ever surfaces an error to the
    /// signed-in person, but a claim that silently never happens is exactly how one account's push
    /// notifications end up on a different account's phone for a month before anyone notices. See
    /// `reclaimForCurrentAccount()` and `claim(_:)`.
    private static let log = Logger(subsystem: "com.flim.app", category: "push")

    /// The account `register_device_token` last confirmed a claim for, THIS session. `nil` until a
    /// claim actually succeeds, never optimistically set just because a token is cached: a cached
    /// token only proves iOS handed this device one at some point, not that the server has it
    /// attached to whoever is signed in now.
    ///
    /// Scoped by account, not a bare flag, because `reclaimForCurrentAccount()` re-runs on every
    /// sign-in on the same device: a success recorded for the PREVIOUS account must not be read as
    /// "this account can receive push" the instant someone else signs in, that's exactly the gap
    /// `NotificationService.scheduleRollDevelopNotification` exists to fall back into.
    private static var registeredAccountId: UUID?

    /// Whether the server has confirmed this device's token is attached to `userId`, this
    /// session. Read by `NotificationService.scheduleRollDevelopNotification` to decide whether a
    /// local develop reminder is still needed as a fallback, now that the server-side develop push
    /// reaches every roll member directly.
    static func isTokenRegistered(for userId: UUID) -> Bool { registeredAccountId == userId }

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
        await retryPendingDetach()
        guard let hex = UserDefaults.standard.string(forKey: tokenKey) else {
            // Not necessarily a bug on its own (a fresh install with permission not yet granted
            // looks like this too), but combined with `registerForRemoteIfAlreadyAuthorized()`
            // running right alongside every call site of this function, it should be rare. A run
            // of these for one account is the signal that its device token claim is stuck.
            log.notice("reclaimForCurrentAccount: no cached device token to claim")
            return
        }
        await claim(hex)
    }

    private static func claim(_ hex: String) async {
        guard let session = try? await supabase.auth.session else {
            log.notice("claim: no session, dropping device token claim")
            return
        }
        do {
            try await supabase
                .rpc("register_device_token", params: ["p_token": hex, "p_platform": "ios"])
                .execute()
            registeredAccountId = session.user.id
        } catch {
            log.error("claim: register_device_token failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Detaches this device from the signed-in account.
    ///
    /// Must run while the session is still alive, since the row is only deletable by
    /// the account that owns it. The cached token is deliberately kept: the device
    /// still has it, and the next sign-in needs it to re-claim.
    static func unregisterCurrentDevice() async {
        guard let hex = UserDefaults.standard.string(forKey: tokenKey) else { return }
        guard let session = try? await supabase.auth.session else { return }
        // This device is about to lose its claim either way, below or via the pending-detach
        // retry; either path means push can no longer reach it for this account, so the develop
        // reminder's local fallback must be considered live again from this point.
        if registeredAccountId == session.user.id { registeredAccountId = nil }
        do {
            try await supabase
                .from("device_tokens")
                .delete()
                .eq("token", value: hex)
                .execute()
            clearPendingDetach()
        } catch {
            // A device that's still attached to a departed account keeps receiving its pushes,
            // roll content included, on a phone nobody is signed into: a privacy leak, not just
            // staleness, so a swallowed failure here can't just be left for the next unrelated
            // fetch to maybe fix. This function is called immediately before the caller signs
            // the session out, so that session (the only thing that can delete this row) is
            // about to be gone. Persisted the same way CrashReporter persists a diagnostic that
            // failed to upload: nothing else is ever going to come back and ask about this one,
            // so the next chance has to be able to find it on disk.
            UserDefaults.standard.set(hex, forKey: pendingDetachTokenKey)
            UserDefaults.standard.set(session.user.id.uuidString, forKey: pendingDetachOwnerKey)
        }
    }

    private static func clearPendingDetach() {
        UserDefaults.standard.removeObject(forKey: pendingDetachTokenKey)
        UserDefaults.standard.removeObject(forKey: pendingDetachOwnerKey)
    }

    /// Finishes a detach `unregisterCurrentDevice()` couldn't confirm landed, the next time this
    /// device has a session at all: reached from `reclaimForCurrentAccount()`, which runs on
    /// every account resolution, the same "next launch" reach `claim` itself already relies on.
    ///
    /// Only acts when the CURRENT session belongs to the account the marker names. If some other
    /// account is signed in now, this session has no row of the departed account's to touch
    /// (`device_tokens`' "own tokens" policy would refuse it) and, more to the point, doesn't
    /// need to: `claim(_:)`, called right after this in `reclaimForCurrentAccount`, already
    /// reassigns this token away from whoever held it via `register_device_token`'s own
    /// cross-account delete, which is what actually closes the leak in that case. Comparing the
    /// account here is what stops this from ever attempting the OTHER thing that phrase could
    /// mean: firing a delete under whatever session happens to be active, which would be a
    /// second privacy bug wearing the fix for the first one.
    private static func retryPendingDetach() async {
        guard let hex = UserDefaults.standard.string(forKey: pendingDetachTokenKey),
              let ownerId = UserDefaults.standard.string(forKey: pendingDetachOwnerKey),
              let session = try? await supabase.auth.session,
              session.user.id.uuidString == ownerId
        else { return }
        do {
            try await supabase
                .from("device_tokens")
                .delete()
                .eq("token", value: hex)
                .execute()
            clearPendingDetach()
        } catch {
            // Left in place; tried again the next time this account's session shows up here.
        }
    }
}

extension Notification.Name {
    /// Posted when a develop notification is tapped, so the UI can jump to the Darkroom.
    ///
    /// Also the SAFE FALLBACK for any notification tap `PushDestination.parse` cannot make sense
    /// of: no `flim` payload (everything already delivered before this existed), an unrecognized
    /// destination, or a malformed id. Never remove this without keeping an equivalent fallback,
    /// pushes with no payload are still arriving on real phones.
    static let openDarkroom = Notification.Name("openDarkroom")
    /// Posted with a `PushDestination` (as `object`) once a notification tap has been decoded.
    /// `MainTabView` is the only listener, and it also checks `PendingPushDestination` on
    /// `onAppear` for the cold-start case where nothing was listening yet when this posted.
    static let openPushDestination = Notification.Name("openPushDestination")
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

    // Routes a tapped notification to wherever its `flim` payload names, falling back to the
    // Darkroom (today's behaviour, unconditionally, for every notification already on a phone)
    // when there is no payload, an unrecognized destination, or a malformed id.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        guard let destination = PushDestination.parse(userInfo: userInfo) else {
            NotificationCenter.default.post(name: .openDarkroom, object: nil)
            completionHandler()
            return
        }
        // Written down AND broadcast: a cold launch, or a launch with nobody signed in yet, has
        // no `MainTabView` alive to catch the broadcast. See `PendingPushDestination`.
        PendingPushDestination.store(destination)
        NotificationCenter.default.post(name: .openPushDestination, object: destination)
        completionHandler()
    }
}

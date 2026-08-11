import Observation
import UserNotifications

/// Local notifications for the "your photo developed" moment. This works fully offline
/// with no backend, when you capture a photo we schedule a local notification for its
/// `develops_at`. (Remote push, for roll-mates' photos developing on *their* devices,
/// is handled separately by the Supabase Edge Function, see `supabase/push/`.)
@MainActor
@Observable
final class NotificationService {
    private(set) var isAuthorized = false

    /// Asks for permission the first time it matters (call right before scheduling).
    /// No-ops once the user has already decided. When permission is in hand we also
    /// register for remote (APNs) push so roll-mates' develop notifications can arrive
    /// via the Supabase Edge Function, see RemotePush + supabase/push/.
    /// True when the OS hasn't been asked yet, used to decide whether to show the soft primer
    /// (asking with context) before the one-shot system prompt.
    func isUndetermined() async -> Bool {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus == .notDetermined
    }

    /// Pure decision: given the OS's current authorization status, should we ask iOS for a fresh
    /// APNs token? Split out from `registerForRemoteIfAlreadyAuthorized()` so the decision is
    /// testable without a real `UNUserNotificationCenter` and without triggering an actual
    /// registration. `.authorized`/`.provisional`/`.ephemeral` mean the user already said yes at
    /// some point, so re-asking iOS for the token is silent (no system prompt). `.notDetermined`
    /// and `.denied` must return false: this function backs a launch-time path that must NEVER be
    /// the thing that shows the permission dialog, that's `requestAuthorizationIfNeeded()`'s job,
    /// gated by the primer.
    nonisolated static func shouldRegisterForRemote(given status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        default:
            return false
        }
    }

    /// Re-asks iOS for the current APNs device token when authorization was already granted in an
    /// earlier session, WITHOUT ever requesting authorization. Safe to call on every launch and
    /// again once an account resolves: a device token is only handed to the app in response to
    /// `registerForRemoteNotifications()`, and neither app launch nor sign-in triggers that on
    /// their own, so without this call a device that already has permission can go a long time
    /// (a reinstall, a token rotation, simply never recapturing after granting permission) without
    /// the signed-in account ever holding the live token, while some OTHER account that happened to
    /// capture or open an undeveloped roll on this device keeps it instead.
    func registerForRemoteIfAlreadyAuthorized() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        guard Self.shouldRegisterForRemote(given: status) else { return }
        isAuthorized = true
        RemotePush.register()
    }

    func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            isAuthorized = granted
        case .authorized, .provisional, .ephemeral:
            isAuthorized = true
        default:
            isAuthorized = false
        }
        if isAuthorized {
            RemotePush.register()
        }
    }

    /// Schedules the develop reminder for a freshly captured photo.
    /// Schedules ONE develop reminder per roll (personal instants are ready immediately, so
    /// they don't need one). Reusing the roll's identifier means every shot you add just
    /// updates the single pending notification instead of stacking dozens at the same reveal.
    func scheduleRollDevelopNotification(rollId: UUID, rollName: String, developsAt: Date, photoCount: Int) {
        guard developsAt > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your \(rollName) roll developed 🎞"
        content.body = photoCount > 0
            ? "Your \(photoCount) shot\(photoCount == 1 ? "" : "s"), and everyone else's, are ready."
            : "Everyone's photos from the roll are ready to see."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        // Same `flim` payload a push would carry, so tapping this (the highest-value notification
        // in the app) opens the reveal instead of falling back to the Darkroom. See
        // `PushDestination` and `FlimAppDelegate.userNotificationCenter(_:didReceive:)`.
        content.userInfo = ["flim": PushDestination.reveal(rollId: rollId).wireValue]

        let interval = max(1, developsAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "develop-roll-\(rollId.uuidString)",   // same id → replaces, never stacks
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Cancels a roll's pending develop reminder, call when a roll is deleted or left, or the
    /// notification still fires at the original develop time claiming "Your <roll> developed"
    /// for a roll you no longer have (deleted) or no longer belong to (left). The identifier
    /// matches `scheduleRollDevelopNotification`'s exactly, so this is a safe no-op if nothing
    /// was ever scheduled (roll developed with notifications off, or before anyone shot into it).
    func cancelRollDevelopNotification(rollId: UUID) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["develop-roll-\(rollId.uuidString)"])
    }

    /// Cancels every pending develop reminder, regardless of which roll it names.
    ///
    /// A develop reminder is scheduled per roll, not per account, so signing out leaves whatever
    /// was pending sitting in the OS's notification queue. Sign in as someone else on the same
    /// device and the departed account's roll name (and shot count) can surface as a time-sensitive
    /// banner or lock-screen card for the new account. Call this on sign-out and on switching
    /// accounts, never on the very first resolve after launch for an account that is simply
    /// continuing to be signed in, or this would cancel its own still-legitimate reminders.
    func cancelAllRollDevelopNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let ids = pending.map(\.identifier).filter { $0.hasPrefix("develop-roll-") }
        guard !ids.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

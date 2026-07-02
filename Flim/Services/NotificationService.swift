import Observation
import UserNotifications

/// Local notifications for the "your photo developed" moment. This works fully offline
/// with no backend — when you capture a photo we schedule a local notification for its
/// `develops_at`. (Remote push, for roll-mates' photos developing on *their* devices,
/// is handled separately by the Supabase Edge Function — see `supabase/push/`.)
@MainActor
@Observable
final class NotificationService {
    private(set) var isAuthorized = false

    /// Asks for permission the first time it matters (call right before scheduling).
    /// No-ops once the user has already decided. When permission is in hand we also
    /// register for remote (APNs) push so roll-mates' develop notifications can arrive
    /// via the Supabase Edge Function — see RemotePush + supabase/push/.
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
            ? "Your \(photoCount) shot\(photoCount == 1 ? "" : "s") — and everyone else's — are ready."
            : "Everyone's photos from the roll are ready to see."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let interval = max(1, developsAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "develop-roll-\(rollId.uuidString)",   // same id → replaces, never stacks
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}

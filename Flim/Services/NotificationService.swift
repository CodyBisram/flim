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
    func scheduleDevelopNotification(photoID: UUID, developsAt: Date, rollName: String?) {
        guard developsAt > .now else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your photo developed 📸"
        content.body = rollName.map { "A new shot is ready in \"\($0)\"." }
            ?? "Your latest shot is ready in the Darkroom."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let interval = max(1, developsAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        let request = UNNotificationRequest(
            identifier: "develop-\(photoID.uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}

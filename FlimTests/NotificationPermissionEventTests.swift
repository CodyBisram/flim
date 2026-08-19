import Testing
import Foundation
import UserNotifications
@testable import Flim

/// The notification permission decision, as the funnel sees it.
///
/// These exist because of a question the data could not answer on 2026-08-19: 42 accounts had
/// `camera_authorized` and 25 held a device token, so 17 people reached a working camera with no
/// push channel, and nothing said whether they had refused or had simply never been asked. Those
/// two want opposite responses, so the events are only worth having if they stay distinguishable.
struct NotificationPermissionEventTests {

    @Test("the raw values match the server's CHECK constraint exactly")
    func rawValues() {
        // A mismatch here is a loud server-side rejection at runtime and silence in the funnel,
        // which is the failure mode this enum exists to prevent. See
        // supabase/migrations/2026-08-19_notification_permission_events.sql.
        #expect(ActivationEvent.notificationsAuthorized.rawValue == "notifications_authorized")
        #expect(ActivationEvent.notificationsDenied.rawValue == "notifications_denied")
    }

    @Test("granted and provisional both count as authorized, denied does not")
    func statusMapping() {
        #expect(NotificationService.authorizationState(for: .authorized) == .authorized)
        #expect(NotificationService.authorizationState(for: .provisional) == .authorized)
        #expect(NotificationService.authorizationState(for: .ephemeral) == .authorized)
        #expect(NotificationService.authorizationState(for: .denied) == .denied)
    }

    @Test("never asked maps to notDetermined, which is the state that must log nothing")
    func notDeterminedStaysDistinct() {
        // The absence of BOTH events is what identifies somebody who was never prompted. If
        // notDetermined ever collapsed into denied, that person would be indistinguishable from a
        // refusal and the whole distinction would be gone.
        #expect(NotificationService.authorizationState(for: .notDetermined) == .notDetermined)
        #expect(NotificationService.authorizationState(for: .notDetermined) != .denied)
    }

    @Test("an unknown future status is treated as never asked, not as a refusal")
    func unknownIsNotARefusal() {
        // Erring toward notDetermined keeps a status this build has never heard of out of the
        // denied bucket, where it would look like a decision nobody made.
        #expect(NotificationService.authorizationState(for: UNAuthorizationStatus(rawValue: 99)!) == .notDetermined)
    }

    @Test("only an authorized status asks iOS for a token")
    func onlyAuthorizedRegisters() {
        #expect(NotificationService.shouldRegisterForRemote(given: .authorized))
        #expect(NotificationService.shouldRegisterForRemote(given: .provisional))
        #expect(!NotificationService.shouldRegisterForRemote(given: .denied))
        #expect(!NotificationService.shouldRegisterForRemote(given: .notDetermined))
    }
}

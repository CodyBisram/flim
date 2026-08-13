import Testing
import UserNotifications
@testable import Flim

/// `NotificationService.authorizationState(for:)` collapses the OS's five-case
/// `UNAuthorizationStatus` down to the three states ProfileView's settings row branches on:
/// never asked (`.notDetermined`), asked and declined (`.denied`), and can post notifications
/// (`.authorized`, which also covers the quiet `.provisional`/`.ephemeral` variants).
///
/// This exists alongside the fix for 11 of 27 real users having no push token at all: ProfileView
/// used to show a bare "Develop reminders" toggle defaulting ON with no read of, or route to, OS
/// permission. Someone who never got asked (or swiped away the one soft primer, which used to burn
/// its single shot on dismissal) saw a working-looking toggle that could never do anything, with no
/// way back in except deleting and reinstalling. This mapping is pure so ProfileView's branching is
/// testable without a real `UNUserNotificationCenter`.
struct NotificationAuthorizationStateTests {
    @Test("authorized maps to .authorized")
    func authorizedMapsToAuthorized() {
        #expect(NotificationService.authorizationState(for: .authorized) == .authorized)
    }

    @Test("provisional (quiet) authorization also maps to .authorized")
    func provisionalMapsToAuthorized() {
        #expect(NotificationService.authorizationState(for: .provisional) == .authorized)
    }

    @Test("ephemeral (App Clip) authorization also maps to .authorized")
    func ephemeralMapsToAuthorized() {
        #expect(NotificationService.authorizationState(for: .ephemeral) == .authorized)
    }

    @Test("not yet determined maps to .notDetermined, the recovery row's trigger")
    func notDeterminedMapsToNotDetermined() {
        #expect(NotificationService.authorizationState(for: .notDetermined) == .notDetermined)
    }

    @Test("denied maps to .denied, the Settings-deep-link row's trigger")
    func deniedMapsToDenied() {
        #expect(NotificationService.authorizationState(for: .denied) == .denied)
    }
}

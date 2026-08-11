import Testing
import UserNotifications
@testable import Flim

/// `NotificationService.shouldRegisterForRemote(given:)` is the decision behind re-asking iOS for
/// an APNs device token on every launch and again once an account resolves, WITHOUT ever showing
/// the system permission dialog.
///
/// The bug this exists for: `RemotePush.register()` (the only thing that makes iOS hand the app a
/// device token) was reachable only from `requestAuthorizationIfNeeded()`'s `.notDetermined`
/// prompt path and its post-grant branch, both gated behind a capture, an undeveloped roll, or the
/// primer. Neither app launch nor sign-in ever called it. A device that had already granted
/// permission in an earlier session could go a whole launch, and a whole sign-in, without the
/// newly-signed-in account ever re-claiming the live token, leaving it attached to whichever
/// account last happened to trigger one of those three call sites, exactly what let one account's
/// push notifications ("you posted N photos") arrive on a different signed-in account's phone.
///
/// This is tested as a pure decision, injecting `UNAuthorizationStatus` directly, rather than
/// through a real `UNUserNotificationCenter` (there is none in a unit test host) or by observing an
/// actual `registerForRemoteNotifications()` call.
struct RemotePushReregistrationTests {
    @Test("already authorized leads to a token request")
    func authorizedRegisters() {
        #expect(NotificationService.shouldRegisterForRemote(given: .authorized))
    }

    @Test("provisional (quiet) authorization also leads to a token request")
    func provisionalRegisters() {
        #expect(NotificationService.shouldRegisterForRemote(given: .provisional))
    }

    @Test("ephemeral (App Clip) authorization also leads to a token request")
    func ephemeralRegisters() {
        #expect(NotificationService.shouldRegisterForRemote(given: .ephemeral))
    }

    @Test("not yet determined must NOT lead to a token request")
    func notDeterminedDoesNotRegister() {
        // This is the constraint that matters most: `registerForRemoteNotifications()` itself does
        // not prompt, but the call sites that reach this decision at launch and on sign-in must
        // never be the thing that shows the permission dialog. `.notDetermined` staying false is
        // what keeps a first-run user's flow byte-identical to today's: they still only ever see
        // the primer, then the one-shot system prompt, on the same schedule as before.
        #expect(!NotificationService.shouldRegisterForRemote(given: .notDetermined))
    }

    @Test("denied must NOT lead to a token request")
    func deniedDoesNotRegister() {
        #expect(!NotificationService.shouldRegisterForRemote(given: .denied))
    }
}

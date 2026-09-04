import Testing
@testable import Flim

/// `NotificationService.shouldScheduleLocalReminder(authorized:tokenRegistered:)`: the decision
/// behind making the "your roll developed" LOCAL notification a fallback now that the server's
/// develop push reaches every roll member directly. Scheduling both on a phone that has push would
/// double up the same moment; this is what stops that.
struct RollDevelopReminderFallbackTests {
    @Test("authorized AND a registered token: push can reach this phone, no local reminder needed")
    func pushFullyAvailableSkipsTheLocalReminder() {
        #expect(!NotificationService.shouldScheduleLocalReminder(authorized: true, tokenRegistered: true))
    }

    @Test("authorized but no token registered this session: push cannot reach this account yet")
    func authorizedWithoutTokenStillSchedulesLocally() {
        #expect(NotificationService.shouldScheduleLocalReminder(authorized: true, tokenRegistered: false))
    }

    @Test("a registered token with no OS authorization: push still cannot deliver anything")
    func tokenRegisteredWithoutAuthorizationStillSchedulesLocally() {
        #expect(NotificationService.shouldScheduleLocalReminder(authorized: false, tokenRegistered: true))
    }

    @Test("neither authorized nor registered: the local reminder is the only channel this phone has")
    func neitherAvailableSchedulesLocally() {
        #expect(NotificationService.shouldScheduleLocalReminder(authorized: false, tokenRegistered: false))
    }
}

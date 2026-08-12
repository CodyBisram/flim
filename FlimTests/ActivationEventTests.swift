import Testing
@testable import Flim

/// Pins `ActivationEvent`'s raw values to exactly the ten strings the server's
/// `log_activation_event` CHECK constraint allows (see
/// `supabase/migrations/2026-08-08_activation_events.sql`). A raw value drifting from this list
/// is the one thing that can silently break the whole feature: the server rejects an unknown
/// string loudly, so a typo here doesn't corrupt data, it just makes an event vanish from the
/// funnel with nothing on screen to say so.
struct ActivationEventTests {

    @Test("the enum has exactly the ten allowed events, no more, no fewer")
    func exactlyTenEvents() {
        let all: [ActivationEvent] = [
            .firstLaunch, .firstShot, .rollCreated, .rollJoined,
            .inviteSent, .inviteRedeemed, .postShared, .revealWatched,
            .onboardingFinished, .cameraAuthorized
        ]
        #expect(all.count == 10)
    }

    @Test("every raw value matches the server's CHECK constraint, exactly and case-sensitively")
    func rawValuesMatchServerContract() {
        #expect(ActivationEvent.firstLaunch.rawValue == "first_launch")
        #expect(ActivationEvent.firstShot.rawValue == "first_shot")
        #expect(ActivationEvent.rollCreated.rawValue == "roll_created")
        #expect(ActivationEvent.rollJoined.rawValue == "roll_joined")
        #expect(ActivationEvent.inviteSent.rawValue == "invite_sent")
        #expect(ActivationEvent.inviteRedeemed.rawValue == "invite_redeemed")
        #expect(ActivationEvent.postShared.rawValue == "post_shared")
        #expect(ActivationEvent.revealWatched.rawValue == "reveal_watched")
        #expect(ActivationEvent.onboardingFinished.rawValue == "onboarding_finished")
        #expect(ActivationEvent.cameraAuthorized.rawValue == "camera_authorized")
    }

    @Test("the raw value set is exactly the server's allowed set, nothing extra")
    func rawValueSetMatchesServerAllowlist() {
        let serverAllowed: Set<String> = [
            "first_launch", "first_shot", "roll_created", "roll_joined",
            "invite_sent", "invite_redeemed", "post_shared", "reveal_watched",
            "onboarding_finished", "camera_authorized"
        ]
        let clientValues: [ActivationEvent] = [
            .firstLaunch, .firstShot, .rollCreated, .rollJoined,
            .inviteSent, .inviteRedeemed, .postShared, .revealWatched,
            .onboardingFinished, .cameraAuthorized
        ]
        let clientRaw = Set(clientValues.map(\.rawValue))
        #expect(clientRaw == serverAllowed)
    }
}

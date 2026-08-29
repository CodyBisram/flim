import Testing
@testable import Flim

/// What the invite screen is allowed to say about a count, and what it must never say.
///
/// The scarcity IS the mechanic: a number that is wrong in the pessimistic direction tells someone
/// they cannot bring a friend in when they can. The three states exist to keep that from happening.
struct InviteQuotaTests {

    @Test("unknown is not zero, and the two must never collapse")
    func unknownIsDistinctFromExhausted() {
        // A failed lookup and a spent allowance are the same shape on the wire (no usable number)
        // and must stay different in the model. `.unknown` renders no count at all; `.remaining(0)`
        // renders "No invites left" and hides the code. Getting these backwards on a flaky network
        // would hide a working invite code from someone who still has invites.
        #expect(AuthService.InviteQuota.unknown != .remaining(0))
    }

    @Test("unlimited is not a number, so it can never be counted down")
    func unlimitedIsItsOwnState() {
        // The server stores NULL for a deliberately unlimited account and never decrements it.
        // Modelling that as a large Int would eventually render a count for someone who has none.
        #expect(AuthService.InviteQuota.unlimited != .remaining(Int.max))
        #expect(AuthService.InviteQuota.unlimited != .unknown)
    }

    @Test("a real count is only ever equal to the same real count")
    func remainingComparesByValue() {
        #expect(AuthService.InviteQuota.remaining(3) == .remaining(3))
        #expect(AuthService.InviteQuota.remaining(3) != .remaining(2))
    }
}

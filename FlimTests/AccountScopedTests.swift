import Testing
import Foundation
@testable import Flim

/// The structural version of the guard rule.
///
/// Five separate omissions of the hand-written guard shipped in one release, three of them in code
/// written to fix the previous one. These tests pin the behaviour of the type that makes the rule
/// impossible to forget for the collections where a stale write moves content between accounts.
@MainActor
struct AccountScopedTests {

    @Test("a commit from the current generation lands")
    func currentCommitLands() {
        var scoped = AccountScoped<[String]>([])
        let epoch = AccountEpoch.current
        let landed = scoped.commit(["a"], ifStillCurrent: epoch)
        #expect(landed)
        #expect(scoped.value == ["a"])
    }

    @Test("a commit from a superseded generation is refused")
    func staleCommitRefused() {
        var scoped = AccountScoped<[String]>(["B's data"])
        let epoch = AccountEpoch.current
        AccountEpoch.bump()
        let landed = scoped.commit(["A's data"], ifStillCurrent: epoch)
        #expect(!landed)
        #expect(scoped.value == ["B's data"], "stale write must not land")
    }

    @Test("the refusal is reported, not silent")
    func refusalIsReported() {
        // A caller that needs to know whether its write landed can ask, rather than assuming.
        var scoped = AccountScoped<Int>(0)
        let epoch = AccountEpoch.current
        AccountEpoch.bump()
        let landed = scoped.commit(99, ifStillCurrent: epoch)
        #expect(landed == false)
    }

    @Test("reset ignores the generation, because clearing IS the account change")
    func resetAlwaysApplies() {
        var scoped = AccountScoped<[String]>(["stale"])
        AccountEpoch.bump()
        scoped.reset(to: [])
        #expect(scoped.value.isEmpty)
    }

    @Test("a second round trip needs its own commit, and gets its own answer")
    func eachWriteIsJudgedSeparately() {
        // The exact shape that shipped three times: one generation, several writes, and only the
        // first protected. Here every write is judged on its own.
        var first = AccountScoped<String>("")
        var second = AccountScoped<String>("")
        let epoch = AccountEpoch.current

        let firstLanded = first.commit("round trip 1", ifStillCurrent: epoch)
        #expect(firstLanded)
        AccountEpoch.bump()
        let secondLanded = second.commit("round trip 2", ifStillCurrent: epoch)
        #expect(!secondLanded, "a later round trip needs its own judgement")

        #expect(first.value == "round trip 1")
        #expect(second.value == "")
    }
}

import Testing
import Foundation
@testable import Flim

struct DiscoverRankingTests {
    private func ids(_ n: Int) -> [UUID] { (0..<n).map { _ in UUID() } }

    @Test func aPersonAppearsOnceInTheirFirstSection() {
        let a = UUID(), b = UUID(), c = UUID()
        var s = DiscoverRanking.Signals()
        s.followsMe = [a]
        s.rollMates = [a, b]
        s.mutuals = [b, c]
        let sections = DiscoverRanking.sections(from: s, excluding: [])
        #expect(sections.map(\.title) == ["Follows you", "In your rolls", "Friends of friends"])
        #expect(sections[0].ids == [a])
        #expect(sections[1].ids == [b])
        #expect(sections[2].ids == [c])
    }

    @Test func theInviteTreeRanksRightAfterRolls() {
        let inviter = UUID(), sibling = UUID(), invitee = UUID(), inviterFriend = UUID()
        var s = DiscoverRanking.Signals()
        s.inviter = inviter; s.siblings = [sibling]; s.invited = [invitee]; s.inviterFollows = [inviterFriend]
        let sections = DiscoverRanking.sections(from: s, excluding: [])
        #expect(sections.map(\.title) == ["Invited you", "Invited by the same person", "You invited", "Friends of friends"])
        #expect(sections[3].ids == [inviterFriend])
    }

    @Test func friendsOfFriendsRankByHowManyVouch() {
        let x = UUID(), y = UUID()
        var s = DiscoverRanking.Signals()
        s.mutuals = [x, y]            // x first by the caller's ranking
        s.inviterFollows = [y]        // but y is vouched for twice
        let sections = DiscoverRanking.sections(from: s, excluding: [])
        #expect(sections.first?.ids == [y, x])
    }

    @Test func newOnFlimIsCappedAndNeverPadsTheList() {
        var s = DiscoverRanking.Signals()
        s.newest = ids(12)
        let sections = DiscoverRanking.sections(from: s, excluding: [])
        #expect(sections.count == 1)
        #expect(sections[0].title == "New on FLIM")
        #expect(sections[0].ids.count == DiscoverRanking.newOnFlimCap)
        #expect(Array(s.newest.prefix(3)) == sections[0].ids)
    }

    @Test func excludedPeopleNeverAppearAndEmptyIsAllowed() {
        let me = UUID(), followed = UUID(), blocked = UUID()
        var s = DiscoverRanking.Signals()
        s.followsMe = [followed]; s.rollMates = [me, blocked]; s.newest = [followed, blocked]
        #expect(DiscoverRanking.sections(from: s, excluding: [me, followed, blocked]).isEmpty)
    }
}

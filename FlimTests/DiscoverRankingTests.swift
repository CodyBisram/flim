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

// MARK: - The thin-feed row (2026-09-17)

@Suite struct PeopleYouKnowRowTests {
    private func profile(_ name: String) -> UserProfile {
        UserProfile(id: UUID(), username: name, avatarPath: nil, bio: nil, displayName: nil, coverPath: nil, createdAt: .now, hiddenFromDiscovery: false, signupOrdinal: nil)
    }

    @Test("shows only under three follows, and only with someone to show")
    func rule() {
        #expect(PeopleYouKnowRow.shouldShow(followingCount: 0, candidates: 1))
        #expect(PeopleYouKnowRow.shouldShow(followingCount: 2, candidates: 3))
        #expect(!PeopleYouKnowRow.shouldShow(followingCount: 3, candidates: 3))
        #expect(!PeopleYouKnowRow.shouldShow(followingCount: 1, candidates: 0))
    }

    @Test("picks three across the sections that carry a reason, never New on FLIM")
    func picks() {
        let a = profile("a"), b = profile("b"), c = profile("c"), d = profile("d"), n = profile("n")
        let sections = [
            FeedService.DiscoverSection(title: "New on FLIM", profiles: [n]),
            FeedService.DiscoverSection(title: "Follows you", profiles: [a, b]),
            FeedService.DiscoverSection(title: "In your rolls", profiles: [b, c, d]),
        ]
        let picked = PeopleYouKnowRow.pick(sections)
        #expect(picked.map(\.profile.id) == [a.id, b.id, c.id])
        #expect(picked.map(\.reason) == ["Follows you", "Follows you", "In your rolls"])
        #expect(!picked.contains { $0.profile.id == n.id })
    }
}

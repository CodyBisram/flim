import XCTest
@testable import Flim

/// `FeedGrouping.grouped`, the rule behind collapsing "picture after picture" from one person into
/// a single swipeable feed card. Measured need: one user posted 78 times in 7 days against a next
/// highest of 25, so a whole page of the feed could be almost entirely one person without this.
final class FeedGroupingTests: XCTestCase {

    private func profile(_ id: UUID = UUID(), name: String = "a") -> UserProfile {
        UserProfile(id: id, username: name, avatarPath: nil, bio: nil, displayName: nil,
                    coverPath: nil, createdAt: .now)
    }

    private func item(author: UserProfile, createdAt: Date) -> FeedItem {
        let post = Post(id: UUID(), userId: author.id, photoId: UUID(), storagePath: "p",
                        thumbPath: nil, feedPath: nil, takenAt: createdAt, caption: nil,
                        createdAt: createdAt)
        return FeedItem(post: post, author: author)
    }

    // MARK: - Basic shape

    func testEmptyFeedGroupsToNothing() {
        XCTAssertEqual(FeedGrouping.grouped([]).count, 0)
    }

    func testSinglePostIsItsOwnGroupOfOne() {
        let alice = profile()
        let groups = FeedGrouping.grouped([item(author: alice, createdAt: .now)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 1)
    }

    // MARK: - Consecutive same author

    func testTwoConsecutivePostsBySameAuthorWithinTheWindowMergeIntoOneGroup() {
        let alice = profile()
        let now = Date.now
        let items = [
            item(author: alice, createdAt: now),
            item(author: alice, createdAt: now.addingTimeInterval(-60))
        ]
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        // Order preserved: newest first, exactly as the feed itself is ordered.
        XCTAssertEqual(groups[0].items.map(\.id), items.map(\.id))
    }

    func testABurstOfManyConsecutivePostsCollapsesToOneGroup() {
        // The measured case this feature exists for: one author posting far more than everyone
        // else, all in the same sitting.
        let alice = profile()
        let now = Date.now
        let items = (0..<78).map { i in item(author: alice, createdAt: now.addingTimeInterval(TimeInterval(-i * 30))) }
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 78)
    }

    // MARK: - Different authors

    func testConsecutivePostsByDifferentAuthorsStayInSeparateGroups() {
        let alice = profile(name: "alice")
        let bob = profile(name: "bob")
        let now = Date.now
        let items = [
            item(author: alice, createdAt: now),
            item(author: bob, createdAt: now.addingTimeInterval(-60))
        ]
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 2)
    }

    func testOneOtherPostInTheMiddleSplitsAnAuthorsRunInTwo() {
        let alice = profile(name: "alice")
        let bob = profile(name: "bob")
        let now = Date.now
        let items = [
            item(author: alice, createdAt: now),
            item(author: bob, createdAt: now.addingTimeInterval(-60)),
            item(author: alice, createdAt: now.addingTimeInterval(-120))
        ]
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 3)
        XCTAssertEqual(groups.map(\.count), [1, 1, 1])
    }

    // MARK: - The time window

    func testGapExactlyAtTheWindowStillMerges() {
        let alice = profile()
        let now = Date.now
        let items = [
            item(author: alice, createdAt: now),
            item(author: alice, createdAt: now.addingTimeInterval(-FeedGrouping.groupingWindow))
        ]
        XCTAssertEqual(FeedGrouping.grouped(items).count, 1)
    }

    func testGapJustOverTheWindowSplits() {
        let alice = profile()
        let now = Date.now
        let items = [
            item(author: alice, createdAt: now),
            item(author: alice, createdAt: now.addingTimeInterval(-FeedGrouping.groupingWindow - 1))
        ]
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.map(\.count), [1, 1])
    }

    func testYesterdaysPhotoDoesNotMergeWithTodays() {
        // The owner's own framing of why the window exists at all.
        let alice = profile()
        let today = Date.now
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today) ?? today
        let groups = FeedGrouping.grouped([
            item(author: alice, createdAt: today),
            item(author: alice, createdAt: yesterday)
        ])
        XCTAssertEqual(groups.count, 2)
    }

    /// A run only ever measures the gap to its own OLDEST post so far, not back to its newest.
    /// Otherwise a long-running burst (many posts, each a few minutes apart) would incorrectly
    /// split once the FIRST and LAST posts in the run are more than `groupingWindow` apart, even
    /// though every adjacent pair was well within it.
    func testALongRunOfCloselySpacedPostsStaysOneGroupEvenIfFirstAndLastAreFarApart() {
        let alice = profile()
        let now = Date.now
        // 10 posts, 1 hour apart: adjacent gaps are all well under the 6-hour window, but the
        // first and last posts are 9 hours apart, which alone would exceed it.
        let items = (0..<10).map { i in item(author: alice, createdAt: now.addingTimeInterval(TimeInterval(-i * 60 * 60))) }
        let groups = FeedGrouping.grouped(items)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 10)
    }

    // MARK: - Group identity

    func testGroupIdIsTheRunsFirstNewestPost() {
        let alice = profile()
        let now = Date.now
        let newest = item(author: alice, createdAt: now)
        let older = item(author: alice, createdAt: now.addingTimeInterval(-60))
        let groups = FeedGrouping.grouped([newest, older])
        XCTAssertEqual(groups[0].id, newest.id)
    }
}

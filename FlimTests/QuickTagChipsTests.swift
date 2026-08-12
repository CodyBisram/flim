import XCTest
@testable import Flim

/// `QuickTagChips`, the pure selection logic behind `TagPhotoSheet`'s quick-tag chip row: which
/// candidate list feeds the row (`candidateIds`), and how that list is pared down to what's
/// actually shown (`selectedIds`).
final class QuickTagChipsTests: XCTestCase {
    private let me = UUID()
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    // MARK: - candidateIds: which source

    func testARollPhotoSourcesFromRollMembers() {
        let ids = QuickTagChips.candidateIds(rollMemberIds: [a, b], recentlyTaggedIds: [c])
        XCTAssertEqual(ids, [a, b])
    }

    func testAPersonalPhotoSourcesFromRecentlyTagged() {
        let ids = QuickTagChips.candidateIds(rollMemberIds: nil, recentlyTaggedIds: [a, b])
        XCTAssertEqual(ids, [a, b])
    }

    func testAnEmptyRollRosterDoesNotFallBackToRecents() {
        // A roll with nobody else in it stays empty rather than silently offering people from
        // posts the roll has nothing to do with.
        let ids = QuickTagChips.candidateIds(rollMemberIds: [], recentlyTaggedIds: [a, b])
        XCTAssertEqual(ids, [])
    }

    func testNeitherSourceYieldsAnyoneStaysEmpty() {
        let ids = QuickTagChips.candidateIds(rollMemberIds: nil, recentlyTaggedIds: [])
        XCTAssertEqual(ids, [])
    }

    // MARK: - selectedIds: filtering + cap

    func testSelfIsExcluded() {
        let ids = QuickTagChips.selectedIds(from: [me, a, b], selfId: me, blockedIds: [])
        XCTAssertEqual(ids, [a, b])
    }

    func testBlockedEitherDirectionIsExcluded() {
        // `blockedIds` already carries the app's one notion of "blocked", reused as-is.
        let ids = QuickTagChips.selectedIds(from: [a, b, c], selfId: me, blockedIds: [b])
        XCTAssertEqual(ids, [a, c])
    }

    func testDuplicatesCollapseToOne() {
        let ids = QuickTagChips.selectedIds(from: [a, a, b], selfId: me, blockedIds: [])
        XCTAssertEqual(ids, [a, b])
    }

    func testOrderIsPreserved() {
        let ids = QuickTagChips.selectedIds(from: [c, a, b], selfId: me, blockedIds: [])
        XCTAssertEqual(ids, [c, a, b])
    }

    func testCapsAtSix() {
        let seven = (0..<7).map { _ in UUID() }
        let ids = QuickTagChips.selectedIds(from: seven, selfId: me, blockedIds: [], cap: 6)
        XCTAssertEqual(ids, Array(seven.prefix(6)))
    }

    func testExclusionsDoNotEatIntoTheVisibleSlotBudget() {
        // Self and a blocked id sit ahead of six otherwise-valid candidates; the cap should still
        // be reached from what's left, not come up two short.
        let rest = (0..<6).map { _ in UUID() }
        let blocked = UUID()
        let ids = QuickTagChips.selectedIds(from: [me, blocked] + rest, selfId: me,
                                             blockedIds: [blocked], cap: 6)
        XCTAssertEqual(ids, rest)
    }

    func testFewerThanTheCapIsNotPaddedOut() {
        let ids = QuickTagChips.selectedIds(from: [a, b], selfId: me, blockedIds: [], cap: 6)
        XCTAssertEqual(ids, [a, b])
    }
}

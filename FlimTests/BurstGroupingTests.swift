import XCTest
@testable import Flim

/// `BurstGrouping`, the pure rule shared by the roll grid (`RollGridItem.build`) and the reveal
/// (`RollRevealViewModel.loadDeck`'s `playback`): which consecutive frames collapse into one
/// burst, which frame is the cover, and what the grid's own fan-open state does to the render
/// list. Nothing here touches Vision or a live view; every fixture below sets `burstGroup`/
/// `sharpness` directly, the same shape a `SELECT *` on `photos` would decode.
final class BurstGroupingTests: XCTestCase {

    private func photo(_ id: UUID = UUID(), userId: UUID, burstGroup: UUID? = nil,
                       sharpness: Double? = nil, takenAt: Date = .now) -> Photo {
        var p = Photo(id: id, userId: userId, rollId: nil, storagePath: "p/\(id).jpg",
                     takenAt: takenAt, developsAt: takenAt, isDeveloped: true)
        p.burstGroup = burstGroup
        p.sharpness = sharpness
        return p
    }

    // MARK: - consecutiveRuns

    func testNilGroupFramesAreEachTheirOwnRun() {
        let user = UUID()
        let photos = (0..<3).map { i in photo(userId: user, takenAt: Date(timeIntervalSince1970: Double(i))) }
        let runs = BurstGrouping.consecutiveRuns(photos)
        XCTAssertEqual(runs.map { $0.map(\.id) }, photos.map { [$0.id] })
    }

    func testTwoBurstsAreSeparateRuns() {
        let user = UUID()
        let groupA = UUID(), groupB = UUID()
        let a1 = photo(userId: user, burstGroup: groupA, takenAt: Date(timeIntervalSince1970: 0))
        let a2 = photo(userId: user, burstGroup: groupA, takenAt: Date(timeIntervalSince1970: 1))
        let singleton = photo(userId: user, takenAt: Date(timeIntervalSince1970: 2))
        let b1 = photo(userId: user, burstGroup: groupB, takenAt: Date(timeIntervalSince1970: 3))
        let b2 = photo(userId: user, burstGroup: groupB, takenAt: Date(timeIntervalSince1970: 4))

        let runs = BurstGrouping.consecutiveRuns([a1, a2, singleton, b1, b2])
        XCTAssertEqual(runs.map { $0.map(\.id) }, [[a1.id, a2.id], [singleton.id], [b1.id, b2.id]])
    }

    func testABurstNeverSpansShooters() {
        // Bad data: two frames tagged with the SAME group id, but a different shooter's frame
        // sits between them. The run must close at the shooter change even though the group id
        // printed on the third frame matches the first two.
        let userA = UUID(), userB = UUID()
        let group = UUID()
        let mine1 = photo(userId: userA, burstGroup: group, takenAt: Date(timeIntervalSince1970: 0))
        let theirs = photo(userId: userB, burstGroup: group, takenAt: Date(timeIntervalSince1970: 1))
        let mine2 = photo(userId: userA, burstGroup: group, takenAt: Date(timeIntervalSince1970: 2))

        let runs = BurstGrouping.consecutiveRuns([mine1, theirs, mine2])
        XCTAssertEqual(runs.map { $0.map(\.id) }, [[mine1.id], [theirs.id], [mine2.id]])
    }

    func testAGroupIdReusedAfterAnUnrelatedFrameStartsAFreshRun() {
        // The same group id appears again after a run of a DIFFERENT group already closed the
        // first run: this is bad/coincidental data, and `consecutiveRuns` must not reach back
        // across the interruption to reunite them.
        let user = UUID()
        let group = UUID(), other = UUID()
        let first = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 0))
        let middle = photo(userId: user, burstGroup: other, takenAt: Date(timeIntervalSince1970: 1))
        let later = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 2))

        let runs = BurstGrouping.consecutiveRuns([first, middle, later])
        XCTAssertEqual(runs.map { $0.map(\.id) }, [[first.id], [middle.id], [later.id]])
    }

    // MARK: - sharpest

    func testSharpestFramePicksTheHighestScore() {
        let user = UUID()
        let dull = photo(userId: user, sharpness: 0.2)
        let sharp = photo(userId: user, sharpness: 0.9)
        XCTAssertEqual(BurstGrouping.sharpest(in: [dull, sharp])?.id, sharp.id)
    }

    func testNilSharpnessRanksLowestNeverHighest() {
        // One measured frame among several unmeasured ones must still win, even at a low score.
        let user = UUID()
        let unmeasured1 = photo(userId: user, sharpness: nil)
        let unmeasured2 = photo(userId: user, sharpness: nil)
        let measured = photo(userId: user, sharpness: 0.05)
        XCTAssertEqual(BurstGrouping.sharpest(in: [unmeasured1, measured, unmeasured2])?.id, measured.id)
    }

    func testTiesBreakOnEarliestTakenAtStably() {
        let user = UUID()
        let later = photo(userId: user, sharpness: 0.5, takenAt: Date(timeIntervalSince1970: 100))
        let earlier = photo(userId: user, sharpness: 0.5, takenAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(BurstGrouping.sharpest(in: [later, earlier])?.id, earlier.id)
        // Order-independent: the same input, reordered, picks the same winner.
        XCTAssertEqual(BurstGrouping.sharpest(in: [earlier, later])?.id, earlier.id)
    }

    func testEmptyRunReturnsNil() {
        XCTAssertNil(BurstGrouping.sharpest(in: []))
    }

    // MARK: - playback

    func testPlaybackPlaysOnlyTheSharpestFrameOfEachBurstAndCountsTheRest() {
        let user = UUID()
        let group = UUID()
        let dull = photo(userId: user, burstGroup: group, sharpness: 0.3, takenAt: Date(timeIntervalSince1970: 0))
        let sharp = photo(userId: user, burstGroup: group, sharpness: 0.9, takenAt: Date(timeIntervalSince1970: 1))
        let third = photo(userId: user, burstGroup: group, sharpness: 0.4, takenAt: Date(timeIntervalSince1970: 2))
        let lone = photo(userId: user, takenAt: Date(timeIntervalSince1970: 3))

        let (played, extra) = BurstGrouping.playback([dull, sharp, third, lone])
        XCTAssertEqual(played.map(\.id), [sharp.id, lone.id])
        XCTAssertEqual(extra[sharp.id], 2)
        XCTAssertNil(extra[lone.id])
        XCTAssertNil(extra[dull.id], "only the COVER's id carries the extra count")
    }

    func testPlaybackOfAnAllSingletonDeckIsUnchanged() {
        let user = UUID()
        let photos = (0..<4).map { i in photo(userId: user, takenAt: Date(timeIntervalSince1970: Double(i))) }
        let (played, extra) = BurstGrouping.playback(photos)
        XCTAssertEqual(played.map(\.id), photos.map(\.id))
        XCTAssertTrue(extra.isEmpty)
    }

    // MARK: - RollGridItem

    func testGridCollapsesABurstToOneStackItem() {
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, sharpness: 0.2, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, sharpness: 0.8, takenAt: Date(timeIntervalSince1970: 1))
        let lone = photo(userId: user, takenAt: Date(timeIntervalSince1970: 2))

        let items = RollGridItem.build(from: [a, b, lone])
        XCTAssertEqual(items.count, 2)
        guard case .stack(let stack) = items[0] else { return XCTFail("expected the burst to collapse first") }
        XCTAssertEqual(stack.cover.id, b.id, "the sharper frame is the cover")
        XCTAssertEqual(stack.frames.map(\.id), [a.id, b.id], "chronological, both frames kept")
        XCTAssertEqual(stack.count, 2)
        guard case .single(let single) = items[1] else { return XCTFail("the lone frame passes through untouched") }
        XCTAssertEqual(single.id, lone.id)
    }

    func testGridWithNoBurstsIsAllSingles() {
        let user = UUID()
        let photos = (0..<3).map { i in photo(userId: user, takenAt: Date(timeIntervalSince1970: Double(i))) }
        let items = RollGridItem.build(from: photos)
        XCTAssertEqual(items.count, 3)
        for item in items {
            guard case .single = item else { return XCTFail("no burst_group anywhere must mean no stacks") }
        }
    }

    func testStackIdIsTheFirstFramesIdNotTheGroupId() {
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, sharpness: 0.9, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, sharpness: 0.1, takenAt: Date(timeIntervalSince1970: 1))
        let items = RollGridItem.build(from: [a, b])
        guard case .stack(let stack) = items.first else { return XCTFail() }
        XCTAssertEqual(stack.id, a.id)
        XCTAssertNotEqual(stack.id, group, "identity must never be the shared group id")
    }

    // MARK: - RollDisplayItem (fan open / collapse)

    func testACollapsedStackShowsOneCoverCell() {
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, sharpness: 0.2, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, sharpness: 0.8, takenAt: Date(timeIntervalSince1970: 1))
        let grid = RollGridItem.build(from: [a, b])

        let displayed = RollDisplayItem.displayItems(from: grid, expanded: [])
        XCTAssertEqual(displayed.count, 1)
        guard case .stackCover(let stack) = displayed[0] else { return XCTFail() }
        XCTAssertEqual(stack.cover.id, b.id)
    }

    func testExpandingAStackShowsEveryFrameInlineChronologically() {
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, sharpness: 0.2, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, sharpness: 0.8, takenAt: Date(timeIntervalSince1970: 1))
        let lone = photo(userId: user, takenAt: Date(timeIntervalSince1970: 2))
        let grid = RollGridItem.build(from: [a, b, lone])
        guard case .stack(let stack) = grid[0] else { return XCTFail() }

        let displayed = RollDisplayItem.displayItems(from: grid, expanded: [stack.id])
        XCTAssertEqual(displayed.count, 3)
        guard case .stackMember(let m0, let stackId0) = displayed[0] else { return XCTFail() }
        guard case .stackMember(let m1, let stackId1) = displayed[1] else { return XCTFail() }
        XCTAssertEqual([m0.id, m1.id], [a.id, b.id], "fanned open, still chronological")
        XCTAssertEqual(stackId0, stack.id)
        XCTAssertEqual(stackId1, stack.id)
        guard case .single(let single) = displayed[2] else { return XCTFail() }
        XCTAssertEqual(single.id, lone.id)
    }

    func testOnlyTheFirstFannedFrameCarriesTheStacksIdentityForCollapsing() {
        // The view uses `stackMember`'s own frame id == `stackId` to decide which fanned cell
        // draws the "collapse" mark; assert that identity only ever matches the first frame.
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 1))
        let c = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 2))
        let grid = RollGridItem.build(from: [a, b, c])
        guard case .stack(let stack) = grid[0] else { return XCTFail() }

        let displayed = RollDisplayItem.displayItems(from: grid, expanded: [stack.id])
        let matches = displayed.compactMap { item -> Bool? in
            guard case .stackMember(let photo, let stackId) = item else { return nil }
            return photo.id == stackId
        }
        XCTAssertEqual(matches, [true, false, false])
    }

    func testAnUnrelatedExpandedIdDoesNothing() {
        let user = UUID()
        let group = UUID()
        let a = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 0))
        let b = photo(userId: user, burstGroup: group, takenAt: Date(timeIntervalSince1970: 1))
        let grid = RollGridItem.build(from: [a, b])

        let displayed = RollDisplayItem.displayItems(from: grid, expanded: [UUID()])
        XCTAssertEqual(displayed.count, 1)
        guard case .stackCover = displayed[0] else { return XCTFail("must stay collapsed") }
    }
}

import XCTest
@testable import Flim

/// `FeedUnit`: the grouping rules behind the per-author feed. These pin the decisions the
/// design settled across its review rounds: the 04:00 day boundary, post-time keying,
/// chronological frames inside recency-ordered units, the strip's cap, and the seen-state
/// derivations (opening frame, pill count, ledger, caught-up seam).
final class FeedUnitTests: XCTestCase {

    // Fixed calendar so the boundary math never depends on the machine running the tests.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func profile(_ id: UUID, name: String) -> UserProfile {
        UserProfile(id: id, username: name, avatarPath: nil, bio: nil, displayName: nil,
                    coverPath: nil, createdAt: date(1, 12), hiddenFromDiscovery: false,
                    signupOrdinal: nil)
    }

    private func item(author: UserProfile, at createdAt: Date, taken: Date? = nil,
                      id: UUID = UUID()) -> FeedItem {
        FeedItem(
            post: Post(id: id, userId: author.id, photoId: UUID(),
                       storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
                       takenAt: taken ?? createdAt, caption: nil, createdAt: createdAt),
            author: author)
    }

    // MARK: - The 04:00 boundary

    func testMidnightStraddleIsOneNight() {
        // 23:40 and 00:20 are one night out. A midnight cut splits them, which is the flood
        // problem in miniature; the 04:00 boundary keeps them one unit.
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [
            item(author: mira, at: date(21, 23, 40)),
            item(author: mira, at: date(22, 0, 20)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].items.count, 2)
    }

    func testShotAfterFourAMFilesUnderTheNewDay() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [
            item(author: mira, at: date(21, 23, 40)),
            item(author: mira, at: date(22, 4, 30)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 2)
    }

    func testTwoAMShotFilesUnderYesterday() {
        // What the person who took it would call it.
        XCTAssertEqual(
            FeedUnit.dayKey(for: date(22, 2, 0), calendar: calendar),
            FeedUnit.dayKey(for: date(21, 14, 0), calendar: calendar))
    }

    // MARK: - Ordering

    func testFramesChronologicalUnitsByRecency() {
        let mira = profile(UUID(), name: "mira")
        let dev = profile(UUID(), name: "dev.k")
        // dev posts once in the morning; mira posts morning and evening. Mira's unit is
        // fresher (newest post wins) even though dev posted after her first shot.
        let miraEarly = item(author: mira, at: date(21, 8, 12))
        let devShot = item(author: dev, at: date(21, 10, 0))
        let miraLate = item(author: mira, at: date(21, 23, 36))
        let units = FeedUnit.units(from: [devShot, miraLate, miraEarly], calendar: calendar)

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].author.id, mira.id)
        // Oldest left, newest right: a day is a sequence you read.
        XCTAssertEqual(units[0].items.map(\.post.id), [miraEarly.post.id, miraLate.post.id])
        XCTAssertEqual(units[1].author.id, dev.id)
    }

    func testSameAuthorTwoDaysIsTwoUnits() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [
            item(author: mira, at: date(20, 12, 0)),
            item(author: mira, at: date(21, 12, 0)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 2)
        XCTAssertGreaterThan(units[0].newestAt, units[1].newestAt)
    }

    // MARK: - Meta line

    func testMetaLineSoloStatesOneTime() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [item(author: mira, at: date(21, 8, 12))], calendar: calendar)
        XCTAssertTrue(units[0].metaLine.hasPrefix("1 shot · "))
        XCTAssertFalse(units[0].metaLine.contains(" to "))
    }

    func testMetaLineSpanForMultipleShots() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [
            item(author: mira, at: date(21, 8, 12)),
            item(author: mira, at: date(21, 23, 36)),
        ], calendar: calendar)
        XCTAssertTrue(units[0].metaLine.hasPrefix("2 shots · "))
        XCTAssertTrue(units[0].metaLine.contains(" to "))
    }

    func testMetaLineNarratesCaptureTimeNotPostTime() {
        // The batch-publish case: both posted at 11:34, taken through the morning. Post time
        // produced "11:34 AM to 11:34 AM"; capture time tells the story.
        let sadia = profile(UUID(), name: "sadia")
        let units = FeedUnit.units(from: [
            item(author: sadia, at: date(21, 11, 34), taken: date(21, 9, 12)),
            item(author: sadia, at: date(21, 11, 34), taken: date(21, 11, 20)),
        ], calendar: calendar)
        let line = units[0].metaLine(calendar: calendar)
        XCTAssertTrue(line.hasPrefix("2 shots · "))
        XCTAssertTrue(line.contains(" to "))
        XCTAssertFalse(line.contains("11:34"))
    }

    func testMetaLineCollapsesADegenerateSpan() {
        // Two captures in the same minute must not read "11:34 AM to 11:34 AM".
        let sadia = profile(UUID(), name: "sadia")
        let units = FeedUnit.units(from: [
            item(author: sadia, at: date(21, 11, 34), taken: date(21, 11, 34)),
            item(author: sadia, at: date(21, 11, 34), taken: date(21, 11, 34)),
        ], calendar: calendar)
        let line = units[0].metaLine(calendar: calendar)
        XCTAssertTrue(line.hasPrefix("2 shots · "))
        XCTAssertFalse(line.contains(" to "))
    }

    func testMetaLineUsesDatesWhenCapturesCrossDays() {
        // Darkroom archaeology: a fresh shot posted beside one taken weeks earlier. A
        // time-of-day span across weeks would lie, so the line switches to dates (which
        // carry no clock, hence no colon).
        let sadia = profile(UUID(), name: "sadia")
        let units = FeedUnit.units(from: [
            item(author: sadia, at: date(21, 11, 34), taken: date(21, 10, 0)),
            item(author: sadia, at: date(21, 11, 34), taken: date(2, 15, 30)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 1, "grouping stays keyed on POST time")
        let line = units[0].metaLine(calendar: calendar)
        XCTAssertTrue(line.hasPrefix("2 shots · "))
        XCTAssertTrue(line.contains(" to "))
        XCTAssertFalse(line.contains(":"), "a cross-day span shows dates, not clock times")
    }

    func testFramesOrderByCaptureTimeWithinAUnit() {
        // Batch-published posts land seconds apart in triage order; the strip should read
        // the day as lived, oldest capture first.
        let sadia = profile(UUID(), name: "sadia")
        let lateCapture = item(author: sadia, at: date(21, 11, 34), taken: date(21, 11, 20))
        let earlyCapture = item(author: sadia, at: date(21, 11, 35), taken: date(21, 9, 12))
        let units = FeedUnit.units(from: [lateCapture, earlyCapture], calendar: calendar)
        XCTAssertEqual(units[0].items.map(\.post.id), [earlyCapture.post.id, lateCapture.post.id])
        // Unit freshness still follows the newest POST, not the newest capture.
        XCTAssertEqual(units[0].newestAt, date(21, 11, 35))
    }

    // MARK: - Seen-state derivations

    func testOpensOnFirstUnseenAndPillCountsRemaining() {
        let mira = profile(UUID(), name: "mira")
        let items = (0..<5).map { item(author: mira, at: date(21, 8 + $0)) }
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        let seen: Set<UUID> = [items[0].post.id, items[1].post.id, items[3].post.id]

        XCTAssertEqual(unit.openingIndex(isSeen: { seen.contains($0) }), 2)
        XCTAssertEqual(unit.unseenCount(isSeen: { seen.contains($0) }), 2)
    }

    func testFullySeenUnitOpensOnItsFirstShot() {
        let mira = profile(UUID(), name: "mira")
        let items = (0..<3).map { item(author: mira, at: date(21, 8 + $0)) }
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        XCTAssertEqual(unit.openingIndex(isSeen: { _ in true }), 0)
    }

    func testLedgerCountsWholeUnitsWithAnythingUnseen() {
        // The ledger counts what ARRIVED: every shot in units holding an unseen mark, not
        // just the unseen shots, and nothing at all from fully-seen units.
        let mira = profile(UUID(), name: "mira")
        let dev = profile(UUID(), name: "dev.k")
        let miraItems = (0..<3).map { item(author: mira, at: date(21, 8 + $0)) }
        let devItems = [item(author: dev, at: date(21, 12))]
        let units = FeedUnit.units(from: miraItems + devItems, calendar: calendar)

        // dev fully seen, mira partially: ledger counts mira's whole day only.
        let seen: Set<UUID> = [devItems[0].post.id, miraItems[0].post.id]
        let ledger = FeedUnit.ledger(units: units, isSeen: { seen.contains($0) })
        XCTAssertEqual(ledger?.shots, 3)
        XCTAssertEqual(ledger?.friends, 1)
    }

    func testLedgerNilWhenEverythingSeen() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [item(author: mira, at: date(21, 8))], calendar: calendar)
        XCTAssertNil(FeedUnit.ledger(units: units, isSeen: { _ in true }))
    }

    func testCaughtUpIndexIsLastUnitWithUnseen() {
        let mira = profile(UUID(), name: "mira")
        let dev = profile(UUID(), name: "dev.k")
        let noor = profile(UUID(), name: "noor")
        // Three units by recency: noor (day 22), dev (day 21), mira (day 20). dev holds the
        // unseen shot, so the seam lands after dev with mira's seen day below it.
        let miraItem = item(author: mira, at: date(20, 12))
        let devItem = item(author: dev, at: date(21, 12))
        let noorItem = item(author: noor, at: date(22, 12))
        let units = FeedUnit.units(from: [miraItem, devItem, noorItem], calendar: calendar)
        let seen: Set<UUID> = [miraItem.post.id, noorItem.post.id]

        XCTAssertEqual(FeedUnit.caughtUpIndex(units: units, isSeen: { seen.contains($0) }), 1)
        XCTAssertNil(FeedUnit.caughtUpIndex(units: units, isSeen: { _ in true }))
    }

    func testDuplicatePostsCollapseToOne() {
        // The render-side guarantee behind the 21-shots-of-12-photos incident: however a
        // duplicate reaches the flat feed (the straddle-completion race that caused it now
        // has a guard), grouping must never emit the same post twice, because colliding ids
        // scramble every ForEach and pager tag keyed on them.
        let ricky = profile(UUID(), name: "ricky")
        let shot = item(author: ricky, at: date(21, 10, 0))
        let other = item(author: ricky, at: date(21, 11, 0))
        let units = FeedUnit.units(from: [shot, other, shot, shot], calendar: calendar)

        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].items.count, 2)
        XCTAssertEqual(Set(units[0].items.map(\.post.id)).count, 2)
        XCTAssertTrue(units[0].metaLine(calendar: calendar).hasPrefix("2 shots"))
    }

    // MARK: - Retention

    func testUnitWithAnyUnseenShotNeverClears() {
        // Nothing unseen expires, however long it takes: one unreached shot keeps the unit.
        let mira = profile(UUID(), name: "mira")
        let items = (0..<3).map { item(author: mira, at: date(10, 8 + $0)) }
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        let marks = [items[0].post.id: date(11, 9), items[1].post.id: date(11, 9)]

        XCTAssertFalse(unit.hasCleared(seenAt: { marks[$0] }, now: date(22, 12), calendar: calendar))
    }

    func testSeenUnitClearsAtTheNextBoundaryAndNotBefore() {
        let mira = profile(UUID(), name: "mira")
        let items = (0..<2).map { item(author: mira, at: date(20, 8 + $0)) }
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        // Both shots read at 9 PM on the 21st.
        let marks = [items[0].post.id: date(21, 21), items[1].post.id: date(21, 21)]
        let seenAt: (UUID) -> Date? = { marks[$0] }

        // Later that night, and even at 3 AM (before the boundary): still in the feed, so
        // the reader can go back to it for the rest of that day.
        XCTAssertFalse(unit.hasCleared(seenAt: seenAt, now: date(21, 23), calendar: calendar))
        XCTAssertFalse(unit.hasCleared(seenAt: seenAt, now: date(22, 3), calendar: calendar))
        // Past 4 AM the next morning: gone.
        XCTAssertTrue(unit.hasCleared(seenAt: seenAt, now: date(22, 5), calendar: calendar))
    }

    func testClearingUsesTheLastShotReached() {
        // One shot read Monday, the other Tuesday evening: the unit lives until the
        // boundary after the LAST mark, not the first.
        let mira = profile(UUID(), name: "mira")
        let items = (0..<2).map { item(author: mira, at: date(20, 8 + $0)) }
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        let marks = [items[0].post.id: date(20, 12), items[1].post.id: date(21, 20)]
        let seenAt: (UUID) -> Date? = { marks[$0] }

        XCTAssertFalse(unit.hasCleared(seenAt: seenAt, now: date(21, 23), calendar: calendar))
        XCTAssertTrue(unit.hasCleared(seenAt: seenAt, now: date(22, 8), calendar: calendar))
    }

    func testLegacyUndatedMarksClearImmediately() {
        // Migrated pre-retention marks carry `.distantPast`: "seen some time before this
        // scheme existed" clears at the first boundary, which is any `now`.
        let mira = profile(UUID(), name: "mira")
        let items = [item(author: mira, at: date(20, 8))]
        let unit = FeedUnit.units(from: items, calendar: calendar)[0]
        XCTAssertTrue(unit.hasCleared(seenAt: { _ in .distantPast }, now: date(20, 12), calendar: calendar))
    }

    // MARK: - Strip cap

    func testStripCapAndOverflow() {
        let mira = profile(UUID(), name: "mira")

        // 20 shots: exactly cap + 1, every frame still shows, no tile (a +1 tile would
        // occupy the slot the twentieth frame could have used).
        let twenty = FeedUnit.units(
            from: (0..<20).map { item(author: mira, at: date(21, 4).addingTimeInterval(Double($0) * 600)) },
            calendar: calendar)[0]
        XCTAssertEqual(twenty.stripOverflow, 0)
        XCTAssertEqual(twenty.stripShown, 20)

        // 40 shots: 19 frames plus a +21 tile.
        let forty = FeedUnit.units(
            from: (0..<40).map { item(author: mira, at: date(21, 4).addingTimeInterval(Double($0) * 600)) },
            calendar: calendar)[0]
        XCTAssertEqual(forty.stripOverflow, 21)
        XCTAssertEqual(forty.stripShown, 19)
    }
}

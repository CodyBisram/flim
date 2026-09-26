import XCTest
@testable import Flim

/// `FeedUnit`: the grouping rules behind the per-author feed. These pin the decisions the
/// design settled across its review rounds: the 04:00 day boundary, post-time keying,
/// chronological frames inside recency-ordered units, the strip's cap, and the seen-state
/// derivations (opening frame, pill count, header count, caught-up seam).
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

    // MARK: - The header count, no server answer (2026-09-26)
    //
    // The whole-unit "what arrived" ledger and its grow-only ratchet were removed: the header
    // counts what is LEFT on both paths now, so the fallback cannot read a different, larger
    // number than the server path. Their tests went with them.

    func testFallbackCountsUnseenFramesNotWholeUnits() {
        // Was `testLedgerCountsWholeUnitsWithAnythingUnseen`, which expected 3: mira's whole
        // day. The fallback now means what the server path means, the frames still unseen.
        let now = date(21, 20)
        let mira = profile(UUID(), name: "mira")
        let dev = profile(UUID(), name: "dev.k")
        let miraItems = (0..<3).map { item(author: mira, at: date(21, 8 + $0)) }
        let devItems = [item(author: dev, at: date(21, 12))]
        let units = FeedUnit.units(from: miraItems + devItems, calendar: calendar)

        let seen: Set<UUID> = [devItems[0].post.id, miraItems[0].post.id]
        let remaining = FeedUnit.loadedRemaining(units: units, currentUserId: nil, now: now,
                                                 isSeen: { seen.contains($0) })
        XCTAssertEqual(remaining?.shots, 2)
        XCTAssertEqual(remaining?.friends, 1)
    }

    func testFallbackNilWhenEverythingSeen() {
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [item(author: mira, at: date(21, 8))], calendar: calendar)
        XCTAssertNil(FeedUnit.loadedRemaining(units: units, currentUserId: nil, now: date(21, 20),
                                              isSeen: { _ in true }))
    }

    func testFallbackExcludesTheSignedInUsersOwnUnitEvenUnseen() {
        // "2 shots from 2 friends" once counted the owner themselves: you are not your own
        // friend, so a unit authored by the signed-in user contributes nothing, unseen or not.
        let me = profile(UUID(), name: "me")
        let dev = profile(UUID(), name: "dev.k")
        let myItems = (0..<3).map { item(author: me, at: date(21, 8 + $0)) }
        let devItems = [item(author: dev, at: date(21, 12))]
        let units = FeedUnit.units(from: myItems + devItems, calendar: calendar)

        let remaining = FeedUnit.loadedRemaining(units: units, currentUserId: me.id, now: date(21, 20),
                                                 isSeen: { _ in false })
        XCTAssertEqual(remaining?.shots, 1)
        XCTAssertEqual(remaining?.friends, 1)
    }

    func testFallbackNilWhenOnlyTheSignedInUsersOwnUnitIsUnseen() {
        let me = profile(UUID(), name: "me")
        let units = FeedUnit.units(from: [item(author: me, at: date(21, 8))], calendar: calendar)
        XCTAssertNil(FeedUnit.loadedRemaining(units: units, currentUserId: me.id, now: date(21, 20),
                                              isSeen: { _ in false }))
    }

    func testFallbackIgnoresAnUnseenPostOlderThanTheWindow() {
        // Loaded hours ago, when it was six days and change old; it has aged out since.
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [item(author: mira, at: date(14, 11))], calendar: calendar)
        XCTAssertNil(FeedUnit.loadedRemaining(units: units, currentUserId: nil, now: date(21, 12),
                                              isSeen: { _ in false }))
    }

    // MARK: - The header count, from the server (2026-09-23)

    func testRemainingLedgerSubtractsMarksTheServerCannotKnowAbout() {
        // The server said 5 shots from 3 friends. Since then the reader reached one frame
        // (dated after the count) and one older mark is still waiting to be pushed; both
        // are unknown to the server, so both come off. A mark dated BEFORE the count that
        // did reach the server is already excluded from its answer and must not come off
        // again.
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira"), dev = profile(UUID(), name: "dev.k"), sam = profile(UUID(), name: "sam")
        let miraItems = (0..<3).map { item(author: mira, at: date(21, 8 + $0)) }
        let devItems = [item(author: dev, at: date(21, 9))]
        let samItems = [item(author: sam, at: date(21, 10))]
        let units = FeedUnit.units(from: miraItems + devItems + samItems, calendar: calendar)
        let seen: [UUID: Date] = [
            miraItems[0].post.id: date(21, 13),   // reached after the count
            devItems[0].post.id: date(21, 11),    // before the count, but never pushed
            samItems[0].post.id: date(21, 11),    // before the count, on the server
        ]
        let pending: Set<UUID> = [devItems[0].post.id]
        let remaining = FeedUnit.remainingLedger(
            serverShots: 5, serverFriends: 3, countedAt: counted, pendingAtCount: [], now: date(21, 13),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { pending.contains($0) })
        XCTAssertEqual(remaining?.shots, 3)
        // dev's only frame is read and unknown to the server: dev is finished. mira still
        // holds two unseen frames. sam's mark was already in the server's count.
        XCTAssertEqual(remaining?.friends, 2)
    }

    func testRemainingLedgerNeverCountsFewerFriendsThanAuthorsStillOpen() {
        // The server's friend count is a floor for nobody: authors with unseen frames on
        // the loaded pages keep it honest even when the server said fewer.
        let counted = date(21, 12)
        let a = profile(UUID(), name: "a"), b = profile(UUID(), name: "b")
        let units = FeedUnit.units(from: [item(author: a, at: date(21, 8)), item(author: b, at: date(21, 9))], calendar: calendar)
        let remaining = FeedUnit.remainingLedger(
            serverShots: 2, serverFriends: 1, countedAt: counted, pendingAtCount: [], now: counted,
            units: units, currentUserId: nil,
            seenDate: { _ in nil }, isPendingSync: { _ in false })
        XCTAssertEqual(remaining?.shots, 2)
        XCTAssertEqual(remaining?.friends, 2)
    }

    func testRemainingLedgerIsNilAtZeroAndIgnoresOwnPosts() {
        // Was `...GoesToZero...`, expecting (0, 0). The function now owns "never a zero"
        // itself, so the header has no zero to accidentally render.
        let counted = date(21, 12)
        let me = profile(UUID(), name: "me"), dev = profile(UUID(), name: "dev.k")
        let mine = [item(author: me, at: date(21, 8))]
        let devItems = [item(author: dev, at: date(21, 9))]
        let units = FeedUnit.units(from: mine + devItems, calendar: calendar)
        // My own unseen post must not be subtracted from the server's count of my friends'.
        let seen: [UUID: Date] = [devItems[0].post.id: date(21, 13), mine[0].post.id: date(21, 13)]
        let remaining = FeedUnit.remainingLedger(
            serverShots: 1, serverFriends: 1, countedAt: counted, pendingAtCount: [], now: date(21, 13),
            units: units, currentUserId: me.id,
            seenDate: { seen[$0] }, isPendingSync: { _ in false })
        XCTAssertNil(remaining)
    }

    func testServerZeroWithALoadedUnseenPostOlderThanTheWindowShowsNoLine() {
        // "0 shots from 0 friends": the feed was loaded when this post was inside the seven
        // days; by the recount it had aged out, so the server said 0 while the loaded post sat
        // unseen and kept the line lit. With a server count in hand, loaded units do not vote.
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira")
        let units = FeedUnit.units(from: [item(author: mira, at: date(14, 11))], calendar: calendar)
        XCTAssertNil(FeedUnit.remainingLedger(
            serverShots: 0, serverFriends: 0, countedAt: counted, pendingAtCount: [], now: counted,
            units: units, currentUserId: nil,
            seenDate: { _ in nil }, isPendingSync: { _ in false }))
    }

    func testAMarkOnAPostOlderThanTheWindowIsNotSubtracted() {
        // The same aged-out post, now reached and still pending. The server's 1 is dev's fresh
        // shot; mira's post left its count when it aged out, so her mark must not take dev's
        // shot off with it (the old arithmetic read 0 and dropped the line under dev's post).
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira"), dev = profile(UUID(), name: "dev.k")
        let old = item(author: mira, at: date(14, 11))
        let fresh = item(author: dev, at: date(21, 9))
        let units = FeedUnit.units(from: [old, fresh], calendar: calendar)
        let seen: [UUID: Date] = [old.post.id: date(21, 13)]
        let remaining = FeedUnit.remainingLedger(
            serverShots: 1, serverFriends: 1, countedAt: counted, pendingAtCount: [old.post.id], now: date(21, 13),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { $0 == old.post.id })
        XCTAssertEqual(remaining?.shots, 1)
        XCTAssertEqual(remaining?.friends, 1)
    }

    func testAMarkOnAPostNewerThanTheCountIsNotSubtracted() {
        // A post that landed after the count was asked (the page load runs beside it) was
        // never in the count, so reaching it takes nothing off.
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira"), dev = profile(UUID(), name: "dev.k")
        let late = item(author: mira, at: date(21, 13))
        let fresh = item(author: dev, at: date(21, 9))
        let units = FeedUnit.units(from: [late, fresh], calendar: calendar)
        let seen: [UUID: Date] = [late.post.id: date(21, 14)]
        let remaining = FeedUnit.remainingLedger(
            serverShots: 1, serverFriends: 1, countedAt: counted, pendingAtCount: [], now: date(21, 14),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { _ in true })
        XCTAssertEqual(remaining?.shots, 1)
    }

    func testAFlushLandingBeforeTheRecountDoesNotBounce() {
        // The four-second flicker. Two marks made before the count were still pending when it
        // was asked, so the count includes them and both come off: 5 to 3. Their push lands
        // and clears "pending now"; the recount that push triggers answers a round trip later.
        // In between, the number must stay 3, not jump back to 5 and fall again.
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira")
        let miraItems = (0..<5).map { item(author: mira, at: date(21, 6 + $0)) }
        let units = FeedUnit.units(from: miraItems, calendar: calendar)
        let marked = [miraItems[0].post.id, miraItems[1].post.id]
        let seen: [UUID: Date] = [marked[0]: date(21, 11), marked[1]: date(21, 11)]
        let pendingAtCount = Set(marked)

        let beforeFlush = FeedUnit.remainingLedger(
            serverShots: 5, serverFriends: 1, countedAt: counted, pendingAtCount: pendingAtCount, now: date(21, 12, 5),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { pendingAtCount.contains($0) })
        let afterFlush = FeedUnit.remainingLedger(
            serverShots: 5, serverFriends: 1, countedAt: counted, pendingAtCount: pendingAtCount, now: date(21, 12, 6),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { _ in false })
        XCTAssertEqual(beforeFlush?.shots, 3)
        XCTAssertEqual(afterFlush?.shots, 3, "the landed push must not put its marks back on the count")

        // Without the snapshot, this is the bounce.
        let unguarded = FeedUnit.remainingLedger(
            serverShots: 5, serverFriends: 1, countedAt: counted, pendingAtCount: [], now: date(21, 12, 6),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { _ in false })
        XCTAssertEqual(unguarded?.shots, 5)
    }

    func testAnAuthorWithOneDayReadAndAnotherOpenIsNotFinished() {
        // Per author, not per unit: mira's day 20 is read (after the count), her day 21 is not.
        // She still counts; sam is on a page not loaded yet. Two friends, not one.
        let counted = date(21, 12)
        let mira = profile(UUID(), name: "mira")
        let readDay = item(author: mira, at: date(20, 10))
        let openDay = item(author: mira, at: date(21, 10))
        let units = FeedUnit.units(from: [readDay, openDay], calendar: calendar)
        let seen: [UUID: Date] = [readDay.post.id: date(21, 13)]
        let remaining = FeedUnit.remainingLedger(
            serverShots: 3, serverFriends: 2, countedAt: counted, pendingAtCount: [], now: date(21, 13),
            units: units, currentUserId: nil,
            seenDate: { seen[$0] }, isPendingSync: { _ in false })
        XCTAssertEqual(remaining?.shots, 2)
        XCTAssertEqual(remaining?.friends, 2)
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
    //
    // The clearing tests that lived here were deleted 2026-08-28 along with `hasCleared` and
    // `clearedUnitIDs`. They passed, and they described a rule that could not work: they only
    // ever exercised units whose every shot carried a mark, which is the case real reading
    // almost never produces. A ten-shot day gets one mark per scroll-past, so it needed ten
    // sessions to clear, and in the meantime the feed both emptied (single-shot days) and never
    // ended (everything else). Green tests over a contradictory spec is why this took a week to
    // find. What replaced the rule is nothing at all: the feed shows what the fetch returned.

    func testTheFeedShowsEveryUnitTheFetchReturned() {
        // The guarantee that replaced clearing, and the reason a seen-state bug can no longer
        // empty the feed or make it endless: grouping is total. Every post in, every post out,
        // whatever the marks say.
        let mira = profile(UUID(), name: "mira")
        let dev = profile(UUID(), name: "dev")
        let items = [item(author: mira, at: date(20, 9)),
                     item(author: mira, at: date(20, 10)),
                     item(author: dev, at: date(21, 9))]

        let units = FeedUnit.units(from: items, calendar: calendar)

        XCTAssertEqual(units.count, 2, "one unit per author per day, nothing withheld")
        XCTAssertEqual(units.flatMap(\.items).count, items.count)
    }

    func testRetentionWindowIsTheOnlyBoundOnLength() {
        // Seven days, and the number that matters now that nothing else shortens the feed.
        // Short windows drop posts that have only just become visible: this app develops on a
        // delay, so a Saturday capture can post on Sunday and a roll can land days later.
        XCTAssertEqual(FeedUnit.retentionWindow, 7 * 86400)
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

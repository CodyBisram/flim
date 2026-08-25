import XCTest
@testable import Flim

/// `DarkroomDayUnit`: the grouping and contact-sheet math behind the Darkroom's night-per-unit
/// redesign. These pin the design's exact strip-cutting rule (greedy fill, pad only the short
/// last strip of a MULTI-strip sheet, never a lone short day) and the 04:00 boundary shared with
/// `FeedUnit`.
final class DarkroomDayUnitTests: XCTestCase {

    // Fixed calendar so the boundary math never depends on the machine running the tests.
    private var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        return cal
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func photo(id: UUID = UUID(), takenAt: Date, developsAt: Date? = nil, ready: Bool = true) -> Photo {
        Photo(id: id, userId: UUID(), rollId: nil, storagePath: "p/\(id).jpg", thumbPath: nil, feedPath: nil,
              takenAt: takenAt, developsAt: developsAt ?? (ready ? takenAt.addingTimeInterval(-1) : .distantFuture),
              isDeveloped: ready, caption: nil, isSorted: true)
    }

    // MARK: - Strip cutting

    func testThirtyShotsCutNineNineNineThree() {
        let photos = (0..<30).map { photo(takenAt: date(21, 4).addingTimeInterval(Double($0) * 60)) }
        let strips = DarkroomDayUnit.cutStrips(photos: photos, capacity: 9)

        XCTAssertEqual(strips.count, 4)
        XCTAssertEqual(strips[0].slots.count, 9)
        XCTAssertEqual(strips[1].slots.count, 9)
        XCTAssertEqual(strips[2].slots.count, 9)
        // Last strip: 3 real frames padded out to capacity with 6 unexposed slots.
        XCTAssertEqual(strips[3].slots.count, 9)
        let lastFrameKinds = strips[3].slots.map { slot -> Bool in
            if case .photo = slot { return true } else { return false }
        }
        XCTAssertEqual(lastFrameKinds.filter { $0 }.count, 3)
        XCTAssertEqual(lastFrameKinds.filter { !$0 }.count, 6)

        // Padding is exclusive to the last strip: the first three are all-real frames.
        for strip in strips[0...2] {
            XCTAssertTrue(strip.slots.allSatisfy { if case .photo = $0 { return true } else { return false } })
        }
    }

    func testFourShotsIsOneUnpaddedStrip() {
        let photos = (0..<4).map { photo(takenAt: date(21, 4).addingTimeInterval(Double($0) * 60)) }
        let strips = DarkroomDayUnit.cutStrips(photos: photos, capacity: 9)

        XCTAssertEqual(strips.count, 1)
        // A single-strip day stays exactly as short as its frame count: no padding.
        XCTAssertEqual(strips[0].slots.count, 4)
        XCTAssertTrue(strips[0].slots.allSatisfy { if case .photo = $0 { return true } else { return false } })
    }

    func testOneShotIsOneUnpaddedFrame() {
        let strips = DarkroomDayUnit.cutStrips(photos: [photo(takenAt: date(21, 4))], capacity: 9)
        XCTAssertEqual(strips.count, 1)
        XCTAssertEqual(strips[0].slots.count, 1)
    }

    func testCapacityIsDerivedFromWidth() {
        // 393pt screen, 16pt side margins: 361pt available, 8 whole frames at 44pt pitch.
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 361), 8)
        // A hair under one more frame's worth still fits 8, not 9.
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 393.9), 8)
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 350), 8)   // exactly 8*44-2
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 349.9), 7)
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 0), 0)
    }

    func testFourteenShotsAtCapacityEightCutEightSixPadded() {
        // PR 1's worked example: a 14-shot night at the new capacity cuts 8 + 6, and only the
        // short LAST strip pads out to capacity with unexposed slots.
        let photos = (0..<14).map { photo(takenAt: date(21, 4).addingTimeInterval(Double($0) * 60)) }
        let strips = DarkroomDayUnit.cutStrips(photos: photos, capacity: 8)
        XCTAssertEqual(strips.count, 2)
        XCTAssertEqual(strips[0].slots.count, 8)
        XCTAssertEqual(strips[1].slots.count, 8)
        let realInLast = strips[1].slots.filter { if case .photo = $0 { return true } else { return false } }.count
        XCTAssertEqual(realInLast, 6)
    }

    // MARK: - Grouping across the 4am boundary

    func testMidnightStraddleIsOneNight() {
        let units = DarkroomDayUnit.units(from: [
            photo(takenAt: date(21, 23, 40)),
            photo(takenAt: date(22, 2, 15)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].photos.count, 2)
    }

    func testShotAfterFourAMFilesUnderTheNewDay() {
        let units = DarkroomDayUnit.units(from: [
            photo(takenAt: date(21, 23, 40)),
            photo(takenAt: date(22, 4, 30)),
        ], calendar: calendar)
        XCTAssertEqual(units.count, 2)
    }

    // MARK: - Ordering

    func testUnitsNewestFirstFramesOldestFirstInside() {
        let early = photo(takenAt: date(20, 12))
        let late = photo(takenAt: date(21, 9))
        let latest = photo(takenAt: date(21, 20))
        let units = DarkroomDayUnit.units(from: [latest, early, late], calendar: calendar)

        XCTAssertEqual(units.count, 2)
        XCTAssertGreaterThan(units[0].dayKey, units[1].dayKey)
        // Day 21 (newer) holds late + latest, oldest capture first.
        XCTAssertEqual(units[0].photos.map(\.id), [late.id, latest.id])
        XCTAssertEqual(units[1].photos.map(\.id), [early.id])
    }

    func testDuplicatePhotosCollapseToOne() {
        let shot = photo(takenAt: date(21, 10))
        let units = DarkroomDayUnit.units(from: [shot, shot, shot], calendar: calendar)
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].photos.count, 1)
    }

    // MARK: - Mixed developed + developing

    func testMixedDayKeepsChronologicalPositions() {
        let developedEarly = photo(takenAt: date(21, 8), ready: true)
        let developingMiddle = photo(takenAt: date(21, 14), ready: false)
        let developedLate = photo(takenAt: date(21, 20), ready: true)
        let units = DarkroomDayUnit.units(from: [developedLate, developingMiddle, developedEarly], calendar: calendar)

        XCTAssertEqual(units.count, 1)
        // Developing keeps its true chronological place rather than being pulled to an end.
        XCTAssertEqual(units[0].photos.map(\.id), [developedEarly.id, developingMiddle.id, developedLate.id])
        XCTAssertEqual(units[0].developed.map(\.id), [developedEarly.id, developedLate.id])
        XCTAssertEqual(units[0].developing.map(\.id), [developingMiddle.id])
    }

    // MARK: - Title

    func testTitleTonightAndLastNight() {
        let now = date(21, 20)
        let tonight = DarkroomDayUnit(dayKey: FeedUnit.dayKey(for: now, calendar: calendar), photos: [photo(takenAt: now)])
        let lastNight = DarkroomDayUnit(
            dayKey: calendar.date(byAdding: .day, value: -1, to: FeedUnit.dayKey(for: now, calendar: calendar))!,
            photos: [photo(takenAt: date(20, 20))])

        XCTAssertEqual(tonight.title(shortForm: true, calendar: calendar, now: now), "Tonight")
        XCTAssertEqual(lastNight.title(shortForm: true, calendar: calendar, now: now), "Last night")
    }

    func testTitleShortAndFullForm() {
        // Aug 15, 2026 is a Saturday.
        let unit = DarkroomDayUnit(dayKey: FeedUnit.dayKey(for: date(15, 20), calendar: calendar),
                                    photos: [photo(takenAt: date(15, 20))])
        let now = date(25, 12)   // far enough from the 15th that neither Tonight/Last night applies
        XCTAssertEqual(unit.title(shortForm: true, calendar: calendar, now: now), "Sat 15")
        XCTAssertEqual(unit.title(shortForm: false, calendar: calendar, now: now), "Sat 15 Aug")
    }

    // MARK: - Meta line

    func testMetaLineOmitsSharedAtZero() {
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [photo(takenAt: date(21, 9))])
        let line = unit.metaLine(sharedIds: [], calendar: calendar)
        XCTAssertFalse(line.contains("shared"))
    }

    func testMetaLineCountsShared() {
        let a = photo(takenAt: date(21, 9))
        let b = photo(takenAt: date(21, 20))
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [a, b])
        let line = unit.metaLine(sharedIds: [a.id], calendar: calendar)
        XCTAssertTrue(line.contains("1 shared"))
    }

    func testMetaLineSoloShotIsOneTime() {
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [photo(takenAt: date(21, 9, 15))])
        let line = unit.metaLine(sharedIds: [], calendar: calendar)
        XCTAssertFalse(line.contains(" to "))
    }

    // MARK: - Developing pill

    func testDevelopingPillNilWhenNothingDeveloping() {
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [photo(takenAt: date(21, 9), ready: true)])
        XCTAssertNil(unit.developingPillText(calendar: calendar))
    }

    func testDevelopingPillUsesSharedTime() {
        // A real future instant, not a fixture date: `isReady` compares against the actual
        // wall clock regardless of which calendar built the fixture.
        let devAt = Date.now.addingTimeInterval(600)
        let one = photo(takenAt: date(21, 9), developsAt: devAt, ready: false)
        let two = photo(takenAt: date(21, 10), developsAt: devAt, ready: false)
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [one, two])
        let text = unit.developingPillText(calendar: calendar)
        XCTAssertEqual(text?.hasPrefix("2 developing · "), true)
    }

    // MARK: - Develop arc (DarkroomDayUnitView.rack's shared per-night fraction)

    /// `developingProgress` only looks at photos `unit.developing` (`!isReady`) already filtered
    /// to, and `Photo.isReady` compares `developsAt` against the REAL wall clock, not any test
    /// fixture calendar — so every fixture below anchors `developsAt` off the real `Date.now`
    /// (same pattern `testDevelopingPillUsesSharedTime` above already uses), never off the fixed
    /// August 2026 calendar the rest of this file uses. The `now:` handed to `developingProgress`
    /// itself is a separate, fully synthetic instant used only for the elapsed/total math.
    private func developingPhoto(takenAt: Date, developsAt: Date) -> Photo {
        photo(takenAt: takenAt, developsAt: developsAt, ready: false)
    }

    func testDevelopingProgressNilWhenNothingDeveloping() {
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [photo(takenAt: date(21, 9), ready: true)])
        XCTAssertNil(unit.developingProgress(now: date(21, 12)))
    }

    func testDevelopingProgressMidWindow() throws {
        // A night that started an hour ago, develops 3 hours from now (a 4-hour window):
        // checking in 1 hour after it started should read a quarter of the way through.
        let start = Date.now.addingTimeInterval(-3600)
        let developsAt = Date.now.addingTimeInterval(3 * 3600)
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [developingPhoto(takenAt: start, developsAt: developsAt)])
        let fraction = try XCTUnwrap(unit.developingProgress(now: start.addingTimeInterval(3600)))
        XCTAssertEqual(fraction, 0.25, accuracy: 0.0001)
    }

    /// Clamped at both ends: a `now` before the night even started (a stale/misordered read)
    /// never goes negative, and a `now` past the develop instant never exceeds 1.
    func testDevelopingProgressClampsBelowZeroAndAboveOne() throws {
        let start = Date.now.addingTimeInterval(-3600)
        let developsAt = Date.now.addingTimeInterval(3 * 3600)
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [developingPhoto(takenAt: start, developsAt: developsAt)])

        let before = try XCTUnwrap(unit.developingProgress(now: start.addingTimeInterval(-600)))
        XCTAssertEqual(before, 0)

        let after = try XCTUnwrap(unit.developingProgress(now: developsAt.addingTimeInterval(3600)))
        XCTAssertEqual(after, 1)
    }

    /// A capture and its develops-at landing on the exact same instant (a zero-length window)
    /// must not divide by zero; it reads as fully progressed rather than crashing or NaN-ing.
    func testDevelopingProgressGuardsAgainstAZeroLengthWindow() throws {
        let instant = Date.now.addingTimeInterval(3600)   // still in the future, so still "developing"
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [developingPhoto(takenAt: instant, developsAt: instant)])
        let fraction = try XCTUnwrap(unit.developingProgress(now: instant))
        XCTAssertEqual(fraction, 1)
        XCTAssertFalse(fraction.isNaN)
    }

    /// Several developing shots with different `developsAt` times: the window runs through to
    /// the LATEST of them (the moment the whole night finishes), same convention as
    /// `developingPillText`.
    func testDevelopingProgressUsesLatestDevelopsAtWhenTheyDiffer() throws {
        let start = Date.now.addingTimeInterval(-3600)
        let earlier = developingPhoto(takenAt: start, developsAt: Date.now.addingTimeInterval(3600))
        let later = developingPhoto(takenAt: Date.now.addingTimeInterval(-1800), developsAt: Date.now.addingTimeInterval(3 * 3600))
        let unit = DarkroomDayUnit(dayKey: date(21, 0), photos: [earlier, later])
        // Total window: start (1hr ago) through the LATEST develops-at (3hr from now) is 4 hours;
        // checking in 2 hours after start is halfway.
        let fraction = try XCTUnwrap(unit.developingProgress(now: start.addingTimeInterval(2 * 3600)))
        XCTAssertEqual(fraction, 0.5, accuracy: 0.0001)
    }

    // MARK: - Sort-row preview

    func testPickPreviewPrefersDistinctNights() {
        let dayOne = [photo(takenAt: date(1, 9)), photo(takenAt: date(1, 10))]
        let dayTwo = [photo(takenAt: date(2, 9))]
        let dayThree = [photo(takenAt: date(3, 9))]
        let unsorted = dayOne + dayTwo + dayThree
        let preview = DarkroomDayUnit.pickPreview(from: unsorted, count: 3, calendar: calendar)
        let days = Set(preview.map { FeedUnit.dayKey(for: $0.takenAt, calendar: calendar) })
        XCTAssertEqual(preview.count, 3)
        XCTAssertEqual(days.count, 3, "prefers one photo per distinct night")
    }

    func testPickPreviewFallsBackWhenTooFewDistinctNights() {
        let unsorted = (0..<5).map { photo(takenAt: date(1, 9).addingTimeInterval(Double($0) * 60)) }
        let preview = DarkroomDayUnit.pickPreview(from: unsorted, count: 3, calendar: calendar)
        XCTAssertEqual(preview.count, 3)
    }

    // MARK: - Distinct night count (sort banner's second line)

    func testDistinctNightCountCollapsesSameNightMultipleShots() {
        let sameNight = [photo(takenAt: date(1, 9)), photo(takenAt: date(1, 10)), photo(takenAt: date(1, 23, 40))]
        XCTAssertEqual(DarkroomDayUnit.distinctNightCount(in: sameNight, calendar: calendar), 1)
    }

    func testDistinctNightCountCountsEachDistinctNightOnce() {
        let unsorted = [photo(takenAt: date(1, 9)), photo(takenAt: date(2, 9)), photo(takenAt: date(3, 20))]
        XCTAssertEqual(DarkroomDayUnit.distinctNightCount(in: unsorted, calendar: calendar), 3)
    }

    func testDistinctNightCountRespectsFourAMBoundary() {
        // A midnight-straddling pair is one night; a shot after 4am starts a new one.
        let unsorted = [photo(takenAt: date(1, 23, 40)), photo(takenAt: date(2, 2, 15)), photo(takenAt: date(2, 4, 30))]
        XCTAssertEqual(DarkroomDayUnit.distinctNightCount(in: unsorted, calendar: calendar), 2)
    }

    func testDistinctNightCountEmpty() {
        XCTAssertEqual(DarkroomDayUnit.distinctNightCount(in: [], calendar: calendar), 0)
    }
}

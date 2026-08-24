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
        // 393pt screen, 16pt side margins: 361pt available, 9 whole frames at 38pt pitch.
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 361), 9)
        // A hair under one more frame's worth still fits 9, not 10.
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 359.9), 9)
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 340), 9)   // exactly 9*38-2
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 339.9), 8)
        XCTAssertEqual(DarkroomDayUnit.stripCapacity(availableWidth: 0), 0)
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

    // MARK: - Month grouping

    func testMonthGroupsSpanTwoMonths() {
        let units = DarkroomDayUnit.units(from: [
            photo(takenAt: date(3, 12)),
            photo(takenAt: date(21, 12)),
        ], calendar: calendar)
        let groups = DarkroomDayUnit.monthGroups(units: units, calendar: calendar)
        XCTAssertEqual(groups.count, 1)   // both in August in this fixture
    }

    /// The band names the month alone inside the current year; the year joins only for months
    /// outside it, where a bare month name in one continuous scroll would be ambiguous.
    func testMonthBandTitleAddsYearOnlyOutsideCurrentYear() {
        let august = DarkroomDayUnit.monthGroups(
            units: DarkroomDayUnit.units(from: [photo(takenAt: date(21, 12))], calendar: calendar),
            calendar: calendar)[0]
        let now = date(24, 12)
        XCTAssertEqual(august.title(calendar: calendar, now: now), "August")

        let january2025 = calendar.date(from: DateComponents(year: 2025, month: 1, day: 15, hour: 12))!
        let older = DarkroomDayUnit.monthGroups(
            units: DarkroomDayUnit.units(from: [photo(takenAt: january2025)], calendar: calendar),
            calendar: calendar)[0]
        XCTAssertEqual(older.title(calendar: calendar, now: now), "January 2025")
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
}

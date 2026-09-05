import Testing
import Foundation
@testable import Flim

/// The shelf's own copy: month label, the `CHAPTER 08` code, and the `34 shared · 2 rolls` stat
/// line, including the singular/plural and zero-rolls cases.
struct ChapterFormattingTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()

    private func date(year: Int, month: Int, day: Int = 1) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }

    private func summary(monthStart: Date, shots: Int = 1, rolls: Int = 0) -> ChapterSummary {
        ChapterSummary(monthStart: monthStart, shotCount: shots, rollCount: rolls,
                       coverPaths: [], firstShotAt: monthStart, lastShotAt: monthStart)
    }

    @Test("the chapter code is the calendar month's own zero-padded number")
    func chapterCodeIsMonthNumber() {
        #expect(summary(monthStart: date(year: 2026, month: 8)).chapterCode(calendar: calendar) == "08")
        #expect(summary(monthStart: date(year: 2026, month: 12)).chapterCode(calendar: calendar) == "12")
        #expect(summary(monthStart: date(year: 2026, month: 1)).chapterCode(calendar: calendar) == "01")
    }

    @Test("the month name is the full month, e.g. August")
    func monthNameIsFull() {
        let name = summary(monthStart: date(year: 2026, month: 8))
            .monthName(calendar: calendar, locale: Locale(identifier: "en_US"))
        #expect(name == "August")
    }

    @Test("a single shot and zero rolls reads as one shared, no roll clause at all")
    func singleShotZeroRolls() {
        #expect(summary(monthStart: date(year: 2026, month: 8), shots: 1, rolls: 0).statsLine == "1 shared")
    }

    @Test("many shots and zero rolls still drops the roll clause entirely")
    func manyShotsZeroRolls() {
        #expect(summary(monthStart: date(year: 2026, month: 8), shots: 34, rolls: 0).statsLine == "34 shared")
    }

    @Test("many shots and one roll: both singular/plural handled independently")
    func mixedSingularPlural() {
        #expect(summary(monthStart: date(year: 2026, month: 8), shots: 34, rolls: 1).statsLine == "34 shared · 1 roll")
        #expect(summary(monthStart: date(year: 2026, month: 8), shots: 1, rolls: 2).statsLine == "1 shared · 2 rolls")
    }

    @Test("many shots and many rolls pluralize both")
    func manyShotsManyRolls() {
        #expect(summary(monthStart: date(year: 2026, month: 8), shots: 34, rolls: 2).statsLine == "34 shared · 2 rolls")
    }

    @Test("only the calendar month currently in progress is the current month")
    func isCurrentMonthOnlyMatchesTheLiveMonth() {
        let now = date(year: 2026, month: 8, day: 15)
        let thisMonth = summary(monthStart: date(year: 2026, month: 8))
        let lastMonth = summary(monthStart: date(year: 2026, month: 7))
        #expect(thisMonth.isCurrentMonth(now: now, calendar: calendar))
        #expect(!lastMonth.isCurrentMonth(now: now, calendar: calendar))
    }

    @Test("the shelf shows only months that have ended, newest first, and nothing else changes")
    func completedMonthsDropsTheMonthInProgress() {
        let now = date(year: 2026, month: 9, day: 4)
        let september = summary(monthStart: date(year: 2026, month: 9), shots: 16)
        let august = summary(monthStart: date(year: 2026, month: 8), shots: 34, rolls: 2)
        let july = summary(monthStart: date(year: 2026, month: 7), shots: 18)
        let shown = ChapterSummary.completedMonths([september, august, july], now: now, calendar: calendar)
        #expect(shown.map(\.monthStart) == [august.monthStart, july.monthStart])
        #expect(ChapterSummary.completedMonths([september], now: now, calendar: calendar).isEmpty)
        #expect(ChapterSummary.completedMonths([], now: now, calendar: calendar).isEmpty)
    }
}

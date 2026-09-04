import Testing
import Foundation
@testable import Flim

/// The closing card's pure half: which of the six candidate lines show, in what order, and every
/// line's exact copy, including the singular/plural and threshold rules. No SwiftUI, no network.
struct ChapterStatsFormattingTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
    private let locale = Locale(identifier: "en_US")

    private func row(_ key: String, valueInt: Int? = nil, valueText: String? = nil,
                      photoId: UUID? = nil, photoThumbPath: String? = nil) -> ChapterStatRow {
        ChapterStatRow(statKey: key, valueInt: valueInt, valueText: valueText,
                       photoId: photoId, photoThumbPath: photoThumbPath)
    }

    // MARK: - Priority and the five-line cap

    @Test("a month with every key present shows exactly five lines, dropping rolls (lowest priority)")
    func capsAtFiveDroppingLowestPriority() {
        let stats: ChapterStats = [
            .mostReacted: row("most_reacted", valueInt: 1, photoId: UUID(), photoThumbPath: "a.jpg"),
            .mostCommented: row("most_commented", valueInt: 1, photoId: UUID(), photoThumbPath: "b.jpg"),
            .busiestDay: row("busiest_day", valueInt: 1, valueText: "2026-08-12"),
            .nightShots: row("night_shots", valueInt: 3),
            .streakDays: row("streak_days", valueInt: 3),
            .rollsCount: row("rolls_count", valueInt: 1),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.count == 5)
        #expect(!lines.contains { $0.kind == .rolls })
    }

    @Test("lines appear in the specified priority order, not dictionary order")
    func linesAreInPriorityOrder() {
        let stats: ChapterStats = [
            .rollsCount: row("rolls_count", valueInt: 1),
            .streakDays: row("streak_days", valueInt: 3),
            .mostReacted: row("most_reacted", valueInt: 1, photoId: UUID(), photoThumbPath: "a.jpg"),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.map(\.kind) == [.mostReacted, .streak, .rolls])
    }

    @Test("an absent key is dropped entirely, never shown as a zero or placeholder line")
    func absentKeyIsDropped() {
        let stats: ChapterStats = [.mostReacted: row("most_reacted", valueInt: 4, photoId: UUID(), photoThumbPath: "a.jpg")]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.count == 1)
        #expect(lines.first?.kind == .mostReacted)
    }

    @Test("no stats at all produces no lines")
    func noStatsProducesNoLines() {
        #expect(ChapterStatsFormatting.lines(from: [:], calendar: calendar, locale: locale).isEmpty)
    }

    // MARK: - Thresholds

    @Test("night_shots below 3 is dropped; at or above 3 it shows")
    func nightShotsThreshold() {
        let below: ChapterStats = [.nightShots: row("night_shots", valueInt: 2)]
        #expect(ChapterStatsFormatting.lines(from: below).isEmpty)

        let at: ChapterStats = [.nightShots: row("night_shots", valueInt: 3)]
        #expect(ChapterStatsFormatting.lines(from: at).map(\.kind) == [.nightOwl])
    }

    @Test("streak_days below 3 is dropped; at or above 3 it shows")
    func streakThreshold() {
        let below: ChapterStats = [.streakDays: row("streak_days", valueInt: 2)]
        #expect(ChapterStatsFormatting.lines(from: below).isEmpty)

        let at: ChapterStats = [.streakDays: row("streak_days", valueInt: 3)]
        #expect(ChapterStatsFormatting.lines(from: at).map(\.kind) == [.streak])
    }

    @Test("rolls_count of 0 is dropped; 1 or more shows")
    func rollsThreshold() {
        let zero: ChapterStats = [.rollsCount: row("rolls_count", valueInt: 0)]
        #expect(ChapterStatsFormatting.lines(from: zero).isEmpty)

        let one: ChapterStats = [.rollsCount: row("rolls_count", valueInt: 1)]
        #expect(ChapterStatsFormatting.lines(from: one).map(\.kind) == [.rolls])
    }

    // MARK: - Copy: most reacted / most commented

    @Test("most reacted uses the top_reaction emoji when present")
    func mostReactedWithEmoji() {
        let stats: ChapterStats = [
            .mostReacted: row("most_reacted", valueInt: 12, photoId: UUID(), photoThumbPath: "a.jpg"),
            .topReaction: row("top_reaction", valueInt: 12, valueText: "❤️"),
        ]
        let line = ChapterStatsFormatting.lines(from: stats).first
        #expect(line?.value == "12 ❤️")
        #expect(line?.label == "Most reacted")
        #expect(line?.opensPhoto == true)
    }

    @Test("most reacted falls back to a plain count without top_reaction, pluralized correctly")
    func mostReactedWithoutEmoji() {
        let many: ChapterStats = [.mostReacted: row("most_reacted", valueInt: 12, photoId: UUID(), photoThumbPath: "a.jpg")]
        #expect(ChapterStatsFormatting.lines(from: many).first?.value == "12 reactions")

        let one: ChapterStats = [.mostReacted: row("most_reacted", valueInt: 1, photoId: UUID(), photoThumbPath: "a.jpg")]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "1 reaction")
    }

    @Test("most commented pluralizes independently of most reacted")
    func mostCommentedPluralization() {
        let many: ChapterStats = [.mostCommented: row("most_commented", valueInt: 5, photoId: UUID(), photoThumbPath: "b.jpg")]
        #expect(ChapterStatsFormatting.lines(from: many).first?.value == "5 comments")

        let one: ChapterStats = [.mostCommented: row("most_commented", valueInt: 1, photoId: UUID(), photoThumbPath: "b.jpg")]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "1 comment")
    }

    // MARK: - Copy: busiest day

    @Test("busiest day formats as weekday, ordinal day, and shot count, locale-pinned")
    func busiestDayFormatting() {
        // 2026-09-12 is a Saturday.
        let stats: ChapterStats = [.busiestDay: row("busiest_day", valueInt: 9, valueText: "2026-09-12")]
        let line = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).first
        #expect(line?.value == "Saturday the 12th · 9 shots")
        #expect(line?.label == "Busiest day")
    }

    @Test("busiest day singularizes a one-shot day")
    func busiestDaySingular() {
        // 2026-09-13 is a Sunday.
        let stats: ChapterStats = [.busiestDay: row("busiest_day", valueInt: 1, valueText: "2026-09-13")]
        let line = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).first
        #expect(line?.value == "Sunday the 13th · 1 shot")
    }

    @Test("ordinal day suffixes: 1st, 2nd, 3rd, 4th, 11th-13th, 21st, 22nd, 23rd")
    func ordinalDaySuffixes() {
        let expectations: [(Int, String)] = [
            (1, "1st"), (2, "2nd"), (3, "3rd"), (4, "4th"),
            (11, "11th"), (12, "12th"), (13, "13th"),
            (21, "21st"), (22, "22nd"), (23, "23rd"), (30, "30th"),
        ]
        for (day, expected) in expectations {
            #expect(ChapterStatsFormatting.ordinalDay(day) == expected)
        }
    }

    @Test("a malformed busiest_day date drops the line entirely rather than crashing or showing garbage")
    func malformedBusiestDayDropsLine() {
        let stats: ChapterStats = [.busiestDay: row("busiest_day", valueInt: 9, valueText: "not-a-date")]
        #expect(ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).isEmpty)
    }

    // MARK: - Copy: after dark, streak, rolls

    @Test("after dark pluralizes the shot count")
    func afterDarkCopy() {
        let stats: ChapterStats = [.nightShots: row("night_shots", valueInt: 7)]
        #expect(ChapterStatsFormatting.lines(from: stats).first?.value == "7 shots between 10pm and 4am")
    }

    @Test("streak copy")
    func streakCopy() {
        let stats: ChapterStats = [.streakDays: row("streak_days", valueInt: 6)]
        #expect(ChapterStatsFormatting.lines(from: stats).first?.value == "6 days running")
    }

    @Test("rolls with people shot with: singular/plural on both clauses")
    func rollsWithPeople() {
        let threeRolls: ChapterStats = [
            .rollsCount: row("rolls_count", valueInt: 3),
            .peopleShotWith: row("people_shot_with", valueInt: 7),
        ]
        #expect(ChapterStatsFormatting.lines(from: threeRolls).first?.value == "3 rolls · 7 people")

        let oneEach: ChapterStats = [
            .rollsCount: row("rolls_count", valueInt: 1),
            .peopleShotWith: row("people_shot_with", valueInt: 1),
        ]
        #expect(ChapterStatsFormatting.lines(from: oneEach).first?.value == "1 roll · 1 person")
    }

    @Test("rolls with zero people omits the people clause entirely")
    func rollsWithZeroPeople() {
        let stats: ChapterStats = [
            .rollsCount: row("rolls_count", valueInt: 2),
            .peopleShotWith: row("people_shot_with", valueInt: 0),
        ]
        #expect(ChapterStatsFormatting.lines(from: stats).first?.value == "2 rolls")
    }

    @Test("rolls with no people_shot_with row at all also omits the clause")
    func rollsWithoutPeopleRow() {
        let stats: ChapterStats = [.rollsCount: row("rolls_count", valueInt: 4)]
        #expect(ChapterStatsFormatting.lines(from: stats).first?.value == "4 rolls")
    }
}

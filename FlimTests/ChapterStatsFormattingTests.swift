import Testing
import Foundation
@testable import Flim

/// The closing card's pure half: which of the eleven candidate lines show, in what order (by
/// score, highest first), and every line's exact copy, including the singular/plural and
/// threshold rules. No SwiftUI, no network.
struct ChapterStatsFormattingTests {
    private let calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal
    }()
    private let locale = Locale(identifier: "en_US")

    private func row(_ key: String, valueInt: Int? = nil, valueText: String? = nil,
                      photoId: UUID? = nil, photoThumbPath: String? = nil,
                      postId: UUID? = nil, userId: UUID? = nil) -> ChapterStatRow {
        ChapterStatRow(statKey: key, valueInt: valueInt, valueText: valueText,
                       photoId: photoId, photoThumbPath: photoThumbPath, postId: postId, userId: userId)
    }

    // MARK: - Scoring: the card picks the five most interesting

    @Test("a big fan outranks a weak busiest day: the fan's count is remarkable against the month's shots, the day barely is")
    func bigFanOutranksWeakBusiestDay() {
        let stats: ChapterStats = [
            .shots: row("shots", valueInt: 10),
            .biggestFan: row("biggest_fan", valueInt: 8, valueText: "sabs", userId: UUID()),
            // 3 of 10 shots on the busiest day: a 0.3 concentration, not strictly above the
            // 0.3 "remarkable" threshold, so this stays a weak line.
            .busiestDay: row("busiest_day", valueInt: 3, valueText: "2026-09-12"),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.first?.kind == .biggestFan)
        #expect(lines.map(\.kind) == [.biggestFan, .busiestDay])
    }

    @Test("a month with nothing but shots and a golden hour still shows something")
    func nothingButGoldenHourStillShowsSomething() {
        let stats: ChapterStats = [
            .shots: row("shots", valueInt: 5),
            .goldenHour: row("golden_hour", valueInt: 20, valueText: "1"),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.count == 1)
        #expect(lines.first?.kind == .goldenHour)
    }

    @Test("the card always keeps a photo-bearing line if any exists, even when it scores lowest")
    func photoLineGuarantee() {
        let stats: ChapterStats = [
            .shots: row("shots", valueInt: 100),
            // The only photo-bearing candidate, deliberately the weakest of the seven.
            .mostReacted: row("most_reacted", valueInt: 1, photoId: UUID(), photoThumbPath: "a.jpg"),
            .topGivenReaction: row("top_given_reaction", valueInt: 60, valueText: "❤️"),
            .nightShots: row("night_shots", valueInt: 30),
            .rollMVP: row("roll_mvp", valueInt: 20, valueText: "tristan", userId: UUID()),
            .streakDays: row("streak_days", valueInt: 10),
            // 40 of 100 shots: above the 0.3 threshold, but still weaker than the four above.
            .goldenHour: row("golden_hour", valueInt: 20, valueText: "40"),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.count == 5)
        #expect(lines.contains { $0.kind == .mostReacted })
        #expect(!lines.contains { $0.kind == .goldenHour })
    }

    @Test("the most reacted shot always shows, first, whatever its score")
    func mostReactedIsAlwaysFirst() {
        let stats: ChapterStats = [
            .shots: row("shots", valueInt: 100),
            // One reaction against a hundred shots: the weakest possible score.
            .mostReacted: row("most_reacted", valueInt: 1, photoId: UUID(), photoThumbPath: "a.jpg"),
            .biggestFan: row("biggest_fan", valueInt: 90, valueText: "sabs", userId: UUID()),
            .topGivenReaction: row("top_given_reaction", valueInt: 60, valueText: "❤️"),
            .nightShots: row("night_shots", valueInt: 30),
            .rollMVP: row("roll_mvp", valueInt: 20, valueText: "tristan", userId: UUID()),
            .streakDays: row("streak_days", valueInt: 10),
            .longestGap: row("longest_gap", valueInt: 9, photoId: UUID(), photoThumbPath: "b.jpg"),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.count == 5)
        #expect(lines.first?.kind == .mostReacted)
        // The other four are the strongest of the rest by score: the given reaction (60) and
        // night shots (30) lead, and the weakest candidates (fan 0.9, longest gap 6) are the ones
        // the anchor displaced. The anchor itself never competes.
        #expect(lines.dropFirst().first?.kind == .yourReaction)
        #expect(!lines.contains { $0.kind == .biggestFan })
    }

    @Test("without a most reacted shot the card falls back to the scored five")
    func noMostReactedMeansPlainScoring() {
        let stats: ChapterStats = [
            .shots: row("shots", valueInt: 10),
            // Fan scores 0.8 (8 of 10 shots); a 4-day streak scores 1 past its 3-day floor.
            .biggestFan: row("biggest_fan", valueInt: 8, valueText: "sabs", userId: UUID()),
            .streakDays: row("streak_days", valueInt: 4),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.map(\.kind) == [.streak, .biggestFan])
    }

    @Test("an exact score tie breaks by the old fixed order, so results are stable")
    func tiesBreakByOldOrder() {
        let stats: ChapterStats = [
            // Both land on a score of 5.0: night_shots scores by raw count, streak by days
            // past its own 3-day floor (8 - 3).
            .nightShots: row("night_shots", valueInt: 5),
            .streakDays: row("streak_days", valueInt: 8),
        ]
        let lines = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale)
        #expect(lines.map(\.kind) == [.nightOwl, .streak])
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
        let stats: ChapterStats = [
            .busiestDay: row("busiest_day", valueInt: 9, valueText: "2026-09-12"),
            .shots: row("shots", valueInt: 12),
        ]
        let line = ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).first
        #expect(line?.value == "Saturday the 12th · 9 shots")
        #expect(line?.label == "Busiest day")
    }

    @Test("busiest day singularizes a one-shot day")
    func busiestDaySingular() {
        // 2026-09-13 is a Sunday.
        let stats: ChapterStats = [
            .busiestDay: row("busiest_day", valueInt: 1, valueText: "2026-09-13"),
            .shots: row("shots", valueInt: 4),
        ]
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
        let stats: ChapterStats = [
            .busiestDay: row("busiest_day", valueInt: 9, valueText: "not-a-date"),
            .shots: row("shots", valueInt: 12),
        ]
        #expect(ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).isEmpty)
    }

    // MARK: - Busiest day: the one-photo-month threshold

    @Test("a one-photo month drops the busiest day line: the day IS the month")
    func onePhotoMonthDropsBusiestDay() {
        let stats: ChapterStats = [
            .busiestDay: row("busiest_day", valueInt: 1, valueText: "2026-09-12"),
            .shots: row("shots", valueInt: 1),
        ]
        #expect(ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).isEmpty)
    }

    @Test("a busiest day that accounts for every shot in the month is dropped even with more than one shot")
    func busiestDayEqualToTotalIsDropped() {
        // Two shots, both taken on the same day: the busiest day and the month are the same thing.
        let stats: ChapterStats = [
            .busiestDay: row("busiest_day", valueInt: 2, valueText: "2026-09-12"),
            .shots: row("shots", valueInt: 2),
        ]
        #expect(ChapterStatsFormatting.lines(from: stats, calendar: calendar, locale: locale).isEmpty)
    }

    @Test("busiest day is dropped when the month's shots total is missing entirely")
    func busiestDayDroppedWithoutShotsTotal() {
        let stats: ChapterStats = [.busiestDay: row("busiest_day", valueInt: 3, valueText: "2026-09-12")]
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

    // MARK: - Copy: biggest fan / your reaction / golden hour / roll MVP / longest gap

    @Test("biggest fan pluralizes, and opens that person's profile, not a photo")
    func biggestFanCopy() {
        let userId = UUID()
        let many: ChapterStats = [.biggestFan: row("biggest_fan", valueInt: 34, valueText: "sabs", userId: userId)]
        let line = ChapterStatsFormatting.lines(from: many).first
        #expect(line?.value == "@sabs · 34 reactions")
        #expect(line?.label == "Biggest fan")
        #expect(line?.opensProfile == true)
        #expect(line?.opensPhoto == false)

        let one: ChapterStats = [.biggestFan: row("biggest_fan", valueInt: 1, valueText: "sabs", userId: userId)]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "@sabs · 1 reaction")
    }

    @Test("your reaction pluralizes, and is not tappable")
    func yourReactionCopy() {
        let many: ChapterStats = [.topGivenReaction: row("top_given_reaction", valueInt: 219, valueText: "❤️")]
        let line = ChapterStatsFormatting.lines(from: many).first
        #expect(line?.value == "❤️ · 219 times")
        #expect(line?.label == "Your reaction")
        #expect(line?.opensPhoto == false)
        #expect(line?.opensProfile == false)

        let one: ChapterStats = [.topGivenReaction: row("top_given_reaction", valueInt: 1, valueText: "❤️")]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "❤️ · 1 time")
    }

    @Test("golden hour formats to the device's 12-hour preference, and is not tappable")
    func goldenHourCopyTwelveHour() {
        let stats: ChapterStats = [.goldenHour: row("golden_hour", valueInt: 20, valueText: "9")]
        // en_US: a 12-hour region.
        let line = ChapterStatsFormatting.lines(
            from: stats, calendar: calendar, locale: Locale(identifier: "en_US")
        ).first
        #expect(line?.value == "Most of your shots were around 8pm")
        #expect(line?.label == "Golden hour")
        #expect(line?.opensPhoto == false)
        #expect(line?.opensProfile == false)
    }

    @Test("golden hour formats to the device's 24-hour preference")
    func goldenHourCopyTwentyFourHour() {
        let stats: ChapterStats = [.goldenHour: row("golden_hour", valueInt: 20, valueText: "9")]
        // en_GB: a 24-hour region.
        let line = ChapterStatsFormatting.lines(
            from: stats, calendar: calendar, locale: Locale(identifier: "en_GB")
        ).first
        #expect(line?.value == "Most of your shots were around 20:00")
    }

    @Test("roll MVP pluralizes, and opens that person's profile")
    func rollMVPCopy() {
        let userId = UUID()
        let many: ChapterStats = [.rollMVP: row("roll_mvp", valueInt: 10, valueText: "tristan", userId: userId)]
        let line = ChapterStatsFormatting.lines(from: many).first
        #expect(line?.value == "@tristan · 10 shots")
        #expect(line?.label == "Roll MVP")
        #expect(line?.opensProfile == true)
        #expect(line?.opensPhoto == false)

        let one: ChapterStats = [.rollMVP: row("roll_mvp", valueInt: 1, valueText: "tristan", userId: userId)]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "@tristan · 1 shot")
    }

    @Test("longest gap pluralizes, and opens the photo that ended it as a post")
    func longestGapCopy() {
        let photoId = UUID()
        let postId = UUID()
        let many: ChapterStats = [.longestGap: row("longest_gap", valueInt: 5, photoId: photoId,
                                                    photoThumbPath: "gap.jpg", postId: postId)]
        let line = ChapterStatsFormatting.lines(from: many).first
        #expect(line?.value == "5 days without a shot")
        #expect(line?.label == "Longest gap")
        #expect(line?.photoId == photoId)
        #expect(line?.photoThumbPath == "gap.jpg")
        #expect(line?.opensPhoto == true)
        #expect(line?.opensProfile == false)

        let one: ChapterStats = [.longestGap: row("longest_gap", valueInt: 1, photoId: photoId, photoThumbPath: "gap.jpg")]
        #expect(ChapterStatsFormatting.lines(from: one).first?.value == "1 day without a shot")
    }
}

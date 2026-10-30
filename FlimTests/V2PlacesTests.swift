import Testing
import Foundation
@testable import Flim

/// The rules v2's three places compute: Friends' groups (product rule 10), their time spans, the
/// camera's roll clock and caption, and the Darkroom's day words.
struct V2PlacesTests {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    /// 2026-10-27 (a Tuesday) at the given hour and minute, New York.
    private static func at(_ hour: Int, _ minute: Int = 0, day: Int = 27) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private static func author(_ name: String) -> UserProfile {
        UserProfile(id: UUID(), username: name, createdAt: .distantPast)
    }

    private static func item(_ author: UserProfile, _ takenAt: Date) -> FeedItem {
        let post = Post(id: UUID(), userId: author.id, photoId: UUID(), storagePath: "p.jpg",
                        takenAt: takenAt, createdAt: takenAt)
        return FeedItem(post: post, author: author)
    }

    @Test("a friend's prints stay one group until three hours pass between two of them")
    func threeHourGap() {
        let nadia = Self.author("nadia")
        let items = [Self.item(nadia, Self.at(18, 12)), Self.item(nadia, Self.at(18, 40)),
                     Self.item(nadia, Self.at(21, 40)),   // exactly 3h later: same group
                     Self.item(nadia, Self.at(23, 50))]   // 2h10m later: same group
        #expect(V2FeedGrouping.groups(items).map(\.items.count) == [4])

        let split = items + [Self.item(nadia, Self.at(3, 0, day: 28))]   // 3h10m after 23:50
        #expect(V2FeedGrouping.groups(split).map(\.items.count) == [1, 4])
    }

    @Test("midnight does not split a group: 11 PM to 2 AM stays one")
    func midnight() {
        let mira = Self.author("mira")
        let items = [Self.item(mira, Self.at(23, 0)), Self.item(mira, Self.at(0, 30, day: 28)),
                     Self.item(mira, Self.at(2, 0, day: 28))]
        #expect(V2FeedGrouping.groups(items).count == 1)
    }

    @Test("groups are one author each, newest last print first, prints oldest first")
    func ordering() {
        let nadia = Self.author("nadia"), dev = Self.author("dev.k")
        let items = [Self.item(dev, Self.at(19, 50)), Self.item(nadia, Self.at(18, 40)),
                     Self.item(dev, Self.at(19, 2)), Self.item(nadia, Self.at(18, 12))]
        let groups = V2FeedGrouping.groups(items)
        #expect(groups.map { $0.author.username } == ["dev.k", "nadia"])
        #expect(groups[0].first == Self.at(19, 2))
        #expect(groups[0].last == Self.at(19, 50))
    }

    @Test("today's span has no day; another day's leads with the weekday")
    func span() {
        let nadia = Self.author("nadia")
        let group = V2FeedGrouping.groups([Self.item(nadia, Self.at(18, 12)), Self.item(nadia, Self.at(18, 40))])[0]
        let today = V2FeedGrouping.span(group, now: Self.at(22), calendar: Self.calendar)
        #expect(today.contains(" to "))
        #expect(!today.contains("Tuesday"))
        let later = V2FeedGrouping.span(group, now: Self.at(10, day: 29), calendar: Self.calendar)
        #expect(later.hasPrefix("Tuesday, "))
    }

    @Test("the roll clock counts down to the second, then in days, then reads OPEN")
    func rollClock() {
        let now = Self.at(12)
        #expect(V2Clock.until(now.addingTimeInterval(2 * 3_600 + 14 * 60 + 9), now: now) == "02:14:09")
        #expect(V2Clock.until(now.addingTimeInterval(86_400 + 4 * 3_600 + 10 * 60), now: now) == "1D 04:10")
        #expect(V2Clock.until(now.addingTimeInterval(-5), now: now) == "OPEN")
    }

    @Test("the camera's caption is the weekday and the part of the day")
    func dayPart() {
        #expect(V2Clock.dayPart(Self.at(9), calendar: Self.calendar).hasSuffix(" morning"))
        #expect(V2Clock.dayPart(Self.at(14), calendar: Self.calendar).hasSuffix(" afternoon"))
        #expect(V2Clock.dayPart(Self.at(19), calendar: Self.calendar).hasSuffix(" evening"))
        #expect(V2Clock.dayPart(Self.at(23), calendar: Self.calendar).hasSuffix(" night"))
    }

    @Test("the Darkroom's day words: tonight, today, yesterday, then the weekday")
    func relativeDay() {
        let now = Self.at(22)
        #expect(V2When.relativeDay(Self.at(19), now: now, calendar: Self.calendar) == "tonight")
        #expect(V2When.relativeDay(Self.at(9), now: now, calendar: Self.calendar) == "today")
        #expect(V2When.relativeDay(Self.at(9, day: 26), now: now, calendar: Self.calendar) == "yesterday")
        #expect(V2When.relativeDay(Self.at(9, day: 23), now: now, calendar: Self.calendar) != "yesterday")
    }

    @Test("a roll's time left reads in the largest whole unit")
    func timeLeft() {
        let now = Self.at(12)
        #expect(V2When.left(until: now.addingTimeInterval(2.5 * 3_600), now: now) == "2h left")
        #expect(V2When.left(until: now.addingTimeInterval(40 * 60), now: now) == "40m left")
        #expect(V2When.left(until: now.addingTimeInterval(3 * 86_400 + 60), now: now) == "3d left")
    }

    @Test("a new roll's opening choices stay inside the server's seven days, and tonight goes once the evening has")
    func rollOpening() {
        let afternoon = Self.at(15)
        #expect(V2RollTime.Choice.available(now: afternoon, calendar: Self.calendar) == [.tonight, .tomorrow, .week])
        #expect(V2RollTime.Choice.available(now: Self.at(21, 30), calendar: Self.calendar) == [.tomorrow, .week])
        for now in [afternoon, Self.at(19), Self.at(23, 50)] {
            let week = V2RollTime.Choice.week.date(now: now, calendar: Self.calendar)
            #expect(week > now)
            #expect(week.timeIntervalSince(now) < 7 * 86_400)
        }
        #expect(V2RollTime.Choice.tonight.date(now: afternoon, calendar: Self.calendar) == Self.at(22))
        #expect(V2RollTime.Choice.tomorrow.date(now: afternoon, calendar: Self.calendar) == Self.at(18, day: 28))
    }

    @Test("the lid's clock is 24-hour and names tonight and tomorrow")
    func lidClock() {
        let now = Self.at(15)
        #expect(V2RollTime.clock(Self.at(18, day: 28), now: now, calendar: Self.calendar).hasPrefix("TOMORROW "))
        #expect(V2RollTime.clock(Self.at(22), now: now, calendar: Self.calendar).hasPrefix("TONIGHT "))
    }

    @Test("every badge has a seal ring line, under twelve characters as the handoff asks")
    func sealRingLines() {
        for kind in ProfileBadgeKind.allCases {
            let line = V2Seal.ringLine(ProfileBadge(id: kind.rawValue, kind: kind, earnedAt: Self.at(12)))
            #expect(!line.isEmpty, "\(kind) has no ring line")
            #expect(line.count <= 12, "\(kind)'s ring line \(line) is too long")
        }
    }

    @Test("the screening spells small counts and keeps large ones as figures")
    func screeningNumbers() {
        #expect(V2ScreeningView.number(4) == "four")
        #expect(V2ScreeningView.number(12) == "twelve")
        #expect(V2ScreeningView.number(40) == "40")
    }

    @Test("a Spotlight week is stamped with its ISO week, and a bad key stamps nothing")
    func spotlightStamp() {
        #expect(V2SpotlightWeek.stamp("2026-09-21") == "WK 39")
        #expect(V2SpotlightWeek.stamp("2026-01-05") == "WK 2")
        #expect(V2SpotlightWeek.stamp("not-a-week") == "")
    }

    @Test("a friend's live line: when they last shot this week, else quiet")
    func friendsLiveLine() {
        let now = Self.at(22)
        #expect(V2FriendsList.liveLine(Self.at(19), now: now, calendar: Self.calendar) == "shot tonight")
        #expect(V2FriendsList.liveLine(Self.at(9, day: 26), now: now, calendar: Self.calendar) == "shot yesterday")
        #expect(V2FriendsList.liveLine(Self.at(9, day: 18), now: now, calendar: Self.calendar) == "quiet this week")
        #expect(V2FriendsList.liveLine(nil, now: now, calendar: Self.calendar) == "quiet this week")
    }
}

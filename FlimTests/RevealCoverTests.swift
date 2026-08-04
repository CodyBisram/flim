import Testing
import Foundation
@testable import Flim

/// The card that plays before the first frame of a reveal.
///
/// Its whole job is to say what you are about to see, so the failure mode is not a crash, it is a
/// sentence that is wrong or that reads like a file property. These pin the phrasing.
struct RevealCoverTests {

    private func photo(user: UUID = UUID(), takenAt: Date = .now) -> Photo {
        Photo(id: UUID(),
              userId: user,
              rollId: UUID(),
              storagePath: "p/\(UUID()).jpg",
              thumbPath: nil,
              feedPath: nil,
              takenAt: takenAt,
              developsAt: takenAt,
              isDeveloped: true,
              caption: nil,
              isSorted: true)
    }

    // MARK: - Counting

    @Test("a group roll names both the shots and the people")
    func groupRoll() {
        let a = UUID(), b = UUID(), c = UUID()
        let cover = RevealCover(photos: [photo(user: a), photo(user: a), photo(user: b), photo(user: c)])

        #expect(cover.shotCount == 4)
        #expect(cover.photographerCount == 3, "the same person shooting twice is still one person")
        #expect(cover.metaLine == "4 shots · 3 people")
    }

    @Test("a solo roll does not announce that one person was there")
    func soloRoll() {
        // "1 person" states the obvious back at someone, and makes a solo roll read as a group
        // roll nobody joined.
        let me = UUID()
        let cover = RevealCover(photos: [photo(user: me), photo(user: me)])
        #expect(cover.metaLine == "2 shots")
    }

    @Test("one shot is singular")
    func singleShot() {
        #expect(RevealCover(photos: [photo()]).metaLine == "1 shot")
    }

    @Test("an empty roll does not crash or claim a date")
    func emptyRoll() {
        let cover = RevealCover(photos: [])
        #expect(cover.shotCount == 0)
        #expect(cover.metaLine == "0 shots")
        #expect(cover.dateLine() == nil)
    }

    // MARK: - The date line

    @Test("the roll is dated from its FIRST shot, not its last")
    func datedFromTheStart() {
        // A roll shot across midnight belongs to the night it began, which is how the people in
        // it will refer to it.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let cover = RevealCover(photos: [photo(takenAt: start.addingTimeInterval(7200)),
                                         photo(takenAt: start)])
        #expect(cover.startedAt == start)
    }

    @Test("today and yesterday are named, not dated")
    func recentDays() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let today = RevealCover(photos: [photo(takenAt: now)])
        #expect(today.dateLine(now: now, calendar: calendar) == "Shot today")

        let yesterday = RevealCover(photos: [photo(takenAt: now.addingTimeInterval(-86_400))])
        #expect(yesterday.dateLine(now: now, calendar: calendar) == "Shot yesterday")
    }

    @Test("inside a week it reads as a weekday")
    func weekdayInsideAWeek() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let threeDaysAgo = RevealCover(photos: [photo(takenAt: now.addingTimeInterval(-3 * 86_400))])
        let line = threeDaysAgo.dateLine(now: now, calendar: calendar)

        #expect(line?.hasPrefix("Shot ") == true)
        #expect(line != "Shot today" && line != "Shot yesterday")
        // A weekday, not a numeric date: no digits in the phrase.
        #expect(line?.contains(where: \.isNumber) == false, "inside a week it should name the day: \(line ?? "nil")")
    }

    @Test("past a week the weekday stops being information and it becomes a date")
    func dateBeyondAWeek() {
        // "Tuesday" three weeks later could be any Tuesday, so it says nothing.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        let old = RevealCover(photos: [photo(takenAt: now.addingTimeInterval(-21 * 86_400))])
        let line = old.dateLine(now: now, calendar: calendar)

        #expect(line?.contains(where: \.isNumber) == true, "an old roll needs a real date: \(line ?? "nil")")
    }

    @Test("a roll from a previous year says which year")
    func oldRollCarriesTheYear() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let lastYear = now.addingTimeInterval(-400 * 86_400)

        let line = RevealCover(photos: [photo(takenAt: lastYear)]).dateLine(now: now, calendar: calendar)
        let year = calendar.component(.year, from: lastYear)
        #expect(line?.contains("\(year)") == true, "got: \(line ?? "nil")")
    }

    // MARK: - When the show may start

    @Test("the show waits for the deck no matter how eager the viewer is")
    func deckGatesEverything() {
        // The card is also the loading state. Starting on a tap before the deck exists is exactly
        // the spinner-with-extra-steps the card was written to remove.
        #expect(!RevealCover.canBegin(deckReady: false, beatElapsed: true, viewerTapped: true))
        #expect(!RevealCover.canBegin(deckReady: false, beatElapsed: false, viewerTapped: false))
    }

    @Test("a tap beats the beat, and the beat needs no tap")
    func eitherServesTheBeat() {
        #expect(RevealCover.canBegin(deckReady: true, beatElapsed: false, viewerTapped: true))
        #expect(RevealCover.canBegin(deckReady: true, beatElapsed: true, viewerTapped: false))
    }

    @Test("a ready deck alone is not enough to skip the moment")
    func aFastDeckStillGetsTheBeat() {
        // Otherwise a warm cache means the card flashes for one frame, which is worse than not
        // having it: it reads as a glitch.
        #expect(!RevealCover.canBegin(deckReady: true, beatElapsed: false, viewerTapped: false))
    }

    @Test("the beat is long enough to read and short enough to forgive")
    func holdDurationIsSane() {
        #expect(RevealCover.holdDuration >= 1.5)
        #expect(RevealCover.holdDuration <= 4)
    }
}

import Testing
import Foundation
@testable import Flim

/// The picker's toggle set <-> `chapter_public_stats` key list conversion, both directions,
/// including the "everything on" <-> `[]` round trip the server treats as its own default.
struct ChapterStatsVisibilityTests {
    @Test("an empty key list (the server's default) maps to every toggle enabled")
    func emptyKeysMeansEverythingOn() {
        let toggles = ChapterStatsVisibility.toggles(fromPublicKeys: [])
        #expect(toggles == Set(ChapterStatToggle.allCases))
    }

    @Test("every toggle enabled saves back to an empty key list, not a spelled-out list of every key")
    func everyToggleOnSavesEmpty() {
        let keys = ChapterStatsVisibility.publicKeys(fromEnabledToggles: Set(ChapterStatToggle.allCases))
        #expect(keys == [])
    }

    @Test("most reacted on sends its rider (top_reaction) alongside it")
    func mostReactedSendsItsRider() {
        let keys = Set(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.mostReacted]))
        #expect(keys == ["most_reacted", "top_reaction"])
    }

    @Test("rolls on sends its rider (people_shot_with) alongside it")
    func rollsSendsItsRider() {
        let keys = Set(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.rolls]))
        #expect(keys == ["rolls_count", "people_shot_with"])
    }

    @Test("a toggle with no rider sends only its own key")
    func toggleWithoutRiderSendsOnlyItsOwnKey() {
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.mostCommented]) == ["most_commented"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.busiestDay]) == ["busiest_day"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.nightShots]) == ["night_shots"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.streak]) == ["streak_days"])
    }

    @Test("a narrowed selection round-trips: keys in produce exactly those toggles, and back out the same keys")
    func narrowedSelectionRoundTrips() {
        let savedKeys = ["most_reacted", "top_reaction", "busiest_day"]
        let toggles = ChapterStatsVisibility.toggles(fromPublicKeys: savedKeys)
        #expect(toggles == [.mostReacted, .busiestDay])

        let backOut = Set(ChapterStatsVisibility.publicKeys(fromEnabledToggles: toggles))
        #expect(backOut == Set(savedKeys))
    }

    @Test("reading back a saved list is keyed off each toggle's primary key, tolerant of a missing rider")
    func toggleDetectionUsesPrimaryKeyOnly() {
        // `most_reacted` present without its own `top_reaction` rider (an inconsistent save from
        // elsewhere, or a future server change) still reads as the toggle being on.
        let toggles = ChapterStatsVisibility.toggles(fromPublicKeys: ["most_reacted"])
        #expect(toggles == [.mostReacted])
    }

    @Test("turning every toggle off saves a non-empty list containing none of the six primary keys")
    func allTogglesOffIsNotConfusedWithAllOn() {
        // An actually-empty array means "show everything" to the server, the exact opposite of
        // every switch being off, so this must never collapse to `[]` the way "all six on" does.
        let keys = ChapterStatsVisibility.publicKeys(fromEnabledToggles: [])
        #expect(!keys.isEmpty)
        let primaryKeys = Set(ChapterStatToggle.allCases.map(\.primaryKey.rawValue))
        #expect(Set(keys).isDisjoint(with: primaryKeys))
        // And it reads back as every toggle off, the true round trip that matters.
        #expect(ChapterStatsVisibility.toggles(fromPublicKeys: keys).isEmpty)
    }

    @Test("all eleven toggles cover the eleven primary keys the closing card's lines use, one each")
    func togglesCoverExactlyElevenPrimaryKeys() {
        let primaryKeys = Set(ChapterStatToggle.allCases.map(\.primaryKey))
        #expect(primaryKeys == [
            .mostReacted, .mostCommented, .busiestDay, .nightShots, .streakDays, .rollsCount,
            .biggestFan, .topGivenReaction, .goldenHour, .rollMVP, .longestGap,
        ])
    }

    // MARK: - The five newer toggles

    @Test("each of the five newer toggles has no rider, sending only its own key")
    func newerTogglesSendOnlyTheirOwnKey() {
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.biggestFan]) == ["biggest_fan"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.topGivenReaction]) == ["top_given_reaction"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.goldenHour]) == ["golden_hour"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.rollMVP]) == ["roll_mvp"])
        #expect(ChapterStatsVisibility.publicKeys(fromEnabledToggles: [.longestGap]) == ["longest_gap"])
    }

    @Test("a narrowed selection of newer toggles round-trips")
    func newerTogglesRoundTrip() {
        let savedKeys = ["biggest_fan", "roll_mvp"]
        let toggles = ChapterStatsVisibility.toggles(fromPublicKeys: savedKeys)
        #expect(toggles == [.biggestFan, .rollMVP])
        #expect(Set(ChapterStatsVisibility.publicKeys(fromEnabledToggles: toggles)) == Set(savedKeys))
    }
}

import Testing
import Foundation
@testable import Flim

/// Copy that states a number the code owns must ask the code for it.
///
/// Onboarding said "the 12-hour mark" as a literal. That was false in every DEBUG build, where
/// rolls develop in two minutes, and it would have gone stale the first time the delay changed.
struct DevelopDelayPhraseTests {

    @Test("hours read as hours")
    func hours() {
        #expect(Roll.developDelayPhrase(for: 12 * 3600) == "12 hours")
        #expect(Roll.developDelayPhrase(for: 3600) == "1 hour")
    }

    @Test("short delays read as minutes, not 0 hours")
    func minutes() {
        #expect(Roll.developDelayPhrase(for: 2 * 60) == "2 minutes")
        #expect(Roll.developDelayPhrase(for: 60) == "1 minute")
    }

    @Test("the phrase always matches the delay actually in force")
    func matchesTheBuild() {
        // The whole point: whichever build this runs in, the sentence is true.
        #expect(Roll.developDelayPhrase == Roll.developDelayPhrase(for: Roll.developDelay))
        #expect(!Roll.developDelayPhrase.isEmpty)
    }
}

import XCTest
@testable import Flim

/// @mention parsing: what counts as a mention, what the composer's autocomplete is currently
/// looking at, and how a suggestion gets inserted.
///
/// The rules here are duplicated in supabase/functions/send-social-push/index.ts (which decides
/// who gets notified). If one changes, both change, or people get highlighted without being
/// notified, or notified without being highlighted.
final class MentionsTests: XCTestCase {

    // MARK: - mentionRuns

    func testRunsRoundTripTheOriginalText() {
        // Nothing may be lost or added: joining the runs must reproduce the comment exactly, or
        // rendering would silently alter what someone wrote.
        for text in ["hi @ana how are you", "@ana", "no mentions here", "a@b.com", "@ana @ben!", ""] {
            XCTAssertEqual(mentionRuns(in: text).map(\.text).joined(), text, "round-trip failed for \(text)")
        }
    }

    func testPlainTextHasNoMentions() {
        XCTAssertEqual(mentionedUsernames(in: "nice shot, love it"), [])
    }

    func testMentionIsFoundAndLowercased() {
        XCTAssertEqual(mentionedUsernames(in: "great one @Ana"), ["ana"])
    }

    func testEmailDoesNotMentionItsDomain() {
        // The @ is mid-word, so it doesn't start a mention.
        XCTAssertEqual(mentionedUsernames(in: "mail me at cody@gmail.com"), [])
    }

    func testPunctuationEndsAMention() {
        let runs = mentionRuns(in: "look @ana!")
        XCTAssertEqual(runs.compactMap(\.username), ["ana"])
        XCTAssertEqual(runs.last?.text, "!")
    }

    func testBareAtIsNotAMention() {
        XCTAssertEqual(mentionedUsernames(in: "wait @ there"), [])
    }

    func testUnderscoresAndDigitsArePartOfTheUsername() {
        XCTAssertEqual(mentionedUsernames(in: "@ana_b12 hey"), ["ana_b12"])
    }

    func testRepeatedMentionIsReportedOnce() {
        // Notification dedup depends on this.
        XCTAssertEqual(mentionedUsernames(in: "@ana and @ana again"), ["ana"])
    }

    func testMultipleMentionsKeepTheirOrder() {
        XCTAssertEqual(mentionedUsernames(in: "@ben then @ana"), ["ben", "ana"])
    }

    func testMentionAtTheVeryStartCounts() {
        XCTAssertEqual(mentionedUsernames(in: "@ana look"), ["ana"])
    }

    func testNewlineIsAWordBoundary() {
        XCTAssertEqual(mentionedUsernames(in: "line one\n@ana"), ["ana"])
    }

    // MARK: - mentionQuery (drives the autocomplete)

    func testNoQueryInPlainText() {
        XCTAssertNil(mentionQuery(in: "nice shot"))
    }

    func testJustTypedAtOpensThePickerWithEverything() {
        XCTAssertEqual(mentionQuery(in: "hey @"), "")
    }

    func testPartialUsernameIsTheQuery() {
        XCTAssertEqual(mentionQuery(in: "hey @an"), "an")
    }

    func testQueryEndsOnceTheWordIsFinished() {
        // A trailing space means the mention is done, so the picker should close.
        XCTAssertNil(mentionQuery(in: "hey @ana "))
    }

    func testOnlyTheTrailingMentionCounts() {
        XCTAssertEqual(mentionQuery(in: "@ben hi @an"), "an")
        XCTAssertNil(mentionQuery(in: "@ben hi there"))
    }

    func testEmailDoesNotOpenThePicker() {
        XCTAssertNil(mentionQuery(in: "cody@gmail"))
    }

    // MARK: - completingMention

    func testCompletingReplacesThePartial() {
        XCTAssertEqual(completingMention(in: "hey @an", with: "ana"), "hey @ana ")
    }

    func testCompletingFromABareAt() {
        XCTAssertEqual(completingMention(in: "hey @", with: "ana"), "hey @ana ")
    }

    func testCompletingLeavesEarlierTextAlone() {
        XCTAssertEqual(completingMention(in: "@ben hi @an", with: "ana"), "@ben hi @ana ")
    }

    func testCompletingIsANoOpWithoutAMentionInProgress() {
        XCTAssertEqual(completingMention(in: "hey there", with: "ana"), "hey there")
    }
}

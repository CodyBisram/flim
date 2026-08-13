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

    // MARK: - prefillingReply (the Reply control's prefill)

    func testReplyOnAnEmptyComposerJustInsertsTheMention() {
        XCTAssertEqual(prefillingReply(to: "@ana", in: ""), "@ana ")
    }

    func testReplyPrependsWithoutLosingExistingText() {
        // Someone half way through a thought who taps Reply should not lose it.
        XCTAssertEqual(prefillingReply(to: "@ana", in: "wait this reminds me"), "@ana wait this reminds me")
    }

    func testReplyDoesNotDuplicateAnAlreadyPresentMention() {
        XCTAssertEqual(prefillingReply(to: "@ana", in: "@ana already replying"), "@ana already replying")
    }

    func testReplyToADifferentPersonStillPrepends() {
        // "@an" is a prefix of "@ana" but not the same mention, so this must still prepend.
        XCTAssertEqual(prefillingReply(to: "@ana", in: "@an hey"), "@ana @an hey")
    }

    func testReplyHandlesUnderscoresAndDigitsInTheHandle() {
        XCTAssertEqual(prefillingReply(to: "@ana_b12", in: ""), "@ana_b12 ")
        XCTAssertEqual(prefillingReply(to: "@ana_b12", in: "@ana_b12 already there"), "@ana_b12 already there")
    }

    // MARK: - isUntouchedReplyPrefill (drives auto-clear on blur)

    func testFreshPrefillIsUntouched() {
        XCTAssertTrue(isUntouchedReplyPrefill(prefillingReply(to: "@ana", in: "")))
    }

    func testAnythingTypedAfterThePrefillIsNotUntouched() {
        XCTAssertFalse(isUntouchedReplyPrefill(prefillingReply(to: "@ana", in: "wait")))
        XCTAssertFalse(isUntouchedReplyPrefill("@ana hi"))
    }

    func testEvenASingleExtraCharacterCountsAsTyped() {
        XCTAssertFalse(isUntouchedReplyPrefill("@ana  "))   // one more space than the prefill leaves
        XCTAssertFalse(isUntouchedReplyPrefill("@ana"))     // missing the trailing space entirely
    }

    func testPlainTextWithNoMentionIsNeverUntouched() {
        XCTAssertFalse(isUntouchedReplyPrefill(""))
        XCTAssertFalse(isUntouchedReplyPrefill("just typing "))
    }

    func testASecondMentionIsNotAnUntouchedPrefill() {
        // Two runs, not one: this is somebody who typed a second @mention, not an abandoned reply.
        XCTAssertFalse(isUntouchedReplyPrefill("@ana @ben "))
    }

    func testUnderscoresAndDigitsInTheHandleStillCountAsUntouched() {
        XCTAssertTrue(isUntouchedReplyPrefill(prefillingReply(to: "@ana_b12", in: "")))
    }
}

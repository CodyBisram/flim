import XCTest
@testable import Flim

/// The rules behind the "In this photo" sheet and the tag editor.
///
/// Both replaced older screens this cycle: names used to be capsules pinned at each person's
/// (x, y) on the photograph, and tagging used to mean tapping a spot and choosing someone in a
/// second sheet on top of the first.
final class PhotoTagsTests: XCTestCase {

    // MARK: - Sheet height

    func testOnePersonGetsAShortSheetRatherThanHalfTheScreen() {
        // 54 header + one 60pt row + 16 padding.
        XCTAssertEqual(taggedPeopleSheetHeight(count: 1), 130)
    }

    func testTheSheetGrowsWithThePeopleInIt() {
        XCTAssertLessThan(taggedPeopleSheetHeight(count: 1), taggedPeopleSheetHeight(count: 3))
    }

    func testAGroupShotIsCappedAndScrollsInstead() {
        // Four and a half rows, so it is visible that there is more without the sheet taking over.
        let capped = taggedPeopleSheetHeight(count: 5)
        XCTAssertEqual(capped, taggedPeopleSheetHeight(count: 40))
        XCTAssertEqual(capped, 54 + 60 * 4.5 + 16)
    }

    func testTheHalfRowIsRealSoSomethingIsAlwaysCutOff() {
        // A whole number of rows would leave the last one flush with the bottom edge, which reads
        // as a complete list. The half row is the affordance that says "keep scrolling".
        let five = taggedPeopleSheetHeight(count: 5)
        XCTAssertNotEqual(five, taggedPeopleSheetHeight(count: 4))
    }

    func testNoPeopleIsNotANegativeHeight() {
        // The sheet is never presented empty (`PhotoTags` renders nothing without tags), but a
        // negative detent is a crash rather than an empty sheet.
        XCTAssertEqual(taggedPeopleSheetHeight(count: 0), 70)
        XCTAssertEqual(taggedPeopleSheetHeight(count: -3), 70)
    }

    // MARK: - Who gets offered a Follow

    private let me = UUID()
    private let someoneElse = UUID()

    func testAStrangerInAFriendsPhotoIsOfferedAFollow() {
        XCTAssertTrue(offersFollow(person: someoneElse, viewer: me, isFollowing: false))
    }

    func testSomeoneYouAlreadyFollowIsNotOfferedAnything() {
        // Deliberately no "Following" button: this sheet is opened to read a name, and a one-tap
        // unfollow under it is a trap. Unfollowing lives on the profile.
        XCTAssertFalse(offersFollow(person: someoneElse, viewer: me, isFollowing: true))
    }

    func testYouAreNeverOfferedAFollowForYourself() {
        XCTAssertFalse(offersFollow(person: me, viewer: me, isFollowing: false))
    }

    func testASignedOutViewerIsStillOfferedTheButton() {
        // There is no signed-out state that can reach this sheet, but resolving `viewer` to nil
        // must not accidentally match a real person's id and hide the button.
        XCTAssertTrue(offersFollow(person: someoneElse, viewer: nil, isFollowing: false))
    }

    // MARK: - Tag editor summary

    func testAnEmptyPhotoSaysSoRatherThanShowingNothing() {
        XCTAssertEqual(tagSummary(handles: []), "Nobody tagged yet")
    }

    func testOnePersonIsJustTheirHandle() {
        XCTAssertEqual(tagSummary(handles: ["@ana"]), "@ana")
    }

    func testTwoPeopleAreBothNamed() {
        XCTAssertEqual(tagSummary(handles: ["@ana", "@jo"]), "@ana and @jo")
    }

    func testPastTwoTheRestBecomeACount() {
        // Names stop being scannable past two, and the number is the useful fact.
        XCTAssertEqual(tagSummary(handles: ["@ana", "@jo", "@sam"]), "@ana, @jo and 1 more")
        XCTAssertEqual(tagSummary(handles: ["@ana", "@jo", "@sam", "@kit", "@rey"]),
                       "@ana, @jo and 3 more")
    }

    func testNoEmDashesInAnyOfTheCopy() {
        // The app-wide copy rule, checked here because this is new user-facing text.
        let copy = [tagSummary(handles: []), tagSummary(handles: ["@ana"]),
                    tagSummary(handles: ["@ana", "@jo"]),
                    tagSummary(handles: ["@ana", "@jo", "@sam"])]
        for line in copy {
            XCTAssertFalse(line.contains("\u{2014}"), "em dash in: \(line)")
            XCTAssertFalse(line.contains("\u{2013}"), "en dash in: \(line)")
        }
    }
}

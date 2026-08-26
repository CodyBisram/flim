import XCTest
@testable import Flim

/// `RollConsequence`: the single source for every roll action that touches other people
/// (confirmations redesign rule 2). These pin the rules that motivated it: counts are only
/// claimed when known, what survives is said first and never overclaims, and the destructive
/// button never carries a bare verb. Replaces the old `rollDeleteConfirmationMessage` tests,
/// which pinned copy the system dialogs took with them.
final class ConsequenceCopyTests: XCTestCase {

    func testDeleteShotCountsPeopleOnlyWhenKnown() {
        let counted = RollConsequence.deleteShot(rollName: "Corner Booth", people: 6, myOtherShots: 11)
        XCTAssertEqual(counted.title, "Delete this shot for all 6 people?")
        XCTAssertEqual(counted.survives, "Your other 11 shots in this roll stay exactly where they are.")

        let uncounted = RollConsequence.deleteShot(rollName: "Corner Booth", people: nil, myOtherShots: nil)
        XCTAssertEqual(uncounted.title, "Delete this shot for everyone?")
        XCTAssertFalse(uncounted.survives.contains("0"), "an unknown count must never read as zero")
    }

    func testDeleteShotSingularShot() {
        let one = RollConsequence.deleteShot(rollName: "Corner Booth", people: 6, myOtherShots: 1)
        XCTAssertEqual(one.survives, "Your other shot in this roll stays exactly where it is.")
    }

    func testLeaveNamesTheRollAndAlwaysMentionsTheCode() {
        // The drift this type exists to prevent: three screens shipped three leave messages,
        // and two disagreed about needing the code to rejoin. The code fact is structural now.
        let leave = RollConsequence.leave(name: "Corner Booth", myShots: 11)
        XCTAssertEqual(leave.title, "Leave Corner Booth?")
        XCTAssertEqual(leave.survives, "Your 11 shots stay in your Darkroom.")
        XCTAssertTrue(leave.loses.contains("invite code"))

        let countless = RollConsequence.leave(name: "Corner Booth", myShots: nil)
        XCTAssertEqual(countless.survives, "Your shots stay in your Darkroom.")
        XCTAssertTrue(countless.loses.contains("invite code"))
    }

    func testDeleteRollLeadsWithWhatSurvives() {
        let del = RollConsequence.deleteRoll(name: "Corner Booth", people: 6)
        XCTAssertEqual(del.title, "Delete Corner Booth for all 6 people?")
        XCTAssertEqual(del.survives, "Everyone keeps the photos they took.")
        XCTAssertEqual(del.loses, "Nobody keeps the roll.")
    }

    func testRemoveMemberSaysWhatTheyKeepAndWhatComingBackTakes() {
        let remove = RollConsequence.removeMember(handle: "@sam", rollName: "Corner Booth", theirShots: 4)
        XCTAssertEqual(remove.title, "Remove @sam from Corner Booth?")
        XCTAssertEqual(remove.survives, "They keep their own 4 shots.")
        XCTAssertTrue(remove.loses.contains("new invite"))
    }

    func testNoBareVerbsOnConfirmButtons() {
        // Rule 5: the destructive button says what the action does to whom, never just the verb.
        let all: [RollConsequence] = [
            .deleteShot(rollName: "R", people: 2, myOtherShots: nil),
            .deleteRoll(name: "R", people: 2),
            .leave(name: "R", myShots: nil),
            .removeMember(handle: "@x", rollName: "R", theirShots: nil),
        ]
        for consequence in all {
            XCTAssertNotEqual(consequence.confirmLabel, "Delete")
            XCTAssertNotEqual(consequence.confirmLabel, "Remove")
            XCTAssertNotEqual(consequence.confirmLabel, "Leave")
            XCTAssertGreaterThan(consequence.confirmLabel.split(separator: " ").count, 1)
        }
    }

    func testNoEmDashesAnywhere() {
        // The copy rule that binds every user-facing string in this app.
        let all: [RollConsequence] = [
            .deleteShot(rollName: "R", people: 6, myOtherShots: 3),
            .deleteRoll(name: "R", people: 6),
            .leave(name: "R", myShots: 3),
            .removeMember(handle: "@x", rollName: "R", theirShots: 3),
        ]
        for consequence in all {
            for text in [consequence.contextLabel, consequence.title, consequence.survives,
                         consequence.loses, consequence.confirmLabel, consequence.cancelLabel] {
                XCTAssertFalse(text.contains("\u{2014}"), "em dash in: \(text)")
            }
        }
    }
}

import XCTest
@testable import Flim

/// `rollsPathAction(for:pushedRollIds:)`: whether a `reveal` push destination should append a
/// fresh `RollDetailView` onto `rollsPath`, or pop back to an instance already there.
///
/// The bug this exists for: every `RollDetailView` instance shares the same `$pendingRollPhoto`
/// binding, and each one's own `onChange` races to consume it by matching `rollId`. A second push
/// for a roll already open used to append a duplicate instance, so a buried one could win that
/// race and leave the visible, topmost screen doing nothing.
final class RollsPathActionTests: XCTestCase {

    func testAppendsWhenTheRollIsNotAlreadyInTheStack() {
        let rollId = UUID()
        let action = rollsPathAction(for: rollId, pushedRollIds: [UUID(), UUID()])
        XCTAssertEqual(action, .append)
    }

    func testAppendsForAnEmptyStack() {
        let action = rollsPathAction(for: UUID(), pushedRollIds: [])
        XCTAssertEqual(action, .append)
    }

    func testPopsBackToAnAlreadyPushedRollRatherThanAppending() {
        let a = UUID(), b = UUID(), c = UUID()
        // b is already the SECOND entry (index 1); a second push for it should truncate back to
        // just past it, keeping the first two entries, not append a third, duplicate instance.
        let action = rollsPathAction(for: b, pushedRollIds: [a, b, c])
        XCTAssertEqual(action, .popTo(keepingFirst: 2))
    }

    func testPopsToTheFirstEntryWhenThatIsTheOneAlreadyOpen() {
        let a = UUID(), b = UUID()
        let action = rollsPathAction(for: a, pushedRollIds: [a, b])
        XCTAssertEqual(action, .popTo(keepingFirst: 1))
    }

    func testASingleEntryStackPopsBackToItself() {
        let a = UUID()
        let action = rollsPathAction(for: a, pushedRollIds: [a])
        XCTAssertEqual(action, .popTo(keepingFirst: 1))
    }

    func testADifferentRollThanAnyOnTheStackStillAppends() {
        let a = UUID(), b = UUID()
        let action = rollsPathAction(for: UUID(), pushedRollIds: [a, b])
        XCTAssertEqual(action, .append)
    }
}

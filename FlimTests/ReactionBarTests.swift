import XCTest
@testable import Flim

/// `reactionDisplayOrder`, the rule that decides which emoji sits first in a reaction row.
///
/// The bug this was extracted for: the roll carousel and photo pager fetch a photo's reactions
/// asynchronously, so the bar built its order against an EMPTY count map and promoted nothing.
/// With `PostEmoji.all` being five entries, a single 😂 reaction stayed at index 2, dead centre,
/// however many times you came back to that photo.
final class ReactionBarTests: XCTestCase {

    private let defaults = PostEmoji.all   // ["❤️", "🔥", "😂", "😮", "🙌"]

    func testSingleReactionIsPromotedToFirst() {
        let order = reactionDisplayOrder(counts: ["😂": 1], defaults: defaults)
        XCTAssertEqual(order.first, "😂")
    }

    func testEmptyCountsLeavesTheDefaultOrderUntouched() {
        // The pre-fetch state. Nothing to promote, so the row must look exactly like the defaults
        // rather than reordering into something arbitrary.
        XCTAssertEqual(reactionDisplayOrder(counts: [:], defaults: defaults), defaults)
    }

    func testMostReactedComesFirst() {
        let order = reactionDisplayOrder(counts: ["😂": 1, "🙌": 5, "🔥": 3], defaults: defaults)
        XCTAssertEqual(Array(order.prefix(3)), ["🙌", "🔥", "😂"])
    }

    func testTiesBreakAlphabeticallySoTheOrderIsStable() {
        // Two emoji on the same count must not depend on dictionary iteration order, or the row
        // would shuffle between appearances of the same photo.
        let a = reactionDisplayOrder(counts: ["😂": 2, "🔥": 2], defaults: defaults)
        let b = reactionDisplayOrder(counts: ["🔥": 2, "😂": 2], defaults: defaults)
        XCTAssertEqual(a, b)
    }

    func testUnreactedDefaultsFollowInTheirOriginalOrder() {
        let order = reactionDisplayOrder(counts: ["🙌": 1], defaults: defaults)
        XCTAssertEqual(order, ["🙌", "❤️", "🔥", "😂", "😮"])
    }

    func testEmojiOutsideTheDefaultsStillLeads() {
        // Reacting with something from the big palette (or the emoji keyboard) must surface it,
        // not drop it because it isn't one of the five defaults.
        let order = reactionDisplayOrder(counts: ["🫡": 2], defaults: defaults)
        XCTAssertEqual(order.first, "🫡")
        XCTAssertEqual(order.count, defaults.count + 1)
    }

    func testZeroCountEntriesAreNotTreatedAsReactions() {
        // A count map can carry a 0 after someone removes their only reaction; that must not
        // promote the emoji above the defaults.
        XCTAssertEqual(reactionDisplayOrder(counts: ["😂": 0], defaults: defaults), defaults)
    }
}

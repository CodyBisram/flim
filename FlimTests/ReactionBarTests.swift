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

/// `emojiPickerSections`, the rule that turns `EmojiCatalog`'s generated categories + recents into
/// the browsable grid's sections. The keyboard escape hatch that used to sit next to this picker is
/// gone (it opened whatever system keyboard the user last used, almost always the text one, and
/// typing a non-emoji character silently dismissed the keyboard onto the photo pager underneath,
/// which read as your keystroke swiping to the next photo); there's no runtime keyboard/focus state
/// left in `ReactionBar` for a test to pin not being touched, so what's pinned instead is that the
/// grid this replaced it with actually shows the whole palette, with nothing dropped or duplicated.
final class EmojiPickerSectionsTests: XCTestCase {

    func testNoRecentsYieldsExactlyTheSourceCategoriesUnchanged() {
        let categories = [
            EmojiCategory(name: "Faces", emojis: ["😀", "😂"]),
            EmojiCategory(name: "Hands", emojis: ["👍", "🙏"]),
        ]
        let sections = emojiPickerSections(categories: categories, recents: [])
        XCTAssertEqual(sections, [
            EmojiPickerSection(name: "Faces", emojis: ["😀", "😂"]),
            EmojiPickerSection(name: "Hands", emojis: ["👍", "🙏"]),
        ])
    }

    func testRecentsArePromotedToALeadingSectionInMostRecentOrder() {
        let categories = [EmojiCategory(name: "Faces", emojis: ["😀", "😂", "😭"])]
        let sections = emojiPickerSections(categories: categories, recents: ["😭", "😀"])
        XCTAssertEqual(sections.first, EmojiPickerSection(name: "Recents", emojis: ["😭", "😀"]))
    }

    func testARecentEmojiIsNotDuplicatedInItsOriginalCategory() {
        let categories = [EmojiCategory(name: "Faces", emojis: ["😀", "😂", "😭"])]
        let sections = emojiPickerSections(categories: categories, recents: ["😂"])
        XCTAssertEqual(sections, [
            EmojiPickerSection(name: "Recents", emojis: ["😂"]),
            EmojiPickerSection(name: "Faces", emojis: ["😀", "😭"]),
        ])
    }

    func testACategoryEmptiedEntirelyByRecentsIsDropped() {
        let categories = [
            EmojiCategory(name: "Faces", emojis: ["😀"]),
            EmojiCategory(name: "Hands", emojis: ["👍"]),
        ]
        let sections = emojiPickerSections(categories: categories, recents: ["😀"])
        XCTAssertEqual(sections, [
            EmojiPickerSection(name: "Recents", emojis: ["😀"]),
            EmojiPickerSection(name: "Hands", emojis: ["👍"]),
        ])
    }

    /// The whole point of the grid: every DISTINCT emoji `EmojiCatalog` generates renders exactly
    /// once, whether or not any of them are recent. `EmojiCatalog.generate()` itself already
    /// guarantees no duplicates (a single `seen` set across every category, flag, and ZWJ template),
    /// so this is really pinning that `emojiPickerSections` doesn't reintroduce one when recents
    /// overlap with the source categories.
    func testEveryDistinctPaletteEmojiAppearsExactlyOnceRegardlessOfRecents() async {
        let categories = await EmojiCatalog.shared.sections()
        let distinct = Set(categories.flatMap(\.emojis))
        let palette = categories.flatMap(\.emojis)
        for recents in [[], ["🔥"], ["🔥", "🫡", "🌊", "🔥"], Array(palette.prefix(12))] {
            let sections = emojiPickerSections(categories: categories, recents: recents)
            let rendered = sections.flatMap(\.emojis)
            XCTAssertEqual(Set(rendered), distinct, "recents=\(recents)")
            XCTAssertEqual(rendered.count, distinct.count, "recents=\(recents) produced a duplicate")
        }
    }

    func testCategoryOrderFromThePaletteIsPreserved() async {
        let categories = await EmojiCatalog.shared.sections()
        let sections = emojiPickerSections(categories: categories, recents: [])
        XCTAssertEqual(sections.map(\.name), categories.map(\.name))
    }

    /// The bug itself, pinned structurally: `ReactionBar` used to hold a `@FocusState` and a
    /// hidden `TextField`, and `keyboardFocused = false` ran on every keystroke that wasn't an
    /// emoji, dismissing the system keyboard onto the photo pager underneath (which read the
    /// key-up as a swipe). Reflecting the view's own stored properties is exactly what would have
    /// caught that class of bug returning: if anyone reintroduces a `FocusState` or a
    /// `TextField`-bound property here, this fails without needing to drive a real keyboard.
    func testTheComponentHoldsNoFocusStateOrTextFieldBinding() {
        let bar = ReactionBar(counts: [:], mine: [], onReact: { _ in })
        let mirror = Mirror(reflecting: bar)
        XCTAssertFalse(mirror.children.isEmpty, "reflection found nothing; the view's storage shape changed")
        for child in mirror.children {
            let typeName = String(describing: type(of: child.value))
            XCTAssertFalse(typeName.contains("FocusState"),
                            "\(child.label ?? "?") is a FocusState (\(typeName)); this component must not focus a text field")
            XCTAssertFalse(typeName.contains("TextField"),
                            "\(child.label ?? "?") is bound to a TextField (\(typeName))")
        }
    }
}

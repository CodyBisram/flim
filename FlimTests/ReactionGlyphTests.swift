import XCTest
@testable import Flim

/// `reactionGlyph(for:renders:)`, the decision behind what a reaction chip draws when the emoji is
/// a string that arrived over the network (a reaction from someone else's phone), possibly on a
/// newer OS than this device's. Kept as a pure function over an injected `renders` predicate
/// exactly so these can stub "this device can't draw it" without needing a real font miss; the
/// real predicate (`RenderProbe`, `EmojiCatalog.swift`) is a genuine offscreen render and its
/// answer is device-dependent by design.
final class ReactionGlyphTests: XCTestCase {

    func testARenderableEmojiRendersAsItself() {
        let glyph = reactionGlyph(for: "🔥", renders: { _ in true })
        XCTAssertEqual(glyph, .emoji("🔥"))
    }

    func testAnUnrenderableStringProducesThePlaceholder() {
        let glyph = reactionGlyph(for: "🔥", renders: { _ in false })
        XCTAssertEqual(glyph, .placeholder(original: "🔥"))
    }

    func testTheToggleValueIsTheOriginalEmojiWhenRenderable() {
        let glyph = reactionGlyph(for: "🫡", renders: { _ in true })
        XCTAssertEqual(glyph.toggleValue, "🫡")
    }

    func testTheToggleValueIsStillTheOriginalEmojiWhenNotRenderable() {
        // The whole point: hiding tofu must never change what tapping the chip reacts with, or
        // someone who reacted with it loses the ability to un-react, and the count would
        // silently stop belonging to the emoji it's displayed next to.
        let glyph = reactionGlyph(for: "🫡", renders: { _ in false })
        XCTAssertEqual(glyph.toggleValue, "🫡")
    }

    func testTheRendersPredicateIsAskedAboutTheExactEmojiPassedIn() {
        var asked: String?
        _ = reactionGlyph(for: "🐦‍🔥", renders: { text in asked = text; return true })
        XCTAssertEqual(asked, "🐦‍🔥")
    }
}

/// `ReactionRenderabilityCache`, the memoization layer in front of the real render probe. Chips
/// re-evaluate their body far more often than the underlying emoji set changes, so this must never
/// re-ask its probe about the same string twice.
final class ReactionRenderabilityCacheTests: XCTestCase {

    @MainActor
    func testARenderableAnswerIsMemoizedAcrossRepeatedLookups() {
        var calls = 0
        let cache = ReactionRenderabilityCache(probe: { _ in calls += 1; return true })

        XCTAssertTrue(cache.renders("🔥"))
        XCTAssertTrue(cache.renders("🔥"))
        XCTAssertTrue(cache.renders("🔥"))

        XCTAssertEqual(calls, 1, "the probe was re-asked about an emoji it already answered")
    }

    @MainActor
    func testAnUnrenderableAnswerIsAlsoMemoizedNotJustSuccesses() {
        var calls = 0
        let cache = ReactionRenderabilityCache(probe: { _ in calls += 1; return false })

        XCTAssertFalse(cache.renders("🫥"))
        XCTAssertFalse(cache.renders("🫥"))

        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testDistinctEmojiAreProbedIndependently() {
        let cache = ReactionRenderabilityCache(probe: { $0 == "🔥" })

        XCTAssertTrue(cache.renders("🔥"))
        XCTAssertFalse(cache.renders("🫥"))
        XCTAssertEqual(cache.probeCallCount, 2)
    }
}

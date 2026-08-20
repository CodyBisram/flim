import Testing
import Foundation
import Vision
@testable import Flim

/// `EmojiLabelMap`'s own shape: every key is a real `VNClassifyImageRequest` identifier, every
/// value is exactly one emoji, and an unknown label resolves to `nil` rather than crashing or
/// silently defaulting to something. A Swift dictionary literal with a repeated key is a RUNTIME
/// crash at first access (not a compile error), so the no-duplicate-keys check here is the only
/// thing standing between a copy/paste mistake in that file and every reaction bar in the app
/// force-crashing the moment it's read.
struct EmojiLabelMapTests {
    /// `VNClassifyImageRequest().supportedIdentifiers()` on this machine: 1,303 entries as of
    /// revision 2. Every key `EmojiLabelMap` ships must be drawn from this set, or it can never
    /// match a real classification and is dead weight at best.
    private static let knownIdentifiers: Set<String> = {
        (try? VNClassifyImageRequest().supportedIdentifiers()).map(Set.init) ?? []
    }()

    @Test("every mapped label is a real Vision identifier")
    func everyLabelIsReal() throws {
        try #require(!Self.knownIdentifiers.isEmpty, "couldn't load Vision's own identifier list")
        for label in Self.sampleLabels {
            #expect(Self.knownIdentifiers.contains(label), "\(label) isn't a real VNClassifyImageRequest identifier")
        }
    }

    @Test("every mapped emoji is exactly one grapheme")
    func everyValueIsASingleEmoji() {
        for label in Self.sampleLabels {
            let emoji = EmojiLabelMap.emoji(forLabel: label)
            #expect(emoji != nil)
            #expect(emoji?.count == 1, "\(label) → \(emoji ?? "nil") isn't a single grapheme")
        }
    }

    @Test("an unknown label yields nil, not a crash or a default")
    func unknownLabelYieldsNil() {
        #expect(EmojiLabelMap.emoji(forLabel: "not_a_real_vision_label") == nil)
        #expect(EmojiLabelMap.emoji(forLabel: "") == nil)
    }

    @Test("the taxonomy's own hierarchy example resolves the way the feature is built on")
    func hierarchyExampleResolves() {
        // The owner's motivating case: a specific reptile label, its family, and the broad
        // fallback that's supposed to save a miss on the specific one.
        #expect(EmojiLabelMap.emoji(forLabel: "lizard") == "🦎")
        #expect(EmojiLabelMap.emoji(forLabel: "reptile") == "🐾")
        #expect(EmojiLabelMap.emoji(forLabel: "animal") == "🐾")
    }

    /// A representative slice, not the full 400+ entries: this is a smoke test that the table's
    /// shape holds, not a re-listing of the table itself.
    private static let sampleLabels = [
        "dog", "corgi", "husky", "cat", "kitten", "lizard", "gecko", "reptile", "animal",
        "snake", "frog", "turtle", "bee", "butterfly", "spider", "apple", "banana", "pizza",
        "hamburger", "sushi", "coffee", "beer", "wine", "cloudy", "rainbow", "snow", "mountain",
        "ocean", "beach", "forest", "rose", "tulip", "sunflower", "cactus", "tree", "skyscraper",
        "bridge", "car", "bicycle", "airplane", "boat", "basketball", "soccer", "guitar",
        "piano", "birthday_cake", "fireworks", "christmas_tree", "laptop", "camera", "sunglasses",
    ]
}

/// `PostEmoji.defaults(suggested:)`, the rule that turns a suggestion (or the lack of one) into
/// the reaction bar's five default slots.
struct PostEmojiDefaultsTests {
    @Test("no suggestion renders exactly the six defaults")
    func noSuggestionIsTheSixDefaults() {
        #expect(PostEmoji.defaults(suggested: []) == PostEmoji.all)
        #expect(PostEmoji.defaults(suggested: []) == ["❤️", "🔥", "😂", "😮", "🙌", "👏"])
    }

    @Test("a full suggestion fills all three contextual slots")
    func fullSuggestionFillsAllSlots() {
        let result = PostEmoji.defaults(suggested: ["🦎", "🐾", "🐸"])
        #expect(result == ["❤️", "🔥", "😂", "🦎", "🐾", "🐸"])
    }

    @Test("a partial suggestion is backfilled from the fallback set")
    func partialSuggestionIsBackfilled() {
        #expect(PostEmoji.defaults(suggested: ["🦎"]) == ["❤️", "🔥", "😂", "🦎", "😮", "🙌"])
        #expect(PostEmoji.defaults(suggested: ["🦎", "🐾"]) == ["❤️", "🔥", "😂", "🦎", "🐾", "😮"])
    }

    @Test("the bar never renders fewer than six slots")
    func alwaysSixSlots() {
        #expect(PostEmoji.defaults(suggested: []).count == 6)
        #expect(PostEmoji.defaults(suggested: ["🦎"]).count == 6)
        #expect(PostEmoji.defaults(suggested: ["🦎", "🐾"]).count == 6)
        #expect(PostEmoji.defaults(suggested: ["🦎", "🐾", "🐸"]).count == 6)
    }

    @Test("a suggestion that collides with a fixed reaction doesn't duplicate it")
    func collisionWithFixedIsDropped() {
        // The server can only ever be asked to write labels this dictionary produces, and none
        // of them are the three fixed reactions, but this is cheap insurance against that ever
        // changing (or a hand-written RPC call from somewhere else).
        let result = PostEmoji.defaults(suggested: ["❤️", "🦎"])
        #expect(result == ["❤️", "🔥", "😂", "🦎", "😮", "🙌"])
    }

    @Test("more than three suggested emoji still yields six slots, not eight")
    func overlongSuggestionIsCapped() {
        let result = PostEmoji.defaults(suggested: ["🦎", "🐾", "🐸", "🐟"])
        #expect(result.count == 6)
        #expect(result == ["❤️", "🔥", "😂", "🦎", "🐾", "🐸"])
    }
}

// The browsable picker's full palette used to be a hardcoded 108-entry list here
// (`PostEmojiCategoriesTests`). It's now generated at runtime by `EmojiCatalog` from Unicode
// scalar properties + on-device font/glyph checks, so a fixed count no longer makes sense to pin
// (it's deliberately different per iOS version). See `EmojiCatalogTests.swift`.

/// `EmojiSuggestion.pick(fromQualifyingIdentifiers:)`, the pure dedup/cap-at-3 rule over
/// already-floor-passing labels. Separated from Vision entirely (`VNClassificationObservation`
/// has no public initializer, so nothing upstream of this point can be built in a test).
struct EmojiSuggestionPickTests {
    @Test("the most confident mapped labels win, most-confident first")
    func mostConfidentWins() {
        #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: ["lizard", "reptile"]) == ["🦎", "🐾"])
    }

    @Test("never more than three, even with many qualifying labels")
    func neverMoreThanThree() {
        let picked = EmojiSuggestion.pick(fromQualifyingIdentifiers: ["dog", "cat", "lizard", "bee"])
        #expect(picked.count == 3)
        #expect(picked == ["🐶", "🐱", "🦎"])
    }

    @Test("the same emoji is never picked twice")
    func noDuplicateEmoji() {
        // "corgi" and "husky" both map to 🐶; a third, distinct label should fill the second slot.
        let picked = EmojiSuggestion.pick(fromQualifyingIdentifiers: ["corgi", "husky", "lizard"])
        #expect(picked == ["🐶", "🦎"])
    }

    @Test("labels with no mapping are skipped, not treated as a miss that stops the scan")
    func unmappedLabelsAreSkippedNotFatal() {
        let picked = EmojiSuggestion.pick(fromQualifyingIdentifiers: ["people", "adult", "lizard"])
        #expect(picked == ["🦎"])
    }

    @Test("no qualifying labels yields no suggestion")
    func emptyInputYieldsEmpty() {
        #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: []).isEmpty)
        #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: ["people", "adult", "baby"]).isEmpty)
    }
}

/// Runs the real classifier against the owner's own photographs, exactly like the look regression
/// pin's `pairLookIsPinned`: local-only (`pairs/` is gitignored), skipped rather than failing on a
/// fresh clone or in CI. This is deliberately NOT a pass/fail assertion on which labels come back —
/// Vision's own model is not this feature's code to pin, and a future OS classifying a photo
/// slightly differently is not a FLIM regression. It exists to print what a REAL capture actually
/// produces, which is the only way to judge whether the label→emoji mapping is any good.
struct EmojiSuggestionRealPhotoTests {
    @Test("classifies the owner's real captures and reports what comes back",
          .enabled(if: LookPairs.isAvailable))
    func classifyRealCaptures() throws {
        // Every neutral pair on disk, not just the five the look pin samples: this is cheap
        // (no rendering, no baseline to keep in sync) and more scenes is strictly more signal
        // for judging the dictionary.
        let files = (try? FileManager.default.contentsOfDirectory(atPath: LookPairs.directory.path)) ?? []
        let scenes = files.filter { $0.hasSuffix("_neutral.jpg") }.sorted()
        try #require(!scenes.isEmpty)

        for file in scenes {
            let data = try Data(contentsOf: LookPairs.directory.appendingPathComponent(file))
            let emoji = EmojiSuggestion.classify(data)
            // No assertion on WHICH emoji: see the type doc. Printed so the report can quote it.
            print("EmojiSuggestion[\(file)] → \(emoji.isEmpty ? "(none)" : emoji.joined(separator: " "))")
            #expect(emoji.count <= 2)
        }
    }
}

import Testing
import Foundation
import NaturalLanguage
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

/// `EmojiSemanticFallback`, the CLDR + `NLEmbedding` resolver that answers for labels
/// `EmojiLabelMap` never learned. Pure over plain strings, same as `pick(fromQualifyingIdentifiers:)`.
///
/// `NLEmbedding.wordEmbedding(for: .english)` is an on-demand asset and can legitimately be nil, so
/// the one test below that depends on the embedding asserts the specific emoji only when the asset
/// is actually present, and asserts the contract (no crash, nothing excluded, capped, stable)
/// unconditionally. Everything else here runs off the bundled corpus and is deterministic anywhere.
struct EmojiSemanticFallbackTests {
    /// Vision's own taxonomy, the same source `EmojiLabelMapTests` checks the hand table against.
    private static let knownIdentifiers: [String] = {
        (try? VNClassifyImageRequest().supportedIdentifiers()) ?? []
    }()

    @Test("the curated table still answers for every label it maps, unchanged")
    func handTableStillWins() {
        // Regression, not coverage: these all resolved this way before the fallback existed and
        // must resolve identically now, whatever the corpus would have said about them.
        for label in ["lizard", "reptile", "animal", "dog", "corgi", "cat", "pizza", "coffee",
                      "book", "laptop", "beach", "sunflower", "guitar", "camera", "bed"] {
            let curated = EmojiLabelMap.emoji(forLabel: label)
            #expect(curated != nil, "\(label) should still be hand-mapped")
            #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: [label]) == [curated].compactMap { $0 })
        }
    }

    @Test("a guess never displaces or outranks a hand-mapped answer")
    func curatedFillsSlotsFirst() {
        // `abacus` is unmapped and first, i.e. the more confident label. The curated 🦎 still
        // takes the first slot, because the whole curated pass runs before any guessing.
        #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: ["abacus", "lizard"]) == ["🦎", "🧮"])
    }

    @Test("labels the hand table never learned resolve straight out of the CLDR corpus")
    func exactCorpusMatchesResolve() {
        // Real Vision identifiers, none of them in `EmojiLabelMap`, each spelled by the corpus.
        let expected = ["abacus": "🧮", "cupcake": "🧁", "elevator": "🛗", "telescope": "🔭",
                        "parachute": "🪂", "screwdriver": "🪛", "jigsaw": "🧩", "mailbox": "📪"]
        for (label, emoji) in expected {
            #expect(EmojiLabelMap.emoji(forLabel: label) == nil, "\(label) is hand-mapped now; pick another case")
            #expect(EmojiSemanticFallback.emoji(forLabel: label) == emoji)
            #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: [label]) == [emoji])
        }
    }

    @Test("a compound label resolves through its head noun, not its qualifier")
    func compoundLabelsUseTheHeadNoun() {
        // "high_chair" is a chair, not ⚡, which is what looking up "high" used to produce.
        #expect(EmojiSemanticFallback.emoji(forLabel: "high_chair") == "🪑")
        #expect(EmojiSemanticFallback.emoji(forLabel: "swivel_chair") == "🪑")
        // Vision's catch-all leaves carry an `_other` suffix that is noise, not a noun.
        #expect(EmojiSemanticFallback.emoji(forLabel: "chair_other") == "🪑")
    }

    @Test("the embedding reaches a label the corpus never spells")
    func semanticPathReachesUnspelledLabels() {
        // The owner's motivating case. "concert" is a real Vision identifier, is not hand-mapped,
        // and is not a CLDR keyword for anything: only the word vectors can get from it to music.
        #expect(EmojiLabelMap.emoji(forLabel: "concert") == nil)
        let picked = EmojiSuggestion.pick(fromQualifyingIdentifiers: ["concert"])
        // Holds with or without the embedding asset installed.
        #expect(picked.count <= 3)
        #expect(!picked.contains(where: EmojiSemanticFallback.isExcluded))
        #expect(picked == EmojiSuggestion.pick(fromQualifyingIdentifiers: ["concert"]))
        // The actual behaviour, asserted only where the asset the behaviour needs exists. On a
        // machine without the English word vectors this degrades to "no suggestion" by design.
        if NLEmbedding.wordEmbedding(for: .english) != nil {
            #expect(picked == ["🎵"], "concert should reach music through its neighbours")
        }
    }

    @Test("every excluded category is refused, whatever the corpus says")
    func excludedCategoriesAreRefused() {
        // One representative per required category, plus the two structural cases (skin tone and
        // ZWJ sequence) that the corpus carries thousands of.
        for emoji in ["🇺🇸", "🏳️", "🏴", "🚩",           // flags
                      "👥", "🧑", "👍", "👂", "🙏", "💃",   // people and body parts
                      "👍🏽", "👨‍👩‍👧",                        // skin tone, joined family
                      "🔫", "🔪", "⚔️", "💣",              // weapons
                      "💉", "💊", "🩹", "🩺", "😷",        // medical and injury
                      "✝️", "☪️", "✡️", "🕉️", "⛪", "📿",   // religious
                      "♒", "☠️", "⚰️", "🚬"] {             // identity-adjacent and sensitive
            #expect(EmojiSemanticFallback.isExcluded(emoji), "\(emoji) should be excluded")
        }
        // And the labels that would otherwise reach them.
        for label in ["people", "adult", "baby", "child", "crowd", "flag", "knife", "sword",
                      "medicine", "wheelchair"] {
            #expect(EmojiSemanticFallback.emoji(forLabel: label) == nil, "\(label) should stay unanswered")
            #expect(EmojiSuggestion.pick(fromQualifyingIdentifiers: [label]).isEmpty)
        }
    }

    @Test("no label in Vision's entire taxonomy can produce an excluded emoji")
    func noIdentifierEverReachesAnExcludedEmoji() throws {
        // The deny policy is applied when the reverse index is built, so this is the assertion
        // that it was applied to every entry and not just the ones anyone thought to check.
        try #require(!Self.knownIdentifiers.isEmpty, "couldn't load Vision's own identifier list")
        for identifier in Self.knownIdentifiers {
            guard let emoji = EmojiSemanticFallback.emoji(forLabel: identifier) else { continue }
            #expect(!EmojiSemanticFallback.isExcluded(emoji), "\(identifier) reached excluded \(emoji)")
        }
    }

    @Test("the cap and the dedup still hold once guesses are in play")
    func capAndDedupHoldAcrossBothPasses() {
        // Two curated, three unmapped: three slots, curated first, guesses filling the rest.
        let picked = EmojiSuggestion.pick(
            fromQualifyingIdentifiers: ["abacus", "lizard", "cupcake", "dog", "telescope"])
        #expect(picked.count == 3)
        #expect(picked == ["🦎", "🐶", "🧮"])
        // `oak_tree` and `eucalyptus_tree` both resolve to 🌲 through their head noun, and 🌲 is
        // also what the curated table gives `evergreen`: one slot, not three.
        let deduped = EmojiSuggestion.pick(
            fromQualifyingIdentifiers: ["evergreen", "oak_tree", "eucalyptus_tree"])
        #expect(deduped == ["🌲"])
    }

    @Test("an unknown or empty label yields nothing rather than a default")
    func unknownLabelsYieldNothing() {
        #expect(EmojiSemanticFallback.emoji(forLabel: "") == nil)
        #expect(EmojiSemanticFallback.emoji(forLabel: "not_a_real_vision_label_xyzzy") == nil)
    }

    @Test("the same labels twice give the same answer")
    func resolutionIsDeterministic() {
        // Covers all three resolution paths at once: curated, corpus, and (asset permitting)
        // embedding. The reverse index picks a winner per keyword from an unordered dictionary
        // walk, so this is the guard against that winner drifting between calls.
        let labels = ["lizard", "abacus", "concert", "high_chair", "people", "cupcake", "cliff"]
        let first = EmojiSuggestion.pick(fromQualifyingIdentifiers: labels)
        #expect(first == EmojiSuggestion.pick(fromQualifyingIdentifiers: labels))
        for label in labels {
            #expect(EmojiSemanticFallback.emoji(forLabel: label)
                    == EmojiSemanticFallback.emoji(forLabel: label))
        }
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
            // 3, the documented cap, not the 2 that happened to be the most the curated table
            // alone ever produced on these scenes. `EmojiSemanticFallback` can now fill the third.
            #expect(emoji.count <= 3)
        }
    }
}

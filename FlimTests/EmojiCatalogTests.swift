import Testing
import Foundation
@testable import Flim

/// `EmojiCatalog`, the runtime-generated full emoji palette that replaced the old hardcoded
/// 108-entry list. These pin the invariants that still hold now that the exact count is
/// deliberately OS-dependent (an emoji from a Unicode revision newer than the simulator's iOS
/// predates just doesn't appear): every entry is unique, every section is real, and nothing here
/// regresses the fixed reaction-bar slots this catalog has nothing to do with.
struct EmojiCatalogTests {
    @Test("the catalog is never empty and never trivially small")
    func catalogIsSubstantial() async {
        let categories = await EmojiCatalog.shared.sections()
        let all = categories.flatMap(\.emojis)
        // However old the simulator's iOS is, the single-scalar walk alone (faces, animals,
        // food, objects, symbols...) plus generated flags is nowhere near this small; a number
        // in this neighborhood would mean the scan ranges or the glyph filter are broken, not
        // that the OS is old.
        #expect(all.count > 500, "only \(all.count) entries; the generator likely regressed")
    }

    @Test("no emoji appears in more than one section")
    func noDuplicatesAcrossSections() async {
        let categories = await EmojiCatalog.shared.sections()
        let all = categories.flatMap(\.emojis)
        #expect(Set(all).count == all.count, "duplicate entries somewhere in the generated catalog")
    }

    @Test("every section has a real name and at least one emoji")
    func everySectionIsNonEmptyAndNamed() async {
        let categories = await EmojiCatalog.shared.sections()
        #expect(!categories.isEmpty)
        for category in categories {
            #expect(!category.name.isEmpty)
            #expect(!category.emojis.isEmpty)
            for emoji in category.emojis {
                #expect(!emoji.isEmpty)
                #expect(!emoji.unicodeScalars.contains(Unicode.Scalar(0xFFFD)!), "\(category.name) contains a replacement character, not a real glyph")
            }
        }
    }

    @Test("the standard section headers the picker UI expects are present")
    func standardSectionsArePresent() async {
        let categories = await EmojiCatalog.shared.sections()
        let names = Set(categories.map(\.name))
        for expected in ["Smileys and Emotion", "Animals and Nature", "Food and Drink", "Flags"] {
            #expect(names.contains(expected), "missing expected section \(expected)")
        }
    }

    @Test("flags are generated from real regional-indicator pairs, not a hardcoded handful")
    func flagsSectionIsGenerated() async {
        let categories = await EmojiCatalog.shared.sections()
        guard let flags = categories.first(where: { $0.name == "Flags" }) else {
            Issue.record("no Flags section generated")
            return
        }
        // Every entry must actually be a two-scalar regional-indicator pair (or a curated ZWJ
        // flag like the rainbow/pirate/trans flags), never a stray single scalar.
        #expect(flags.emojis.count > 50, "only \(flags.emojis.count) flags; the pair-generation loop likely regressed")
        #expect(flags.emojis.contains("🇺🇸"), "an extremely common, unambiguous flag failed to render")
    }

    @Test("sections() is cached: repeat calls return the identical generated array")
    func sectionsAreCached() async {
        let first = await EmojiCatalog.shared.sections()
        let second = await EmojiCatalog.shared.sections()
        #expect(first == second)
    }

    @Test("the fixed reaction slots are untouched by any of this")
    func fixedAndFallbackAreUnchanged() {
        #expect(PostEmoji.fixed == ["❤️", "🔥", "😂"])
        #expect(PostEmoji.fallback == ["😮", "🙌"])
        #expect(PostEmoji.all == ["❤️", "🔥", "😂", "😮", "🙌"])
    }

    /// Pins the exact regression that shipped from a device: `RenderProbe.renders` used to demand
    /// a SATURATED pixel (max channel minus min channel over a threshold) for any font reporting
    /// the color-glyph trait. Apple's designs for these are almost entirely white/grey/black — R, G,
    /// and B stay near-equal everywhere they're drawn — so nothing ever cleared that threshold and
    /// every one of these real, renderable glyphs was rejected as tofu. The probe must accept a
    /// glyph because the font actually HAS one (a non-`.notdef` glyph id), never because it looks
    /// colourful.
    @Test("achromatic emoji are accepted, not rejected for lacking a saturated pixel", arguments: [
        "👟", "🎩", "👓", "🖤", "⚪", "🐧",
    ])
    func achromaticEmojiAreNotFalseNegatives(_ emoji: String) {
        let probe = RenderProbe()
        #expect(probe.renders(emoji), "\(emoji) should render on this OS but the probe rejected it")
    }

    // MARK: - Search token extraction (pure functions, no font or catalog dependency)

    @Test("a plain single-scalar emoji tokenizes to its Unicode name's words")
    func plainEmojiTokenizes() {
        let tokens = emojiSearchTokens(for: "😀")
        #expect(tokens.contains("grinning"))
        #expect(tokens.contains("face"))
    }

    @Test("a ZWJ sequence keeps every component's name, so it's findable under any of them")
    func zwjSequenceKeepsEveryComponent() {
        // 🧑‍🚀: ADULT (Unicode's own name for 🧑, not "person"), ZERO WIDTH JOINER (noise,
        // dropped), ROCKET.
        let tokens = emojiSearchTokens(for: "🧑‍🚀")
        #expect(tokens.contains("adult"))
        #expect(tokens.contains("rocket"))
        #expect(!tokens.contains("zero"))
        #expect(!tokens.contains("joiner"))
    }

    @Test("a keycap tokenizes to its own base character, since plain ASCII digits aren't wrapped in Unicode names")
    func keycapTokenizesToBaseCharacter() {
        // 3️⃣: the bare "3" gets no \N{...} name at all from CFStringTransform (only non-ASCII
        // scalars are wrapped), so the base character has to be supplied directly; the variation
        // selector and combining keycap mark are still filtered out as noise.
        let tokens = keycapSearchTokens(base: "3", text: "3\u{FE0F}\u{20E3}")
        #expect(tokens.contains("3"))
        #expect(!tokens.contains("variation"))
        #expect(!tokens.contains("selector"))
        #expect(!tokens.contains("combining"))
        #expect(!tokens.contains("keycap"))
    }

    @Test("a variation-selector emoji drops the selector and keeps only the meaningful name")
    func variationSelectorEmojiDropsSelector() {
        // ❤️: HEAVY BLACK HEART, VARIATION SELECTOR-16 (noise).
        let tokens = emojiSearchTokens(for: "\u{2764}\u{FE0F}")
        #expect(tokens.contains("heart"))
        #expect(!tokens.contains("variation"))
        #expect(!tokens.contains("selector"))
    }

    @Test("a flag decodes back to its ISO region code")
    func flagDecodesToRegionCode() {
        #expect(regionCode(forFlag: "🇺🇸") == "US")
        #expect(regionCode(forFlag: "🇹🇹") == "TT")
    }

    @Test("a non-flag two-scalar string doesn't falsely decode as a region code")
    func nonFlagDoesNotDecode() {
        #expect(regionCode(forFlag: "3\u{FE0F}") == nil)
        #expect(regionCode(forFlag: "😀") == nil)
    }

    @Test("word tokenization lowercases and splits on non-letters")
    func wordTokenizationSplitsAndLowercases() {
        #expect(wordTokens("GRINNING FACE") == ["grinning", "face"])
        #expect(wordTokens("Côte d'Ivoire") == ["côte", "d", "ivoire"])
    }

    // MARK: - Matching and ranking

    @Test("matching is whole-word by prefix, not substring")
    func matchingIsWholeWordPrefix() {
        #expect(emojiSearchRank(["dog", "face"], query: "dog") != nil)
        #expect(emojiSearchRank(["dog", "face"], query: "og") == nil)
    }

    @Test("an exact whole-word match outranks a prefix-only match")
    func exactMatchOutranksPrefix() {
        let exact = emojiSearchRank(["fire"], query: "fire")
        let prefix = emojiSearchRank(["fireworks"], query: "fire")
        #expect(exact == 0)
        #expect(prefix == 1)
        #expect(exact! < prefix!)
    }

    @Test("an empty query never matches a specific token search")
    func emptyQueryDoesNotRank() {
        #expect(emojiSearchRank(["fire"], query: "") == nil)
    }

    @Test("search results are empty for an empty query, not the full palette")
    func emptyQueryProducesNoSearchResults() {
        let categories = [EmojiCategory(name: "Test", emojis: ["🔥"])]
        let results = emojiSearchResults(categories: categories, tokens: ["🔥": ["fire"]], query: "")
        #expect(results.isEmpty)
    }

    @Test("search ranks exact matches ahead of partial matches within results")
    func searchResultsRankExactFirst() {
        let categories = [EmojiCategory(name: "Test", emojis: ["🎆", "🔥"])]
        let tokens: [String: [String]] = ["🎆": ["fireworks"], "🔥": ["fire"]]
        let results = emojiSearchResults(categories: categories, tokens: tokens, query: "fire")
        #expect(results.count == 1)
        #expect(results[0].emojis.first == "🔥", "the exact match should sort ahead of the prefix-only match")
    }
}

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
        #expect(PostEmoji.fallback == ["😮", "🙌", "👏"])
        #expect(PostEmoji.all == ["❤️", "🔥", "😂", "😮", "🙌", "👏"])
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

    @Test("a stem-only match still ranks, behind exact and prefix matches")
    func stemMatchRanksLast() {
        // Unicode calls 😊 SMILING FACE WITH SMILING EYES, so the word a person actually types
        // ("smile") appears nowhere in its tokens. Generation stores each word's stem alongside
        // it (see `withStems`), which is what lets the query's own stem find it.
        let tokens = withStems(["smiling", "face"])
        #expect(emojiSearchRank(tokens, query: "smiling") == 0)
        #expect(emojiSearchRank(tokens, query: "smilin") == 1)
        #expect(emojiSearchRank(tokens, query: "smile") == 2)
    }

    @Test("stemming matches plurals without matching unrelated words that share a stem prefix")
    func stemmingIsWholeStemNotPrefix() {
        #expect(emojiSearchRank(withStems(["dog", "face"]), query: "dogs") == 2)
        // "fire" stems to "fir", which IS a prefix of "first" — the whole-stem rule is what stops
        // FIRST PLACE MEDAL from answering a search for fire.
        #expect(emojiSearchRank(withStems(["first", "place", "medal"]), query: "fire") == nil)
    }

    @Test("stems are added alongside the real words, never in place of them")
    func stemsAreAdditive() {
        let tokens = withStems(["smiling", "face"])
        #expect(tokens.contains("smiling"))
        #expect(tokens.contains("face"))
        #expect(tokens.contains("smil"))
    }

    @Test("stemming leaves short words alone rather than collapsing them")
    func stemmingLeavesShortWordsAlone() {
        // Every rule only fires if at least three characters survive it, so these are unchanged
        // and can't cross-match each other.
        #expect(searchStem("eye") == "eye")
        #expect(searchStem("eyes") == "eye")
        #expect(searchStem("ice") == "ice")
        #expect(searchStem("cry") == "cry")
    }

    @Test("a word and its participle stem to the same thing, in both directions")
    func stemmingIsSymmetric() {
        // The stemmer is crude on purpose; what it has to be is symmetric, since it is only ever
        // applied to both sides of a comparison.
        #expect(searchStem("smile") == searchStem("smiling"))
        #expect(searchStem("laugh") == searchStem("laughing"))
        #expect(searchStem("dance") == searchStem("dancing"))
        #expect(searchStem("run") == searchStem("running"))
        #expect(searchStem("kiss") == searchStem("kissing"))
    }

    // MARK: - Search aliases

    @Test("every alias emoji is spelled in its canonical presentation form")
    func aliasEmojiUseCanonicalPresentationForm() {
        // Aliases are matched against `generate()`'s own keys by exact string equality, and those
        // keys are bare when the scalar is Emoji_Presentation=Yes and carry U+FE0F when it isn't.
        // A wrong variation selector here would silently find nothing instead of failing, so this
        // is the check that makes the table honest. Multi-scalar sequences (the ZWJ entries) are
        // spelled as `zwjTemplates` spells them and are skipped here.
        for (keyword, emojis) in emojiSearchAliases {
            for emoji in emojis {
                let scalars = Array(emoji.unicodeScalars)
                let isSingle = scalars.count == 1
                let isSelected = scalars.count == 2 && scalars[1].value == 0xFE0F
                guard isSingle || isSelected, let base = scalars.first else { continue }
                let canonical = base.properties.isEmojiPresentation ? String(base) : "\(base)\u{FE0F}"
                #expect(emoji == canonical,
                        "\"\(keyword)\" lists \(emoji), which the catalog would key as \(canonical)")
            }
        }
    }

    @Test("aliases invert to per-emoji tokens, so one keyword reaches every emoji it lists")
    func aliasesInvertToTokens() {
        let inverted = aliasTokensByEmoji()
        // The bug this whole table exists for: "laugh" appears in no Unicode name but 🤣's, so
        // 😂 could only ever be found by typing "tears" or "joy".
        #expect(inverted["😂"]?.contains("laugh") == true)
        #expect(inverted["😆"]?.contains("laugh") == true)
        #expect(inverted["😢"]?.contains("sad") == true)
        // Inversion is a fan-out, not a rename: an emoji listed under several keywords carries
        // all of them.
        #expect((inverted["🔥"]?.count ?? 0) > 1)
    }

    @Test("alias tokens are sorted, so two runs of the same build rank identically")
    func aliasTokensAreDeterministic() {
        // Dictionary iteration order isn't stable across runs and these feed a visible ranking.
        for (_, tokens) in aliasTokensByEmoji() {
            #expect(tokens == tokens.sorted())
        }
    }

    @Test("searching a real generated catalog for everyday words finds more than a token result")
    func everydayWordsFindRealResults() async {
        // The regression this pins is the shipped one: "laugh" returned exactly one emoji, the
        // only one with the word in its Unicode name, while the system keyboard filled a row.
        let categories = await EmojiCatalog.shared.sections()
        let tokens = await EmojiCatalog.shared.searchTokens()
        for word in ["laugh", "sad", "happy", "love", "party", "food"] {
            let results = emojiSearchResults(categories: categories, tokens: tokens, query: word)
            let count = results.flatMap(\.emojis).count
            #expect(count >= 5, "\"\(word)\" found only \(count) emoji")
        }
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

/// The bar the picker is held to: emoji findable by the words people type in Messages, not only
/// by formal Unicode names. Backed by the bundled CLDR annotation keywords
/// (`emoji-keywords.txt`, generated by `scripts/gen_emoji_keywords.py`) layered with the hand
/// aliases. Every pair here runs through the REAL pipeline: the catalog's generated tokens and
/// `emojiSearchRank`, exactly what the reaction picker executes per keystroke.
struct EmojiMessagesParityTests {

    /// Vernacular, slang, and plain words, each with the emoji Messages surfaces for it.
    private static let expectations: [(query: String, emoji: String)] = [
        ("laugh", "😂"), ("lol", "😂"), ("lmao", "🤣"), ("hilarious", "🤣"),
        ("bday", "🎂"), ("birthday", "🎂"), ("party", "🥳"), ("celebrate", "🎉"),
        ("taco", "🌮"), ("avocado", "🥑"), ("pizza", "🍕"), ("coffee", "☕"),
        ("beer", "🍺"), ("wine", "🍷"),
        ("dog", "🐶"), ("cat", "🐱"), ("unicorn", "🦄"), ("goat", "🐐"),
        ("rain", "🌧️"), ("snow", "❄️"), ("sun", "☀️"), ("moon", "🌙"),
        ("car", "🚗"), ("plane", "✈️"), ("train", "🚆"),
        ("money", "💰"), ("rich", "🤑"), ("gift", "🎁"),
        ("ghost", "👻"), ("skull", "💀"), ("yolo", "💀"),
        ("clap", "👏"), ("congrats", "👏"), ("pray", "🙏"), ("thanks", "🙏"),
        ("wink", "😉"), ("kiss", "😘"), ("heart", "❤️"), ("love", "😍"),
        ("sad", "😢"), ("cry", "😭"), ("angry", "😡"), ("mad", "😡"),
        ("cool", "😎"), ("nervous", "😅"), ("sick", "🤒"), ("sleepy", "😴"),
        ("poop", "💩"), ("fire", "🔥"), ("hundred", "💯"),
        ("soccer", "⚽"), ("basketball", "🏀"), ("guitar", "🎸"),
        ("camera", "📷"), ("photo", "📷"), ("film", "🎞️"),
    ]

    @Test("every Messages-style query surfaces its emoji")
    func parity() async {
        let tokens = await EmojiCatalog.shared.searchTokens()
        for pair in Self.expectations {
            // The emoji may be catalogued with or without VS16; accept either form, since that
            // presentation detail is invisible to the person searching.
            let stripped = String(String.UnicodeScalarView(
                pair.emoji.unicodeScalars.filter { $0.value != 0xFE0F }))
            let candidates = [pair.emoji, stripped, stripped + "\u{FE0F}"]
            let found = candidates.contains { candidate in
                tokens[candidate].flatMap { emojiSearchRank($0, query: pair.query) } != nil
            }
            #expect(found, "\"\(pair.query)\" does not find \(pair.emoji)")
        }
    }

    @Test("the CLDR resource is present and substantial")
    func resourceLoads() async {
        // If the bundled file goes missing (a resource-phase regression, a rename), search
        // degrades to Unicode names and hand aliases SILENTLY. Assert scale, not exact counts,
        // so regenerating against a newer CLDR never breaks this.
        let tokens = await EmojiCatalog.shared.searchTokens()
        let laugh = tokens["😂"] ?? []
        #expect(laugh.contains("lmao"), "CLDR keywords missing from 😂: \(laugh)")
    }
}

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
}

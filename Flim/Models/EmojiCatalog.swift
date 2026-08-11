import Foundation
import CoreText
import CoreGraphics

/// The full emoji palette for the reaction picker's browsable grid, generated at runtime from
/// Unicode scalar properties and filtered against what THIS device can actually DRAW, rather than
/// a hand-maintained list. That's what keeps the picker correct for whatever iOS is actually
/// running: an emoji from a Unicode revision newer than the installed font just never shows up (no
/// tofu), and a future iOS with more emoji widens the palette with no code change here.
///
/// The render check (`RenderProbe.renders`) never names a font. An earlier version of this file
/// asked for a font by the literal name `"AppleColorEmoji"`, which is exactly the kind of
/// per-OS-version fragility this whole feature exists to avoid: on one simulator runtime that name
/// resolved to a font whose metadata (PostScript name, the `traitColorGlyphs` bit) was entirely
/// correct, and which still failed to draw a single pixel. The fix applies regardless of that
/// detail: never assume a name, always resolve through `CTFontCreateForString`, which asks CoreText
/// for whatever font it would ACTUALLY pick to draw a given string on THIS OS, then shape it and
/// check the shaped glyph id, never pixels (see `RenderProbe.renders` for why a rasterize-and-scan
/// approach was tried and rejected: it produces false negatives for largely achromatic emoji like
/// 👟, 🎩, and 👓).
///
/// Scope, decided deliberately:
///  - Single-scalar pictographs are the bulk of the set: every scalar in Unicode's emoji-relevant
///    ranges (`scanRanges`) that reports `isEmoji` and isn't a component (a lone skin-tone
///    modifier, a lone regional-indicator letter, or the combining keycap mark) is a candidate.
///  - Skin tones and hair-color/gender ZWJ variants are never enumerated. Every applicable base
///    already appears once, in its default (unmodified) form, which IS "one representative per
///    family" for that axis, for free. This is a deliberate product decision (confirmed with the
///    owner): completeness stops at one entry per emoji CONCEPT, never one per skin-tone × gender
///    permutation of it, because that axis alone would multiply the grid past 3,500 cells. Adding
///    a skin-tone choice as a long-press on a cell later would be cheap; it isn't built here.
///  - Flags are generated, not listed: all 26×26 regional-indicator pairs are tried and a pair is
///    kept only if this device's font actually draws it as one flag (not two letter-in-box glyphs
///    sitting side by side). That also self-updates as new region flags ship; no ISO country list
///    is hardcoded anywhere. The three subdivision flags (England, Scotland, Wales) use Unicode TAG
///    characters instead of regional indicators, so they can't be reached by that loop; they're
///    listed explicitly below and, like everything else, only survive if they actually render.
///  - Keycaps (0-9, #, *) are generated from the closed, exhaustively-enumerable set Unicode
///    defines for the combining keycap mark — not "a list", a complete small alphabet.
///  - ZWJ sequences are the one place a curated list was unavoidable: Unicode exposes no
///    scalar-level property that says "these components combine into a real sequence", so there is
///    no way to *discover* valid combinations purely from properties the way single scalars and
///    flags can be. `zwjTemplates` below is one gender-neutral, non-permuted representative per
///    well-known concept (professions, family/relationship symbols that only exist as ZWJ
///    sequences, a handful of ZWJ-only animals and faces). It is deliberately not exhaustive — RGI
///    defines thousands of ZWJ sequences once every gender × skin-tone × profession combination is
///    counted — but every entry is still gated by the same render check, so a wrong or
///    OS-unsupported guess here just silently doesn't appear rather than showing tofu.
actor EmojiCatalog {
    static let shared = EmojiCatalog()

    private var cached: [EmojiCategory]?
    private var task: Task<[EmojiCategory], Never>?

    /// Kicks off generation in the background if nothing has started yet. Fire-and-forget by
    /// design, like `EmojiSuggestion.suggest`: nothing here is awaited by the caller. Safe to call
    /// on every `ReactionBar` appear; only the very first call does anything, because it's what
    /// gets generation done well before anyone can reach the "+" button and actually open the
    /// picker.
    nonisolated func warm() {
        Task { await self.ensureStarted() }
    }

    /// The full palette, grouped into labelled sections. Returns instantly once `warm()` (or a
    /// prior call to this) has finished; awaits the in-flight generation otherwise, which only
    /// happens if the picker is opened before any `ReactionBar` has had a chance to warm it.
    func sections() async -> [EmojiCategory] {
        if let cached { return cached }
        let result = await ensureStarted().value
        cached = result
        return result
    }

    @discardableResult
    private func ensureStarted() -> Task<[EmojiCategory], Never> {
        if let task { return task }
        // `.utility`: this is thousands of scalar checks, each now a real (if small) offscreen
        // render rather than a cheap cmap lookup. Real work, but never urgent, and must never
        // compete with anything the user is actively waiting on.
        let newTask = Task.detached(priority: .utility) { generate() }
        task = newTask
        return newTask
    }
}

/// Unicode blocks that contain `Emoji=Yes` code points as of Unicode 16 (2024). New emoji almost
/// always land inside these already-reserved ranges in later revisions too (that's how Unicode
/// allocates them), so this rarely needs to change; if a future revision opens a genuinely new
/// block, THAT would need a code update, but nothing about which individual emoji exist would.
private let scanRanges: [ClosedRange<UInt32>] = [
    0x2000...0x2BFF,   // dingbats, misc symbols, misc technical, geometric shapes, arrows
    0x1F000...0x1FAFF, // mahjong/cards, misc pictographs, emoticons, transport, supplemental
]

private let categoryOrder = [
    "Smileys and Emotion", "People and Body", "Animals and Nature", "Food and Drink",
    "Travel and Places", "Activities", "Objects", "Symbols", "Flags",
]

/// The complete, closed set of keycap bases Unicode defines (there is no other valid base): the
/// ten digits, `#`, and `*`. Each becomes a real keycap sequence by appending the variation
/// selector and the combining enclosing keycap mark, e.g. `"3\u{FE0F}\u{20E3}"` → 3️⃣.
private let keycapBases = Array("0123456789#*")

/// The three officially recognized subdivision flags (RGI ZWJ sequences built from Unicode TAG
/// characters spelling the ISO 3166-2 subdivision code, terminated by the cancel tag), which is
/// the complete set — there are no others in the standard. Unlike country flags these can't be
/// reached by iterating regional-indicator pairs, so they're listed explicitly; like everything
/// else they only survive generation if this device's font actually renders them.
private let subdivisionFlags: [(text: String, name: String)] = [
    ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "England"),
    ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "Scotland"),
    ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}", "Wales"),
]

/// A curated, explicitly incomplete set of ZWJ sequences; see the type doc for why this one part
/// of the catalog can't be derived purely from Unicode properties the way everything else is. One
/// representative per concept: no skin tones, no gender permutations of the same role.
private let zwjTemplates: [(text: String, category: String)] = [
    // People and Body: gender-neutral professions/roles.
    ("🧑‍💻", "People and Body"), ("🧑‍🎨", "People and Body"), ("🧑‍🍳", "People and Body"),
    ("🧑‍🌾", "People and Body"), ("🧑‍🚀", "People and Body"), ("🧑‍🚒", "People and Body"),
    ("🧑‍⚕️", "People and Body"), ("🧑‍🏫", "People and Body"), ("🧑‍⚖️", "People and Body"),
    ("🧑‍✈️", "People and Body"), ("🧑‍🔧", "People and Body"), ("🧑‍🔬", "People and Body"),
    ("🧑‍🎤", "People and Body"), ("🧑‍🎓", "People and Body"), ("🧑‍🏭", "People and Body"),
    ("🧑‍💼", "People and Body"),
    ("🧑‍🤝‍🧑", "People and Body"), ("🧑‍🦯", "People and Body"), ("🧑‍🦽", "People and Body"),
    ("🧑‍🦼", "People and Body"), ("👁️‍🗨️", "People and Body"),
    // Smileys and Emotion: faces that only exist as ZWJ sequences (not reachable by the
    // single-scalar walk at all, unlike most faces).
    ("😵‍💫", "Smileys and Emotion"), ("😮‍💨", "Smileys and Emotion"), ("😶‍🌫️", "Smileys and Emotion"),
    // Flags: not representable as a single scalar or a regional-indicator pair.
    ("🏳️‍🌈", "Flags"), ("🏴‍☠️", "Flags"), ("🏳️‍⚧️", "Flags"),
    // Animals and Nature: concepts that only exist as ZWJ sequences, not skin-tone/gender variants
    // of something already covered above.
    ("🐈‍⬛", "Animals and Nature"), ("🐕‍🦺", "Animals and Nature"), ("🐻‍❄️", "Animals and Nature"),
    ("🐦‍⬛", "Animals and Nature"), ("🐦‍🔥", "Animals and Nature"),
    // Food and Drink: same story — this specific concept only exists as a ZWJ sequence.
    ("🍄‍🟫", "Food and Drink"),
]

/// Runs entirely off the actor: called from inside `Task.detached`, touches no actor state, so it
/// never needs to hop onto `EmojiCatalog`'s executor just to compute.
private func generate() -> [EmojiCategory] {
    var byCategory: [String: [String]] = [:]
    var seen = Set<String>()
    let probe = RenderProbe()

    func add(_ text: String, to category: String) {
        guard !text.isEmpty, seen.insert(text).inserted else { return }
        byCategory[category, default: []].append(text)
    }

    for range in scanRanges {
        for value in range {
            guard let scalar = Unicode.Scalar(value), isStandalonePictograph(scalar) else { continue }
            let text = scalar.properties.isEmojiPresentation ? String(scalar) : "\(scalar)\u{FE0F}"
            guard probe.renders(text) else { continue }
            add(text, to: category(for: scalar))
        }
    }

    let regionalIndicators = (0..<26).compactMap { Unicode.Scalar(0x1F1E6 + $0) }
    for first in regionalIndicators {
        for second in regionalIndicators {
            let text = "\(first)\(second)"
            guard probe.renders(text) else { continue }
            add(text, to: "Flags")
        }
    }

    for flag in subdivisionFlags where probe.renders(flag.text) {
        add(flag.text, to: "Flags")
    }

    for base in keycapBases {
        let text = "\(base)\u{FE0F}\u{20E3}"
        guard probe.renders(text) else { continue }
        add(text, to: "Symbols")
    }

    for template in zwjTemplates where probe.renders(template.text) {
        add(template.text, to: template.category)
    }

    return categoryOrder.compactMap { name in
        byCategory[name].map { EmojiCategory(name: name, emojis: $0) }
    }
}

/// `isEmoji` alone still lets through a handful of scalars that are components, never meant to
/// stand alone: skin-tone modifiers, the bare regional-indicator letters (flags are built from
/// PAIRS of these separately, above), and the combining keycap mark used in sequences like 3️⃣
/// (generated separately, above, from the closed digit/#/* alphabet).
private func isStandalonePictograph(_ scalar: Unicode.Scalar) -> Bool {
    guard scalar.properties.isEmoji else { return false }
    switch scalar.value {
    case 0x1F3FB...0x1F3FF, 0x1F1E6...0x1F1FF, 0x20E3:
        return false
    default:
        return true
    }
}

/// Resolves and shapes candidate text with zero dependence on any font's NAME, and only counts it
/// as renderable if the shape actually produced a real glyph — never by rasterizing and inspecting
/// pixels. One instance is created per `generate()` call and reused across every candidate (font
/// resolution is the expensive part; reusing it is what keeps thousands of checks fast).
///
/// Not `private`: also used at the reaction-chip level (`ReactionRenderabilityCache`, see
/// `ReactionGlyph.swift`) to check an incoming reaction's emoji before drawing it — reactions
/// travel between phones, so a chip can carry a string generated on a newer OS than the one
/// displaying it, unlike this file's own picker grid, which is filtered by this exact same check
/// at generation time and therefore never shows anything the running device can't draw. Same
/// check, reused rather than copied, per the type's own contract: name-independent, no pixels.
final class RenderProbe {
    /// The plain system UI font, resolved by role rather than name. It cannot draw emoji itself,
    /// which is exactly what forces `CTFontCreateForString` below to perform REAL fallback
    /// resolution to whatever font this OS actually uses for a given string, rather than trusting
    /// a name I've hardcoded that might not match this OS's actual font registration.
    private let seedFont: CTFont

    init() {
        seedFont = CTFontCreateUIFontForLanguage(.system, 28, nil)
            ?? CTFontCreateWithName("System" as CFString, 28, nil)
    }

    /// True only if `text` (one scalar or several) shapes to a SINGLE glyph — the general signal
    /// for "this OS ligatures this exact sequence" that works identically for a plain face, a flag
    /// pair, and a ZWJ family — AND that glyph is not `.notdef` (glyph id 0), the exact signal a
    /// font gives for "I have no glyph for this", which is what renders as a tofu box.
    ///
    /// Deliberately never rasterizes. An earlier version of this check drew the shaped line into a
    /// bitmap and demanded a pixel whose channels differed by more than a threshold when the
    /// resolved font reported the color-glyph trait, on the theory that "some ink" alone let a
    /// broken rasterizer's solid-black fallback (see below) pass as a false positive. That threshold
    /// asks "is this glyph colourful", not "can this device draw this glyph": Apple's largely
    /// achromatic emoji designs (👟, 🎩, 👓 — sneaker, top hat, glasses, all near-equal RGB
    /// everywhere) never produced a pixel saturated enough to clear it, so real, renderable glyphs
    /// were rejected as tofu. Reading the glyph id directly off the shaped run sidesteps rasterizing
    /// at all, so it can't be fooled in either direction: a genuinely broken rasterizer (the
    /// original motivation — one simulator runtime resolved emoji correctly by every piece of font
    /// metadata, including a correct cmap, yet drew nothing, while a plain non-emoji string on that
    /// same runtime drew as solid black ink) still reports the correct, non-zero glyph id, because
    /// glyph resolution and rasterization are separate steps in CoreText. Also still rejects
    /// `LastResort`, CoreText's own permanent, always-present "nothing else matched" sentinel font by
    /// name — unlike naming an emoji font (which is what broke before), this name never changes
    /// across OS versions, so it isn't the kind of fragility this rewrite exists to avoid.
    func renders(_ text: String) -> Bool {
        let cfText = text as CFString
        let resolved = CTFontCreateForString(seedFont, cfText, CFRange(location: 0, length: text.utf16.count))
        guard !(CTFontCopyPostScriptName(resolved) as String).contains("LastResort") else { return false }

        let attributed = NSAttributedString(string: text, attributes: [.font: resolved])
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        let glyphCount = runs.reduce(0) { $0 + CTRunGetGlyphCount($1) }
        guard glyphCount == 1, let run = runs.first(where: { CTRunGetGlyphCount($0) == 1 }) else { return false }

        var glyph = CGGlyph()
        CTRunGetGlyphs(run, CFRange(location: 0, length: 1), &glyph)
        return glyph != 0
    }
}

/// Coarse, hardcoded block-level grouping into the picker's standard section headers. Approximate
/// at the edges (Unicode's own blocks mix people/objects/nature more than a clean split allows),
/// same trade the task brief explicitly sanctions for grouping; unmatched scalars fall through to
/// "Symbols", the catch-all for dingbats, arrows, and misc technical symbols.
private func category(for scalar: Unicode.Scalar) -> String {
    switch scalar.value {
    case 0x1F600...0x1F644, 0x1F910...0x1F92F, 0x1F970...0x1F979, 0x1FAE0...0x1FAEF,
         0x2764, 0x1F493...0x1F49F, 0x1F5A4, 0x1F90D, 0x1F90E, 0x1F9E1, 0x1FA75...0x1FA77:
        return "Smileys and Emotion"

    case 0x1F440...0x1F450, 0x1F466...0x1F487, 0x1F48F, 0x1F491, 0x1F574...0x1F575,
         0x1F57A, 0x1F590...0x1F596, 0x1F645...0x1F64F, 0x1F9B0...0x1F9B9,
         0x1F9CD...0x1F9DF, 0x1FAC0...0x1FAC5, 0x1FAF0...0x1FAFF:
        return "People and Body"

    case 0x1F400...0x1F43E, 0x1F980...0x1F9AE, 0x1F332...0x1F343, 0x1FAB0...0x1FABF,
         0x2600...0x2603, 0x2618, 0x1F30D...0x1F30F, 0x1F311...0x1F320, 0x1F30A:
        return "Animals and Nature"

    case 0x1F32D...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CB, 0x1FAD0...0x1FAD9:
        return "Food and Drink"

    case 0x1F680...0x1F6C5, 0x1F3E0...0x1F3F0, 0x1F30C, 0x1F5FA...0x1F5FF,
         0x26F0...0x26F5, 0x1F3D4...0x1F3DF, 0x1F6E0...0x1F6EC, 0x1F6F0...0x1F6FC, 0x1F308:
        return "Travel and Places"

    case 0x1F3A0...0x1F3C4, 0x1F3C6...0x1F3CE, 0x1F3CF...0x1F3D3, 0x26BD...0x26BE,
         0x1F93A...0x1F94F, 0x1F396...0x1F397:
        return "Activities"

    case 0x1F4A0...0x1F4FF, 0x1F50A...0x1F5A3, 0x1F5A5...0x1F5F9, 0x1F6CB...0x1F6D0,
         0x1F9F0...0x1F9FF, 0x1FA70...0x1FA74, 0x1FA78...0x1FA7C, 0x1FA80...0x1FA86,
         0x1FA90...0x1FA9F:
        return "Objects"

    default:
        return "Symbols"
    }
}

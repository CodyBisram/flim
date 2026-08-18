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

    private var cached: EmojiCatalogData?
    private var task: Task<EmojiCatalogData, Never>?

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
        await data().sections
    }

    /// Every generated emoji's precomputed lowercase search tokens (Unicode component names for
    /// most entries, region names for flags, `emojiSearchAliases` layered on top, and each of
    /// those words' `searchStem`), for the picker's search field. Computed once alongside
    /// `sections()` in the same background pass, not per keystroke: see `generate()`.
    func searchTokens() async -> [String: [String]] {
        await data().tokens
    }

    private func data() async -> EmojiCatalogData {
        if let cached { return cached }
        let result = await ensureStarted().value
        cached = result
        return result
    }

    @discardableResult
    private func ensureStarted() -> Task<EmojiCatalogData, Never> {
        if let task { return task }
        // `.utility`: this is thousands of scalar checks, each now a real (if small) offscreen
        // render rather than a cheap cmap lookup. Real work, but never urgent, and must never
        // compete with anything the user is actively waiting on.
        let newTask = Task.detached(priority: .utility) { generate() }
        task = newTask
        return newTask
    }
}

/// The result of one `generate()` pass: the browsable sections, and every entry's search tokens
/// keyed by the emoji itself. Bundled together so both are produced (and cached) by the exact same
/// background pass instead of a second one running later for search.
struct EmojiCatalogData {
    let sections: [EmojiCategory]
    let tokens: [String: [String]]
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

/// The one curated part of the search index, keyed by the word you'd type rather than by the emoji
/// it should find: Unicode's own component names are formal, frozen in 2010, and miss most of what
/// people actually type. Measured against the generated catalog before this existed, "laugh"
/// matched exactly one emoji (🤣, the only one whose Unicode name contains the word at all — 😂 is
/// FACE WITH TEARS OF JOY, 😆 is SMILING FACE WITH OPEN MOUTH AND TIGHTLY-CLOSED EYES), "sad"
/// matched nothing whatsoever, and "happy" matched a raised hand. Unicode exposes no keyword
/// property to derive these from, so, like `zwjTemplates` above, this is unavoidably hand-maintained.
///
/// It used to be deliberately tiny, on the reasoning that production reaction data is dominated by
/// a handful of emoji. That was the wrong bar: the picker's search field is judged against the one
/// on the keyboard people already use, where typing "laugh" fills the row. The right size is
/// "everyday vocabulary", not "the emoji already in the data" — the whole point of search is to
/// reach the ones that AREN'T. It's still not CLDR: no synonym chains, no rare concepts, one
/// obvious set of answers per word people actually type at a photo.
///
/// Keyword → emoji, not emoji → keywords, because the maintainable question is "what should typing
/// this give me", and the answer wants to be read as a row. It's inverted into per-emoji tokens
/// once, inside `generate()`. An entry naming an emoji THIS device can't draw is simply never
/// reachable (the emoji never enters the catalog, so nothing carries its tokens), exactly like
/// every other part of this file degrading the same way.
///
/// Every emoji here must be spelled in its CANONICAL presentation form — bare when the scalar is
/// `Emoji_Presentation=Yes` (😀, 🔥, ⭐), with a trailing `U+FE0F` when it isn't (❤️, ☺️, ✌️) —
/// because these are matched against `generate()`'s own keys by exact string equality, so a wrong
/// variation selector silently does nothing rather than failing loudly. `EmojiCatalogTests` checks
/// that invariant for every entry, which is also why this isn't `private`.
let emojiSearchAliases: [String: [String]] = [
    // MARK: - Laughing, joy, and the everyday reaction vocabulary
    "laugh": ["😂", "🤣", "😆", "😹", "😅", "😄", "😃"],
    "lol": ["😂", "🤣", "😆", "😹"],
    "haha": ["😂", "🤣", "😆"],
    "lmao": ["😂", "🤣"],
    "funny": ["😂", "🤣", "😆", "🤡"],
    "hilarious": ["😂", "🤣"],
    "giggle": ["😆", "🤭", "😹"],
    "happy": ["😀", "😃", "😄", "😁", "😊", "🙂", "🥰", "😌", "🤗", "🥳"],
    "smile": ["😀", "😃", "😄", "😁", "😊", "🙂", "😸"],
    "grin": ["😀", "😃", "😄", "😁"],
    "joy": ["😂", "😊", "🥹", "🎉"],
    "excited": ["🤩", "😆", "🥳", "😻"],
    "proud": ["🥹", "🤩", "💪", "🏆"],

    // MARK: - Sadness, hurt, and worry
    "sad": ["😢", "😭", "🙁", "☹️", "😞", "😔", "😥", "😿", "💔", "🥲"],
    "cry": ["😢", "😭", "🥲", "😿", "😥"],
    "sob": ["😭", "😢"],
    "upset": ["😞", "😔", "😩", "😫", "💔"],
    "hurt": ["💔", "😢", "🤕"],
    "lonely": ["🥺", "😔", "🫂"],
    "sorry": ["🙏", "😔", "🥺"],
    "worried": ["😟", "😰", "😬", "🥺"],
    "stressed": ["😩", "😫", "😰", "🤯"],
    "disappointed": ["😞", "😔", "👎"],

    // MARK: - Anger and disgust
    "angry": ["😠", "😡", "🤬", "😤", "👿", "😾"],
    "mad": ["😠", "😡", "🤬", "😤"],
    "rage": ["🤬", "😡", "👿"],
    "annoyed": ["😒", "🙄", "😤"],
    "gross": ["🤢", "🤮", "😷", "💩"],
    "sick": ["🤢", "🤮", "🤒", "🤕", "😷"],
    "eww": ["🤢", "🤮"],

    // MARK: - Love and affection
    "love": ["❤️", "😍", "🥰", "😘", "💕", "💖", "💗", "💘", "💞", "💓", "❣️", "😻", "🫶"],
    "heart": ["❤️", "🧡", "💛", "💚", "💙", "💜", "🖤", "🤍", "🤎", "💕", "💖", "💗", "💘", "💞", "💓", "💝", "❣️", "💌", "🫶"],
    "crush": ["😍", "🥰", "😻", "💘"],
    "kiss": ["😘", "😗", "😙", "😚", "💋", "💏", "😽"],
    "hug": ["🤗", "🫂"],
    "cute": ["🥰", "😍", "🥺", "🐣", "🐶", "🐱"],
    "romance": ["❤️", "💐", "🌹", "💏", "🕯️"],
    "heartbroken": ["💔", "😭", "😢"],
    "breakup": ["💔", "😭"],
    "wedding": ["💍", "👰", "🤵", "💒", "🎊"],
    "marry": ["💍", "👰", "🤵", "💒"],

    // MARK: - Shock, fear, confusion
    "wow": ["😮", "😲", "🤯", "😱", "🤩", "‼️"],
    "shocked": ["😮", "😲", "😱", "🤯"],
    "surprised": ["😮", "😲", "🎉", "🤯"],
    "omg": ["😱", "😲", "🤯", "😮"],
    "scared": ["😱", "😨", "😰", "🙀", "👻"],
    "creepy": ["😨", "👻", "🕷️", "💀"],
    "confused": ["😕", "🤨", "😵‍💫", "🤷", "❓"],
    "shrug": ["🤷"],
    "idk": ["🤷", "😕"],
    "whatever": ["🤷", "🙄", "😒"],
    "thinking": ["🤔", "🧐", "💭"],
    "hmm": ["🤔", "🧐"],
    "facepalm": ["🤦", "🙈"],
    "awkward": ["😬", "😅", "😳"],
    "embarrassed": ["😳", "🙈", "😅"],
    "oops": ["🙈", "😅", "😬"],
    "blush": ["😳", "☺️", "🥰"],

    // MARK: - Attitude, banter, mischief
    "cool": ["😎", "🆒", "🕶️", "🔥"],
    "smirk": ["😏"],
    "wink": ["😉", "😜"],
    "tongue": ["😛", "😜", "😝", "🤪", "👅"],
    "silly": ["🤪", "😜", "🤡", "😝"],
    "crazy": ["🤪", "🤯", "😵‍💫"],
    "nerd": ["🤓", "🧐", "📚"],
    "sarcastic": ["🙄", "😒", "😏"],
    "lie": ["🤥", "🧢"],
    "secret": ["🤫", "🤐", "🔒", "🤝"],
    "quiet": ["🤫", "🤐"],
    "evil": ["😈", "👿", "💀"],
    "angel": ["😇", "👼"],
    "clown": ["🤡"],
    "poop": ["💩"],
    "shit": ["💩"],
    "dead": ["💀", "☠️", "😵", "⚰️"],
    "sleep": ["😴", "😪", "🥱", "💤", "🛏️"],
    "tired": ["😴", "🥱", "😩", "😪"],
    "bored": ["🥱", "😑", "😐"],
    "hungry": ["😋", "🤤", "🍕", "🍔"],
    "drunk": ["🥴", "🍻", "🍺", "🍷"],
    "rich": ["🤑", "💰", "💵", "💎"],

    // MARK: - Hands and gestures
    "yes": ["👍", "✅", "🆗", "🙌", "☑️"],
    "ok": ["👌", "👍", "🆗", "✅"],
    "agree": ["👍", "💯", "🙌", "🤝"],
    "thumbsup": ["👍"],
    "no": ["👎", "❌", "🚫", "🙅"],
    "nope": ["👎", "❌", "🙅"],
    "thumbsdown": ["👎"],
    "clap": ["👏", "🙌"],
    "applause": ["👏", "🙌"],
    "bravo": ["👏", "🙌", "🏆"],
    "wave": ["👋", "🌊"],
    "hi": ["👋", "🙂"],
    "hello": ["👋", "🙂"],
    "bye": ["👋", "✌️"],
    "peace": ["✌️", "🕊️", "☮️"],
    "strong": ["💪", "🔥", "🦾"],
    "muscle": ["💪", "🏋️", "🦾"],
    "flex": ["💪", "😎"],
    "fist": ["👊", "🤛", "🤜", "✊"],
    "pray": ["🙏"],
    "please": ["🙏", "🥺"],
    "thanks": ["🙏", "🤗", "💐"],
    "thank": ["🙏", "🤗"],
    "salute": ["🫡"],
    "respect": ["🫡", "🙇", "🙏"],
    "eyes": ["👀", "👁️"],
    "look": ["👀", "🔍", "👁️"],
    "watching": ["👀", "📺"],
    "point": ["👉", "👈", "👆", "👇"],
    "middle finger": ["🖕"],

    // MARK: - Celebration and milestones
    "party": ["🎉", "🎊", "🥳", "🪩", "🍾", "🎈"],
    "celebrate": ["🎉", "🎊", "🥳", "🍾", "🙌", "🥂"],
    "congrats": ["🎉", "🎊", "👏", "🏆", "🥂"],
    "yay": ["🎉", "🙌", "🥳"],
    "hooray": ["🎉", "🙌", "🥳"],
    "birthday": ["🎂", "🎈", "🎁", "🥳", "🎉"],
    "cheers": ["🥂", "🍻", "🍾", "🍷"],
    "gift": ["🎁", "🎀"],
    "win": ["🏆", "🥇", "🎯", "🙌"],
    "winner": ["🏆", "🥇", "👑"],
    "trophy": ["🏆", "🥇", "🎖️"],
    "goat": ["🐐", "🏆"],
    "fire": ["🔥"],
    "lit": ["🔥", "🎉", "🪩"],
    "hot": ["🔥", "🥵", "🌶️", "☀️"],
    "cold": ["🥶", "❄️", "🧊", "⛄"],
    "perfect": ["💯", "👌", "✨"],
    "hundred": ["💯"],
    "star": ["⭐", "🌟", "✨", "🌠"],
    "sparkle": ["✨", "🌟", "💫"],
    "magic": ["✨", "🪄", "🔮", "🎩"],
    "lucky": ["🍀", "🎰", "🌈"],
    "new": ["🆕", "✨", "🐣"],

    // MARK: - Photos, film, and making things
    "photo": ["📷", "📸", "🖼️", "🎞️"],
    "camera": ["📷", "📸", "🎥", "📹"],
    "picture": ["📷", "🖼️", "📸"],
    "film": ["🎞️", "🎬", "📽️", "🎥"],
    "movie": ["🎬", "🍿", "📽️", "🎥"],
    "video": ["📹", "🎥", "📺"],
    "art": ["🎨", "🖌️", "🖼️", "✏️"],
    "draw": ["✏️", "🖍️", "🎨"],
    "music": ["🎵", "🎶", "🎧", "🎤", "🎸"],
    "song": ["🎵", "🎶", "🎤"],
    "sing": ["🎤", "🎶", "🎵"],
    "dance": ["💃", "🕺", "🪩", "🎶"],
    "book": ["📚", "📖", "📕"],
    "read": ["📖", "📚", "🤓"],
    "write": ["✍️", "📝", "✏️"],
    "idea": ["💡", "🤔", "✨"],

    // MARK: - Food and drink
    "food": ["🍕", "🍔", "🍟", "🌮", "🍣", "🍜", "🍝", "🥗", "🍲", "😋"],
    "eat": ["😋", "🍽️", "🍕", "🍴"],
    "yum": ["😋", "🤤", "😍"],
    "pizza": ["🍕"],
    "burger": ["🍔", "🍟"],
    "taco": ["🌮", "🌯"],
    "sushi": ["🍣", "🍱", "🥢"],
    "coffee": ["☕", "🥐"],
    "tea": ["🍵", "🧋"],
    "beer": ["🍺", "🍻"],
    "wine": ["🍷", "🍾", "🥂"],
    "cocktail": ["🍸", "🍹", "🥃"],
    "drink": ["🍺", "🍷", "☕", "🥤", "🍸"],
    "cake": ["🍰", "🎂", "🧁"],
    "dessert": ["🍰", "🍦", "🍩", "🍪", "🧁"],
    "icecream": ["🍦", "🍨"],
    "candy": ["🍬", "🍫", "🍭"],
    "cook": ["🍳", "🔪", "🥘", "🧑‍🍳"],
    "breakfast": ["🍳", "🥐", "☕", "🥞"],

    // MARK: - Places, weather, and getting there
    "travel": ["✈️", "🧳", "🗺️", "🌍", "🚆"],
    "trip": ["✈️", "🧳", "🚗", "🗺️"],
    "vacation": ["🏖️", "✈️", "🌴", "🕶️"],
    "beach": ["🏖️", "🌊", "🌴", "🐚", "☀️"],
    "summer": ["☀️", "🏖️", "🍉", "🕶️"],
    "winter": ["❄️", "⛄", "🧣", "🎿"],
    "snow": ["❄️", "⛄", "🌨️", "🏂"],
    "rain": ["🌧️", "☔", "⛈️", "🌈"],
    "storm": ["⛈️", "🌩️", "🌪️", "⚡"],
    "sun": ["☀️", "🌞", "🌅", "😎"],
    "night": ["🌙", "🌃", "✨", "😴"],
    "moon": ["🌙", "🌛", "🌝", "🌕"],
    "rainbow": ["🌈", "🏳️‍🌈"],
    "pride": ["🏳️‍🌈", "🏳️‍⚧️", "🌈"],
    "nature": ["🌳", "🌲", "🍃", "🌿", "⛰️"],
    "flower": ["🌸", "🌺", "🌻", "🌷", "🌹", "🌼", "💐"],
    "plant": ["🪴", "🌱", "🌿", "🌵"],
    "space": ["🚀", "🌌", "🪐", "👽", "🌠"],
    "world": ["🌍", "🌎", "🌏", "🗺️"],
    "ocean": ["🌊", "🐬", "🐟", "🏖️", "⛵"],
    "swim": ["🏊", "🌊", "🩱"],
    "home": ["🏠", "🏡", "🛋️", "🔑"],
    "city": ["🏙️", "🌃", "🚕", "🏢"],
    "car": ["🚗", "🚙", "🏎️", "🛣️"],
    "drive": ["🚗", "🛣️", "🚙"],
    "bike": ["🚲", "🚴", "🛵"],
    "plane": ["✈️", "🛫", "🛬"],
    "train": ["🚆", "🚂", "🚇"],

    // MARK: - People, animals, and everyday life
    "baby": ["👶", "🍼", "🧸", "🐣"],
    "family": ["👪", "🏠", "❤️"],
    "friend": ["🫂", "🧑‍🤝‍🧑", "🤝", "❤️"],
    "dog": ["🐶", "🐕", "🦮", "🐩", "🐕‍🦺"],
    "puppy": ["🐶", "🐕"],
    "cat": ["🐱", "🐈", "🐈‍⬛", "😻", "🐾"],
    "kitten": ["🐱", "🐈"],
    "pet": ["🐶", "🐱", "🐾", "🐹"],
    "bird": ["🐦", "🦅", "🕊️", "🦜"],
    "fish": ["🐟", "🐠", "🎣", "🍣"],
    "bug": ["🐛", "🐜", "🐝", "🦋", "🕷️"],
    "work": ["💼", "💻", "🏢", "📊", "🧑‍💻"],
    "job": ["💼", "🧑‍💻", "🏢"],
    "busy": ["😩", "💼", "⏰", "🏃"],
    "school": ["🏫", "📚", "✏️", "🎓"],
    "study": ["📚", "✏️", "🤓", "📝"],
    "exam": ["📝", "😰", "📚"],
    "graduate": ["🎓", "🎉", "🧑‍🎓"],
    "gym": ["💪", "🏋️", "🏃", "🤸"],
    "workout": ["💪", "🏋️", "🏃", "🧘"],
    "exercise": ["🏃", "🏋️", "🚴", "🧘"],
    "run": ["🏃", "👟", "🎽"],
    "yoga": ["🧘", "🧎"],
    "sport": ["⚽", "🏀", "🏈", "⚾", "🎾", "🏐"],
    "game": ["🎮", "🕹️", "🎲", "♟️"],
    "gaming": ["🎮", "🕹️"],
    "money": ["💰", "💵", "💸", "🤑", "💳"],
    "shopping": ["🛒", "🛍️", "💳"],
    "phone": ["📱", "☎️", "📞"],
    "call": ["📞", "☎️", "📱"],
    "message": ["💬", "🗨️", "📩", "💭"],
    "chat": ["💬", "🗨️", "📱"],
    "email": ["📧", "📩", "✉️"],
    "time": ["⏰", "⌛", "⏳", "🕐"],
    "late": ["⏰", "🏃", "😬"],
    "clean": ["🧼", "🧹", "🧽", "✨"],
    "health": ["🏥", "💊", "🩺", "🍎"],
    "doctor": ["🧑‍⚕️", "🏥", "🩺"],
    "medicine": ["💊", "💉", "🩹"],

    // MARK: - Marks, status, and signals
    "check": ["✅", "☑️", "✔️"],
    "done": ["✅", "☑️", "🏁", "🙌"],
    "correct": ["✅", "✔️", "💯"],
    "wrong": ["❌", "🚫", "👎"],
    "cancel": ["❌", "🚫", "⛔"],
    "stop": ["🛑", "✋", "⛔", "🚫"],
    "warning": ["⚠️", "🚨", "❗"],
    "careful": ["⚠️", "👀", "🚨"],
    "urgent": ["🚨", "❗", "⏰"],
    "question": ["❓", "🤔", "🙋"],
    "key": ["🔑", "🗝️", "🔓"],
    "lock": ["🔒", "🔐", "🔑"],
    "search": ["🔍", "👀", "🔎"],
    "up": ["⬆️", "📈", "🔺"],
    "down": ["⬇️", "📉", "🔻"],
    "chart": ["📊", "📈", "📉"],

    // MARK: - Water, weather, and the physical world
    // Added after "water" returned a water buffalo but neither droplet, and "wet" returned
    // nothing at all. A sweep of 257 words a person might plausibly type at a photograph found
    // 93 of them matching nothing; this section and the four below are that list, answered.
    "water": ["💧", "💦", "🌊", "🚰", "🥤"],
    "wet": ["💦", "💧", "🌧️", "☔"],
    "dry": ["🏜️", "🌵", "🧺"],
    "drip": ["💧", "💦"],
    "splash": ["💦", "🌊", "💧"],
    "thirsty": ["🥤", "💧", "🫗"],
    "dirt": ["🪨", "🌱", "🧹"],
    "mud": ["🪨", "🌧️"],
    "dust": ["🧹", "💨"],
    "rock": ["🪨", "⛰️", "🎸"],
    "stone": ["🪨", "💎"],
    "metal": ["⚙️", "🔩", "🪙"],
    "wood": ["🪵", "🌳"],
    "plastic": ["🧴", "♻️"],
    "trash": ["🗑️", "♻️"],
    "burn": ["🔥", "🥵", "🧯"],
    "smoke": ["💨", "🌫️", "🚬"],
    "windy": ["💨", "🌬️", "🍃"],
    "fog": ["🌫️", "🌁"],
    "freeze": ["🥶", "❄️", "🧊"],
    "melt": ["🫠", "🍦", "🔥"],
    "warm": ["🌞", "☕", "🧣"],
    "warmth": ["🔥", "☕", "🧣"],
    "weather": ["🌤️", "🌧️", "⛅", "🌡️"],
    "climate": ["🌍", "🌡️", "♻️"],
    "season": ["🍂", "🌸", "❄️", "☀️"],
    "autumn": ["🍂", "🍁", "🎃"],
    "fall": ["🍂", "🍁"],
    "spring": ["🌸", "🌱", "🌷"],
    "shadow": ["🌑", "🕶️"],
    "blur": ["🌫️", "😵‍💫"],
    "shine": ["✨", "🌟", "💫"],
    "glow": ["✨", "🌟", "🕯️"],
    "bright": ["☀️", "✨", "🔆"],
    "dark": ["🌑", "🌚", "🕶️"],
    "color": ["🎨", "🌈"],
    "grey": ["🩶", "☁️"],
    "gray": ["🩶", "☁️"],
    "pink": ["🩷", "🌸", "💗"],
    "sky": ["☁️", "🌤️", "🌌"],
    "lake": ["🏞️", "🦆"],
    "river": ["🏞️", "🌊"],
    "forest": ["🌲", "🌳", "🍃"],
    "grass": ["🌱", "🌿", "🍀"],
    "fruit": ["🍎", "🍌", "🍇", "🍓"],

    // MARK: - Time of day, and the calendar people actually say out loud
    "morning": ["🌅", "☕", "🌞"],
    "noon": ["🌞", "🕛"],
    "evening": ["🌆", "🌙"],
    "tonight": ["🌙", "🌃", "✨"],
    "today": ["📅", "🗓️"],
    "tomorrow": ["📅", "⏭️"],
    "yesterday": ["📅", "⏮️"],
    "weekend": ["🎉", "🛌", "🍻"],
    "monday": ["📅", "😩", "☕"],
    "anniversary": ["💍", "🥂", "❤️"],
    "holiday": ["🏖️", "✈️", "🎄"],
    "christmas": ["🎄", "🎅", "🎁"],
    "halloween": ["🎃", "👻", "🦇"],
    "newyear": ["🎆", "🥂", "🎊"],
    "valentine": ["❤️", "🌹", "💘"],
    "memory": ["📷", "💭", "🖼️"],
    "moment": ["⏳", "📷", "✨"],
    "forever": ["♾️", "💍", "❤️"],
    "never": ["🚫", "❌"],
    "always": ["♾️", "💯"],

    // MARK: - Moving, resting, and everything between
    "walk": ["🚶", "👟"],
    "jump": ["🤸", "🦘"],
    "climb": ["🧗", "🪜", "⛰️"],
    "fly": ["✈️", "🕊️", "🦋"],
    "ride": ["🚴", "🛵", "🏇"],
    "sail": ["⛵", "🌊"],
    "dive": ["🤿", "🏊", "🌊"],
    "hike": ["🥾", "⛰️", "🎒"],
    "sit": ["🪑", "🧘"],
    "stand": ["🧍"],
    "wake": ["⏰", "🌅", "😴"],
    "dream": ["💭", "😴", "🌙"],
    "rest": ["😴", "🛌", "🧘"],
    "relax": ["🧘", "🛀", "😌"],
    "chill": ["🧊", "😎", "🧘"],
    "vibe": ["✨", "🎶", "😎"],
    "mood": ["😌", "🎭", "✨"],
    "fast": ["⚡", "🏃", "🏎️"],
    "slow": ["🐌", "🐢"],
    "lazy": ["🦥", "😴", "🛋️"],
    "cozy": ["🕯️", "🛋️", "🧣"],
    "comfort": ["🤗", "🛋️", "☕"],

    // MARK: - People, and how they come in groups
    "mom": ["👩", "💐", "❤️"],
    "dad": ["👨", "👔"],
    "sister": ["👭", "👩"],
    "brother": ["👬", "👦"],
    "kid": ["🧒", "👦", "👧"],
    "couple": ["💑", "💏", "❤️"],
    "group": ["👥", "🧑‍🤝‍🧑", "🎉"],
    "crowd": ["👥", "🏟️"],
    "alone": ["🧍", "🥺", "🌑"],
    "brave": ["🦁", "💪", "🫡"],
    "shy": ["😳", "🙈", "🥺"],
    "calm": ["😌", "🧘", "🕊️"],
    "soul": ["👻", "✨", "❤️"],
    "spirit": ["👻", "✨", "🕊️"],
    "weak": ["🥺", "🫠"],
    "healthy": ["🥗", "💪", "🍎"],
    "maybe": ["🤷", "🤔"],
    "help": ["🆘", "🙏", "🚨"],
    "lose": ["😞", "👎", "💔"],
    "fight": ["🥊", "👊", "⚔️"],
    "team": ["🤝", "🧑‍🤝‍🧑", "🏆"],
    "goal": ["🥅", "🎯", "🏆"],
    "score": ["🎯", "🏆", "🥅"],
    "emergency": ["🚨", "🆘", "🚑"],
    "funeral": ["⚱️", "🕊️", "🖤"],

    // MARK: - Places and things around the house
    "deadline": ["⏰", "📅", "😰"],
    "meeting": ["💼", "📅", "🧑‍💻"],
    "laptop": ["💻", "⌨️"],
    "kitchen": ["🍳", "🔪", "🏠"],
    "bathroom": ["🚿", "🛁", "🚽"],
    "room": ["🛋️", "🛏️", "🚪"],
    "door": ["🚪", "🔑"],
    "window": ["🪟"],
    "garden": ["🪴", "🌷", "🏡", "🌻"],
    "road": ["🛣️", "🚗"],
    "street": ["🛣️", "🏙️", "🚦"],
    "town": ["🏘️", "🏙️"],
    "village": ["🏘️", "🌾"],
    "bed": ["🛏️", "😴"],
    "boat": ["⛵", "🛥️", "🚤"],
    "paint": ["🎨", "🖌️", "🖼️"],
    "hospital": ["🏥", "🚑", "💊"],
    "sleepy": ["😪", "😴", "🥱"],
    "free": ["🆓", "🕊️"],
    "full": ["🍽️", "😋", "🌕"],
]

/// `emojiSearchAliases` read the other way round: emoji → the keywords that should find it. Built
/// once per `generate()` pass rather than stored, so the table above stays the single place any of
/// this is maintained.
func aliasTokensByEmoji() -> [String: [String]] {
    var inverted: [String: [String]] = [:]
    for (keyword, emojis) in emojiSearchAliases {
        for emoji in emojis {
            inverted[emoji, default: []].append(keyword)
        }
    }
    // Dictionary iteration order is not stable, and these end up in a user-visible ranking, so
    // sort: two runs of the same build must produce the same tokens in the same order.
    return inverted.mapValues { $0.sorted() }
}

/// Runs entirely off the actor: called from inside `Task.detached`, touches no actor state, so it
/// never needs to hop onto `EmojiCatalog`'s executor just to compute.
private func generate() -> EmojiCatalogData {
    var byCategory: [String: [String]] = [:]
    var tokensByEmoji: [String: [String]] = [:]
    var seen = Set<String>()
    let probe = RenderProbe()
    let aliases = aliasTokensByEmoji()

    func add(_ text: String, to category: String, tokens: [String]) {
        guard !text.isEmpty, seen.insert(text).inserted else { return }
        byCategory[category, default: []].append(text)
        var deduped: [String] = []
        var dedupedSeen = Set<String>()
        for token in withStems(tokens + (aliases[text] ?? [])) where dedupedSeen.insert(token).inserted {
            deduped.append(token)
        }
        tokensByEmoji[text] = deduped
    }

    for range in scanRanges {
        for value in range {
            guard let scalar = Unicode.Scalar(value), isStandalonePictograph(scalar) else { continue }
            let text = scalar.properties.isEmojiPresentation ? String(scalar) : "\(scalar)\u{FE0F}"
            guard probe.renders(text) else { continue }
            add(text, to: category(for: scalar), tokens: emojiSearchTokens(for: text))
        }
    }

    let regionalIndicators = (0..<26).compactMap { Unicode.Scalar(0x1F1E6 + $0) }
    for first in regionalIndicators {
        for second in regionalIndicators {
            let text = "\(first)\(second)"
            guard probe.renders(text) else { continue }
            add(text, to: "Flags", tokens: flagSearchTokens(for: text))
        }
    }

    for flag in subdivisionFlags where probe.renders(flag.text) {
        add(flag.text, to: "Flags", tokens: wordTokens(flag.name))
    }

    for base in keycapBases {
        let text = "\(base)\u{FE0F}\u{20E3}"
        guard probe.renders(text) else { continue }
        add(text, to: "Symbols", tokens: keycapSearchTokens(base: base, text: text))
    }

    for template in zwjTemplates where probe.renders(template.text) {
        add(template.text, to: template.category, tokens: emojiSearchTokens(for: template.text))
    }

    let sections = categoryOrder.compactMap { name in
        byCategory[name].map { EmojiCategory(name: name, emojis: $0) }
    }
    return EmojiCatalogData(sections: sections, tokens: tokensByEmoji)
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

/// Lowercase search words extracted from `text`'s Unicode character name(s), via
/// `CFStringTransform(_, _, kCFStringTransformToUnicodeName, _)`. Free, device-derived, and
/// self-updating from the OS's own Unicode tables, unlike a bundled keyword file. Works
/// identically for a plain scalar ("😀" → "grinning", "face") and a ZWJ sequence ("🧑‍🚀" →
/// "astronaut", from ASTRONAUT's own name, joined with "person" from 🧑's), because the transform
/// names every scalar in `text` and this just walks all of them. Not `private`: exercised directly
/// by `EmojiCatalogTests` as a pure function, and used for both single scalars and ZWJ sequences.
func emojiSearchTokens(for text: String) -> [String] {
    let mutable = NSMutableString(string: text)
    guard CFStringTransform(mutable, nil, kCFStringTransformToUnicodeName, false) else { return [] }
    let named = mutable as String

    var tokens: [String] = []
    var seen = Set<String>()
    var index = named.startIndex
    while let open = named.range(of: "\\N{", range: index..<named.endIndex),
          let close = named.range(of: "}", range: open.upperBound..<named.endIndex) {
        let componentName = named[open.upperBound..<close.lowerBound]
        index = close.upperBound
        guard !isNoiseComponentName(componentName) else { continue }
        for token in wordTokens(String(componentName)) where seen.insert(token).inserted {
            tokens.append(token)
        }
    }
    return tokens
}

/// Component names that are Unicode machinery, not anything a person would type: the variation
/// selectors that pick text vs. emoji presentation, the zero-width joiner that stitches a ZWJ
/// sequence together, the combining mark that turns a digit into a keycap, and the bare
/// regional-indicator letters that make up a flag pair (flags get real names from
/// `flagSearchTokens` instead, since "REGIONAL INDICATOR SYMBOL LETTER U" means nothing to search).
private func isNoiseComponentName<S: StringProtocol>(_ name: S) -> Bool {
    let upper = name.uppercased()
    return upper.hasPrefix("VARIATION SELECTOR")
        || upper == "ZERO WIDTH JOINER"
        || upper == "COMBINING ENCLOSING KEYCAP"
        || upper.hasPrefix("REGIONAL INDICATOR SYMBOL LETTER")
}

/// A country flag's search tokens: its ISO 3166-1 alpha-2 region code, and the words of its
/// localized region name, e.g. 🇺🇸 → "us", "united", "states". Unicode's own name for a flag pair is
/// useless for search ("REGIONAL INDICATOR SYMBOL LETTER U, LETTER S"), but a flag IS its region
/// code, so this decodes the pair back to the two letters and asks `Locale` instead. Falls back to
/// the region code alone if `Locale` doesn't recognize it (a real regional-indicator pair the font
/// renders but that isn't a currently assigned ISO region, which does happen).
func flagSearchTokens(for text: String) -> [String] {
    guard let code = regionCode(forFlag: text) else { return [] }
    var tokens = [code.lowercased()]
    if let name = Locale.current.localizedString(forRegionCode: code) {
        tokens += wordTokens(name)
    }
    return tokens
}

/// Decodes a two-scalar regional-indicator flag back to its ISO 3166-1 alpha-2 region code, e.g.
/// 🇺🇸 → "US". Each regional-indicator scalar encodes a Latin letter as an offset from
/// `U+1F1E6` (which stands for "A"), so subtracting that base and re-adding `"A"`'s own value
/// recovers the letter. Returns `nil` for anything that isn't exactly a two-scalar
/// regional-indicator pair, which covers the subdivision and ZWJ flags; those get their tokens from
/// their own listed name instead. Not `private`: exercised directly by `EmojiCatalogTests`.
func regionCode(forFlag text: String) -> String? {
    let scalars = Array(text.unicodeScalars)
    guard scalars.count == 2 else { return nil }
    var letters = ""
    for scalar in scalars {
        guard (0x1F1E6...0x1F1FF).contains(scalar.value),
              let letter = Unicode.Scalar(scalar.value - 0x1F1E6 + Unicode.Scalar("A").value) else {
            return nil
        }
        letters.append(Character(letter))
    }
    return letters
}

/// A keycap's search tokens: whatever `emojiSearchTokens` pulls from its Unicode component names,
/// plus the base character itself. In practice that first part contributes nothing useful, because
/// `CFStringTransform`'s Unicode-name transform only wraps scalars in `\N{...}` when they don't
/// already print as themselves; plain ASCII digits, `#`, and `*` are left bare, so
/// `emojiSearchTokens(for: "3\u{FE0F}\u{20E3}")` sees only the (filtered-out) variation selector
/// and combining keycap mark and finds no name for the "3" at all. Appending the base character
/// directly is what makes typing "3" actually find 3️⃣. Not `private`: exercised directly by
/// `EmojiCatalogTests` as a pure function.
func keycapSearchTokens(base: Character, text: String) -> [String] {
    emojiSearchTokens(for: text) + [String(base).lowercased()]
}

/// A crude, deliberately symmetric suffix stem: "smiling" and "smile" both reduce to "smil",
/// "laughing" and "laugh" to "laugh", "dogs" to "dog". Nothing here is linguistics — it strips
/// `-ing`/`-ed`, then a plural `-s`/`-es`, then a silent `-e`, then an undoubled consonant
/// ("running" → "runn" → "run") — and it does not need to be, because it is only ever applied to
/// BOTH sides of a comparison. A stem that is wrong in the same way for the token and the query
/// still matches them to each other, which is the entire job.
///
/// It exists because the catalog's tokens come from Unicode's own frozen, formal names, which are
/// full of participles a person would never type: 😊 is SMILING FACE WITH SMILING EYES, so before
/// this, typing the actual word "smile" found nothing at all, while "smiling" found twenty. Each
/// rule only fires if at least three characters survive, so short words are left alone ("eye" stays
/// "eye" rather than collapsing into "ey", and "ice" stays "ice").
///
/// Stems are stored ALONGSIDE the real words at generation time (see `withStems`), never in place
/// of them, so an exact word match still outranks a stem match. Not `private`: exercised directly
/// by `EmojiCatalogTests`, and used by `emojiSearchRank` to stem the query the same way.
func searchStem(_ word: String) -> String {
    var stem = Substring(word)
    @discardableResult
    func drop(_ count: Int) -> Bool {
        guard stem.count - count >= 3 else { return false }
        stem = stem.dropLast(count)
        return true
    }
    if stem.hasSuffix("ing") { drop(3) } else if stem.hasSuffix("ed") { drop(2) }
    if stem.hasSuffix("es") {
        if !drop(2) { drop(1) }          // "eyes" → "eye", not the two-letter "ey"
    } else if stem.hasSuffix("s") {
        drop(1)
    }
    if stem.hasSuffix("e") { drop(1) }
    if let last = stem.last, stem.dropLast().last == last, !"aeiou".contains(last) { drop(1) }
    return String(stem)
}

/// `tokens` plus each one's `searchStem`, when the stem differs from the word itself. Precomputing
/// these into the stored token list is what keeps search cheap: `emojiSearchRank` then stems only
/// the query, once per keystroke, instead of stemming every token of all ~3,500 entries on every
/// keystroke. Order is preserved and stems are appended, never substituted.
func withStems(_ tokens: [String]) -> [String] {
    var out: [String] = []
    out.reserveCapacity(tokens.count * 2)
    for token in tokens {
        out.append(token)
        let stem = searchStem(token)
        if stem != token { out.append(stem) }
    }
    return out
}

/// Splits any string into lowercase word tokens, breaking on anything that isn't a letter or digit
/// (spaces, hyphens, apostrophes, commas), e.g. "Côte d'Ivoire" → "côte", "d", "ivoire". Shared by
/// every token source in this file (Unicode component names, locale region names, the subdivision
/// flag names, keycap bases) so they all tokenize identically.
func wordTokens(_ text: String) -> [String] {
    text.lowercased()
        .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        .map(String.init)
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

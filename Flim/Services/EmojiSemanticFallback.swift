import Foundation
import NaturalLanguage

/// The second, unsupervised half of the reaction bar's label to emoji resolution: everything
/// `EmojiLabelMap` deliberately never learned.
///
/// The hand table is 471 entries against a 1,303-entry Vision taxonomy, so ~830 labels that clear
/// the precision floor resolve to nothing at all today. This fills some of that gap from the CLDR
/// annotation corpus already bundled for emoji search (`emoji-keywords.txt`, 4,342 emoji, ~37,860
/// keywords) plus `NLEmbedding`'s on-device word vectors, so a `concert` photo can reach 🎵 without
/// anyone hand-mapping the word "concert".
///
/// Three properties this must keep, in priority order:
///
/// 1. It is strictly additive. `EmojiSuggestion.pick` runs the curated table over every qualifying
///    label FIRST and only then offers the leftovers here, so no measured behaviour of the hand
///    table changes and a guess can never displace, reorder, or outrank a hand-checked answer.
/// 2. It refuses far more than it answers. The governing rule is the one already written into
///    `EmojiSuggestion`: a wrong emoji next to someone's photo is worse than a blank slot. See
///    `isExcluded(_:)` and `deniedLabels` for the two deny policies that implement that.
/// 3. It is synchronous, allocation-bounded, and never throws. `EmojiSuggestion.suggest` calls it
///    from a fire-and-forget `Task.detached(priority: .utility)`; `NLEmbedding.wordEmbedding` can
///    return nil (locale asset missing or evicted) and that degrades to "no suggestion", never to
///    a crash and never to a wait.
///
/// The keyword resource is re-parsed here (`buildIndex`, about ten lines) rather than reached for
/// through `EmojiCatalog`, which parses the same file. That is on purpose. `EmojiCatalog` is a
/// heavyweight actor whose generation pass font-render-probes every scalar in Unicode to decide
/// what the picker may show; awaiting it would put an actor hop plus that probe on the capture
/// path, and would make this type async for no benefit. Ten lines of duplicated `split` is the
/// cheaper coupling. The two parses are independent by design: this one keeps only what is safe to
/// GUESS, the catalog keeps everything a person may deliberately pick.
enum EmojiSemanticFallback {

    /// One emoji for one Vision identifier, or nil, which is the common and preferred answer.
    ///
    /// Resolution order, first hit wins:
    /// 1. the whole label as a phrase (`amusement_park` becomes "amusement park"),
    /// 2. the label's head noun alone ("park"),
    /// 3. the head noun's nearest embedding neighbours, subject to the agreement rule in
    ///    `semanticNeighbour(of:)`.
    ///
    /// Only the head (last) word is ever looked up on its own. English compound labels are
    /// head-final, and trying every word is what produced the worst misses in the taxonomy sweep
    /// that calibrated this file: `high_chair` resolved through "high" to ⚡, `go_kart` through
    /// "go" to 💨, `ice_cream` through "ice" to ⛸, `green_beans` through "green" to 🍏. Dropping
    /// the non-head words removed that entire class at the cost of nothing that was right.
    ///
    /// Vision spells its catch-all leaves `<thing>_other` (`chair_other`, `candy_other`); the
    /// suffix is noise, not a noun, so it is stripped before any lookup.
    static func emoji(forLabel label: String) -> String? {
        guard !label.isEmpty, !deniedLabels.contains(label) else { return nil }
        var words = label.split(separator: "_").map(String.init)
        if words.count > 1, words.last == "other" { words.removeLast() }
        guard let head = words.last else { return nil }
        if words.count > 1, let phraseHit = index[words.joined(separator: " ")] { return phraseHit }
        if let headHit = index[head] { return headHit }
        return semanticNeighbour(of: head)
    }

    // MARK: - Deny policy

    /// Whether this glyph may never be suggested, whatever the corpus says about it.
    ///
    /// Exposed rather than private because it is the guardrail worth testing directly, and
    /// `EmojiSuggestionFallbackTests` asserts it holds across Vision's entire published taxonomy.
    ///
    /// Applied when the reverse index is BUILT, not when it is read, so an excluded emoji cannot
    /// squat a keyword that an allowed emoji also carries: dropping ⛹ at build time is what lets
    /// "ball" still reach ⚽.
    ///
    /// Deliberately NOT applied to `EmojiLabelMap`. The curated table maps `swimming` to 🏊 and
    /// `dancing` to 💃 on purpose, and a hand-checked mapping is a different bar from a guess. The
    /// exclusions below govern guesses only.
    static func isExcluded(_ emoji: String) -> Bool {
        for scalar in emoji.unicodeScalars {
            if excludedScalars.contains(scalar.value) { return true }
            for range in excludedRanges where range.contains(scalar.value) { return true }
        }
        return false
    }

    /// Whole scalar ranges no guess may land in. A sequence is excluded if ANY of its scalars is,
    /// which is what makes ZWJ families, skin-tone variants, and subdivision flags fall out for
    /// free (the corpus carries 1,614 ZWJ sequences and 2,035 tone variants, mostly of people).
    ///
    /// Add a range here to extend the policy; nothing else needs to change.
    private static let excludedRanges: [ClosedRange<UInt32>] = [
        0x1F1E6...0x1F1FF,  // regional indicators: every country flag
        0xE0020...0xE007F,  // tag characters: England/Scotland/Wales subdivision flags
        0x1F3FB...0x1F3FF,  // skin tone modifiers
        0x1F440...0x1F450,  // eyes, ear, nose, tongue, mouth, and every pointing/gesturing hand
        0x1F464...0x1F487,  // busts, people, families, roles, and body parts
        0x1F574...0x1F596,  // suited figures, detective, raised hands, vulcan salute
        0x1F600...0x1F64F,  // faces and gesturing people: a classifier cannot see a mood, and the
                            // reaction bar's fixed slots are already ❤️🔥😂
        0x1F3C2...0x1F3C4,  // snowboarder, runner, surfer
        0x1F3CA...0x1F3CC,  // swimmer, weightlifter, golfer
        0x1F6B4...0x1F6BC,  // cyclists, pedestrian signage, restroom signage, baby symbol
        0x1F90C...0x1F93E,  // later hand gestures, more faces, and people-doing-things
        0x1F970...0x1F97A,  // later faces
        0x1F9B0...0x1F9BF,  // hair components, body parts, prosthetics
        0x1F9CC...0x1F9DF,  // troll and every later person or human-shaped figure
        0x1FAC0...0x1FAC5,  // anatomical heart, lungs, people hugging, person with crown
        0x1FAE0...0x1FAE8,  // later faces
        0x1FAF0...0x1FAF8,  // later hands
        0x2648...0x2653,    // zodiac signs: identity claims, not scene content
    ]

    /// Single scalars excluded by category. Grouped by the reason, so extending the policy is a
    /// matter of finding the right group rather than reasoning about the whole list.
    private static let excludedScalars: Set<UInt32> = [
        // Human figures outside the ranges above.
        0x1F3C7, 0x1F6A3, 0x1F6C0, 0x1F6CC, 0x26F7, 0x26F9,
        // Flags of any kind, including the plain and racing ones.
        0x1F3C1, 0x1F3F3, 0x1F3F4, 0x1F6A9, 0x1F38C,
        // Weapons.
        0x1F52A, 0x1F52B, 0x1F5E1, 0x2694, 0x1F3F9, 0x1FA93, 0x1F4A3, 0x1F9E8, 0x1F6E1, 0x1FA83, 0x1FA96,
        // Medical, injury, illness.
        0x1F489, 0x1F48A, 0x1FA78, 0x1FA79, 0x1FA7A, 0x1FA7B, 0x1FA7C, 0x2695, 0x1F9A0, 0x1F3E5,
        0x1F691, 0x1F637,
        // Religious symbols and places of worship.
        0x271D, 0x2626, 0x262A, 0x2721, 0x1F549, 0x2638, 0x262F, 0x1F52F, 0x1F54B, 0x1F54C, 0x1F54D,
        0x1F54E, 0x26EA, 0x26E9, 0x1F6D5, 0x1F6D0, 0x1F4FF, 0x26CE,
        // Death and funerals. Not in the required list, same failure mode, cheap to refuse.
        0x2620, 0x26B0, 0x26B1, 0x1FAA6,
        // Smoking and age gating.
        0x1F6AC, 0x1F51E,
        // Underwear and swimwear: body-adjacent in a way ordinary clothing is not.
        0x1F459, 0x1FA71, 0x1FA72, 0x1FA73, 0x1FA74,
        // Zero-width joiner: every joined sequence in this corpus is a person, a family, a
        // profession, or a mood. Excluding the joiner itself covers all of them at once.
        0x200D,
    ]

    /// Vision identifiers this may never answer for, even though the corpus has something to say.
    ///
    /// Two kinds of entry, both found by running all 1,303 identifiers from
    /// `VNClassifyImageRequest().supportedIdentifiers()` through this resolver and reading the
    /// output by hand:
    ///
    /// - identity-adjacent labels, refused for the same reason `EmojiLabelMap` refuses to map
    ///   `people` and `adult`: there is no emoji it is ever appropriate to guess about a person;
    /// - labels where the corpus answer is confidently wrong, almost always because the label's
    ///   head noun is a different sense of the same word (a baseball bat is not 🦇, a circuit
    ///   board is not 🎬, a golf club is not ♣) or because the label names a species with no
    ///   emoji of its own and the embedding hands back the wrong animal (cheetah to 🦛).
    ///
    /// This is a refusal list, never a mapping: adding a label here can only ever remove a
    /// suggestion. That is why it is allowed to grow, and it is the right place to put anything
    /// the field turns up.
    private static let deniedLabels: Set<String> = [
        // Identity-adjacent.
        "adult", "baby", "child", "crowd", "people", "teen", "wheelchair",
        // Categorically refused subjects.
        "flag", "flagpole", "knife", "sword", "medicine",
        // Polysemous single words whose corpus winner is the other sense.
        "bar", "bench", "bottle", "closet", "dam", "flipper", "insect", "light", "machine",
        "media", "nut", "pen", "pipe", "pole", "pool", "record", "sand", "sign", "spice", "suit",
        "table", "workout",
        // Compounds whose head noun means something else on its own.
        "baseball_bat", "candy_cane", "cardboard_box", "circuit_board", "computer_tower",
        "cutting_board", "drone_machine", "gas_mask", "golf_club", "health_club", "jack_o_lantern",
        "laundry_machine", "license_plate", "measuring_tape", "paper_bag", "pepper_veggie",
        "prairie_dog", "raw_glass", "rice_field", "rolling_pin", "stained_glass", "sticky_note",
        "street_sign", "stuffed_animals", "watering_can", "wood_natural",
        // Species with no emoji of their own; the nearest embedding neighbour is another animal.
        "cheetah", "chinchilla", "ferret", "hyena", "mackerel", "millipede", "moth", "sardine",
        "tuna", "urchin",
        // Audited wrong for reasons specific to the label.
        "apron", "chairlift", "windsurfing",
    ]

    // MARK: - Semantic neighbours

    /// How many neighbours to ask for. Past roughly this depth the returned words are topical
    /// co-occurrence rather than meaning ("library" reaches "bequest"), and the agreement rule
    /// below is what actually decides, so a wider net costs precision nothing.
    private static let neighbourCount = 25
    /// Cosine distance past which a neighbour is not considered at all.
    ///
    /// Measured, not guessed: across the label vocabulary this feature sees, `NLEmbedding`'s
    /// distances run from about 0.5 (true synonyms) to 1.1 (same paragraph, unrelated thing).
    /// 0.95 is where the lists stop being about the label at all. It is a coarse gate rather than
    /// the discriminator: `minimumAgreement` is what carries the precision here, and a ceiling
    /// tight enough to matter on its own (0.8 was tried) also loses the cases this exists for,
    /// including "concert" reaching "music" at 0.87.
    private static let neighbourCeiling = 0.95
    /// How many distinct neighbours must land on the SAME emoji before it is offered.
    ///
    /// The single most valuable rule in this file. Taking the closest neighbour that happened to
    /// resolve produced confident nonsense at every ceiling tried: airport to ⛴ via "passenger",
    /// bedroom to 🚽 via "bathroom" at a distance of only 0.67, crutch to 🍗 via "leg". Requiring
    /// two independent neighbours to agree removed all three and cut the taxonomy's semantic hits
    /// from 247 to 96, which is the trade this feature is supposed to make.
    private static let minimumAgreement = 2

    /// The winner of a small vote among the word's nearest neighbours, or nil if nothing agreed.
    ///
    /// Ties are impossible to observe: `order` records first appearance, neighbours arrive sorted
    /// by increasing distance, and the scan keeps a candidate only on a strictly greater count, so
    /// the closest of any equally-voted candidates always wins. Two runs of the same build on the
    /// same input therefore always return the same emoji.
    private static func semanticNeighbour(of word: String) -> String? {
        guard let embedding = Self.embedding else { return nil }
        var order: [String] = []
        var votes: [String: Int] = [:]
        for (neighbour, distance) in embedding.neighbors(for: word, maximumCount: neighbourCount) {
            guard distance <= neighbourCeiling else { break }
            guard let candidate = index[neighbour.lowercased()] else { continue }
            if votes[candidate] == nil { order.append(candidate) }
            votes[candidate, default: 0] += 1
        }
        var winner: String?
        var winningVotes = 0
        for candidate in order where votes[candidate, default: 0] > winningVotes {
            winner = candidate
            winningVotes = votes[candidate, default: 0]
        }
        return winningVotes >= minimumAgreement ? winner : nil
    }

    /// Built once per process, lazily, on whichever thread asks first. Nil when the English word
    /// vectors are not installed, which is a supported state: `emoji(forLabel:)` then answers from
    /// the corpus alone.
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    // MARK: - Reverse index

    /// Lowercased CLDR keyword to the single emoji that keyword should resolve to.
    ///
    /// One `static let` for the process. Building it parses 4,342 lines and reads a Unicode name
    /// per emoji, a few tens of milliseconds once, off the main thread, on the first suggestion of
    /// the session. Lookups after that are dictionary hits.
    private static let index: [String: String] = buildIndex()

    /// The corpus format is one line per emoji: `emoji\tkeyword|keyword|keyword`. Same file and
    /// same shape `EmojiCatalog.cldrKeywordsBySkeleton()` reads; see this type's doc for why it is
    /// read twice rather than shared.
    ///
    /// A keyword is usually claimed by several emoji ("music" by 23 of them), so the winner has to
    /// be chosen, and chosen the same way every run. In order:
    ///
    /// 1. the emoji whose own Unicode name ENDS in that keyword, since the last word of an emoji's
    ///    name is what it depicts: this is what sends "cake" to 🎂 (BIRTHDAY CAKE) instead of 🍥
    ///    (FISH CAKE WITH SWIRL), and "note" to 🎵 rather than 🗒;
    /// 2. failing that, an emoji whose name merely contains the keyword ("music" to 🎵, MUSICAL
    ///    NOTE, ahead of 🎙, STUDIO MICROPHONE, which only lists it as an annotation);
    /// 3. failing that, the emoji with the shortest name, which prefers the plain glyph over the
    ///    specific one (🥐 CROISSANT over 🍥 FISH CAKE WITH SWIRL for "pastry");
    /// 4. failing that, corpus order, which is codepoint order and fixed in the bundled file.
    ///
    /// Every rule is total and data-only, so the table is identical on every launch of a build.
    ///
    /// Two things are dropped outright. Non-pictographs, because the corpus also annotates
    /// punctuation, currency, arrows, and maths symbols ("bar" would otherwise resolve to ⏸), and
    /// anything `isExcluded(_:)` refuses.
    ///
    /// Keywords too generic to mean anything are dropped as well: if more than six emoji claim a
    /// keyword and not one of them is named after it, it is a category word ("food", "clothing",
    /// "tool", "fruit") whose winner would be arbitrary, so no one gets it.
    private static func buildIndex() -> [String: String] {
        struct Candidate { var emoji: String; var rank: Int; var nameLength: Int }
        guard let url = Bundle.main.url(forResource: "emoji-keywords", withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var best: [String: Candidate] = [:]
        var claimants: [String: Int] = [:]
        best.reserveCapacity(4500)
        for line in raw.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let emoji = String(line[..<tab])
            guard isPictograph(emoji), !isExcluded(emoji) else { continue }
            let nameWords = nameWords(of: emoji)
            for field in line[line.index(after: tab)...].split(separator: "|") {
                let keyword = field.lowercased()
                guard !keyword.isEmpty else { continue }
                claimants[keyword, default: 0] += 1
                let candidate = Candidate(emoji: emoji,
                                          rank: nameRank(of: keyword, in: nameWords),
                                          nameLength: nameWords.count)
                guard let winner = best[keyword] else { best[keyword] = candidate; continue }
                if candidate.rank < winner.rank
                    || (candidate.rank == winner.rank && candidate.nameLength < winner.nameLength) {
                    best[keyword] = candidate
                }
            }
        }
        var index: [String: String] = [:]
        index.reserveCapacity(best.count)
        for (keyword, candidate) in best {
            guard candidate.rank < 2 || claimants[keyword, default: 0] <= 6 else { continue }
            index[keyword] = candidate.emoji
        }
        return index
    }

    /// Emoji only. The corpus keys 412 entries that are not pictographs at all (ASCII punctuation,
    /// currency signs, arrows, keycaps, set-theory symbols) and a handful of codepoints too new
    /// for the running OS to have a glyph for. `isEmoji` alone still admits `#` and `©`, so the
    /// plane check does the rest.
    private static func isPictograph(_ emoji: String) -> Bool {
        guard let first = emoji.unicodeScalars.first else { return false }
        return first.properties.isEmoji && first.value > 0x2100
    }

    /// The emoji's own Unicode name, lowercased and split into words. Empty when the running OS
    /// has no name for the scalar, which downgrades that emoji to the corpus-order tie-break.
    private static func nameWords(of emoji: String) -> [String] {
        guard let name = emoji.unicodeScalars.first?.properties.name else { return [] }
        return name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    /// 0 when the keyword is the last word of the name, 1 when it appears anywhere else in it,
    /// 2 when the name does not mention it. A trailing "s"/"es" still counts as the same word, so
    /// "note" matches MULTIPLE MUSICAL NOTES and "music" matches MUSICAL NOTE.
    private static func nameRank(of keyword: String, in nameWords: [String]) -> Int {
        func matches(_ word: String) -> Bool {
            word == keyword || (word.hasPrefix(keyword) && word.count - keyword.count <= 2)
        }
        guard let last = nameWords.last else { return 2 }
        if matches(last) { return 0 }
        return nameWords.contains(where: matches) ? 1 : 2
    }
}

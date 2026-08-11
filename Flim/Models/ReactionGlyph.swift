import Foundation

/// What a reaction CHIP draws for one emoji: the emoji itself if this device can draw it, or a
/// neutral placeholder standing in for a reaction sent from a phone whose OS knows a glyph this
/// one doesn't. `EmojiCatalog`'s picker grid can never hit the placeholder case (it's filtered by
/// the exact same render check at generation time), but a reaction is a string that arrived over
/// the network from whoever tapped it, possibly on a newer OS than the one displaying it. Widening
/// the picker's palette (see `EmojiCatalog.swift`) widened what a chip can be asked to draw too.
enum ReactionGlyph: Equatable {
    case emoji(String)
    /// `original` is always the exact string the reaction was stored/toggled with. The
    /// placeholder swaps only what's DRAWN, never what's toggled, so tapping it still reacts (or
    /// un-reacts) with whatever emoji the sender actually chose, and the count it sits next to
    /// still belongs to that same emoji.
    case placeholder(original: String)

    /// The string to react/un-react with. Always the original emoji, whether or not it renders.
    var toggleValue: String {
        switch self {
        case .emoji(let text): return text
        case .placeholder(let original): return original
        }
    }
}

/// The pure decision behind `ReactionGlyph`: draw `emoji` as itself if `renders` says this device
/// can, otherwise fall back to a placeholder that still carries the original string. `renders` is
/// injected rather than hardcoded to `RenderProbe` so this decision is unit-testable with a
/// stubbed answer — the real probe does an offscreen render and is device-dependent by design,
/// there is no way to force a real font "miss" from a test.
func reactionGlyph(for emoji: String, renders: (String) -> Bool) -> ReactionGlyph {
    renders(emoji) ? .emoji(emoji) : .placeholder(original: emoji)
}

/// Memoizes the real render probe (`RenderProbe`, `EmojiCatalog.swift`) by emoji string, so
/// reaction chips never re-run an offscreen render on every body evaluation. `@MainActor` because
/// every caller (`ReactionBar`, `ActivityFeedView`) already runs on the main thread — SwiftUI view
/// bodies — so this needs no locking of its own. The number of distinct emoji any set of visible
/// reactions carries is small (a handful per photo, at most a few dozen across an activity list),
/// so the cache never grows large in practice.
@MainActor
final class ReactionRenderabilityCache {
    static let shared = ReactionRenderabilityCache()

    private var cache: [String: Bool] = [:]
    private let probe: (String) -> Bool
    /// How many times `probe` (not the cache) has actually been asked. Exposed only so a test can
    /// prove memoization is happening, never read by production code.
    private(set) var probeCallCount = 0

    /// `probe` is a plain closure, not the concrete `RenderProbe`, so a test can inject a stubbed
    /// answer (and count calls) without touching a real, device-dependent font render.
    init(probe: @escaping (String) -> Bool) {
        self.probe = probe
    }

    /// One real `RenderProbe` created here and reused for every distinct emoji this cache ever
    /// sees, the same "expensive setup once, cheap checks after" shape `EmojiCatalog.generate()`
    /// uses for the identical reason.
    convenience init() {
        let probe = RenderProbe()
        self.init(probe: probe.renders)
    }

    func renders(_ emoji: String) -> Bool {
        if let cached = cache[emoji] { return cached }
        probeCallCount += 1
        let result = probe(emoji)
        cache[emoji] = result
        return result
    }
}

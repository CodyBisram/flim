import Foundation
import Supabase
import Vision

/// On-device classification that feeds the reaction bar's two contextual emoji slots.
///
/// Fire-and-forget instrumentation riding along a capture, same discipline as `Activation.log`:
/// nothing here is `async` or `throws` from the caller's side, nothing is awaited by the capture
/// pipeline, and every internal failure (a bad decode, Vision finding nothing, the network) is
/// swallowed with `try?` rather than surfaced. A dropped suggestion just leaves that photo's
/// reaction bar showing today's ordinary fallback two; it must never be able to slow down, delay,
/// or fail the capture it rides along with, which is the one thing on this path that cannot be
/// reproduced if lost.
///
/// `VNClassifyImageRequest` itself only genuinely runs on a real device. Measured on both an iOS
/// 18 and a current-OS Simulator: the default backend throws `"Failed to create espresso
/// context"` every time (caught by `try?` here, so this is already safe, just silent), and its
/// documented alternative (`usesCPUOnly`) doesn't fix that so much as paper over it, on the
/// Simulator it returns the identical top labels for every image regardless of content. Nothing
/// here can be verified for classification QUALITY off a physical device; see `EmojiSuggestionRealPhotoTests`.
enum EmojiSuggestion {
    /// `hasMinimumRecall(_:forPrecision:)`, not raw `confidence`: Vision's confidence numbers
    /// aren't comparable across its ~1,300 labels, so a bare threshold on them would accept and
    /// reject the wrong things depending on which label happened to fire. Asking "if this label
    /// fires, how often is it actually right" is the calibrated question, and 0.9 precision means
    /// at most roughly 1 in 10 accepted labels is a false positive. The trade for that is a low
    /// recall floor, plenty of real matches never clear the bar, which is the right trade here: a
    /// wrong emoji next to someone's photo is worse than a blank slot.
    private static let precisionFloor: Float = 0.9
    private static let recallFloor: Float = 0.01

    /// Classifies the RAW capture (never the graded output) and, if anything confidently mapped,
    /// writes it via `set_photo_suggested_emoji`. Fires and returns immediately.
    ///
    /// Classifying the raw bytes is deliberate, not incidental: FLIM's own grain and warm shift
    /// are exactly what degrades a classifier, and this is the one place in the pipeline where the
    /// untouched capture is still in memory once a photo has a row to attach a suggestion to (see
    /// `PhotoService.enqueueCapture`, the only caller).
    static func suggest(rawData: Data, photoId: UUID) {
        Task.detached(priority: .utility) {
            let emoji = classify(rawData)
            guard !emoji.isEmpty else { return }
            struct Params: Encodable { let p_photo_id: UUID; let p_emoji: [String] }
            _ = try? await supabase
                .rpc("set_photo_suggested_emoji", params: Params(p_photo_id: photoId, p_emoji: emoji))
                .execute()
        }
    }

    /// Up to two emoji for one image, most-confident first, never more than one per emoji.
    ///
    /// Vision returns all ~1,300 labels for every request, sorted by descending confidence,
    /// hierarchy and all (a lizard photo carries `lizard`, `reptile`, and `animal` as separate
    /// observations, each with its own confidence). Walking that full list rather than only its
    /// top entry is what gives this the hierarchy fallback the feature is built on: if the
    /// specific label misses the floor but a broader parent clears it, the broader label is still
    /// sitting further down the same sorted list and gets picked up there instead.
    static func classify(_ rawData: Data) -> [String] {
        let request = VNClassifyImageRequest()
        // NOT forced onto `usesCPUOnly`, on purpose, even though the default path throws
        // outright on every iOS Simulator tested (real device required, see this type's own
        // doc). Measured: forcing CPU-only silences that failure, but on the Simulator it then
        // returns the exact same "outdoor / night_sky / sky" result for every image regardless
        // of content, i.e. a confident WRONG answer rather than an honest empty one, which is
        // worse than what `try?` already gives this call for free. A real device's ordinary,
        // un-forced backend selection is Apple's own well-exercised default path and is what
        // every other app calling this request already relies on.
        let handler = VNImageRequestHandler(data: rawData, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }
        let qualifying = results
            .filter { $0.hasMinimumRecall(recallFloor, forPrecision: precisionFloor) }
            .map(\.identifier)
        return pick(fromQualifyingIdentifiers: qualifying)
    }

    /// The pure dedup/cap-at-2 picking rule, over identifiers that already cleared the
    /// precision/recall floor (most-confident first). Kept apart from `classify` so it's unit
    /// testable with plain strings: `VNClassificationObservation` has no public initializer, so
    /// nothing upstream of this point can be constructed in a test.
    static func pick(fromQualifyingIdentifiers identifiers: [String]) -> [String] {
        var picked: [String] = []
        var usedEmoji = Set<String>()
        for identifier in identifiers {
            guard picked.count < 2 else { break }
            guard let emoji = EmojiLabelMap.emoji(forLabel: identifier) else { continue }
            guard usedEmoji.insert(emoji).inserted else { continue }
            picked.append(emoji)
        }
        return picked
    }
}

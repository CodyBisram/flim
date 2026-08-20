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
    /// fires, how often is it actually right" is the calibrated question, and this floor means at
    /// most roughly 1 in 5 accepted labels is a false positive. The trade for that is a lower
    /// recall than a stricter floor would give, plenty of real matches still never clear the bar,
    /// which is the right trade here: a wrong emoji next to someone's photo is worse than a blank
    /// slot.
    ///
    /// 0.8, not the original 0.9. Measured (not guessed) by running `VNClassifyImageRequest`
    /// against the look-regression pin's 13 real photographs (`pairs/*_neutral.jpg`, on macOS,
    /// see `EmojiSuggestionRealPhotoTests`) at 0.9/0.8/0.7/0.6/0.5/0.4 and hand-checking every
    /// resulting emoji against the actual photo, not just the label list. 0.9 produced a
    /// suggestion for only 5 of 13 photos, of which 1 (an indoor neon sign against a fake-hedge
    /// wall, misread as "sky") was already wrong, a Vision misclassification no floor fixes,
    /// since it's wrong at the strictest floor tested. 0.8 lifts that to 7 of 13, adding a correct
    /// laptop/screen hit (the exact 🖥️💻 scenario production has already seen fire) alongside one
    /// new wrong one (an indoor restaurant booth misread as having sky overhead). Going lower, to
    /// 0.7, looked like a bigger win at first (13 of 13 photos get a suggestion) but four separate
    /// bedroom photos independently misfire "canine"/"dog" off rumpled bedding and a plush toy,
    /// and it POLLUTES an already-correct single-emoji answer (a bed photo that was cleanly just
    /// 🛏️ at 0.8) into a mixed-wrong 🛏️🐾 pair. 0.8 is the last floor before that pattern starts,
    /// so it's the one point on the curve that both actually moves recall and doesn't yet trade
    /// away a previously-clean answer.
    private static let precisionFloor: Float = 0.8
    /// Checked alongside `precisionFloor`, not just assumed: sweeping this from 0.01 up to 0.3 at
    /// precision 0.8 (or 0.7) changes NOTHING in the qualifying label set for any of the 13 test
    /// photos, identical counts start to finish. It only starts trimming anything past 0.3, and
    /// even then only labels this table doesn't map anyway (e.g. `housewares`, `tool`). At the
    /// precision this feature actually runs at, 0.01 is not a binding constraint, it's headroom
    /// against a genuinely obscure label clearing precision on almost no real photos, kept at its
    /// original value because raising it measurably does nothing today.
    private static let recallFloor: Float = 0.01

    /// Classifies the RAW capture (never the graded output) and, if anything confidently mapped,
    /// writes it via `set_photo_suggested_emoji`. Fires and returns immediately.
    ///
    /// Classifying the raw bytes is deliberate, not incidental: FLIM's own grain and warm shift
    /// are exactly what degrades a classifier, and this is the one place in the pipeline where the
    /// untouched capture is still in memory once a photo has a row to attach a suggestion to (see
    /// `PhotoService.enqueueCapture`, the only caller).
    ///
    /// - Parameter onWritten: called with the emoji once the RPC write actually lands, `@MainActor`
    ///   so the caller (`PhotoService`) can patch its own cache directly instead of that photo's
    ///   entry sitting stale until something re-fetches it. Never called if there was nothing to
    ///   write or the write failed, both of which already leave the caller's own state untouched.
    static func suggest(rawData: Data, photoId: UUID,
                        onWritten: @escaping @MainActor ([String]) -> Void = { _ in }) {
        Task.detached(priority: .utility) {
            let emoji = classify(rawData)
            guard !emoji.isEmpty else { return }
            struct Params: Encodable { let p_photo_id: UUID; let p_emoji: [String] }
            guard (try? await supabase
                .rpc("set_photo_suggested_emoji", params: Params(p_photo_id: photoId, p_emoji: emoji))
                .execute()) != nil
            else { return }
            await onWritten(emoji)
        }
    }

    /// Up to three emoji for one image, most-confident first, never more than one per emoji.
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

    /// The pure dedup/cap-at-3 picking rule, over identifiers that already cleared the
    /// precision/recall floor (most-confident first). Kept apart from `classify` so it's unit
    /// testable with plain strings: `VNClassificationObservation` has no public initializer, so
    /// nothing upstream of this point can be constructed in a test.
    static func pick(fromQualifyingIdentifiers identifiers: [String]) -> [String] {
        var picked: [String] = []
        var usedEmoji = Set<String>()
        for identifier in identifiers {
            guard picked.count < 3 else { break }
            guard let emoji = EmojiLabelMap.emoji(forLabel: identifier) else { continue }
            guard usedEmoji.insert(emoji).inserted else { continue }
            picked.append(emoji)
        }
        return picked
    }
}

import Foundation
import UIKit
import Vision

/// Runs the Vision requests behind `ChapterCurator.select`, off the main actor.
///
/// A plain `actor`, not `@MainActor`: this does CPU-bound image analysis, and possibly a network
/// fetch per photo, for up to a thousand photos in a month, none of which touches view state
/// directly. Scores and feature prints are cached per photo id for the session, so re-opening the
/// same month's recap redoes no work and re-downloads no bytes. `ChapterCurationCache`, one layer
/// up in `ChapterRecapViewModel`, is what makes a LATER session (a relaunch) skip this actor
/// entirely for a month that has already ended.
///
/// Split from `ChapterCurator` on purpose: that type is the pure, plain-numbers selection rule
/// and is unit tested directly; this type is the part that actually calls Vision and can only be
/// verified for quality on a real device (`VNClassifyImageRequest`, used elsewhere in this app,
/// is already known to behave differently or fail outright in the Simulator, and the newer
/// requests used here are assumed to share that limitation).
actor ChapterCuration {
    static let shared = ChapterCuration()

    private var qualityScores: [UUID: Double] = [:]
    private var featurePrints: [UUID: VNFeaturePrintObservation] = [:]

    /// How many photos are scored at once. Bounded, not unlimited: `qualityScore` awaits a
    /// network fetch before the (synchronous, CPU-bound) Vision calls, so a small amount of
    /// overlap keeps the network round trips from serializing behind one another the way they did
    /// when `curate` scored one photo at a time, without launching an unbounded flood of decodes
    /// against `ImageLoader`'s own shared decode budget.
    private static let maxConcurrentScores = 4

    /// A detected face is worth this much added to the raw aesthetics score (both roughly
    /// 0...1): a plain quality metric has no notion of "someone is in this photo", and a recap
    /// that is all scenery reads wrong for a month that had people in it.
    nonisolated static let faceBonus = 0.12

    /// Feature-print distances at or beyond this are treated as "not alike at all" (similarity
    /// 0); below it, similarity falls off linearly to 1 at distance 0. This is a design constant,
    /// not a measured one: an off value degrades curation to "somewhat less diverse than ideal",
    /// never a crash or a blank recap, so it's fine to retune from real libraries later without
    /// touching the (tested) selection rule itself.
    private static let dissimilarityFloor: Float = 2.0

    private init() {}

    /// Up to `limit` photo ids to actually play, chronological order, always keeping the month's
    /// first and last shot.
    ///
    /// `thumbURLs` is resolved ONCE, up front, by the caller (`FeedService.signedURLs(for:)`, a
    /// single batched call over every photo's thumb path) rather than a per-photo closure: a
    /// resolve-then-download-then-score pass repeated one photo at a time, serially, is exactly
    /// what made a 60-shot month take sixty sequential network round trips before this had
    /// anything to say. A path missing from `thumbURLs` (a sign failure for that one path) scores
    /// the same neutral 0.5 a download failure always has.
    ///
    /// Any Vision failure for one photo (a corrupt frame, a missing URL, an unsupported format)
    /// degrades that one photo to a neutral score and zero measured similarity to everything
    /// else, and never throws: one bad frame must not blank a whole month's recap.
    func curate(photos: [ChapterPhoto], displayScale: CGFloat,
                thumbURLs: [String: URL], limit: Int = 15) async -> [UUID] {
        // Dead frames never make the deck, whatever else is true of them.
        let photos = photos.filter { !$0.isDeadFrame }
        guard photos.count > limit else { return photos.map(\.id) }

        // The fast path: every candidate already carries its capture-time score and hash, so the
        // month is curated from numbers the RPC returned, with no download and no Vision. This is
        // what makes a chapter open instantly; the path below it is what runs for any month with
        // photos from before the columns existed.
        if let candidates = Self.columnCandidates(photos) {
            let hashes = Dictionary(uniqueKeysWithValues: photos.compactMap { p in p.phash.map { (p.id, CaptureAnalysis.hash(fromStored: $0)) } })
            return ChapterCurator.select(from: candidates, limit: limit) { a, b in
                guard let ha = hashes[a], let hb = hashes[b] else { return 0 }
                return CaptureAnalysis.similarity(hamming: CaptureAnalysis.hamming(ha, hb))
            }
        }

        // Bounded concurrency: at most `maxConcurrentScores` photos being scored at once, a new
        // one submitted the instant any one finishes, rather than either fully serial (the
        // original bug) or unbounded (every photo's fetch and Vision pass fighting at once).
        var candidatesByOrder: [Int: ChapterCurator.Candidate] = [:]
        candidatesByOrder.reserveCapacity(photos.count)
        await withTaskGroup(of: (Int, ChapterCurator.Candidate).self) { group in
            var nextOrder = 0
            func submitNext() {
                guard nextOrder < photos.count else { return }
                let order = nextOrder
                let photo = photos[order]
                nextOrder += 1
                group.addTask {
                    let score = await self.qualityScore(for: photo, displayScale: displayScale,
                                                        thumbURL: thumbURLs[photo.displayPath])
                    return (order, .init(id: photo.id, order: order, qualityScore: score))
                }
            }
            for _ in 0..<min(Self.maxConcurrentScores, photos.count) { submitNext() }
            while let (order, candidate) = await group.next() {
                candidatesByOrder[order] = candidate
                submitNext()
            }
        }
        let candidates = (0..<photos.count).compactMap { candidatesByOrder[$0] }

        // Captured as a value (a snapshot of this actor's cache at this instant), so the
        // similarity closure handed to `select` is a plain, synchronous, non-isolated function,
        // matching `ChapterCurator.Similarity` exactly. Reading it here, before `select` runs, is
        // an ordinary synchronous access on the actor's own turn.
        let prints = featurePrints
        return ChapterCurator.select(from: candidates, limit: limit) { a, b in
            guard let printA = prints[a], let printB = prints[b] else { return 0 }
            var distance: Float = 0
            guard (try? printA.computeDistance(&distance, to: printB)) != nil else { return 0 }
            let clamped = min(max(distance, 0), Self.dissimilarityFloor)
            return Double(1 - clamped / Self.dissimilarityFloor)
        }
    }

    /// Candidates built purely from stored columns, or `nil` if any photo lacks either number,
    /// in which case the whole month takes the Vision path (mixing the two scales would rank
    /// scored months against unscored guesses). Pure and internal so it is tested directly.
    nonisolated static func columnCandidates(_ photos: [ChapterPhoto]) -> [ChapterCurator.Candidate]? {
        var out: [ChapterCurator.Candidate] = []
        out.reserveCapacity(photos.count)
        for (order, photo) in photos.enumerated() {
            guard let quality = photo.quality, photo.phash != nil else { return nil }
            out.append(.init(id: photo.id, order: order, qualityScore: quality))
        }
        return out
    }

    /// The quality number itself, shared with `BurstDetector` so the value stored at capture is
    /// the value this actor used to compute per view: Vision's aesthetics score normalised from
    /// its roughly -1...1 into 0...1, plus `faceBonus` when anyone is in the frame. 0.5 when the
    /// aesthetics request is unavailable, which is the same neutral the old path used.
    nonisolated static func visionQuality(of cgImage: CGImage, handler: VNImageRequestHandler? = nil) -> Double {
        let handler = handler ?? VNImageRequestHandler(cgImage: cgImage, options: [:])
        var quality = 0.5
        if #available(iOS 18.0, *) {
            let aesthetics = VNCalculateImageAestheticsScoresRequest()
            if (try? handler.perform([aesthetics])) != nil, let result = aesthetics.results?.first {
                quality = Double((result.overallScore + 1) / 2)
            }
        }
        let faceRequest = VNDetectFaceRectanglesRequest()
        if (try? handler.perform([faceRequest])) != nil, let faces = faceRequest.results, !faces.isEmpty {
            quality = min(1, quality + Self.faceBonus)
        }
        return min(1, max(0, quality))
    }

    private func qualityScore(for photo: ChapterPhoto, displayScale: CGFloat,
                               thumbURL: URL?) async -> Double {
        if let cached = qualityScores[photo.id] { return cached }
        // A stored score wins over a download, even on the mixed path.
        if let stored = photo.quality { qualityScores[photo.id] = stored; return stored }
        guard let url = thumbURL,
              // The THUMB rendition, never the full image: curation runs over an entire month,
              // and this is a scoring pass, not a viewing one.
              let image = await ImageLoader.fetch(url: url, maxPixel: 400, scale: displayScale,
                                                  cacheKey: photo.displayPath),
              let cgImage = image.cgImage
        else {
            qualityScores[photo.id] = 0.5
            return 0.5
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let quality = Self.visionQuality(of: cgImage, handler: handler)

        let featurePrintRequest = VNGenerateImageFeaturePrintRequest()
        if (try? handler.perform([featurePrintRequest])) != nil,
           let observation = featurePrintRequest.results?.first {
            featurePrints[photo.id] = observation
        }

        qualityScores[photo.id] = quality
        return quality
    }
}

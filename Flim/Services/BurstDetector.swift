import CoreGraphics
import Foundation
import Vision

/// The pure membership rule behind `BurstDetector.analyze`, pulled out so the time window, the
/// stream/shooter boundary, and the distance threshold are unit-tested directly, without a live
/// Vision request. This app's own Vision surfaces are already documented (`ChapterCuration`) as
/// unreliable in the Simulator; nothing here needs one to be pinned.
enum BurstMembership {
    /// Same shooter, same stream (a stream is one roll, or "personal", see
    /// `BurstDetector.streamKey`), the previous shot within `timeWindow` seconds and not AFTER the
    /// current one, a feature-print distance at or under `distanceThreshold`, AND the two frames'
    /// pixels agreeing (`correlation` at or above `correlationFloor`). A previous shot with no
    /// measurable distance or correlation (this capture's own analysis failed, or there was
    /// nothing to compare it against) never matches: two frames are never joined on time and
    /// stream alone, and never on the feature print alone either.
    ///
    /// Two checks, not one, because they fail differently. The feature print is a semantic
    /// embedding: it says "this is the same kind of scene", and at a theme park two different
    /// people photographed against the same wall three seconds apart score as the same kind of
    /// scene. Measured on the 2026-09-06 Epic Universe roll, the pairs a person would call one
    /// moment sat at 0.18 to 0.45; pairs that were plainly two photographs (a floor, then a face)
    /// sat at 0.6 to 1.0 and STILL cleared the old 0.9 bar. The correlation is dumb and local, a
    /// 16 by 16 grey thumbnail compared cell for cell: a re-composed shot of the same instant
    /// keeps most of its layout (0.7 to 0.97 on those same pairs), a different photograph does not
    /// (below 0.25 on every false pair). Requiring both is what separates "held the shutter down"
    /// from "stood in the same place".
    static func matches(
        currentUserId: UUID, currentStreamKey: String, currentTakenAt: Date, distance: Float?,
        previousUserId: UUID, previousStreamKey: String, previousTakenAt: Date,
        timeWindow: TimeInterval, distanceThreshold: Float,
        correlation: Float? = 1, correlationFloor: Float = 0
    ) -> Bool {
        guard currentUserId == previousUserId, currentStreamKey == previousStreamKey else { return false }
        let delta = currentTakenAt.timeIntervalSince(previousTakenAt)
        guard delta >= 0, delta <= timeWindow else { return false }
        guard let distance, distance <= distanceThreshold else { return false }
        guard let correlation else { return false }
        return correlation >= correlationFloor
    }

    /// Whether a frame that matched the PREVIOUS frame may also join the previous frame's
    /// existing group, judged against that group's FIRST frame. Without this a burst is a chain:
    /// A matches B, B matches C, C matches D, and by D the subject has walked out of the frame
    /// while every link stayed under the bar. Measured on the same roll, an eight-frame group
    /// drifted from one person at a water cannon to a different person at the same cannon, with
    /// every consecutive pair under 0.35 and the last frame 0.69 from the first. The anchor bar
    /// is looser than the neighbour bar (a real burst does move a little) but it is a bar.
    static func staysWithAnchor(distanceToAnchor: Float?, correlationToAnchor: Float?,
                                distanceThreshold: Float, correlationFloor: Float) -> Bool {
        guard let distanceToAnchor, let correlationToAnchor else { return false }
        return distanceToAnchor <= distanceThreshold && correlationToAnchor >= correlationFloor
    }

    /// Pearson correlation of two equal-length grey thumbnails, in -1...1. `nil` when either is
    /// empty, mismatched, or flat (a flat frame has no layout to agree with anything).
    static func correlation(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        let n = Float(a.count)
        let meanA = a.reduce(0, +) / n, meanB = b.reduce(0, +) / n
        var num: Float = 0, denA: Float = 0, denB: Float = 0
        for i in a.indices {
            let x = a[i] - meanA, y = b[i] - meanB
            num += x * y; denA += x * x; denB += y * y
        }
        guard denA > 0, denB > 0 else { return nil }
        return num / (denA.squareRoot() * denB.squareRoot())
    }
}

/// Runs the on-device analysis behind burst grouping: a Vision feature print and a sharpness
/// score, computed once per capture, on THIS device, at the moment the shot is taken. A roll shot
/// is not seen by anyone until the roll develops, but its bytes exist right away, so this runs
/// silently on the shooter's phone; the `burst_group`/`sharpness` columns it writes are what let
/// every OTHER phone's grid and reveal collapse the burst later, off a plain `SELECT *`.
///
/// A plain `actor`, matching `ChapterCuration`'s own reasoning exactly: this is CPU-bound image
/// work with no view state to touch directly, called from `PhotoService`'s `@MainActor` capture
/// pipeline.
///
/// The ring only ever compares a new capture against the MOST RECENT prior capture sharing its
/// (userId, streamKey), never anything older, matching the design: a burst is "the previous shot
/// was near-identical, within a few seconds", not "any shot in the last N was".
actor BurstDetector {
    static let shared = BurstDetector()

    /// One shot to feed the membership check against a later one. Nothing here is persisted
    /// beyond the two columns the caller writes to `photos`; this only lives in memory for the
    /// life of the app process.
    private struct Entry {
        let photoId: UUID
        let userId: UUID
        let streamKey: String
        let takenAt: Date
        let print: VNFeaturePrintObservation?
        /// The 16 by 16 grey thumbnail `BurstMembership.correlation` compares, see `signature`.
        let signature: [Float]?
        var group: UUID?
        /// The group's FIRST frame, carried on every member so the anchor check never has to
        /// find it in a ring that may already have trimmed it away.
        var anchorPrint: VNFeaturePrintObservation?
        var anchorSignature: [Float]?
    }

    /// This capture's own verdict.
    struct Decision: Equatable {
        static func == (lhs: Decision, rhs: Decision) -> Bool {
            lhs.group == rhs.group && lhs.sharpness == rhs.sharpness
                && lhs.patchEarlier?.photoId == rhs.patchEarlier?.photoId
                && lhs.patchEarlier?.group == rhs.patchEarlier?.group
        }

        /// This capture's own `burst_group`, written on ITS OWN insert. `nil` when this shot
        /// starts (or simply doesn't join) a burst.
        let group: UUID?
        /// This capture's own `sharpness`, `nil` if the image was unavailable or Vision failed.
        let sharpness: Double?
        /// An EARLIER capture that just learned its group for the first time because THIS shot
        /// matched it: apply as a single UPDATE against that photo's own row, `burst_group` only,
        /// once. `nil` on every shot except the second frame of a fresh pair.
        let patchEarlier: (photoId: UUID, group: UUID)?

        static let none = Decision(group: nil, sharpness: nil, patchEarlier: nil)
    }

    /// Kept short on purpose: this is "the previous few shots this session", not a library-wide
    /// index. Bounded so a very long shooting session (or an account switch, which this actor is
    /// never explicitly reset for) can never grow this without limit; matching by `userId` already
    /// means a different account's stale entries simply never match.
    private var ring: [Entry] = []
    private static let ringLimit = 12

    /// Previous shot within this many seconds counts as "the same moment". Three seconds is a
    /// deliberate guess at "still holding the shutter down / re-composing the same instant",
    /// wide enough to catch a genuine burst, narrow enough that two deliberately separate shots of
    /// the same static scene a few seconds apart (a common, NOT-a-burst case) still fall outside it.
    static let burstTimeWindow: TimeInterval = 3
    /// Feature-print distance at/under this counts as "the same moment", not merely "a similar
    /// scene". `ChapterCuration.dissimilarityFloor` (2.0) marks the point past which two photos
    /// are treated as unrelated for recap DIVERSITY, a much looser bar; a burst needs near-
    /// duplicate frames, so this sits well inside that floor rather than reusing it directly.
    ///
    /// 0.9 until 2026-09-08, which grouped two photographs of different people (see
    /// `BurstMembership.matches`). Real bursts measured 0.18 to 0.45 between neighbours; 0.5
    /// leaves headroom above the loosest real one and sits under the tightest false one (0.6).
    static let burstDistanceThreshold: Float = 0.5
    /// Pixel agreement between neighbours, the second half of `BurstMembership.matches`. Real
    /// bursts measured 0.7 and up; a panned or re-composed frame of the same instant can drop to
    /// about 0.5; every false pair sat under 0.25.
    static let burstCorrelationFloor: Float = 0.45
    /// The anchor bars, see `BurstMembership.staysWithAnchor`: a real burst of eight drifts a
    /// little across its length, so these are looser than the neighbour bars, but a frame that
    /// no longer resembles the first one starts a new burst instead of joining this one.
    static let burstAnchorDistanceThreshold: Float = 0.65
    static let burstAnchorCorrelationFloor: Float = 0.35
    /// Side of the grey thumbnail behind the correlation check. Sixteen is coarse on purpose:
    /// grain, a hand jitter, or a face turning a few degrees barely move it, a different
    /// photograph moves everything.
    static let signatureSide = 16
    /// The graded capture is downsampled to this before Vision and the sharpness scorer ever see
    /// it: both only need a small image, and the CGImage handed in is already the full-resolution
    /// decoded capture, so shrinking it here (rather than decoding the master a second time at a
    /// smaller size) is the one extra cost this analysis pays.
    private static let analysisMaxDimension: CGFloat = 512
    /// Laplacian variance is normalised into 0...1 by dividing by this and clamping, so
    /// `sharpness` is comparable across shots and across devices. Not measured from a corpus (no
    /// calibration harness exists for this yet): it's a conservative read of "clearly sharp" for
    /// an 8-bit grayscale image at `analysisMaxDimension`, where a plainly sharp frame typically
    /// lands in the low thousands on this exact 3x3 kernel and a badly blurred one lands under a
    /// few hundred. Safe to retune later from real captures; `sharpness` is a fresh column with no
    /// existing reader whose scale would break.
    private static let sharpnessNormalizationScale: Double = 2000

    private init() {}

    /// The stream a capture belongs to for burst purposes: one shared roll, or "personal" for
    /// every instant outside a roll. Two personal shots from the same person can still burst
    /// together; two shots in different rolls, or one personal and one in a roll, cannot.
    nonisolated static func streamKey(rollId: UUID?) -> String {
        rollId?.uuidString ?? "personal"
    }

    /// Analyzes one capture and decides its burst membership. Never throws, never blocks the
    /// capture that's already on its way to Storage by the time this typically finishes: a Vision
    /// failure (or `image == nil`, the calibration path's ungraded fallback) degrades to
    /// `Decision.none` rather than stalling or failing the upload.
    func analyze(photoId: UUID, userId: UUID, streamKey: String, takenAt: Date, image: CGImage?) async -> Decision {
        let (printObs, signature, sharpness) = await Self.score(image)
        let fresh = Entry(photoId: photoId, userId: userId, streamKey: streamKey, takenAt: takenAt,
                          print: printObs, signature: signature, group: nil,
                          anchorPrint: nil, anchorSignature: nil)

        guard let candidate = ring.last(where: { $0.userId == userId && $0.streamKey == streamKey }) else {
            ring.append(fresh)
            trim()
            return Decision(group: nil, sharpness: sharpness, patchEarlier: nil)
        }

        let distance = Self.distance(printObs, candidate.print)
        let correlation = Self.correlation(signature, candidate.signature)
        guard BurstMembership.matches(
            currentUserId: userId, currentStreamKey: streamKey, currentTakenAt: takenAt, distance: distance,
            previousUserId: candidate.userId, previousStreamKey: candidate.streamKey, previousTakenAt: candidate.takenAt,
            timeWindow: Self.burstTimeWindow, distanceThreshold: Self.burstDistanceThreshold,
            correlation: correlation, correlationFloor: Self.burstCorrelationFloor
        ) else {
            ring.append(fresh)
            trim()
            return Decision(group: nil, sharpness: sharpness, patchEarlier: nil)
        }

        if let existingGroup = candidate.group {
            // Matched the previous frame; now the burst's first frame gets a say, so a chain of
            // small moves cannot walk the group onto a different subject.
            let anchorDistance = Self.distance(printObs, candidate.anchorPrint)
            let anchorCorrelation = Self.correlation(signature, candidate.anchorSignature)
            guard BurstMembership.staysWithAnchor(
                distanceToAnchor: anchorDistance, correlationToAnchor: anchorCorrelation,
                distanceThreshold: Self.burstAnchorDistanceThreshold,
                correlationFloor: Self.burstAnchorCorrelationFloor
            ) else {
                ring.append(fresh)
                trim()
                return Decision(group: nil, sharpness: sharpness, patchEarlier: nil)
            }
            var member = fresh
            member.group = existingGroup
            member.anchorPrint = candidate.anchorPrint
            member.anchorSignature = candidate.anchorSignature
            ring.append(member)
            trim()
            return Decision(group: existingGroup, sharpness: sharpness, patchEarlier: nil)
        }

        // The candidate has no group yet: this is the SECOND frame of a fresh pair. Mint one UUID
        // for both, retroactively tag the candidate IN THE RING (so a third frame in the same
        // burst matches against an entry that now carries the group too), and tell the caller to
        // patch the candidate's already-inserted row. The candidate is the burst's anchor.
        let newGroup = UUID()
        if let index = ring.lastIndex(where: { $0.photoId == candidate.photoId }) {
            ring[index].group = newGroup
            ring[index].anchorPrint = candidate.print
            ring[index].anchorSignature = candidate.signature
        }
        var member = fresh
        member.group = newGroup
        member.anchorPrint = candidate.print
        member.anchorSignature = candidate.signature
        ring.append(member)
        trim()
        return Decision(group: newGroup, sharpness: sharpness, patchEarlier: (photoId: candidate.photoId, group: newGroup))
    }

    private func trim() {
        if ring.count > Self.ringLimit { ring.removeFirst(ring.count - Self.ringLimit) }
    }

    /// Off the actor: a detached task so the Vision request and the sharpness scan never hold up
    /// whatever the actor is doing for a concurrent capture (captures are serialized upstream in
    /// `PhotoService`'s own pipeline anyway, but this keeps the actor's own turn short regardless).
    private static func score(_ image: CGImage?) async -> (VNFeaturePrintObservation?, [Float]?, Double?) {
        guard let image else { return (nil, nil, nil) }
        return await Task.detached(priority: .utility) {
            guard let small = downsample(image, maxDimension: analysisMaxDimension) else { return (nil, nil, nil) }
            var printObs: VNFeaturePrintObservation?
            let handler = VNImageRequestHandler(cgImage: small, options: [:])
            let request = VNGenerateImageFeaturePrintRequest()
            if (try? handler.perform([request])) != nil {
                printObs = request.results?.first
            }
            return (printObs, signature(small), sharpnessScore(small))
        }.value
    }

    private static func distance(_ a: VNFeaturePrintObservation?, _ b: VNFeaturePrintObservation?) -> Float? {
        guard let a, let b else { return nil }
        var d: Float = 0
        guard (try? a.computeDistance(&d, to: b)) != nil else { return nil }
        return d
    }

    private static func correlation(_ a: [Float]?, _ b: [Float]?) -> Float? {
        guard let a, let b else { return nil }
        return BurstMembership.correlation(a, b)
    }

    /// The image reduced to a `signatureSide` square of linear grey, row-major, 0...1. The whole
    /// frame is averaged into each cell, so this is the frame's layout and nothing finer. Not
    /// `private`: tested with synthetic images like `sharpnessScore`.
    static func signature(_ image: CGImage, side: Int = signatureSide) -> [Float]? {
        guard side > 0, image.width > 0, image.height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return pixels.map { Float($0) / 255 }
    }

    /// A plain CGContext redraw at (at most) `maxDimension` on the longest edge. No third-party
    /// dependency, and cheap: the source is already a decoded bitmap in memory, this only ever
    /// shrinks it.
    private static func downsample(_ image: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(image.width), height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(1, maxDimension / max(width, height))
        let targetWidth = max(1, Int(width * scale)), targetHeight = max(1, Int(height * scale))
        guard let ctx = CGContext(
            data: nil, width: targetWidth, height: targetHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return ctx.makeImage()
    }

    /// Variance of the Laplacian over an 8-bit grayscale render of `image`, normalised into
    /// 0...1 by `sharpnessNormalizationScale`. Deterministic: the same pixels always score the
    /// same, with no randomness and no dependency on Vision (which this app's own Vision surfaces
    /// are documented as unreliable for in the Simulator), so this half of the analysis is exactly
    /// as testable as any other pure function in this codebase.
    ///
    /// Not `private`: exercised directly with synthetic images in tests, the same reasoning
    /// `ChapterCuration`'s own Vision-adjacent constants are documented, not hidden, for.
    static func sharpnessScore(_ image: CGImage) -> Double? {
        let width = image.width, height = image.height
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray),
              let ctx = CGContext(
                data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
              )
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum: Double = 0
        var sumSquares: Double = 0
        var count = 0
        for y in 1..<(height - 1) {
            let row = y * width
            let rowAbove = row - width
            let rowBelow = row + width
            for x in 1..<(width - 1) {
                let center = Int(pixels[row + x])
                let laplacian = Int(pixels[rowAbove + x]) + Int(pixels[rowBelow + x])
                    + Int(pixels[row + x - 1]) + Int(pixels[row + x + 1]) - 4 * center
                let v = Double(laplacian)
                sum += v
                sumSquares += v * v
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        let variance = sumSquares / Double(count) - mean * mean
        return min(1, max(0, variance / sharpnessNormalizationScale))
    }
}

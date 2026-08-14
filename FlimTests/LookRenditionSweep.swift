import Testing
import CoreImage
import ImageIO
import Foundation
@testable import Flim

/// The rendition sweep: what quality and what PIXEL DIMENSION each cost the look, in bytes and in
/// the look pin's own units.
///
/// Separate from `LookEncoderSweep`, which varies the codec. This varies the two levers that are
/// actually on the table for cutting egress, and it keeps them apart on purpose:
///
///   - QUALITY attacks the grain directly. Grain is fine, high-frequency, full-frame texture, which
///     is the worst case for the DCT: it is the first thing a lower quantisation table throws away.
///   - DIMENSION attacks the grain indirectly, by resampling. Fewer pixels means the grain the
///     viewer sees is either averaged down (if the card is still larger than its display size) or
///     interpolated back up (if it is smaller), and only the second one is destructive.
///
/// Because the two levers are not comparable at native resolution (a 1080px card and a 1400px card
/// have different `localContrast` for reasons that have nothing to do with the encoder), every
/// candidate is ALSO measured after being resampled to the size the feed card is actually displayed
/// at. That is the only comparison in which the two levers are in the same units.
///
/// Nothing under `Flim/` is touched, no baseline is re-recorded, and this is opt-in so a normal
/// suite run never pays for it:
///
///     FLIM_RENDITION_SWEEP=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/LookRenditionSweep
struct LookRenditionSweep {
    static let isSweeping = ProcessInfo.processInfo.environment["FLIM_RENDITION_SWEEP"] == "1"

    /// Card long edges to try. 1400 is what ships. 1520 is not a saving candidate: it is the size
    /// that would make the card pixel-exact on a 440pt Pro Max, included as a control so "how much
    /// of the card's softness is already there today" is on the record next to "how much a smaller
    /// card would add".
    static let cardDims: [CGFloat] = [1520, 1400, 1280, 1200, 1080]
    /// 0.95 is not a candidate; it is the near-transparent reference that lets the quality lever be
    /// isolated AT each dimension, so "this dimension moved the look" and "this quality moved the
    /// look" never get charged to each other.
    static let cardQualities: [CGFloat] = [0.95, 0.82, 0.78, 0.75, 0.72, 0.70, 0.65, 0.60]

    static let thumbDims: [CGFloat] = [500, 400, 360]
    static let thumbQualities: [CGFloat] = [0.95, 0.80, 0.75, 0.70, 0.65, 0.60]

    /// The width the card's IMAGE is actually laid out at, in pixels, on the largest phone in the
    /// current lineup. `FeedView` puts the LazyVStack in 16pt of horizontal padding and the card in
    /// another 14pt, so a 440pt Pro Max shows the photo across 380pt, i.e. 1140px at 3x. This is the
    /// worst case for a shrunken card, because it is where the rendition has to be magnified most.
    static let cardDisplayWidth: CGFloat = 1140
    /// The same width on the phone most people are holding: 393pt − 60pt of padding = 333pt, 999px
    /// at 3x. Both are measured because they sit on opposite sides of the shipping card's own
    /// 1050px width, so one is a slight downscale and the other a slight magnification, and a
    /// recommendation that only looked at one of them would be flattering itself.
    static let cardDisplayWidthCompact: CGFloat = 999
    /// A 3-column Darkroom cell is ~128pt, so ~384px at 3x. The cell square-crops (`aspectRatio(1,
    /// .fit)` with `scaledToFill`), so what has to cover it is the thumbnail's SHORT edge, which is
    /// the axis measured here.
    static let thumbDisplayWidth: CGFloat = 384

    static let scenes: [String] = LookFixture.allCases.map(\.rawValue)
        + (LookPairs.isAvailable ? LookPairs.scenes : [])

    static func sourceData(_ scene: String) -> Data? {
        if let fixture = LookFixture(rawValue: scene) { return fixture.pngData() }
        return LookPairs.neutralData(scene)
    }

    /// Resamples to an exact display width with Lanczos, so every candidate is measured at the size
    /// a phone shows it at. Lanczos is a stand-in for CALayer's own magnification filter, and a
    /// generous one: the real thing is bilinear, which smears fine grain harder than this does.
    static func resampled(_ cg: CGImage, toWidth width: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: cg)
        let scale = width / ci.extent.width
        let out = ci.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1.0
        ])
        return LookMeasure.context.createCGImage(out, from: out.extent, format: .RGBA8,
                                                 colorSpace: LookMeasure.srgb)
    }

    private static func fields(_ prefix: String, _ s: LookStats) -> String {
        s.fields.map { "\(prefix)\($0.name)=\(String(format: "%.5f", $0.value))" }.joined(separator: " ")
    }

    // MARK: - Grain attribution

    /// The graded pixels with grain SKIPPED and nothing else changed.
    ///
    /// This is the hypothesis test: if grain is what makes these files big, the same frame without
    /// it must be dramatically smaller at the same quality and the same dimension.
    ///
    /// It reconstructs the pipeline from its own internal steps rather than adding a switch to the
    /// processor, and deliberately does NOT restate the adaptive-exposure formula (which lives in
    /// `InstantFilmProcessor` and `scripts/fit_lut.py` only). The consequence is that this
    /// reconstruction is only faithful on scenes where neither the adaptive-EV branch nor the
    /// dark-scene bloom reduction fires. `grainOnReconstruction` below is the check that proves it:
    /// where the with-grain reconstruction is byte-identical to the shipping path, the grain-off
    /// number for that scene is trustworthy, and where it is not, the scene is reported as
    /// unattributable instead of quietly wrong.
    static func reconstruction(_ data: Data, grain: Bool) -> CGImage? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }
        let params = FilmStock.original.params
        var image = InstantFilmProcessor.filtered(source, params: params, extent: extent)
        if grain { image = InstantFilmProcessor.grainOverlay(on: image, amount: params.grain) }
        // The storage cap, matching `InstantFilmProcessor.maxStoredEdge` (private). If this ever
        // disagrees with the processor, the byte-identity check below fails and says so.
        let longEdge = max(extent.width, extent.height)
        if longEdge > 2048 {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: 2048 / longEdge, kCIInputAspectRatioKey: 1.0
            ])
        }
        return LookMeasure.context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                 colorSpace: LookMeasure.srgb)
    }

    // MARK: - Sweep

    @Test("rendition sweep: quality × dimension, in bytes and in look drift",
          .enabled(if: isSweeping), arguments: scenes)
    func sweep(_ scene: String) throws {
        let data = try #require(Self.sourceData(scene))

        // The shipping master, graded once. Every card and thumb below is derived from these exact
        // bytes, which is what production does (`PhotoService` re-renditions the processed image).
        let graded = try #require(InstantFilmProcessor.gradedPixels(data, stock: .original))
        let masterSpec = InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: 0.85)
        let master = try #require(InstantFilmProcessor.encodeImage(graded, masterSpec))

        // Grain attribution, and its own validity check.
        let grainOn = Self.reconstruction(data, grain: true)
        let grainOff = Self.reconstruction(data, grain: false)
        let grainOnBytes = grainOn.flatMap { InstantFilmProcessor.encodeImage($0, masterSpec)?.data.count } ?? -1
        let attributable = grainOnBytes == master.data.count
        let grainOffMaster = grainOff.flatMap { InstantFilmProcessor.encodeImage($0, masterSpec) }
        print("""
        RSWEEPBASE scene=\(scene) masterBytes=\(master.data.count) \
        masterW=\(graded.width) masterH=\(graded.height) \
        reconBytes=\(grainOnBytes) attributable=\(attributable) \
        grainOffMasterBytes=\(grainOffMaster?.data.count ?? -1)
        """)

        // MARK: card
        var cardReference: LookStats?          // (1400, 0.82) at native size
        var cardDisplayReference: LookStats?   // (1400, 0.82) as displayed

        for dim in Self.cardDims {
            for q in Self.cardQualities {
                let spec = InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: q)
                let encoded = try #require(InstantFilmProcessor.rendition(
                    from: master.data, longEdge: dim, encoding: spec))
                let cg = try #require(LookMeasure.decode(encoded.data))
                let native = try #require(LookMeasure.stats(of: cg))
                let shown = try #require(Self.resampled(cg, toWidth: Self.cardDisplayWidth))
                let display = try #require(LookMeasure.stats(of: shown))
                let shownCompact = try #require(Self.resampled(cg, toWidth: Self.cardDisplayWidthCompact))
                let displayCompact = try #require(LookMeasure.stats(of: shownCompact))

                if dim == 1400 && q == 0.82 { cardReference = native; cardDisplayReference = display }

                // Grain-off bytes at the same point, for the hypothesis. Bytes only: the look of a
                // grainless FLIM photo is not a candidate, it is a control.
                var offBytes = -1
                if let grainOffMaster,
                   let off = InstantFilmProcessor.rendition(from: grainOffMaster.data,
                                                            longEdge: dim, encoding: spec) {
                    offBytes = off.data.count
                }

                print("""
                RSWEEP scene=\(scene) tier=card dim=\(Int(dim)) q=\(String(format: "%.2f", q)) \
                bytes=\(encoded.data.count) w=\(cg.width) h=\(cg.height) \
                grainOffBytes=\(offBytes) attributable=\(attributable) \
                \(Self.fields("nat_", native)) \(Self.fields("disp_", display)) \
                \(Self.fields("small_", displayCompact))
                """)
            }
        }
        // Restated once so the analysis has the reference row explicitly, not by convention.
        if let cardReference, let cardDisplayReference {
            print("""
            RSWEEPREF scene=\(scene) tier=card dim=1400 q=0.82 \
            \(Self.fields("nat_", cardReference)) \(Self.fields("disp_", cardDisplayReference))
            """)
        }

        // MARK: thumb
        for dim in Self.thumbDims {
            for q in Self.thumbQualities {
                let spec = InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: q)
                let encoded = try #require(InstantFilmProcessor.rendition(
                    from: master.data, longEdge: dim, encoding: spec))
                let cg = try #require(LookMeasure.decode(encoded.data))
                let native = try #require(LookMeasure.stats(of: cg))
                let shown = try #require(Self.resampled(cg, toWidth: Self.thumbDisplayWidth))
                let display = try #require(LookMeasure.stats(of: shown))

                var offBytes = -1
                if let grainOffMaster,
                   let off = InstantFilmProcessor.rendition(from: grainOffMaster.data,
                                                            longEdge: dim, encoding: spec) {
                    offBytes = off.data.count
                }

                print("""
                RSWEEP scene=\(scene) tier=thumb dim=\(Int(dim)) q=\(String(format: "%.2f", q)) \
                bytes=\(encoded.data.count) w=\(cg.width) h=\(cg.height) \
                grainOffBytes=\(offBytes) attributable=\(attributable) \
                \(Self.fields("nat_", native)) \(Self.fields("disp_", display))
                """)
            }
        }
    }

    /// What the card costs because it is a re-encode of an already-lossy master.
    ///
    /// Production derives both small renditions from `imageData`, the q0.85 JPEG master
    /// (`PhotoService.upload`), so the card is a second generation: it has to spend bits
    /// re-describing the master's own DCT artifacts as if they were photographic detail. This
    /// measures that, holding the resampler fixed (both sides go through the same
    /// `rendition` → ImageIO path) and varying only whether the intermediate was lossy. The
    /// lossless side is a PNG of the identical graded pixels, so nothing but generation differs.
    ///
    /// Measurement only. It says what a different SOURCE for the rendition would be worth; it does
    /// not propose one.
    @Test("generation loss: card from the lossy master vs from the graded pixels",
          .enabled(if: isSweeping), arguments: scenes)
    func generationLoss(_ scene: String) throws {
        let data = try #require(Self.sourceData(scene))
        let graded = try #require(InstantFilmProcessor.gradedPixels(data, stock: .original))
        let master = try #require(InstantFilmProcessor.encodeImage(
            graded, InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: 0.85)))

        // Lossless intermediate carrying the same pixels.
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, graded, nil)
        #expect(CGImageDestinationFinalize(dest))

        for q in [0.82, 0.75, 0.72] as [CGFloat] {
            let spec = InstantFilmProcessor.EncodeSpec(format: .jpeg, quality: q)
            let fromMaster = try #require(InstantFilmProcessor.rendition(
                from: master.data, longEdge: 1400, encoding: spec))
            let fromGraded = try #require(InstantFilmProcessor.rendition(
                from: png as Data, longEdge: 1400, encoding: spec))
            let a = try #require(LookMeasure.stats(ofJPEG: fromMaster.data))
            let b = try #require(LookMeasure.stats(ofJPEG: fromGraded.data))
            print("""
            RSWEEPGEN scene=\(scene) q=\(String(format: "%.2f", q)) \
            fromMasterBytes=\(fromMaster.data.count) fromGradedBytes=\(fromGraded.data.count) \
            \(Self.fields("master_", a)) \(Self.fields("graded_", b))
            """)
        }
    }
}

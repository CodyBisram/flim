import Testing
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Foundation
@testable import Flim

// MARK: - Probe: what does the composite do to the frame's tone?

/// Measures the grain composite on FLAT patches, where "what did grain do to the tone here" has an
/// exact answer and no scene content can hide it.
///
/// Everything is measured in Core Image's LINEAR working space (rendered to `RGBAf` through the
/// linear sRGB space), because that is where the blend actually resolves. Measuring in encoded sRGB
/// would fold the transfer function into the fit and make an affine bias look like a curve.
struct GrainCompositeProbe {
    static let isProbing = ProcessInfo.processInfo.environment["FLIM_GRAIN_PROBE"] == "1"
    static let context = CIContext()

    /// A flat opaque patch at an 8-bit sRGB level.
    static func patch(level: Int, side: Int = 512) -> CIImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let v = CGFloat(level) / 255
        ctx.setFillColor(CGColor(colorSpace: cs, components: [v, v, v, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return CIImage(cgImage: ctx.makeImage()!)
    }

    /// Mean of an image in the linear working space, and in encoded sRGB, over its whole extent.
    /// Both are returned from the SAME render so the two domains can be compared directly.
    static func means(_ image: CIImage, side: Int = 512) -> (linear: Double, srgb: Double) {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        var linear = [Float](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &linear, rowBytes: side * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        var encoded = [Float](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &encoded, rowBytes: side * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var sumL = 0.0, sumS = 0.0
        for i in stride(from: 0, to: linear.count, by: 4) {
            sumL += Double(linear[i]); sumS += Double(encoded[i])
        }
        let n = Double(side * side)
        return (sumL / n, sumS / n)
    }

    /// The one property this whole change exists to establish, pinned as an ordinary test so it
    /// cannot regress quietly: compositing grain must not move the frame's tone.
    ///
    /// Flat patches across the range, measured in the linear working space where the composite
    /// resolves. The tolerance is 0.0005 linear, which at the worst-case patch here is well under
    /// a quarter of an 8-bit level once encoded, and ~40× tighter than the +0.019 mean the
    /// source-over composite was measured to add on the owner's real scenes.
    @Test("grain composites without moving the frame's tone", arguments: [16, 48, 96, 128, 190, 240])
    func meanIsPreserved(_ level: Int) {
        let clean = Self.patch(level: level)
        let grained = InstantFilmProcessor.grainOverlay(on: clean, amount: 0.06,
                                                        composite: .meanPreserving)
        let shift = Self.means(grained).linear - Self.means(clean).linear
        #expect(abs(shift) < 0.0005,
                "level \(level): grain moved the linear mean by \(String(format: "%+.5f", shift))")
    }

    /// The property, stated as a test so nothing is measured against a moving target: the SHIPPED
    /// composite is a white veil at random opacity, so it only ever ADDS light, and it adds most of
    /// it where the picture has least. Measured, known, and shipped: `.meanPreserving` removes it,
    /// was the default for the length of 1.5.1, and was reverted with the rest of that grain work
    /// on 2026-09-03.
    @Test("the source-over composite really does add light, which is what meanPreserving removes")
    func sourceOverBiasIsReal() {
        func shift(_ level: Int) -> Double {
            let patch = Self.patch(level: level)
            return Self.means(InstantFilmProcessor.grainOverlay(on: patch, amount: 0.06,
                                                                 composite: .sourceOver)).linear
                - Self.means(patch).linear
        }
        let dark = shift(48), bright = shift(200)
        #expect(dark > 0.002)
        #expect(bright > 0)
        #expect(dark > bright * 4)
    }

    /// Standard deviation as well as the mean, in the linear working space.
    static func stats(_ image: CIImage, side: Int = 512) -> (mean: Double, sd: Double, alpha: Double) {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        var buffer = [Float](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &buffer, rowBytes: side * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        var sum = 0.0, square = 0.0, alpha = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let v = Double(buffer[i])
            sum += v; square += v * v; alpha += Double(buffer[i + 3])
        }
        let n = Double(side * side)
        let mean = sum / n
        return (mean, (square / n - mean * mean).squareRoot(), alpha / n)
    }

    /// The shipping noise layer, rebuilt here so the probe can look at it and at the composite
    /// WITHOUT `grainOverlay`'s luminance mask in the way. Kept byte-identical to
    /// `InstantFilmProcessor.grainOverlay`'s own layer; `layerMatchesShipping` asserts that.
    static func noiseLayer(amount: CGFloat, chroma: CGFloat = 0, extent: CGRect) -> CIImage {
        CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: chroma, kCIInputContrastKey: 1
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
            ])
    }

    /// The one thing the mean-preserving composite assumes about the noise layer, at every chroma
    /// the profiles use: that its premultiplied mean is HALF the amount. `precompensated` divides
    /// exactly that out, so if chroma moved it, every chroma-carrying frame would come out tinted
    /// or lifted. Measured, chroma does not move it (it changes which channel gets which sample,
    /// not what they average to), and this is what keeps that true.
    @Test("the noise layer's mean is amount/2 at every chroma the profiles use",
          arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func layerMeanIsHalfTheAmount(_ profile: GrainProfile) {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        let amount: CGFloat = 0.06
        let layer = Self.noiseLayer(amount: amount, chroma: profile.chroma, extent: extent)
        let measured = Self.stats(layer).mean / Double(amount)
        #expect(abs(measured - 0.5) < 0.01, """
            chroma \(profile.chroma): the layer's premultiplied mean is \
            \(String(format: "%.4f", measured)) of the amount, not 0.5. The mean-preserving \
            composite subtracts amount/2, so this puts a tone shift into every frame.
            """)
    }

    /// The mask lands the coverage its anchors ask for.
    ///
    /// This is the test that would have caught the thing nobody had measured: between `CIToneCurve`
    /// and `CIBlendWithMask` the mask's value is linearised twice, so the curve FLIM shipped
    /// through 1.5.0 asked for 0.30 of coverage in deep shadow and delivered 0.0054. The anchors
    /// and their effect were free to disagree by a factor of fifty and every test still passed.
    ///
    /// Measured AT THE ANCHOR LUMINANCES only, deliberately: `CIToneCurve` interpolates with a
    /// spline that passes exactly through its control points and overshoots between them, so the
    /// anchors are the only places where the intended value and the rendered one are the same
    /// question. The lift ratio is the coverage, since out = m·grained + (1 − m)·base.
    @Test("the tone mask lands the coverage its anchors ask for",
          arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func maskLandsTheCoverageItAsksFor(_ profile: GrainProfile) {
        let extent = CGRect(x: 0, y: 0, width: 512, height: 512)
        for anchor in profile.anchors {
            let level = Int((anchor.luminance * 255).rounded())
            let base = Self.patch(level: level)
            let baseMean = Self.stats(base).mean
            let raw = Self.stats(Self.noiseLayer(amount: 0.06, chroma: profile.chroma,
                                                  extent: extent)
                .applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputBackgroundImageKey: base
                ])).mean - baseMean
            let masked = Self.stats(InstantFilmProcessor.grainOverlay(
                on: base, amount: 0.06, composite: .sourceOver, profile: profile)).mean - baseMean
            guard abs(raw) > 1e-6 else { continue }   // pure white leaves nothing to lift
            let rendered = masked / raw
            let asked = Double(InstantFilmProcessor.grainCoverage(
                luminance: CGFloat(level) / 255, profile: profile))
            print("""
            MASKCOVERAGE chroma=\(profile.chroma) luminance=\(anchor.luminance) \
            asked=\(String(format: "%.4f", asked)) rendered=\(String(format: "%.4f", rendered))
            """)
            // 0.05, and the worst measured deviation is 0.043 (`midtone` at luminance 0.25,
            // `pushed` at 0.40): the double linearisation predicts the coverage to within about a
            // twentieth, and the remainder is `CIToneCurve` fitting a spline rather than the
            // straight segments the anchors describe. The point of this test is the FACTOR OF
            // FIFTY the model removes, not the last hundredth.
            #expect(abs(rendered - asked) < 0.05, """
                at luminance \(anchor.luminance) the mask asks for \(String(format: "%.4f", asked)) \
                of coverage and lands \(String(format: "%.4f", rendered)). The anchors and what \
                reaches the photograph have come apart.
                """)
        }
    }

    /// What chroma does to the layer, per channel, and what it does to the constant the composite
    /// has to cancel: the table that establishes chroma does not move the composite's DC term.
    @Test("the noise layer as a function of chroma", .enabled(if: isProbing))
    func chromaAnatomy() {
        let side = 512
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        let amount: CGFloat = 0.06
        for chroma in [0, 0.15, 0.25, 0.35, 0.5, 0.65, 0.8, 1.0] as [CGFloat] {
            let layer = Self.noiseLayer(amount: amount, chroma: chroma, extent: extent)
            let s = Self.channelStats(layer)
            // What the layer does to a flat mid-grey through the real composite, both ways.
            let patch = Self.patch(level: 128)
            var profile = GrainProfile.pushed
            profile.chroma = chroma
            let over = InstantFilmProcessor.grainOverlay(on: patch, amount: amount,
                                                         composite: .sourceOver, profile: profile)
            let mp = InstantFilmProcessor.grainOverlay(on: patch, amount: amount,
                                                       composite: .meanPreserving, profile: profile)
            let base = Self.stats(patch)
            print("""
            CHROMA chroma=\(String(format: "%.2f", chroma)) \
            veil=\(String(format: "%.5f", Self.stats(layer).mean / Double(amount))) \
            meanR=\(String(format: "%.5f", s.r)) meanG=\(String(format: "%.5f", s.g)) \
            meanB=\(String(format: "%.5f", s.b)) alpha=\(String(format: "%.5f", s.a)) \
            chanSpread=\(String(format: "%.5f", s.spread)) \
            overLift=\(String(format: "%+.5f", Self.stats(over).mean - base.mean)) \
            mpLift=\(String(format: "%+.5f", Self.stats(mp).mean - base.mean)) \
            mpSD=\(String(format: "%.5f", Self.stats(mp).sd))
            """)
        }
    }

    /// Per-channel means, and the mean absolute spread BETWEEN channels at a pixel, which is the
    /// thing chroma grain is for: at chroma 0 it is ~0 by construction.
    static func channelStats(_ image: CIImage, side: Int = 512)
        -> (r: Double, g: Double, b: Double, a: Double, spread: Double) {
        let bounds = CGRect(x: 0, y: 0, width: side, height: side)
        var buffer = [Float](repeating: 0, count: side * side * 4)
        context.render(image, toBitmap: &buffer, rowBytes: side * 16, bounds: bounds,
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
        var r = 0.0, g = 0.0, b = 0.0, a = 0.0, spread = 0.0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            let (x, y, z) = (Double(buffer[i]), Double(buffer[i + 1]), Double(buffer[i + 2]))
            r += x; g += y; b += z; a += Double(buffer[i + 3])
            spread += max(x, max(y, z)) - min(x, min(y, z))
        }
        let n = Double(side * side)
        return (r / n, g / n, b / n, a / n, spread / n)
    }

    /// The tone mask as the pipeline actually applies it, per 8-bit level, for a given profile.
    ///
    /// The anchors are a curve in some space, and WHICH space is not a matter of opinion: the mask
    /// is built inside the Core Image graph, whose working space is linear, and `CIToneCurve` is
    /// applied there. This prints the effective mask against both the encoded level and the linear
    /// value so the anchors can be placed against what the mask DOES rather than against what the
    /// numbers look like they say.
    @Test("the tone mask, per level", .enabled(if: isProbing),
          arguments: [GrainProfile.midtone, GrainProfile.pushed])
    func maskByTone(_ profile: GrainProfile) {
        let side = 512
        let extent = CGRect(x: 0, y: 0, width: side, height: side)
        for level in stride(from: 0, through: 255, by: 8) {
            let base = Self.patch(level: level)
            let baseMean = Self.stats(base).mean
            let raw = Self.stats(Self.noiseLayer(amount: 0.06, chroma: profile.chroma, extent: extent)
                .applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputBackgroundImageKey: base
                ])).mean - baseMean
            let masked = Self.stats(InstantFilmProcessor.grainOverlay(
                on: base, amount: 0.06, composite: .sourceOver, profile: profile)).mean - baseMean
            let effective = abs(raw) > 1e-7 ? masked / raw : 0
            // The mask's own alpha, read directly, so "what the curve produced" and "what the
            // blend did with it" are separate numbers.
            var alphaBuffer = [Float](repeating: 0, count: 4)
            let mask = InstantFilmProcessor.grainLuminanceMask(for: base, profile: profile)
            Self.context.render(mask, toBitmap: &alphaBuffer, rowBytes: 16,
                                bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf,
                                colorSpace: CGColorSpace(name: CGColorSpace.linearSRGB)!)
            print("""
            MASKROW chroma=\(profile.chroma) level=\(level) \
            maskR=\(String(format: "%.4f", alphaBuffer[0])) \
            maskA=\(String(format: "%.4f", alphaBuffer[3])) \
            srgb=\(String(format: "%.4f", Double(level) / 255)) \
            lin=\(String(format: "%.5f", baseMean)) \
            effective=\(String(format: "%.4f", effective)) \
            curveAtLinear=\(String(format: "%.4f", InstantFilmProcessor.grainVisibility(luminance: CGFloat(baseMean), profile: profile))) \
            curveAtSRGB=\(String(format: "%.4f", InstantFilmProcessor.grainVisibility(luminance: CGFloat(level) / 255, profile: profile)))
            """)
        }
    }

    /// What the composite is actually made of: the working space's linearity, the noise layer's own
    /// mean/spread/alpha, and the UNMASKED source-over lift as a function of base.
    @Test("what the grain composite is actually doing", .enabled(if: isProbing))
    func anatomy() {
        let side = 512
        let extent = CGRect(x: 0, y: 0, width: side, height: side)

        // Is the working space linear? Composite flat white at alpha 0.5 over black. Linear says
        // the result is 0.5 linear; a gamma-encoded working space says 0.214.
        let white = CIImage(color: .white).cropped(to: extent)
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.5)
            ])
        let overBlack = white.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: Self.patch(level: 0)
        ])
        print("ANATOMY halfWhiteOverBlack lin=\(Self.stats(overBlack).mean) srgb=\(Self.means(overBlack).srgb)")

        let raw = CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: extent)
        let luma = raw.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0, kCIInputContrastKey: 1
        ])
        for (name, image) in [("random", raw), ("luma", luma),
                              ("layer0.06", Self.noiseLayer(amount: 0.06, extent: extent))] {
            let s = Self.stats(image)
            let e = Self.means(image)
            print("ANATOMY \(name) linMean=\(String(format: "%.5f", s.mean)) linSD=\(String(format: "%.5f", s.sd)) alpha=\(String(format: "%.5f", s.alpha)) srgbMean=\(String(format: "%.5f", e.srgb))")
        }

        // The composite with NO mask, which is the thing that has to be inverted.
        for level in stride(from: 0, through: 255, by: 16) {
            let base = Self.patch(level: level)
            let baseStats = Self.stats(base)
            let composited = Self.noiseLayer(amount: 0.06, extent: extent)
                .applyingFilter("CISourceOverCompositing", parameters: [
                    kCIInputBackgroundImageKey: base
                ])
            let out = Self.stats(composited)
            let masked = Self.stats(InstantFilmProcessor.grainOverlay(on: base, amount: 0.06,
                                                                      composite: .sourceOver))
            let rawLift = out.mean - baseStats.mean
            let maskedLift = masked.mean - baseStats.mean
            print("""
            ANATOMYROW level=\(level) baseLin=\(String(format: "%.5f", baseStats.mean)) \
            rawLift=\(String(format: "%+.5f", rawLift)) rawSD=\(String(format: "%.5f", out.sd)) \
            maskedLift=\(String(format: "%+.5f", maskedLift)) \
            maskEffective=\(String(format: "%.4f", abs(rawLift) > 1e-7 ? maskedLift / rawLift : 0))
            """)
        }
    }

    /// Fits `E[out]` against `base` for the shipping composite, and reports the residual the
    /// corrected one leaves behind, at 33 levels across the range.
    ///
    ///     TEST_RUNNER_FLIM_GRAIN_PROBE=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
    ///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    ///       -only-testing:FlimTests/GrainCompositeProbe
    ///
    /// (The `TEST_RUNNER_` prefix is what actually reaches a test running in the simulator; a plain
    /// environment variable on the xcodebuild command line does not, and the test silently skips.)
    ///
    /// The `grainAnchors` mask scales every delta below by an unknown-but-common factor m(L), so
    /// the LIFT column alone cannot be inverted. The RESIDUAL/LIFT ratio can: it is m-free, so a
    /// ratio of ~0 at every level proves the correction is exactly right regardless of the mask.
    /// Measured on this tree at `amount` 0.06: residual ≤ 0.00019 linear (0.00074 encoded) against
    /// lifts up to 0.0250, i.e. the composite's tone bias is down by more than 99%.
    @Test("fit the source-over bias and report what the correction leaves behind",
          .enabled(if: isProbing), arguments: [0.06, 0.12] as [CGFloat])
    func fitTheBias(_ amount: CGFloat) {
        print("PROBE amount=\(amount)")
        for level in stride(from: 0, through: 255, by: 8) {
            let clean = Self.patch(level: level)
            let base = Self.means(clean)
            let legacy = Self.means(InstantFilmProcessor.grainOverlay(on: clean, amount: amount,
                                                                       composite: .sourceOver))
            let fixed = Self.means(InstantFilmProcessor.grainOverlay(on: clean, amount: amount,
                                                                      composite: .meanPreserving))
            let lift = legacy.linear - base.linear
            let residual = fixed.linear - base.linear
            print("""
            PROBEROW amount=\(amount) level=\(level) \
            baseLin=\(String(format: "%.5f", base.linear)) \
            baseSRGB=\(String(format: "%.5f", base.srgb)) \
            liftLin=\(String(format: "%+.5f", lift)) \
            liftSRGB=\(String(format: "%+.5f", legacy.srgb - base.srgb)) \
            residLin=\(String(format: "%+.5f", residual)) \
            residSRGB=\(String(format: "%+.5f", fixed.srgb - base.srgb)) \
            ratio=\(String(format: "%+.4f", abs(lift) > 1e-6 ? residual / lift : 0))
            """)
        }
    }
}

// MARK: - The 13 real pairs, rendered production-faithfully

/// What the grain composite costs (or stops costing) on the owner's real calibration scenes.
///
/// Two things make this harness different from every other measurement in the suite, and both are
/// mandatory:
///
/// 1. **The pairs skip the production downscale.** `X_neutral.jpg` is already 1536×2048, so feeding
///    it straight in leaves grain landing 1:1 at the stored size, where it measures ~4.6× the
///    texture a real capture carries (a 12MP frame is graded at 3024×4032 and then averaged down to
///    2048). Every scene here is therefore upscaled to a 4032 long edge FIRST, so the downscale
///    branch fires and the grain that reaches the measurement is the grain that reaches a viewer.
/// 2. **Grain is stochastic but not random.** `CIRandomGenerator` is a deterministic function of
///    pixel coordinates, so the no-grain render can be subtracted from the grained one pixel by
///    pixel: the difference IS the grain, and it can be binned by tone.
///
/// Side-by-side renders for the five scenes in `shotScenes` are written to
/// `FLIM_GRAIN_OUT` (default `~/Desktop/flim-grain-review`). They are derived from the owner's
/// calibration photographs, so they are written OUTSIDE the repository and must never be committed.
///
///     TEST_RUNNER_FLIM_GRAIN_SWEEP=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/GrainCompositeSweep
struct GrainCompositeSweep {
    static let isSweeping = ProcessInfo.processInfo.environment["FLIM_GRAIN_SWEEP"] == "1"

    /// All thirteen, not the pin's five: this is a measurement of a change, not a regression pin,
    /// and the saturation gap it is chasing was reported across all thirteen.
    static let allScenes = [
        "cap", "corner-dark", "corner-lit", "laptop", "parkview-flash", "parkview-noflash",
        "plush", "restaurant-a", "restaurant-b", "sign", "steering", "wide-dim", "wide-lit"
    ]

    /// Scenes that get side-by-side renders written out. A dark scene, a dark-ish wide, a mixed
    /// tungsten interior with point lights, the most saturated scene in the set, and the scene with
    /// the worst measured saturation gap against Lapse.
    static let shotScenes = ["parkview-noflash", "wide-dim", "restaurant-a", "plush", "steering"]

    /// The long edge a real capture is graded at (12MP, 3024×4032), which is what the pairs have to
    /// be upscaled to before the storage downscale means anything.
    static let captureLongEdge: CGFloat = 4032

    /// `sourceover` is no longer the shipped row; 1.5.1 flipped the default to `meanpreserving`
    /// because shadow-peaked grain cannot be had on a mean-shifting composite (see
    /// `InstantFilmProcessor.GrainComposite`). Both stay here so the flip stays measurable.
    ///
    /// Overlay and soft light were measured here too, on 2026-08-17, from a build that carried them
    /// as two extra `GrainComposite` cases. Both were rejected and removed rather than left in the
    /// shipping enum: soft light lifted the midtone band +0.0033 (so it is not mean-preserving at
    /// all), and overlay, while mean-preserving, needs a completely different noise layer and
    /// delivered 0.11× this composite's texture at the closest scale tried. See the rationale on
    /// `InstantFilmProcessor.precompensated`. Re-adding a case here is all it takes to re-measure.
    static let modes: [(name: String, composite: InstantFilmProcessor.GrainComposite)] = [
        ("sourceover", .sourceOver),
        ("meanpreserving", .meanPreserving)
    ]

    static var outputDirectory: URL = {
        let preferred = ProcessInfo.processInfo.environment["FLIM_GRAIN_OUT"]
            ?? "/Users/bisramc/Desktop/flim-grain-review"
        for path in [preferred, NSTemporaryDirectory() + "flim-grain-review"] {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if (try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)) != nil {
                return url
            }
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }()

    // MARK: Inputs

    static func lapseData(_ scene: String) -> Data? {
        try? Data(contentsOf: LookPairs.directory.appendingPathComponent("\(scene)_lapse.jpg"))
    }

    /// The neutral capture, upscaled to capture resolution and re-encoded LOSSLESSLY (PNG), so the
    /// only thing this adds to the pipeline is pixel count. JPEG here would put a second generation
    /// of DCT noise underneath the grain being measured.
    static func upscaledNeutral(_ scene: String) -> Data? {
        guard let data = LookPairs.neutralData(scene),
              let image = CIImage(data: data, options: [.applyOrientationProperty: true])
        else { return nil }
        let edge = max(image.extent.width, image.extent.height)
        let scaled = image.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: captureLongEdge / edge, kCIInputAspectRatioKey: 1.0
        ])
        guard let cg = LookMeasure.context.createCGImage(scaled, from: scaled.extent,
                                                         format: .RGBA8,
                                                         colorSpace: LookMeasure.srgb)
        else { return nil }
        return png(cg)
    }

    static func png(_ cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                          1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// The shipping stock with grain switched off, for the control render. Nothing else differs.
    static var grainlessStock: FilmStock {
        var params = FilmStock.original.params
        params.grain = 0
        return FilmStock(id: FilmStock.original.id, name: FilmStock.original.name,
                         tagline: FilmStock.original.tagline, params: params)
    }

    // MARK: Pixel helpers

    static func rgba(_ cg: CGImage) -> (pixels: [UInt8], width: Int, height: Int)? {
        let w = cg.width, h = cg.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: LookMeasure.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (pixels, w, h)
    }

    static func luma(_ p: [UInt8], _ i: Int) -> Double {
        (0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2])) / 255
    }

    /// Grain as a signed difference from the grainless render, binned by the tone it landed on.
    ///
    /// `mean` is the light the composite ADDS in that band (the bug, in one number per band) and
    /// `rms` is the texture it delivers there (what must survive the fix).
    struct GrainBand {
        var name: String, mean: Double, rms: Double, share: Double
    }

    static func grainBands(grained: [UInt8], clean: [UInt8], count: Int) -> [GrainBand] {
        let edges: [(String, Double, Double)] = [
            ("shadow", 0.0, 0.25), ("mid", 0.25, 0.60), ("high", 0.60, 1.01), ("all", 0.0, 1.01)
        ]
        var sums = [Double](repeating: 0, count: edges.count)
        var squares = [Double](repeating: 0, count: edges.count)
        var counts = [Double](repeating: 0, count: edges.count)
        for i in stride(from: 0, to: count * 4, by: 4) {
            let base = luma(clean, i)
            let delta = luma(grained, i) - base
            for (j, edge) in edges.enumerated() where base >= edge.1 && base < edge.2 {
                sums[j] += delta; squares[j] += delta * delta; counts[j] += 1
            }
        }
        return edges.enumerated().map { j, edge in
            let n = max(counts[j], 1)
            return GrainBand(name: edge.0, mean: sums[j] / n, rms: (squares[j] / n).squareRoot(),
                             share: counts[j] / Double(count))
        }
    }

    // MARK: Sweep

    @Test("grain composite sweep across the owner's 13 calibration scenes",
          .enabled(if: isSweeping && LookPairs.isAvailable), arguments: allScenes)
    func sweep(_ scene: String) async throws {
        let data = try #require(Self.upscaledNeutral(scene), "no neutral for \(scene)")

        // Lapse's own rendering of the same frame, the target the saturation gap is measured against.
        if let lapse = Self.lapseData(scene), let stats = LookMeasure.stats(ofJPEG: lapse) {
            print("GSWEEP scene=\(scene) mode=lapse \(Self.fields(stats))")
        }

        // The control: identical pipeline, grain amount 0.
        let control = try #require(await InstantFilmProcessor.process(data, stock: Self.grainlessStock))
        let controlCG = try #require(LookMeasure.decode(control.data))
        let controlPixels = try #require(Self.rgba(controlCG))
        print("GSWEEP scene=\(scene) mode=nograin \(Self.fields(try #require(LookMeasure.stats(of: controlCG)))) w=\(controlCG.width) h=\(controlCG.height)")

        var renders: [String: CGImage] = [:]
        for mode in Self.modes {
            let out = try #require(await InstantFilmProcessor.process(data, stock: .original,
                                                                       grain: mode.composite))
            let cg = try #require(LookMeasure.decode(out.data))
            renders[mode.name] = cg
            let stats = try #require(LookMeasure.stats(of: cg))
            let pixels = try #require(Self.rgba(cg))
            let bands = Self.grainBands(grained: pixels.pixels, clean: controlPixels.pixels,
                                        count: pixels.width * pixels.height)
            let bandFields = bands.map { band -> String in
                let mean = String(format: "%+.5f", band.mean)
                let rms = String(format: "%.5f", band.rms)
                let share = String(format: "%.3f", band.share)
                return "\(band.name)Mean=\(mean) \(band.name)RMS=\(rms) \(band.name)Share=\(share)"
            }.joined(separator: " ")
            print("GSWEEP scene=\(scene) mode=\(mode.name) \(Self.fields(stats)) bytes=\(out.data.count) \(bandFields)")
        }

        if Self.shotScenes.contains(scene),
           let before = renders["sourceover"], let after = renders["meanpreserving"] {
            Self.writeComparisons(scene: scene, before: before, after: after, control: controlCG)
        }
    }

    static func fields(_ s: LookStats) -> String {
        let lum = 0.299 * s.meanR + 0.587 * s.meanG + 0.114 * s.meanB
        return "meanLum=\(String(format: "%.5f", lum)) " + s.fields.map {
            "\($0.name)=\(String(format: "%.5f", $0.value))"
        }.joined(separator: " ")
    }

    // MARK: Side-by-side renders

    /// Writes the review shots: a full-frame A/B, and two 1:1 crops (the frame's darkest tile and
    /// its centre) where grain is actually resolvable on screen.
    static func writeComparisons(scene: String, before: CGImage, after: CGImage, control: CGImage) {
        let dir = outputDirectory
        write(png(before), to: dir.appendingPathComponent("\(scene)_1_current.png"))
        write(png(after), to: dir.appendingPathComponent("\(scene)_2_meanpreserving.png"))
        if let pair = sideBySide(before, after) {
            write(png(pair), to: dir.appendingPathComponent("\(scene)_3_sidebyside.png"))
        }
        let side = 560
        for (label, origin) in [("darkest", darkestTile(control, side: side)),
                                ("centre", CGPoint(x: (control.width - side) / 2,
                                                   y: (control.height - side) / 2))] {
            let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(side), height: CGFloat(side))
            guard let a = before.cropping(to: rect), let b = after.cropping(to: rect),
                  let pair = sideBySide(a, b) else { continue }
            write(png(pair), to: dir.appendingPathComponent("\(scene)_4_crop-\(label)-1to1.png"))
        }
    }

    /// Top-left corner of the darkest `side`×`side` tile, on a coarse grid. Grain's mean-lift is
    /// most visible where there is least light, so the review crop is chosen by measurement rather
    /// than by eye.
    static func darkestTile(_ cg: CGImage, side: Int) -> CGPoint {
        guard let (pixels, w, h) = rgba(cg).map({ ($0.pixels, $0.width, $0.height) }),
              w > side, h > side else { return .zero }
        var best = CGPoint.zero
        var bestMean = Double.infinity
        let step = 140
        for y in stride(from: 0, through: h - side, by: step) {
            for x in stride(from: 0, through: w - side, by: step) {
                var sum = 0.0
                // Sampled on an 8px lattice: this only has to rank tiles, not measure them.
                for sy in stride(from: 0, to: side, by: 8) {
                    for sx in stride(from: 0, to: side, by: 8) {
                        sum += luma(pixels, ((y + sy) * w + (x + sx)) * 4)
                    }
                }
                if sum < bestMean { bestMean = sum; best = CGPoint(x: x, y: y) }
            }
        }
        return best
    }

    static func sideBySide(_ left: CGImage, _ right: CGImage) -> CGImage? {
        let gap = 12
        let w = left.width + right.width + gap, h = max(left.height, right.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: LookMeasure.srgb,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(left, in: CGRect(x: 0, y: 0, width: left.width, height: left.height))
        ctx.draw(right, in: CGRect(x: left.width + gap, y: 0,
                                   width: right.width, height: right.height))
        return ctx.makeImage()
    }

    static func write(_ data: Data?, to url: URL) {
        guard let data else { return }
        do {
            try data.write(to: url)
            print("GSHOT wrote \(url.path) (\(data.count) bytes)")
        } catch {
            print("GSHOT FAILED \(url.path): \(error)")
        }
    }
}

// MARK: - Where the grain sits on the tone curve, against Lapse

/// The measurement the 1.5.1 grain work was fitted from: how much texture Lapse puts in each tone
/// band, how much FLIM puts there, and what a candidate profile does to the ratio.
///
/// THE ESTIMATOR, and why it is not the difference-of-renders one above. `grainBands` subtracts a
/// grainless render from a grained one, which is exact, and impossible on Lapse's output: there is
/// no grainless Lapse. So this measures a single image instead, and it has to separate grain from
/// scene detail without a control:
///
///   1. Luma is box-downsampled 2x into a STRUCTURE image, which halves the grain and keeps the
///      scene. Every decision below (which band a pixel is in, whether it is flat) is made on that
///      image rather than on the noisy one, so the noise cannot select its own sample.
///   2. A pixel counts only if the structure image is FLAT around it (its 4-neighbour gradient is
///      under 0.02, i.e. five 8-bit levels across two structure pixels). In a flat region every
///      high-frequency component left IS grain.
///   3. Grain amplitude is read off the 1D Laplacian d = L(x) − (L(x−1) + L(x+1))/2, which is zero
///      on any linear ramp, so a gentle gradient that survived step 2 still contributes nothing.
///      For white noise Var(d) = 1.5·σ², hence the √1.5.
///
/// It is validated rather than trusted: `estimatorAgreesWithTheControlledMeasurement` runs it on a
/// FLIM render and on the same render with grain switched off, and checks the difference it reports
/// matches what subtracting the two renders says. Systematic error that survives that check is
/// common to FLIM and to Lapse, because both are measured the identical way, which is what makes
/// the RATIO the number to read.
///
///     TEST_RUNNER_FLIM_GRAIN_TUNE=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///       -only-testing:FlimTests/GrainProfileSweep/tune
@Suite(.serialized)
struct GrainProfileSweep {
    static let isTuning = ProcessInfo.processInfo.environment["FLIM_GRAIN_TUNE"] == "1"
    static let isReporting = ProcessInfo.processInfo.environment["FLIM_GRAIN_REPORT"] == "1"
    static let isPreviewing = ProcessInfo.processInfo.environment["FLIM_GRAIN_PREVIEW"] == "1"

    /// Every pair that is fit to be measured against.
    ///
    /// `corner-dark` and `hallway-noflash` are excluded for the reasons written down in
    /// `scripts/fit_lut.py`'s `DEFAULT_EXCLUDE`: the first was rendered by Lapse 0.9 stop DARKER
    /// than its own neutral, the second is a black room whose Lapse frame is ~95% sensor noise, and
    /// a grain measurement against a frame that IS noise would be the worst possible target.
    /// `hallway-flash` is the only hold-out (shot after the LUT was fitted) and is reported apart
    /// from the rest.
    static let inSample = ["cap", "corner-lit", "laptop", "parkview-flash", "parkview-noflash",
                           "plush", "restaurant-a", "restaurant-b", "sign", "steering",
                           "wide-dim", "wide-lit"]
    static let holdOut = "hallway-flash"
    static let allValid = inSample + [holdOut]

    /// The subset the candidate search runs on: the darkest scene, a dark-ish wide, a mixed
    /// tungsten interior, the most saturated scene, the worst measured saturation gap, and a flash
    /// frame (where shadow-peaked grain meets the falloff's floor).
    static let tuningScenes = ["parkview-noflash", "wide-dim", "restaurant-a", "plush", "steering",
                               "parkview-flash"]

    // MARK: Tone bands

    static let bands: [(name: String, lo: Double, hi: Double)] = [
        ("shadow", 0.00, 0.15),     // where Lapse peaks
        ("low", 0.15, 0.35),
        ("mid", 0.35, 0.60),
        ("high", 0.60, 1.01),
        ("all", 0.00, 1.01)
    ]

    struct Texture {
        var sigma: [Double]         // grain amplitude per band, 0...1
        var share: [Double]         // fraction of the frame each band's flat sample came from
        var saturation: [Double]    // mean HSV saturation per band, for the coupling
    }

    /// Flat-region grain amplitude per tone band. See the type comment for the method.
    static func texture(_ cg: CGImage, flatness: Double = 0.02) -> Texture? {
        guard let (px, w, h) = GrainCompositeSweep.rgba(cg).map({ ($0.pixels, $0.width, $0.height) }),
              w > 4, h > 4
        else { return nil }
        var luma = [Double](repeating: 0, count: w * h)
        var sat = [Double](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let j = i * 4
            let r = Double(px[j]) / 255, g = Double(px[j + 1]) / 255, b = Double(px[j + 2]) / 255
            luma[i] = 0.299 * r + 0.587 * g + 0.114 * b
            let mx = max(r, max(g, b)), mn = min(r, min(g, b))
            sat[i] = mx > 0 ? (mx - mn) / mx : 0
        }
        // Structure image: 2x box downsample, so the grain in it is halved and the scene is not.
        let sw = w / 2, sh = h / 2
        var structure = [Double](repeating: 0, count: sw * sh)
        for y in 0..<sh {
            for x in 0..<sw {
                let a = luma[(y * 2) * w + x * 2], b = luma[(y * 2) * w + x * 2 + 1]
                let c = luma[(y * 2 + 1) * w + x * 2], d = luma[(y * 2 + 1) * w + x * 2 + 1]
                structure[y * sw + x] = (a + b + c + d) / 4
            }
        }

        var squares = [Double](repeating: 0, count: bands.count)
        var counts = [Double](repeating: 0, count: bands.count)
        var sats = [Double](repeating: 0, count: bands.count)
        for y in 2..<(h - 2) {
            let sy = y / 2
            guard sy >= 1, sy < sh - 1 else { continue }
            for x in 2..<(w - 2) {
                let sx = x / 2
                guard sx >= 1, sx < sw - 1 else { continue }
                let s = structure[sy * sw + sx]
                let gx = abs(structure[sy * sw + sx + 1] - structure[sy * sw + sx - 1])
                let gy = abs(structure[(sy + 1) * sw + sx] - structure[(sy - 1) * sw + sx])
                guard gx + gy < flatness else { continue }
                let d = luma[y * w + x] - (luma[y * w + x - 1] + luma[y * w + x + 1]) / 2
                for (j, band) in bands.enumerated() where s >= band.lo && s < band.hi {
                    squares[j] += d * d
                    counts[j] += 1
                    sats[j] += sat[y * w + x]
                }
            }
        }
        let total = Double(w * h)
        return Texture(
            sigma: (0..<bands.count).map { (squares[$0] / max(counts[$0], 1) / 1.5).squareRoot() },
            share: (0..<bands.count).map { counts[$0] / total },
            saturation: (0..<bands.count).map { sats[$0] / max(counts[$0], 1) })
    }

    static func textureFields(_ prefix: String, _ t: Texture) -> String {
        bands.enumerated().map { j, band in
            "\(prefix)\(band.name)Sigma=\(String(format: "%.5f", t.sigma[j])) "
            + "\(prefix)\(band.name)Share=\(String(format: "%.4f", t.share[j])) "
            + "\(prefix)\(band.name)Sat=\(String(format: "%.4f", t.saturation[j]))"
        }.joined(separator: " ")
    }

    // MARK: Candidates

    /// A candidate grain: an amount, a profile, and a composite. `legacy` is what ships and every
    /// other row is measured against it.
    struct Candidate {
        var label: String
        var amount: CGFloat
        var profile: GrainProfile
        var composite: InstantFilmProcessor.GrainComposite

        var stock: FilmStock {
            var params = FilmStock.original.params
            params.grain = amount
            params.grainProfile = profile
            return FilmStock(id: "grain-\(label)", name: label, tagline: "", params: params)
        }
    }

    /// The shipped grain, and the control every other row is measured against. It carries the
    /// `legacy` name it was given when it was expected to be replaced; 1.5.1 replaced it for one
    /// release and was reverted, so this is production again.
    static let legacy = Candidate(label: "legacy", amount: 0.06, profile: .midtone,
                                  composite: .sourceOver)

    /// A profile written in COVERAGE, which is the only readable way to write one: the tone curve
    /// linearises its own output twice on the way to the blend, so a control point of 0.30 lands
    /// 0.0054 of coverage. See `InstantFilmProcessor.grainCoverage`.
    static func profile(_ coverage: [(CGFloat, CGFloat)], chroma: CGFloat,
                        evPush: CGFloat = 0) -> GrainProfile {
        GrainProfile(anchors: coverage.map { GrainAnchor(luminance: $0.0, coverage: $0.1) },
                     chroma: chroma, evPush: evPush)
    }

    /// The shadow-peaked shape at three strengths, plus the two axes that can be varied
    /// independently of it (chroma, and whether the composite shifts the mean).
    ///
    /// The shape is Lapse's, measured: its grain peaks over 0-0.15 luma and falls away through the
    /// midtone, where FLIM's peaked at the midtone and put essentially nothing in the shadows. What
    /// is NOT known in advance is the strength, because coverage buys far more texture in the
    /// shadows than in the midtones (the sRGB transfer function is ~6x steeper there), so the three
    /// strengths bracket the prediction rather than assume it.
    static var candidates: [Candidate] {
        guard ProcessInfo.processInfo.environment["FLIM_GRAIN_CANDIDATES"] == "1" else {
            // Default pass: the target and the control only. Every fit starts from Lapse's own
            // per-band texture and the legacy grain's, and neither needs a candidate rendered.
            return [legacy]
        }
        func shape(_ shadow: CGFloat, _ mid: CGFloat, _ high: CGFloat, _ white: CGFloat)
            -> [(CGFloat, CGFloat)] {
            [(0.00, shadow), (0.15, shadow), (0.40, mid), (0.70, high), (1.00, white)]
        }
        let fitted = shape(0.35, 0.20, 0.07, 0.02)

        var out: [Candidate] = [legacy]
        // The composite alone, with the legacy mask: what the DC fix costs and buys on its own.
        out.append(Candidate(label: "mp-only", amount: 0.06, profile: .midtone,
                             composite: .meanPreserving))
        // Chroma at the FITTED strength, so its effect is read where it will actually ship rather
        // than at a strength nothing will use.
        for chroma in [0, 0.25, 0.5] as [CGFloat] {
            out.append(Candidate(label: "fit-c\(Int(chroma * 100))", amount: 0.06,
                                 profile: profile(fitted, chroma: chroma),
                                 composite: .meanPreserving))
        }
        // Half a strength either side of the fit, so the fit is on the record as a choice between
        // measured neighbours rather than as a single row.
        out.append(Candidate(label: "fit-weak", amount: 0.06,
                             profile: profile(shape(0.25, 0.15, 0.05, 0.02), chroma: 0.25),
                             composite: .meanPreserving))
        out.append(Candidate(label: "fit-strong", amount: 0.06,
                             profile: profile(shape(0.50, 0.28, 0.10, 0.03), chroma: 0.25),
                             composite: .meanPreserving))
        return out
    }

    // MARK: Rendering

    static func render(_ scene: String, _ candidate: Candidate) async
        -> InstantFilmProcessor.EncodedImage? {
        guard let data = GrainCompositeSweep.upscaledNeutral(scene) else { return nil }
        return await InstantFilmProcessor.process(data, stock: candidate.stock,
                                                  grain: candidate.composite)
    }

    static func row(_ scene: String, _ label: String, _ cg: CGImage, feed: Data? = nil) {
        guard let stats = LookMeasure.stats(of: cg), let t = texture(cg) else { return }
        // The 1400px feed card as well as the master, because the card is the rendition people
        // actually look at and the one whose JPEG has the least budget for fine texture. A grain
        // change that only survives at 2048 is a change nobody sees.
        var card = ""
        if let feed, let feedCG = LookMeasure.decode(feed), let feedStats = LookMeasure.stats(of: feedCG),
           let feedTexture = texture(feedCG) {
            card = " feedBytes=\(feed.count) "
                + "feedLC=\(String(format: "%.5f", feedStats.localContrast)) "
                + "feedSat=\(String(format: "%.5f", feedStats.meanSaturation)) "
                + "feedShadowSigma=\(String(format: "%.5f", feedTexture.sigma[0]))"
        }
        print("""
        GPROFILE scene=\(scene) mode=\(label) \(GrainCompositeSweep.fields(stats)) \
        \(textureFields("", t))\(card)
        """)
    }

    // MARK: Tests

    @Test("the flat-region estimator agrees with the controlled difference measurement",
          .enabled(if: LookPairs.isAvailable))
    func estimatorAgreesWithTheControlledMeasurement() async throws {
        // One scene, both ways. The estimator has to reproduce a number that is known exactly,
        // or every ratio it reports against Lapse is decoration.
        let data = try #require(GrainCompositeSweep.upscaledNeutral("wide-lit"))
        let grained = try #require(await InstantFilmProcessor.process(data, stock: .original))
        let clean = try #require(await InstantFilmProcessor.process(
            data, stock: GrainCompositeSweep.grainlessStock))
        let grainedCG = try #require(LookMeasure.decode(grained.data))
        let cleanCG = try #require(LookMeasure.decode(clean.data))

        let withGrain = try #require(Self.texture(grainedCG))
        let without = try #require(Self.texture(cleanCG))
        let controlled = GrainCompositeSweep.grainBands(
            grained: try #require(GrainCompositeSweep.rgba(grainedCG)).pixels,
            clean: try #require(GrainCompositeSweep.rgba(cleanCG)).pixels,
            count: grainedCG.width * grainedCG.height)

        // The estimator's grain term: what is left after the grainless render's own flat-region
        // energy (JPEG texture, sensor noise in the capture) is removed in quadrature.
        let allIndex = Self.bands.firstIndex { $0.name == "all" }!
        let estimated = (max(0, withGrain.sigma[allIndex] * withGrain.sigma[allIndex]
                             - without.sigma[allIndex] * without.sigma[allIndex])).squareRoot()
        let truth = controlled.first { $0.name == "all" }?.rms ?? 0
        print("""
        GESTIMATOR withGrain=\(String(format: "%.5f", withGrain.sigma[allIndex])) \
        without=\(String(format: "%.5f", without.sigma[allIndex])) \
        estimated=\(String(format: "%.5f", estimated)) controlled=\(String(format: "%.5f", truth)) \
        ratio=\(String(format: "%.3f", truth > 0 ? estimated / truth : 0))
        """)
        // A CONSTANT-FACTOR agreement is all that is claimed, and the factor is expected to be
        // below 1: the estimator reads a 1D Laplacian, whose variance is 1.5x the sample variance
        // only for genuinely white noise, and the grain that reaches the stored image is not white
        // any more. It was generated at capture resolution and averaged down to 2048, so
        // neighbouring pixels are positively correlated (0.6-0.9px, measured 2026-08-14) and the
        // Laplacian cancels part of it.
        //
        // THE FACTOR DEPENDS ON THE GRAIN, which is why the band is wide. Measured on `wide-lit`:
        // 0.45 of the controlled value with `GrainProfile.pushed` (2026-09-01) and 0.15 with the
        // shipped `.midtone` (2026-09-03, after the revert). The difference is not the estimator
        // getting worse, it is the quadrature subtraction having less to recover: the shipped grain
        // leaves the scene's own flat-region energy at 0.00534 against 0.00660 with grain, so most
        // of what the tiles measure is the photograph rather than the noise. That is fine for the
        // thing this is used for, because FLIM and Lapse are measured the identical way and their
        // grain has the same spatial scale, so the bias divides out of the RATIO. What the bound
        // catches is the estimator reading zero, or reading MORE than the truth, either of which
        // would mean it is measuring something other than grain.
        #expect(estimated > truth * 0.10 && estimated < truth * 1.2, """
            the flat-region estimator says \(estimated) where subtracting the two renders says \
            \(truth). Outside a constant factor it is measuring something other than grain.
            """)
    }

    @Test("candidate sweep", .enabled(if: isTuning && LookPairs.isAvailable),
          arguments: tuningScenes)
    func tune(_ scene: String) async throws {
        try await Self.reportScene(scene, candidates: Self.candidates)
    }

    @Test("before and after on every valid pair", .enabled(if: isReporting && LookPairs.isAvailable),
          arguments: allValid)
    func report(_ scene: String) async throws {
        // The composite is not carried on `FilmParams`, so it has to be restated here, and it must
        // match `InstantFilmProcessor.GrainComposite`'s default or this reports a look nobody
        // ships. Since the 1.5.1 revert this row is `legacy` by construction; it stays separate so
        // that a trial candidate put on the stock shows up here without editing the sweep.
        let shipping = Candidate(label: "shipping", amount: FilmStock.original.params.grain,
                                 profile: FilmStock.original.params.grainProfile,
                                 composite: .sourceOver)
        try await Self.reportScene(scene, candidates: [Self.legacy, shipping])
    }

    static func reportScene(_ scene: String, candidates: [Candidate]) async throws {
        // Lapse's own rendering of the same frame: the target every ratio is taken against.
        if let lapseData = GrainCompositeSweep.lapseData(scene), let lapse = lapseCG(scene) {
            row(scene, "lapse", lapse,
                feed: InstantFilmProcessor.feedRendition(from: lapseData)?.data)
        }
        // The pipeline with no grain at all, so the scene's own flat-region energy is on the record
        // and the grain term can be separated from it.
        let data = try #require(GrainCompositeSweep.upscaledNeutral(scene))
        print("GINPUT scene=\(scene) meanLum=\(String(format: "%.5f", LookMeasure.inputMeanLuminance(ofJPEG: data)))")
        if let clean = await InstantFilmProcessor.process(data, stock: GrainCompositeSweep.grainlessStock),
           let cg = LookMeasure.decode(clean.data) {
            row(scene, "nograin", cg, feed: InstantFilmProcessor.feedRendition(from: clean.data)?.data)
        }
        for candidate in candidates {
            guard let out = await render(scene, candidate),
                  let cg = LookMeasure.decode(out.data) else { continue }
            row(scene, candidate.label, cg,
                feed: InstantFilmProcessor.feedRendition(from: out.data)?.data)
        }
    }

    /// Before/after renders for the owner, through the production path: the shipped grain against
    /// whatever is on the stock.
    ///
    /// THIS IS THE TEST THAT SETTLED IT. The numbers said the shadow texture matched Lapse and the
    /// saturation gap closed; the owner looked at these frames on a device and did not want them,
    /// and 1.5.1 was reverted on 2026-09-03. Grain is the thing nobody has ever settled with a
    /// statistic, because the failure mode is "it reads as dirt" and dirt and film grain measure
    /// the same. Since the revert both halves render the same look by construction, which is itself
    /// the check that a revert is complete.
    ///
    ///     TEST_RUNNER_FLIM_GRAIN_PREVIEW=1 xcodebuild test -project Flim.xcodeproj -scheme Flim \
    ///       -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    ///       -only-testing:FlimTests/GrainProfileSweep/writePreviews
    ///
    /// Each scene is written three ways: the full frame before, the full frame after, and a 1:1
    /// side-by-side crop of the frame's DARKEST tile, which is where this change does nearly all of
    /// its work and the only magnification at which 2048px grain is honestly visible on a desk
    /// monitor. Output goes to `pairs/_grain_preview/`, inside the gitignored calibration directory
    /// and deliberately so: these are renders of the owner's own photographs.
    ///
    /// The flash scenes are forced through the falloff with `flashOverride`, because the Film Lab's
    /// neutral export strips EXIF and they would otherwise preview as ambient frames. That is the
    /// interesting frame for this change: shadow-peaked grain lands hardest exactly where the
    /// falloff just put its floor.
    @Test("write before/after grain previews for the owner",
          .enabled(if: isPreviewing && LookPairs.isAvailable),
          arguments: ["wide-lit", "restaurant-a", "parkview-flash", "hallway-flash", "steering",
                      "plush"])
    func writePreviews(_ scene: String) async throws {
        let directory = LookPairs.directory.appendingPathComponent("_grain_preview")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(GrainCompositeSweep.upscaledNeutral(scene))
        // Same restatement as `report`, same requirement: this has to be the default in
        // `InstantFilmProcessor.GrainComposite` or the "after" frame is not what a capture makes.
        let shipping = Candidate(label: "after", amount: FilmStock.original.params.grain,
                                 profile: FilmStock.original.params.grainProfile,
                                 composite: .sourceOver)
        let flash = scene.hasSuffix("-flash")

        var renders: [String: CGImage] = [:]
        for candidate in [Candidate(label: "before", amount: Self.legacy.amount,
                                    profile: Self.legacy.profile,
                                    composite: Self.legacy.composite), shipping] {
            let out = try #require(await InstantFilmProcessor.process(
                data, stock: candidate.stock, grain: candidate.composite,
                flashOverride: flash ? true : nil))
            let url = directory.appendingPathComponent("\(scene)_\(candidate.label).jpg")
            try out.data.write(to: url)
            print("GRAINPREVIEW \(url.path)")
            renders[candidate.label] = LookMeasure.decode(out.data)
        }
        guard let before = renders["before"], let after = renders["after"] else { return }
        let side = 560
        let origin = GrainCompositeSweep.darkestTile(before, side: side)
        let rect = CGRect(x: origin.x, y: origin.y, width: CGFloat(side), height: CGFloat(side))
        guard let a = before.cropping(to: rect), let b = after.cropping(to: rect),
              let pair = GrainCompositeSweep.sideBySide(a, b),
              let png = GrainCompositeSweep.png(pair) else { return }
        let url = directory.appendingPathComponent("\(scene)_crop-darkest-1to1.png")
        try png.write(to: url)
        print("GRAINPREVIEW \(url.path)")
    }

    static func lapseCG(_ scene: String) -> CGImage? {
        GrainCompositeSweep.lapseData(scene).flatMap { LookMeasure.decode($0) }
    }
}

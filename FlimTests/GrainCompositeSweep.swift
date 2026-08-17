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

    /// The bug, stated as a test so the fix is not measured against a moving target: the composite
    /// that shipped until 2026-08-17 is a white veil at random opacity, so it only ever ADDS light,
    /// and it adds most of it where the picture has least.
    @Test("the source-over composite really does add light, which is why this changed")
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
    static func noiseLayer(amount: CGFloat, extent: CGRect) -> CIImage {
        CIFilter(name: "CIRandomGenerator")!.outputImage!
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0, kCIInputContrastKey: 1
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
            ])
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

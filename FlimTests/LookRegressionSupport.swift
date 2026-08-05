import CoreImage
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Flim

// MARK: - Measured statistics

/// The summary statistics the look regression pin is built on.
///
/// Every one of these is an average (or a percentile) over the WHOLE frame. That was chosen to
/// survive stochastic grain, on the assumption that `CIRandomGenerator` (which takes no seed)
/// would make individual pixels irreproducible. Measured, it turns out not to: the generator is a
/// deterministic function of pixel coordinates, every image here renders at a fixed extent
/// anchored at the origin, and the whole pipeline came back bit-identical across repeats,
/// processes and simulator device models. Frame averages are kept anyway, because they are what
/// makes the numbers mean something a person could look at, and because a future Core Image that
/// does seed its noise would only cost this pin a little precision instead of breaking it.
struct LookStats {
    /// Mean of each channel, 0...1. Catches any shift in the grade's colour balance.
    var meanR: Double
    var meanG: Double
    var meanB: Double
    /// Rec.601 luminance percentiles, 0...1. p5 catches lifted/crushed blacks, p95 catches
    /// highlight rolloff and bloom, p50 catches overall exposure.
    var lumP5: Double
    var lumP50: Double
    var lumP95: Double
    /// Mean HSV saturation, 0...1. Catches the LUT being swapped, desaturated, or bypassed.
    var meanSaturation: Double
    /// Mean absolute luminance difference between horizontally adjacent pixels, 0...1.
    ///
    /// This is the only statistic that sees SPATIAL structure, and it is here for one specific
    /// failure: grain and bloom are applied at full resolution and the downscale to 2048 averages
    /// them down on purpose (see the ordering comment in `InstantFilmProcessor.processSync`). Move
    /// the downscale earlier and every frame-average statistic above stays put while grain stops
    /// being averaged and starts reading as dirt. This number moves when that happens.
    var localContrast: Double

    /// Field-by-field names and values, for diffing a failure against the baseline.
    var fields: [(name: String, value: Double)] {
        [("meanR", meanR), ("meanG", meanG), ("meanB", meanB),
         ("lumP5", lumP5), ("lumP50", lumP50), ("lumP95", lumP95),
         ("saturation", meanSaturation), ("localContrast", localContrast)]
    }
}

enum LookMeasure {
    /// One shared context, like the processor's own. Building one per render is slow and, on the
    /// simulator, occasionally picks a different backing device, which is a source of drift we do
    /// not want inside a tolerance measurement.
    static let context = CIContext()
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Rec.601, the same weighting `InstantFilmProcessor` uses for its own luminance decisions, so
    /// "midtone" means the same thing in the pin as it does in the pipeline.
    private static func luma(_ r: Double, _ g: Double, _ b: Double) -> Double {
        0.299 * r + 0.587 * g + 0.114 * b
    }

    /// Decodes finished JPEG bytes and measures them. Deliberately measures the ENCODED output
    /// rather than the CIImage: the JPEG round-trip at quality 0.85 is part of what ships, and a
    /// change to it (quality, colour space, encoder) changes the photo people actually see.
    static func stats(ofJPEG data: Data) -> LookStats? {
        guard let cg = decode(data) else { return nil }
        return stats(of: cg)
    }

    static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func stats(of cg: CGImage) -> LookStats? {
        let w = cg.width, h = cg.height
        guard w > 1, h > 1 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumSat = 0.0, sumEdge = 0.0
        var histogram = [Int](repeating: 0, count: 256)

        for y in 0..<h {
            let row = y * w * 4
            var previousLuma = 0.0
            for x in 0..<w {
                let i = row + x * 4
                let r = Double(pixels[i]) / 255
                let g = Double(pixels[i + 1]) / 255
                let b = Double(pixels[i + 2]) / 255
                sumR += r; sumG += g; sumB += b

                let mx = max(r, max(g, b)), mn = min(r, min(g, b))
                if mx > 0 { sumSat += (mx - mn) / mx }

                let l = luma(r, g, b)
                // 8-bit output, so a 256-bin histogram is exact rather than an approximation.
                histogram[min(255, max(0, Int((l * 255).rounded())))] += 1
                if x > 0 { sumEdge += abs(l - previousLuma) }
                previousLuma = l
            }
        }

        let n = Double(w * h)
        func percentile(_ p: Double) -> Double {
            let target = p * n
            var cumulative = 0.0
            for bin in 0..<256 {
                cumulative += Double(histogram[bin])
                if cumulative >= target { return Double(bin) / 255 }
            }
            return 1
        }

        return LookStats(
            meanR: sumR / n, meanG: sumG / n, meanB: sumB / n,
            lumP5: percentile(0.05), lumP50: percentile(0.50), lumP95: percentile(0.95),
            meanSaturation: sumSat / n,
            localContrast: sumEdge / Double((w - 1) * h)
        )
    }

    /// Mean scene luminance of an INPUT, by the same route `InstantFilmProcessor` uses to decide
    /// adaptive exposure and dark-scene bloom (CIAreaAverage, read back through device RGB, Rec.601).
    ///
    /// Reimplemented here rather than exposed from the processor because it is used only to record
    /// which branch each fixture lands in. The exposure FORMULA is not duplicated: it lives in
    /// `InstantFilmProcessor` and `scripts/fit_lut.py` only, and this pin covers it through the
    /// rendered result instead of by restating it.
    static func inputMeanLuminance(ofJPEG data: Data) -> Double {
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
              let avg = CIFilter(name: "CIAreaAverage", parameters: [
                  kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)
              ])?.outputImage else { return 0 }
        var px: [UInt8] = [0, 0, 0, 0]
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return luma(Double(px[0]) / 255, Double(px[1]) / 255, Double(px[2]) / 255)
    }
}

// MARK: - Synthetic scenes

/// Deterministic stand-in scenes, rendered from arithmetic rather than loaded from disk.
///
/// The calibration photographs in `pairs/` cannot carry this pin on their own. They are gitignored
/// on purpose (they are photographs of the owner's life, see `.gitignore`), so nothing that depends
/// on them can run on a fresh clone or in CI. They also happen to miss two branches of the
/// pipeline entirely: every neutral capture is already 1536×2048, so none of them crosses the
/// 2048 storage cap and none exercises the downscale, and only one is dark enough to trip adaptive
/// exposure at all, by 0.03 EV, which is far too small a signal to pin the formula with.
///
/// These fixtures are chosen to cover exactly what the photographs cannot:
///
/// | fixture   | input mean luminance | what it pins                                        |
/// |-----------|----------------------|-----------------------------------------------------|
/// | night     | 0.055                | adaptive EV at its 0.5 clamp, bloom at its 0.35 floor |
/// | dusk      | 0.133                | adaptive EV on its linear slope, bloom mid-ramp      |
/// | oversize  | 0.366                | the >2048 downscale, and grain averaged by it       |
/// | daylight  | 0.504                | no EV, full bloom, ordinary content                  |
/// | gamut     | 0.529                | the LUT across the whole colour cube                 |
/// | speculars | 0.613                | halation intensity and warmth (see below)           |
///
/// (Measured, not intended: those are the values `CIAreaAverage` reports for each fixture, which
/// is the number `processSync` branches on. `night` and `dusk` are the only two below 0.22.)
///
/// `speculars` exists because of a measurement, not a hunch. With ordinary scenes (including the
/// owner's real captures) a +0.02 change to bloom moves every frame-average statistic by less than
/// 0.0002, because halation only touches the few percent of pixels sitting near a highlight. A pin
/// built on those scenes alone would sail straight past "someone adjusted halation". `speculars`
/// packs the frame with small blown highlights so the glow covers essentially all of it, which is
/// also the scene type where a bloom change is most visible to the eye: night lights and bokeh.
///
/// Because they are generated rather than stored, this generator is itself part of the pinned
/// contract. `fixtureInputsAreStable` measures the UNGRADED fixtures against their own baseline, so
/// a change here fails as "the fixture moved" instead of masquerading as "the look moved".
enum LookFixture: String, CaseIterable {
    case night, dusk, speculars, daylight, gamut, oversize

    var pixelSize: (width: Int, height: Int) {
        switch self {
        // Deliberately over the 2048 storage cap so `processSync` takes its downscale branch.
        case .oversize: return (2560, 1920)
        // The capture size the neutral pairs arrive at, so the pinned scenes match real inputs.
        default: return (1152, 1536)
        }
    }

    /// What the storage cap should leave behind. `oversize` is the only fixture that crosses it.
    var expectedOutputSize: (width: Int, height: Int) {
        switch self {
        case .oversize: return (2048, 1536)
        default: return pixelSize
        }
    }

    /// Integer hash, 0...1. Explicitly integer maths so the fixtures are bit-identical on any
    /// machine; a float PRNG would invite exactly the drift this pin is meant to detect.
    private static func hash(_ x: Int, _ y: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: x &* 374_761_393 &+ y &* 668_265_263 &+ 1_442_695_041)
        h ^= h >> 13
        h = h &* 1_274_126_177
        h ^= h >> 16
        return Double(h) / Double(UInt32.max)
    }

    /// Smooth value noise on a coarse grid.
    ///
    /// Coarse and smoothed on purpose: per-pixel white noise in the fixture would be a second
    /// grain layer, and it would swamp the `localContrast` statistic that exists to watch the real
    /// grain. This gives the LUT varied input without adding high-frequency energy.
    private static func noise(_ x: Int, _ y: Int, cell: Int) -> Double {
        let cx = x / cell, cy = y / cell
        let fx = Double(x % cell) / Double(cell), fy = Double(y % cell) / Double(cell)
        let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
        let a = hash(cx, cy), b = hash(cx + 1, cy)
        let c = hash(cx, cy + 1), d = hash(cx + 1, cy + 1)
        return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy
    }

    /// A soft radial highlight, the thing halation is supposed to bleed from.
    private static func spot(_ u: Double, _ v: Double, _ cu: Double, _ cv: Double, _ radius: Double) -> Double {
        let d = ((u - cu) * (u - cu) + (v - cv) * (v - cv)).squareRoot() / radius
        guard d < 1 else { return 0 }
        let t = 1 - d
        return t * t
    }

    /// RGB at a pixel, 0...1 before clamping.
    private func color(x: Int, y: Int, width: Int, height: Int) -> (Double, Double, Double) {
        let u = Double(x) / Double(width - 1)
        let v = Double(y) / Double(height - 1)
        let texture = LookFixture.noise(x, y, cell: 24) - 0.5

        switch self {
        case .night:
            // A dark street: near-black cool base, a handful of blown point lights.
            let base = 0.020 + 0.045 * (1 - v) + 0.020 * texture
            var r = base * 0.92, g = base * 0.98, b = base * 1.30
            let lamps = [(0.22, 0.28, 0.055), (0.68, 0.18, 0.040), (0.47, 0.62, 0.030)]
            for (cu, cv, radius) in lamps {
                let s = LookFixture.spot(u, v, cu, cv, radius)
                r += s * 1.15; g += s * 0.95; b += s * 0.60
            }
            return (r, g, b)

        case .dusk:
            // Sky falling into a dark foreground, a warm horizon, two lit windows.
            //
            // The brightness constants here are tuned, and measured, to land this scene's mean
            // luminance between 0.101 and 0.18: below 0.18 the adaptive EV is zero, below 0.101 it
            // saturates at the 0.5 clamp, and either way the 0.6 coefficient in the formula stops
            // being observable. Inside that window the EV is on its slope (~0.25 EV here), so this
            // fixture is what pins the coefficient itself. `night` pins the clamp above it.
            let sky = 0.235 * (1 - v) * (1 - v)
            let horizon = 0.138 * LookFixture.spot(u, v, 0.5, 0.46, 0.55)
            let ground = v > 0.55 ? 0.028 : 0.0
            let base = sky + ground + 0.021 * texture
            var r = base * 1.05 + horizon * 1.25
            var g = base * 1.00 + horizon * 0.85
            var b = base * 1.35 + horizon * 0.45
            for (cu, cv) in [(0.30, 0.70), (0.74, 0.66)] {
                let s = LookFixture.spot(u, v, cu, cv, 0.045)
                r += s * 1.00; g += s * 0.86; b += s * 0.52
            }
            return (r, g, b)

        case .speculars:
            // A field of small blown highlights on a dim surround: city lights, or bokeh.
            //
            // Geometry in PIXELS, not in u/v, because the halation radius is a pixel quantity
            // (long edge × 0.005, so ~7.7px here). The dots are spaced closer than the glow's own
            // reach so the blurred highlights overlap and cover the whole frame, which is what
            // turns a bloom change from a 0.0002 frame-average nudge into a measurable one.
            //
            // The surround is dark so the glow's COLOUR is readable. Against a bright surround the
            // screen blend clips the glow toward white and the halation tint stops being
            // measurable at all (measured: a 0.15 drop in warmth moved every statistic by less
            // than 0.0006). The scene still avoids the adaptive-EV and dark-bloom branches,
            // because those key off mean luminance computed in LINEAR light, where the blown dots
            // dominate and carry the mean far above the 0.22 threshold despite the dark surround.
            let base = 0.09 + 0.012 * texture
            var r = base * 0.94, g = base * 0.97, b = base * 1.16
            let spacing = 24.0
            let dx = Double(x % Int(spacing)) - spacing / 2
            let dy = Double(y % Int(spacing)) - spacing / 2
            let d = (dx * dx + dy * dy).squareRoot()
            // Flat-topped so a real fraction of the frame is genuinely over the 0.68 halation
            // threshold; a smooth peak would put only a pixel or two per dot above it.
            let dot = d <= 7 ? 1.0 : max(0, (10 - d) / 3)
            r += dot * (1.00 - r); g += dot * (0.97 - g); b += dot * (0.90 - b)
            return (r, g, b)

        case .daylight:
            // A bright frame with real colour in it: sky, foliage, skin, and a blown specular.
            let base = 0.42 + 0.16 * (1 - v) + 0.08 * texture
            var r = base, g = base, b = base
            if v < 0.34 {                       // sky
                r *= 0.78; g *= 0.94; b *= 1.35
            } else if v < 0.58 {                // foliage
                r *= 0.62; g *= 1.10; b *= 0.55
            } else if u < 0.42 {                // skin
                r *= 1.28; g *= 0.98; b *= 0.84
            } else {                            // warm wall
                r *= 1.14; g *= 1.02; b *= 0.88
            }
            let sun = LookFixture.spot(u, v, 0.80, 0.22, 0.13)
            r += sun * 0.95; g += sun * 0.92; b += sun * 0.85
            return (r, g, b)

        case .gamut:
            // A colour chart, not a scene. 12×12 patches sweeping hue, saturation and value so the
            // pin sees the whole cube, plus a neutral ramp along the bottom. A photograph only ever
            // covers the corner of the LUT it happens to contain; this covers all of it.
            if v > 0.88 {
                let ramp = (Double(Int(u * 16)) / 15).clampedUnit
                return (ramp, ramp, ramp)
            }
            let col = Int(u * 12), row = Int(v / 0.88 * 12)
            let hue = Double(col) / 12
            let saturation = 0.25 + 0.75 * Double(row % 4) / 3
            let value = 0.20 + 0.75 * Double(row / 4) / 2
            return LookFixture.hsv(hue: hue, saturation: saturation, value: value)

        case .oversize:
            // A mid-bright interior with fine structure, large enough to cross the storage cap.
            let base = 0.30 + 0.14 * (1 - v) + 0.06 * texture
            var r = base * 1.10, g = base * 1.00, b = base * 0.86
            if Int(u * 18) % 2 == 0 { r *= 0.86; g *= 0.90; b *= 1.05 }
            let lamp = LookFixture.spot(u, v, 0.62, 0.30, 0.10)
            r += lamp * 1.05; g += lamp * 0.90; b += lamp * 0.62
            return (r, g, b)
        }
    }

    private static func hsv(hue: Double, saturation: Double, value: Double) -> (Double, Double, Double) {
        let h = (hue * 6).truncatingRemainder(dividingBy: 6)
        let i = Int(h), f = h - Double(i)
        let p = value * (1 - saturation)
        let q = value * (1 - saturation * f)
        let t = value * (1 - saturation * (1 - f))
        switch i {
        case 0: return (value, t, p)
        case 1: return (q, value, p)
        case 2: return (p, value, t)
        case 3: return (p, q, value)
        case 4: return (t, p, value)
        default: return (value, p, q)
        }
    }

    /// The fixture as PNG bytes, ready to feed the real capture entry point.
    ///
    /// PNG rather than JPEG on purpose. The pipeline accepts both, and a lossless input keeps the
    /// pinned numbers a function of the pipeline alone. A JPEG fixture would re-encode through
    /// whatever libjpeg the toolchain ships, so a plain Xcode upgrade could move the baseline and
    /// look exactly like a look regression.
    /// Generated once for the whole test run. Two tests measure every fixture (graded and
    /// ungraded) and swift-testing runs them in parallel, so without this each fixture is
    /// synthesised twice, which was measurably the most expensive thing in the suite. A `static
    /// let` is initialised exactly once and is safe to read from several tests at once.
    private static let cache: [LookFixture: Data] = Dictionary(
        uniqueKeysWithValues: LookFixture.allCases.map { ($0, $0.renderPNG()) })

    func pngData() -> Data { LookFixture.cache[self]! }

    private func renderPNG() -> Data {
        let (w, h) = pixelSize
        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h {
            for x in 0..<w {
                let (r, g, b) = color(x: x, y: y, width: w, height: h)
                let i = (y * w + x) * 4
                pixels[i] = UInt8(r.clampedUnit * 255)
                pixels[i + 1] = UInt8(g.clampedUnit * 255)
                pixels[i + 2] = UInt8(b.clampedUnit * 255)
            }
        }
        let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: LookMeasure.srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cg = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }
}

private extension Double {
    var clampedUnit: Double { Swift.min(1, Swift.max(0, self)) }
}

// MARK: - Calibration pairs (local only)

/// The real neutral captures, when they exist on this machine.
///
/// `pairs/` is gitignored, so this is present on the owner's machine and absent everywhere else.
/// Tests that use it are `.enabled(if:)` on `isAvailable` and report as skipped rather than failing
/// on a fresh clone.
enum LookPairs {
    /// Resolved from the test source location, since the test bundle carries no copy of `pairs/`
    /// (and must not: those photographs are never committed and never shipped).
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()      // FlimTests
        .deletingLastPathComponent()      // repo root
        .appendingPathComponent("pairs")

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("wide-lit_neutral.jpg").path)
    }

    /// The subset the pin runs on, and why each one earns its place. Chosen from measured input
    /// luminance across all 13 neutral captures rather than by eye:
    ///
    /// - `parkview-noflash` (0.17) is the darkest scene in the set, and the only one that trips
    ///   adaptive exposure and the dark-scene bloom reduction at all.
    /// - `wide-dim` (0.32) sits just above the dark branches, so the pair of them straddles the
    ///   0.22 bloom threshold.
    /// - `parkview-flash` (0.38) is the same subject as `parkview-noflash` with the flash fired,
    ///   which is the harshest input the look receives.
    /// - `restaurant-a` (0.51) is mixed tungsten interior with point lights, i.e. the case halation
    ///   was rewritten for.
    /// - `plush` (0.62) is the brightest and most saturated scene in the set, where a LUT change
    ///   shows up first.
    ///
    /// The other eight are near-duplicates of these in both luminance and saturation, and each one
    /// costs a full-resolution render, so they are left out to keep the suite fast.
    static let scenes = ["parkview-noflash", "wide-dim", "parkview-flash", "restaurant-a", "plush"]

    static func neutralData(_ scene: String) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent("\(scene)_neutral.jpg"))
    }
}

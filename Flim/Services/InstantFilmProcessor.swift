import CoreImage
import UIKit
import ImageIO

/// Bakes an instant-camera film look into a captured photo at capture time, so the
/// developed reveal already carries the aesthetic with no view-time processing.
enum InstantFilmProcessor {
    // CIContext is expensive to build, create once and reuse for every capture.
    private static let context = CIContext()

    /// The one declared color space for the whole exported chain. sRGB is the safe universal
    /// choice, it's what shared-photo consumers (Messages/web/Android) assume for untagged
    /// JPEGs, and it's the space the LUT was fitted in. Every JPEG we write is rendered into
    /// this space AND tagged with its ICC profile so it reads identically outside the app.
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders a finished CIImage to sRGB JPEG bytes with the sRGB ICC profile embedded.
    /// `createCGImage(colorSpace:)` pins the output to sRGB (previously it inherited the
    /// context default, and `UIImage.jpegData` then wrote an UNTAGGED JPEG). We encode via
    /// CGImageDestination with the color space set explicitly so the ICC tag is guaranteed, 
    /// UIImage.jpegData does not reliably embed a profile from a bare CGImage.
    private static func srgbJPEG(_ image: CIImage, quality: CGFloat) -> Data? {
        guard let cg = context.createCGImage(
            image, from: image.extent, format: .RGBA8, colorSpace: outputColorSpace
        ) else { return nil }
        return encodeJPEG(cg, quality: quality)
    }

    /// Encodes a CGImage as JPEG with its ICC profile embedded, so downstream viewers don't
    /// guess the color space. CGImageDestination writes the ICC bytes of the CGImage's OWN
    /// color space; callers pass an sRGB-tagged CGImage (from `createCGImage(colorSpace:)` or
    /// a thumbnail of our own sRGB output), so the file carries the sRGB profile. Falls back to
    /// `UIImage.jpegData` only if the destination can't be built, a photo must not be lost.
    private static func encodeJPEG(_ cg: CGImage, quality: CGFloat) -> Data? {
        // Guarantee the CGImage is sRGB before encoding; if it somehow isn't (e.g. a thumbnail
        // of an untagged fallback original), redraw it into sRGB so the embedded ICC is honest.
        let srgb = cg.colorSpace?.name == outputColorSpace.name ? cg : redrawSRGB(cg) ?? cg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil
        ) else { return UIImage(cgImage: srgb).jpegData(compressionQuality: quality) }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, srgb, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return UIImage(cgImage: srgb).jpegData(compressionQuality: quality)
        }
        return out as Data
    }

    /// sRGB-tagged JPEG bytes from a CGImage, for callers that produced pixels themselves rather
    /// than through the film pipeline (the profile cropper). Goes through the same encoder as
    /// every other export so a cropped avatar carries an ICC profile like everything else.
    static func jpegData(from cg: CGImage, quality: CGFloat = 0.9) -> Data? {
        encodeJPEG(cg, quality: quality)
    }

    /// Redraws a CGImage into the sRGB space (used only when an input isn't already sRGB).
    private static func redrawSRGB(_ cg: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
            bytesPerRow: 0, space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return ctx.makeImage()
    }

    /// Processes raw JPEG/HEIC data through the given film stock and returns JPEG bytes.
    /// Runs off the main actor. Returns `nil` on failure so the caller can fall back to
    /// the original bytes (a photo should never be lost to a filter error).
    static func process(_ data: Data, stock: FilmStock) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            processSync(data, stock: stock)
        }.value
    }

    /// A small JPEG thumbnail (longest edge ~`maxPixel` × 2, for retina grids) of an already
    /// processed photo, uploaded alongside the full image so grids/feeds download ~30KB, not MBs.
    static func thumbnail(from data: Data, maxPixel: CGFloat = 400) -> Data? {
        rendition(from: data, longEdge: maxPixel * 2, quality: 0.8)
    }

    /// The feed-card rendition: ~1400px long edge, pixel-identical at feed width on a 3x screen,
    /// but ~1/3 the bytes of the stored full image. Cuts the feed's first-view egress ~65%.
    static func feedRendition(from data: Data) -> Data? {
        rendition(from: data, longEdge: 1400, quality: 0.82)
    }

    /// Downsampled JPEG at an exact long edge, via ImageIO (no full decode of the source).
    static func rendition(from data: Data, longEdge: CGFloat, quality: CGFloat) -> Data? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Re-encode through CGImageDestination so the downscaled rendition keeps an ICC tag.
        // The source here is our own sRGB-tagged full JPEG, so the thumbnail CGImage is already
        // sRGB; encodeJPEG embeds the profile (UIImage.jpegData would drop it, the export bug).
        return encodeJPEG(cg, quality: quality)
    }

    /// Longest edge we store the full image at. 2048 keeps shots crisp at full-screen *and* under
    /// zoom / when saved out (a big jump from 1600), while still being ~3× smaller than raw 12MP
    /// sensor output so egress stays sane. Bump higher (2560+) if you want near-original quality.
    private static let maxStoredEdge: CGFloat = 2048

    /// TestFlight-only calibration mode (Settings → Film Lab): stores the capture with NO grade,
    /// grain, vignette, or bloom, the neutral half of a (neutral, Lapse) pair for LUT fitting.
    static let neutralCaptureKey = "neutralCapture"

    private static func processSync(_ data: Data, stock: FilmStock) -> Data? {
        // Apply embedded EXIF orientation so the output is upright.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }

        // Calibration path: neutral, higher-quality JPEG (no look at all).
        if UserDefaults.standard.bool(forKey: neutralCaptureKey), !AppInfo.isAppStore {
            var neutral = source
            let edge = max(extent.width, extent.height)
            if edge > maxStoredEdge {
                neutral = neutral.applyingFilter("CILanczosScaleTransform", parameters: [
                    kCIInputScaleKey: maxStoredEdge / edge, kCIInputAspectRatioKey: 1.0
                ])
            }
            // Render + tag sRGB like every other export. Pixel values are unchanged from the
            // old untagged path (the context already resolved to sRGB); fit_lut.py reads these
            // via PIL, which assumes sRGB for untagged input, so the fit sees the same numbers,
            // now correctly tagged.
            return srgbJPEG(neutral, quality: 0.92)
        }

        // Scene-adaptive exposure, deliberately GENTLE, night must stay night (a city
        // skyline can't get daylighted), so only truly underexposed scenes get a nudge.
        // Mirrors scripts/fit_lut.py normalize_exposure exactly (the LUT was fitted against
        // inputs normalized with this formula, keep them in sync).
        var graded = source
        let meanLum = averageLuminance(of: source, extent: extent)
        let ev = min(0.5, max(0, 0.6 * log2(0.18 / max(meanLum, 0.0001))))
        if ev > 0.01 {
            graded = graded.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev])
        }

        // Dark scenes also get bloom scaled way down, halation over a night scene spreads
        // every point light into milky haze and lifts the blacks (the washed-skyline bug).
        var params = stock.params
        if meanLum < 0.22 {
            params.bloom *= max(0.35, meanLum / 0.22)
        }

        // Color grade + bloom at FULL resolution (bloom's glow reads best against native pixel
        // detail), WITHOUT grain yet.
        var image = filtered(graded, params: params, extent: extent)

        // Grain at FULL resolution too, BEFORE the downscale below. This is the original ordering
        // and it is deliberate.
        //
        // Grain was moved to after the downscale at one point, on the reasoning that averaging
        // ~4 noise pixels into 1 was collapsing it into near-invisible static. It does average it
        // down, and that averaging is exactly what makes it read as FILM: sub-pixel noise
        // resolving into soft, slightly clumped texture. Applied after the downscale instead, each
        // noise sample survives as a discrete 1-2px speck at final resolution, which reads as
        // dirt or sensor dust rather than grain, worst of all on flat evenly-lit surfaces where
        // there is no detail to sit inside. Reducing the amount only made it fainter dirt; the
        // problem was never the strength, it was the scale.
        image = grainOverlay(on: image, amount: params.grain)

        // Downscale the finished image to the storage cap (keeps egress sane, look intact).
        let longEdge = max(extent.width, extent.height)
        if longEdge > maxStoredEdge {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: maxStoredEdge / longEdge,
                kCIInputAspectRatioKey: 1.0
            ])
        }
        // LUT input space: we deliberately do NOT insert a P3→sRGB conversion before the grade.
        // The look was signed off with the source flowing into the CI graph exactly as it does
        // here, and CubeLUT.apply already declares the cube's own working space (sRGB) to
        // CIColorCubeWithColorSpace. Converting the source first would shift the on-screen result;
        // the goal here is correct EXPORT tagging, not a regrade. We only pin the OUTPUT to sRGB.
        return srgbJPEG(image, quality: 0.85)
    }

    /// Mean scene luminance (0–1) via CIAreaAverage, drives the adaptive dark-scene exposure.
    private static func averageLuminance(of image: CIImage, extent: CGRect) -> CGFloat {
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: extent)])?.outputImage else { return 0.5 }
        var px: [UInt8] = [0, 0, 0, 0]
        context.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = CGFloat(px[0]) / 255, g = CGFloat(px[1]) / 255, b = CGFloat(px[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// The film look as a pure CIImage → CIImage transform, applied at CAPTURE time only.
    /// The live viewfinder deliberately shows the RAW, ungraded preview, this is a
    /// disposable/instant-camera app: you don't see the developed result until it develops.
    /// So this is the source of truth for the baked look, not for what the viewfinder shows.
    static func filtered(_ input: CIImage, params p: FilmParams, extent: CGRect) -> CIImage {
        var image: CIImage

        // Color grade: a .cube LUT if one is set and loads, otherwise the parametric chain.
        if let lut = p.lut, CubeLUT.load(lut) != nil {
            image = CubeLUT.apply(lut, to: input)
        } else {
            // 1. Saturation + contrast.
            image = input.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: p.monochrome ? 0 : p.saturation,
                kCIInputContrastKey: p.contrast,
                kCIInputBrightnessKey: 0
            ])

            // 2. Warmth / white-balance shift.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: p.temperature, y: p.tint)
            ])

            // 3. Tone curve, lift the blacks and roll off the highlights for that faded film feel.
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p.blackLift),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + p.blackLift * 0.4),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + p.blackLift * 0.1),
                "inputPoint3": CIVector(x: 0.75, y: min(0.85, p.highlightRolloff)),
                "inputPoint4": CIVector(x: 1.0, y: p.highlightRolloff)
            ])
        }

        // 4. Halation glow on the highlights.
        if p.bloom > 0 {
            image = halation(on: image, intensity: p.bloom, warmth: p.halationWarmth, extent: extent)
        }

        // 5. Vignette.
        image = image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: p.vignetteIntensity,
            kCIInputRadiusKey: p.vignetteRadius
        ])

        // Grain is applied separately by the caller, at full resolution and BEFORE the storage
        // downscale (see processSync + grainOverlay). This comment previously said "after the
        // downscale", which was true of a version that made grain read as dirt.
        return image
    }

    // MARK: - Halation

    /// Luminance above which a pixel is treated as a highlight that can bleed. Chosen so ordinary
    /// bright midtones (skin in sun, a white shirt) don't glow, but genuine speculars, sky through
    /// a window, and light sources do. Lower this and the whole frame hazes over.
    private static let halationThreshold: CGFloat = 0.68

    /// The per-channel multiplier that gives the glow its colour, as (r, g, b).
    ///
    /// Pure and internal-visible so the warmth curve can be asserted in tests without rendering:
    /// at `warmth` 0 this is exactly (1, 1, 1), i.e. the neutral white glow `CIBloom` used to
    /// produce, which is what makes 0 a true no-op escape hatch if the warm look is ever wrong.
    /// Red is never attenuated; green and blue fall away, green less than blue, which is what
    /// puts the fringe at red-orange rather than pure red.
    static func halationTint(warmth: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let w = min(1, max(0, warmth))
        return (1.0, 1.0 - 0.38 * w, 1.0 - 0.62 * w)
    }

    /// Warm halation: isolate the highlights, spread them, tint the spread light, add it back.
    ///
    /// This replaces `CIBloom`, which spreads a NEUTRAL glow. The structure here is deliberately
    /// the physical one rather than a stylised approximation, because each step maps to something
    /// real: what bleeds is only the light that was bright enough to scatter (threshold), it
    /// spreads (blur), the film base tints it on the way back (colour matrix), and it is added as
    /// LIGHT on top of the image, because the scattered light is extra exposure landing on the
    /// emulsion rather than a different colour of the original.
    ///
    /// Composited with screen, not `CIAdditionCompositing`. Addition is the obvious choice and it
    /// is wrong here: measured, it does not leave a zero-valued glow as a no-op, it lifts a flat
    /// mid-grey from 51 to 69 across the WHOLE frame, because it resolves in linear working space
    /// and round-trips the background through it. Screen leaves an untouched area bit-identical
    /// and still brightens where the glow actually is. It also rolls off instead of clipping, so
    /// the core of a highlight blooms toward white while the falloff stays warm enough to read as
    /// colour, which is the part that looks like film.
    private static func halation(on image: CIImage, intensity: CGFloat, warmth: CGFloat, extent: CGRect) -> CIImage {
        // Radius scales with the image's own long edge, not a fixed pixel count, so the glow is
        // the same softness on any sensor resolution and survives the later downscale to 2048 as
        // a soft, wide halation rather than a tight edge-sharpen. (0.005 ≈ ~20px on a 12MP frame,
        // ~10px once stored.) Carried over unchanged from the CIBloom version.
        let radius = max(6.0, max(extent.width, extent.height) * 0.005)

        // Isolate the highlights: subtract the threshold, then rescale what's left back up to
        // 0...1, so a pixel at the threshold contributes nothing and a pixel at pure white
        // contributes fully. CIColorClamp discards everything that went negative, which is every
        // pixel that was below the threshold.
        let scale = 1 / (1 - halationThreshold)
        let bias = -halationThreshold * scale
        var glow = image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: scale, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: scale, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: scale, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ])
            .applyingFilter("CIColorClamp")

        // clampedToExtent BEFORE the blur, cropped after: without it the blur samples transparent
        // pixels beyond the frame and the glow fades out along all four edges, which reads as a
        // second vignette on top of the real one.
        glow = glow
            .clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: extent)

        // Tint the scattered light and scale it by the stock's bloom amount in one matrix.
        let tint = halationTint(warmth: warmth)
        glow = glow.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: tint.r * intensity, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: tint.g * intensity, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: tint.b * intensity, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])

        return glow
            .applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
            .cropped(to: extent)
    }

    // MARK: - Grain

    /// Grain visibility by luminance, as (input, multiplier) anchor points.
    ///
    /// On real film the grain you see IS the silver halide crystals that formed the image, so
    /// where no image formed there is nothing to see: deep shadow holds little, blown highlights
    /// hold almost none, and midtones hold the most. Grain that ignores this is uniform speckle,
    /// and it shows up worst on skies, which should be clean and instead get the same texture as
    /// a face.
    ///
    /// Midtones sit at exactly 1.0 on purpose. The grain character at midtone was signed off after
    /// the ordering fix (full resolution, before the storage downscale), so this must not change
    /// it: this curve only takes grain AWAY from the two ends where it was never meant to be.
    static let grainAnchors: [(luminance: CGFloat, visibility: CGFloat)] = [
        (0.00, 0.30),   // deep shadow: present, but sunk
        (0.25, 0.80),
        (0.50, 1.00),   // midtone: unchanged from the approved look
        (0.75, 0.62),
        (1.00, 0.10)    // blown highlight: all but gone
    ]

    /// The anchor curve as a function, for tests and for reasoning about a luminance value.
    ///
    /// Piecewise-linear between the anchors. `CIToneCurve` interpolates the same anchors with a
    /// spline, so this agrees exactly AT the anchors and approximates between them; assert on the
    /// anchors and on the shape (rises to the midtone, falls after it), not on intermediate values.
    static func grainVisibility(luminance: CGFloat) -> CGFloat {
        let l = min(1, max(0, luminance))
        for i in 1..<grainAnchors.count {
            let (x1, y1) = grainAnchors[i]
            guard l <= x1 else { continue }
            let (x0, y0) = grainAnchors[i - 1]
            guard x1 > x0 else { return y1 }
            return y0 + (y1 - y0) * (l - x0) / (x1 - x0)
        }
        return grainAnchors[grainAnchors.count - 1].visibility
    }

    /// A mask whose ALPHA is `grainVisibility` of the image's luminance, for `CIBlendWithMask`.
    private static func grainLuminanceMask(for image: CIImage) -> CIImage {
        // Rec.601 luma into all three channels, matching averageLuminance above so "midtone"
        // means the same thing in both places.
        let luma = CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0)
        let curve = grainAnchors.map { CIVector(x: $0.luminance, y: $0.visibility) }
        return image
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": luma, "inputGVector": luma, "inputBVector": luma,
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
            ])
            .applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": curve[0], "inputPoint1": curve[1], "inputPoint2": curve[2],
                "inputPoint3": curve[3], "inputPoint4": curve[4]
            ])
            // CIBlendWithMask reads the mask's ALPHA channel, so move the curved luminance from
            // red into alpha. Without this the mask is opaque everywhere and modulates nothing.
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0)
            ])
    }

    /// Fine film grain: desaturated random noise composited at low opacity, at FULL sensor
    /// resolution (see the call site) so the storage downscale averages it into soft film-like
    /// texture rather than leaving discrete specks.
    ///
    /// Deliberately no Lanczos pre-upscale of the noise. That was added to fake grain clumping
    /// back when this ran at the final stored resolution and single-pixel noise looked like
    /// static; interpolating random samples is a poor substitute for the real averaging the
    /// downscale does, and it is unnecessary now that the ordering is restored.
    /// Internal rather than private so a test can render a known luminance ramp through it and
    /// confirm the mask is actually connected. The halation rewrite is the argument for that: its
    /// tint maths was right and its compositing silently lifted the whole frame, and only a
    /// render-and-measure test caught it.
    static func grainOverlay(on image: CIImage, amount: CGFloat) -> CIImage {
        let extent = image.extent
        guard amount > 0, !extent.isInfinite, !extent.isEmpty,
              let noise = CIFilter(name: "CIRandomGenerator")?.outputImage else { return image }
        let grainLayer = noise
            .cropped(to: extent)
            .applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1
            ])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: amount)
            ])
        let grained = grainLayer.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: image
        ])

        // Modulate by luminance: blend between the ungrained image (where the mask is 0) and the
        // uniformly grained one (where it is 1), per pixel. Doing it as a blend rather than by
        // varying the noise layer's own alpha is what keeps the midtone result bit-identical to
        // the approved look, since the mask is exactly 1.0 there.
        return grained.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: grainLuminanceMask(for: image)
        ])
    }
}

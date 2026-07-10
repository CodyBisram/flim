import CoreImage
import UIKit
import ImageIO

/// Bakes an instant-camera film look into a captured photo at capture time, so the
/// developed reveal already carries the aesthetic with no view-time processing.
enum InstantFilmProcessor {
    // CIContext is expensive to build — create once and reuse for every capture.
    private static let context = CIContext()

    /// The one declared color space for the whole exported chain. sRGB is the safe universal
    /// choice — it's what shared-photo consumers (Messages/web/Android) assume for untagged
    /// JPEGs, and it's the space the LUT was fitted in. Every JPEG we write is rendered into
    /// this space AND tagged with its ICC profile so it reads identically outside the app.
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Renders a finished CIImage to sRGB JPEG bytes with the sRGB ICC profile embedded.
    /// `createCGImage(colorSpace:)` pins the output to sRGB (previously it inherited the
    /// context default, and `UIImage.jpegData` then wrote an UNTAGGED JPEG). We encode via
    /// CGImageDestination with the color space set explicitly so the ICC tag is guaranteed —
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
    /// `UIImage.jpegData` only if the destination can't be built — a photo must not be lost.
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
    /// processed photo — uploaded alongside the full image so grids/feeds download ~30KB, not MBs.
    static func thumbnail(from data: Data, maxPixel: CGFloat = 400) -> Data? {
        rendition(from: data, longEdge: maxPixel * 2, quality: 0.8)
    }

    /// The feed-card rendition: ~1400px long edge — pixel-identical at feed width on a 3x screen,
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
        // sRGB; encodeJPEG embeds the profile (UIImage.jpegData would drop it — the export bug).
        return encodeJPEG(cg, quality: quality)
    }

    /// Longest edge we store the full image at. 2048 keeps shots crisp at full-screen *and* under
    /// zoom / when saved out (a big jump from 1600), while still being ~3× smaller than raw 12MP
    /// sensor output so egress stays sane. Bump higher (2560+) if you want near-original quality.
    private static let maxStoredEdge: CGFloat = 2048

    /// TestFlight-only calibration mode (Settings → Film Lab): stores the capture with NO grade,
    /// grain, vignette, or bloom — the neutral half of a (neutral, Lapse) pair for LUT fitting.
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
            // via PIL, which assumes sRGB for untagged input — so the fit sees the same numbers,
            // now correctly tagged.
            return srgbJPEG(neutral, quality: 0.92)
        }

        // Scene-adaptive exposure, deliberately GENTLE — night must stay night (a city
        // skyline can't get daylighted), so only truly underexposed scenes get a nudge.
        // Mirrors scripts/fit_lut.py normalize_exposure exactly (the LUT was fitted against
        // inputs normalized with this formula — keep them in sync).
        var graded = source
        let meanLum = averageLuminance(of: source, extent: extent)
        let ev = min(0.5, max(0, 0.6 * log2(0.18 / max(meanLum, 0.0001))))
        if ev > 0.01 {
            graded = graded.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev])
        }

        // Dark scenes also get bloom scaled way down — halation over a night scene spreads
        // every point light into milky haze and lifts the blacks (the washed-skyline bug).
        var params = stock.params
        if meanLum < 0.22 {
            params.bloom *= max(0.35, meanLum / 0.22)
        }

        // Filter at FULL resolution — this matches the original look. Grain and bloom render
        // relative to the native pixel size; downscaling *before* filtering (a past egress tweak)
        // made the grain coarse and the bloom too strong. So bake the look first…
        var image = filtered(graded, params: params, extent: extent, grain: true)

        // …then downscale the finished image to the storage cap (keeps egress sane, look intact).
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

    /// Mean scene luminance (0–1) via CIAreaAverage — drives the adaptive dark-scene exposure.
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
    /// The live viewfinder deliberately shows the RAW, ungraded preview — this is a
    /// disposable/instant-camera app: you don't see the developed result until it develops.
    /// So this is the source of truth for the baked look, not for what the viewfinder shows.
    static func filtered(_ input: CIImage, params p: FilmParams, extent: CGRect, grain: Bool) -> CIImage {
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

            // 3. Tone curve — lift the blacks and roll off the highlights for that faded film feel.
            image = image.applyingFilter("CIToneCurve", parameters: [
                "inputPoint0": CIVector(x: 0.0, y: p.blackLift),
                "inputPoint1": CIVector(x: 0.25, y: 0.25 + p.blackLift * 0.4),
                "inputPoint2": CIVector(x: 0.5, y: 0.5 + p.blackLift * 0.1),
                "inputPoint3": CIVector(x: 0.75, y: min(0.85, p.highlightRolloff)),
                "inputPoint4": CIVector(x: 1.0, y: p.highlightRolloff)
            ])
        }

        // 4. Halation / bloom glow on the highlights. Bloom grows the extent, so crop back.
        if p.bloom > 0 {
            image = image
                .applyingFilter("CIBloom", parameters: [
                    kCIInputRadiusKey: 6.0,
                    kCIInputIntensityKey: p.bloom
                ])
                .cropped(to: extent)
        }

        // 5. Vignette.
        image = image.applyingFilter("CIVignette", parameters: [
            kCIInputIntensityKey: p.vignetteIntensity,
            kCIInputRadiusKey: p.vignetteRadius
        ])

        // 6. Fine film grain — desaturated random noise composited at low opacity.
        if grain, p.grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grainLayer = noise
                .cropped(to: extent)
                .applyingFilter("CIColorControls", parameters: [
                    kCIInputSaturationKey: 0,
                    kCIInputContrastKey: 1
                ])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: p.grain)
                ])
            image = grainLayer.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: image
            ])
        }

        return image
    }
}

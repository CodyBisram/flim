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
    /// JPEGs, and it's the space the LUT was fitted in. Every image we write is rendered into
    /// this space AND tagged with its ICC profile so it reads identically outside the app.
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// Which container format a set of already-encoded image bytes actually carry. Every upload
    /// site must derive its `contentType`/path suffix from this rather than assume one, HEIC
    /// encoding can fail (some simulators, or a device with no HEVC encoder), so the format that
    /// was actually produced is the only thing safe to label bytes with.
    enum ImageEncoding {
        case heic
        case jpeg

        var contentType: String {
            switch self {
            case .heic: return "image/heic"
            case .jpeg: return "image/jpeg"
            }
        }

        /// Storage path suffix, without the leading dot.
        var pathExtension: String {
            switch self {
            case .heic: return "heic"
            case .jpeg: return "jpg"
            }
        }
    }

    /// Encoded bytes paired with the format they were actually produced as. Keeping the two
    /// together is what makes it impossible for a caller to upload one format labelled as the
    /// other, the failure mode this whole type exists to rule out.
    struct EncodedImage {
        let data: Data
        let format: ImageEncoding
    }

    /// One rendition's encoding policy: which container, and at what lossy quality.
    ///
    /// This is a LOOK decision, not a plumbing detail, which is why it is a named policy per
    /// rendition instead of a bare number at each call site.
    ///
    /// All three renditions are JPEG, and that is a measured result, not the status quo winning
    /// by default. `LookEncoderSweep` renders the pin's eleven scenes once and feeds the identical
    /// graded pixels to JPEG and to HEIC at 0.80/0.85/0.90/0.93/0.95/0.97/1.00. What it found:
    ///
    /// 1. HEIC removes our grain. `localContrast` fell on 11/11 scenes at every quality up to 0.93
    ///    (worst: daylight -0.00386, 3.9× the pin's tolerance). Our grain is fine, low-amplitude,
    ///    high-frequency texture, which is exactly what HEVC intra coding is designed to identify
    ///    as sensor noise and spend no bits on.
    /// 2. The quality at which HEIC stops removing it is the quality at which it stops being
    ///    small. HEIC only undercuts JPEG below ~0.90; by 0.93 it is already +11.9% LARGER than
    ///    JPEG 0.85, and even at 1.00 (+107% bytes) only 5/11 scenes clear the pin.
    /// 3. There is no qualifying quality at all. The lowest HEIC quality where all eleven scenes
    ///    land inside tolerance does not exist: the best any quality manages is 6/11.
    /// 4. HEIC also carries a small quality-INDEPENDENT tone offset (full tier, averaged over the
    ///    eleven scenes: meanR -0.0008, meanG +0.0005, meanB -0.0008; on the 500px thumbnail
    ///    -0.0022/-0.0013/-0.0024). It does not shrink as quality rises, so it is a property of
    ///    the codec's colour handling, not of its bit budget.
    ///
    /// So the trade on offer was ~35% smaller files for a measurably softer, slightly darker
    /// photograph. The look is the product; we do not sell it for storage. Re-run the sweep
    /// before revisiting this, the command is in `LookEncoderSweep`'s own documentation.
    struct EncodeSpec {
        let format: ImageEncoding
        let quality: CGFloat
    }

    /// The full stored image (2048px long edge): the archival master, and what full-screen viewing
    /// and save-to-camera-roll serve. The strictest tier, and the one the look pin measures.
    static let fullEncoding = EncodeSpec(format: .jpeg, quality: 0.85)

    /// The feed card (1400px), the rendition users actually look at, so its grain matters most
    /// perceptually. HEIC's best showing here was 9/11 scenes, and only at qualities 23% to 139%
    /// LARGER than this.
    static let feedEncoding = EncodeSpec(format: .jpeg, quality: 0.82)

    /// The grid thumbnail (500px). Grain is barely resolvable at a 128pt grid cell, so this was
    /// the tier most likely to tolerate HEIC, and it is the one that tolerated it least: 0/11
    /// scenes clear tolerance at ANY quality, because of the tone offset in note 4 above rather
    /// than because of grain. A HEIC thumbnail is ~0.6 of an 8-bit level darker in R and B than
    /// the master it stands for, at every quality, so grids would not match the photos they open.
    /// It is also the smallest tier: only ~4% of the bytes stored per photo, so even the reckless
    /// -39.7% version returns ~1.5% of storage.
    static let thumbEncoding = EncodeSpec(format: .jpeg, quality: 0.8)

    /// Detects which format a set of already-encoded image bytes actually carry, from the bytes
    /// themselves rather than any label a caller might otherwise attach. Used at upload
    /// boundaries that only have raw `Data` in hand (a capture that fell back to its
    /// pre-processed bytes, or a retried upload whose format was never threaded through the
    /// on-disk failed-upload queue), so a payload can never be mislabelled even after round
    /// tripping through storage this class doesn't control.
    static func detectedEncoding(of data: Data) -> ImageEncoding {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              type == "public.heic" || type == "public.heif"
        else { return .jpeg }
        return .heic
    }

    /// Encodes a CGImage in the rendition's preferred format, falling back to JPEG whenever HEIC
    /// was asked for but this device has no HEIC encoder available (some simulators, or an
    /// ImageIO build without one). Returns the format actually produced alongside the bytes so
    /// nothing downstream has to guess.
    static func encodeImage(_ cg: CGImage, _ spec: EncodeSpec) -> EncodedImage? {
        // Guarantee the CGImage is sRGB before encoding; if it somehow isn't (e.g. a thumbnail
        // of an untagged fallback original), redraw it into sRGB so the embedded ICC is honest.
        let srgb = cg.colorSpace?.name == outputColorSpace.name ? cg : redrawSRGB(cg) ?? cg
        if spec.format == .heic, let heic = encodeHEIC(srgb, quality: spec.quality) {
            return EncodedImage(data: heic, format: .heic)
        }
        guard let jpeg = encodeJPEG(srgb, quality: spec.quality) else { return nil }
        return EncodedImage(data: jpeg, format: .jpeg)
    }

    /// Encodes a CGImage as HEIC with its ICC profile embedded. Returns nil (rather than
    /// throwing or crashing) whenever this device can't produce HEIC at all, that's the signal
    /// `encodeImage` uses to fall back to JPEG.
    private static func encodeHEIC(_ cg: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, "public.heic" as CFString, 1, nil
        ) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
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
    /// than through the film pipeline (the profile cropper) and that re-encode the result
    /// themselves downstream (so this deliberately stays JPEG-only rather than HEIC-first: its
    /// only caller passes the bytes straight back into `uploadOwnedImage`, which re-thumbnails
    /// and re-labels them anyway). Goes through the same encoder shape as every other export so
    /// a cropped avatar carries an ICC profile like everything else.
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

    /// Processes raw JPEG/HEIC data through the given film stock and returns encoded image bytes
    /// plus the format actually produced. Runs off the main actor. Returns `nil` on failure so the
    /// caller can fall back to the original bytes (a photo should never be lost to a filter
    /// error). `encoding` exists so the encoder sweep can hold the grade fixed and vary only the
    /// codec; production always takes the default.
    static func process(_ data: Data, stock: FilmStock,
                        encoding: EncodeSpec = fullEncoding,
                        grain: GrainComposite = .sourceOver) async -> EncodedImage? {
        await Task.detached(priority: .userInitiated) {
            processSync(data, stock: stock, encoding: encoding, grain: grain)
        }.value
    }

    /// A small thumbnail (longest edge ~`maxPixel` × 2, for retina grids) of an already
    /// processed photo, uploaded alongside the full image so grids/feeds download ~30KB, not MBs.
    /// The grid thumbnail: 500px on the long edge.
    ///
    /// It was `maxPixel * 2` with a default of 400, so a "400px thumbnail" was encoded at 800px:
    /// four times the pixel area, and the reason these average 123 kB in production against the
    /// ~30 kB the upload path's own comment expects. Thumbnails are the most-fetched asset in the
    /// app, so that multiplier was being paid on every grid scroll, by everyone.
    ///
    /// 500 comes from the largest real consumer rather than from a round number. The biggest place
    /// a thumbnail is shown is a cell in the 3-column Darkroom grid, about 128pt wide, so about
    /// 384px on a 3x screen. 500 clears that with room for a 2-column layout without paying for
    /// 800. Everywhere else it appears is smaller (Activity rows at 88pt) or blurred past
    /// recognition (the reveal's developing frame, at blur radius 26).
    ///
    /// The parameter now means what it says: pass a long edge, get that long edge.
    static func thumbnail(from data: Data, longEdge: CGFloat = 500,
                          encoding: EncodeSpec = thumbEncoding) -> EncodedImage? {
        rendition(from: data, longEdge: longEdge, encoding: encoding)
    }

    /// The feed-card rendition: ~1400px long edge, pixel-identical at feed width on a 3x screen,
    /// but ~1/3 the bytes of the stored full image. Cuts the feed's first-view egress ~65%.
    static func feedRendition(from data: Data,
                              encoding: EncodeSpec = feedEncoding) -> EncodedImage? {
        rendition(from: data, longEdge: 1400, encoding: encoding)
    }

    /// Downsampled image bytes at an exact long edge, via ImageIO (no full decode of the
    /// source), in the format `encoding` asks for, see `encodeImage`.
    static func rendition(from data: Data, longEdge: CGFloat, encoding: EncodeSpec) -> EncodedImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longEdge
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Re-encode through CGImageDestination so the downscaled rendition keeps an ICC tag.
        // The source here is our own sRGB-tagged image, so the thumbnail CGImage is already
        // sRGB; encodeImage embeds the profile (UIImage.jpegData would drop it, the export bug).
        return encodeImage(cg, encoding)
    }

    /// Longest edge we store the full image at. 2048 keeps shots crisp at full-screen *and* under
    /// zoom / when saved out (a big jump from 1600), while still being ~3× smaller than raw 12MP
    /// sensor output so egress stays sane. Bump higher (2560+) if you want near-original quality.
    private static let maxStoredEdge: CGFloat = 2048

    /// TestFlight-only calibration mode (Settings → Film Lab): stores the capture with NO grade,
    /// grain, vignette, or bloom, the neutral half of a (neutral, Lapse) pair for LUT fitting.
    static let neutralCaptureKey = "neutralCapture"

    private static func processSync(_ data: Data, stock: FilmStock, encoding: EncodeSpec,
                                    grain: GrainComposite = .sourceOver) -> EncodedImage? {
        // Apply embedded EXIF orientation so the output is upright.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }

        // Calibration path: neutral, higher-quality export (no look at all).
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
            //
            // Deliberately kept JPEG-only (not the HEIC-first `srgbImage`): these frames are
            // consumed by `scripts/fit_lut.py` via PIL, which this project does not run with an
            // HEIC-capable plugin, switching this one export to HEIC would silently break the
            // calibration pipeline rather than the app.
            guard let cg = context.createCGImage(
                neutral, from: neutral.extent, format: .RGBA8, colorSpace: outputColorSpace
            ), let jpeg = encodeJPEG(cg, quality: 0.92) else { return nil }
            return EncodedImage(data: jpeg, format: .jpeg)
        }

        guard let cg = gradedPixels(source, extent: extent, stock: stock,
                                    grain: grain) else { return nil }
        return encodeImage(cg, encoding)
    }

    /// The finished, graded pixels of a capture: sRGB-tagged, downscaled to the storage cap, and
    /// carrying grain, BEFORE any lossy encode touches them.
    ///
    /// Split out of `processSync` so the encoder can be measured as the look decision it is. The
    /// encoder sweep feeds these identical pixels to every candidate codec and quality, which is
    /// the only way the drift it reports is attributable to the encoder and nothing else. The
    /// shipping path is unchanged: `processSync` is exactly this plus `encodeImage`.
    static func gradedPixels(_ data: Data, stock: FilmStock,
                             grain: GrainComposite = .sourceOver) -> CGImage? {
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }
        return gradedPixels(source, extent: extent, stock: stock, grain: grain)
    }

    private static func gradedPixels(_ source: CIImage, extent: CGRect, stock: FilmStock,
                                     grain: GrainComposite = .sourceOver) -> CGImage? {
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
        image = grainOverlay(on: image, amount: params.grain, composite: grain)

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
        //
        // `createCGImage(colorSpace:)` pins the output to sRGB (previously it inherited the
        // context default, and `UIImage.jpegData` then wrote an UNTAGGED JPEG). The encode goes
        // through CGImageDestination with this space set explicitly so the ICC tag is guaranteed.
        return context.createCGImage(image, from: image.extent, format: .RGBA8,
                                     colorSpace: outputColorSpace)
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

    /// How the noise layer is composited onto the frame.
    ///
    /// This is the one lever this enum exists for, and it is a LOOK decision: source-over adds
    /// light, the mean-preserving form does not. Both cases stay in the code so switching is a
    /// default-argument change rather than a rewrite.
    ///
    /// Currently `.sourceOver`, i.e. the shipped look, DESPITE `.meanPreserving` being measured
    /// better on 2026-08-17 (median saturation gap to Lapse −0.079 → −0.028, mean lift +0.019 → 0,
    /// texture 1.26x). It is held back deliberately: renditions are never rewritten, so the first
    /// build that ships `.meanPreserving` splits the feed into two looks permanently, and Cody
    /// wanted an unrelated profile change tested on TestFlight without that confound. Flipping it
    /// means changing the default on ALL FIVE signatures below, not just `grainOverlay`, since the
    /// outer entry points pass their own default down and would override it.
    ///
    /// The 11 look-regression baselines are recorded against `.sourceOver`, so they pass as-is and
    /// must be re-recorded (`FLIM_RECORD_LOOK_BASELINE=1`) at the same time as any flip.
    enum GrainComposite {
        /// What shipped up to 2026-08-17: the layer composited straight over the frame. Measured,
        /// that layer is a WHITE veil at random opacity rather than grey noise (see
        /// `precompensated`), so the composite could only ever add light:
        ///
        ///     E[out] = (1 − amount/2)·base + amount/2
        ///
        /// Rendered production-faithfully across the owner's 13 calibration scenes that is a median
        /// +0.019 mean and +0.024 p50, and a median 0.051 of measured saturation, before any colour
        /// value is involved at all.
        case sourceOver

        /// The same noise, the same alpha, the same mask, with the composite's known bias removed.
        case meanPreserving
    }

    /// Fine film grain: a random-opacity layer composited over the frame at FULL sensor resolution
    /// (see the call site) so the storage downscale averages it into soft film-like texture rather
    /// than leaving discrete specks.
    ///
    /// It reads as "desaturated noise at low opacity", and that is what this code was written to
    /// be, but it is not what Core Image builds out of it: measured, the layer is white at a random
    /// opacity (`precompensated` has the numbers). Which is why `composite` exists.
    ///
    /// Deliberately no Lanczos pre-upscale of the noise. That was added to fake grain clumping
    /// back when this ran at the final stored resolution and single-pixel noise looked like
    /// static; interpolating random samples is a poor substitute for the real averaging the
    /// downscale does, and it is unnecessary now that the ordering is restored.
    /// Internal rather than private so a test can render a known luminance ramp through it and
    /// confirm the mask is actually connected. The halation rewrite is the argument for that: its
    /// tint maths was right and its compositing silently lifted the whole frame, and only a
    /// render-and-measure test caught it.
    static func grainOverlay(on image: CIImage, amount: CGFloat,
                             composite: GrainComposite = .sourceOver) -> CIImage {
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

        // The frame the layer is composited ONTO. The composite carries a deterministic lift equal
        // to the veil's average opacity; `meanPreserving` cancels exactly that in the background
        // beforehand, which leaves the noise term itself — amplitude, spatial scale, distribution,
        // and the tone mask below — completely untouched. See `precompensated`.
        let background = composite == .meanPreserving ? precompensated(image, amount: amount) : image
        let grained = grainLayer.applyingFilter("CISourceOverCompositing", parameters: [
            kCIInputBackgroundImageKey: background
        ])

        // Modulate by luminance: blend between the ungrained image (where the mask is 0) and the
        // uniformly grained one (where it is 1), per pixel. Doing it as a blend rather than by
        // varying the noise layer's own alpha is what keeps the midtone result bit-identical to
        // the approved look, since the mask is exactly 1.0 there.
        //
        // The clean branch is the ORIGINAL image, not the pre-compensated one, and that is what
        // makes the correction exact at every mask value: the grained branch is unbiased on its
        // own, so any mix of the two is unbiased too.
        return grained.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputBackgroundImageKey: image,
            kCIInputMaskImageKey: grainLuminanceMask(for: image)
        ])
    }

    /// The frame, pre-scaled so that compositing the grain layer over it leaves the frame's tone
    /// exactly where it started.
    ///
    /// WHAT THE LAYER ACTUALLY IS, measured rather than assumed (`GrainCompositeProbe.anatomy`
    /// renders it and reads the pixels back in the linear working space):
    ///
    ///   layer mean 0.02982, layer alpha mean 0.03006, at `amount` 0.06
    ///
    /// Its colour is essentially WHITE at a random opacity, not mid-grey noise at a fixed low
    /// opacity. `CIRandomGenerator` emits four independent random channels which Core Image treats
    /// as PREMULTIPLIED, so `CIColorControls` un-premultiplies (rgb ÷ a, usually well above 1) and
    /// clamps, and what comes out the other side is a white veil whose opacity is the noise. So the
    /// composite is:
    ///
    ///     out = base + a·(1 − base),     a = amount·u,  u ∈ 0...1, mean ½
    ///
    /// It can only ever ADD light, most of it where there is least, and its expectation is affine
    /// in base with constant coefficients:
    ///
    ///     E[out] = (1 − amount/2)·base + amount/2
    ///
    /// Measured at `amount` 0.06: +0.0298 at black, +0.0233 at a linear midtone, +0.0036 near
    /// white, with the fitted slope (−0.03005) and intercept (+0.02982) both landing on amount/2 to
    /// within 0.8%. That is not texture, it is a veil, and it is why grain measured +0.019 mean and
    /// +0.024 p50 across the owner's 13 calibration scenes. It costs measured saturation too, since
    /// `(max − min)/max` falls whenever all three channels are lifted together.
    ///
    /// Applying the exact inverse affine to the background first cancels it:
    ///
    ///     base′ = (base − amount/2) / (1 − amount/2)      ⟹      E[out] = base
    ///
    /// per pixel, at every tone, for any amount. What is left is
    ///
    ///     out = base + (a − amount/2)·(1 − base)
    ///
    /// a mean-zero modulation of the veil's DENSITY: the frame is pre-darkened by the veil's
    /// average opacity, and the noise then thickens and thins it around that. Nothing about the
    /// noise itself changes: same generator, same alpha, same amplitude, same 1-pixel spatial
    /// scale, same `grainAnchors` mask. Only the DC term is gone.
    ///
    /// Overlay and soft light were the obvious alternatives, and both were built and measured on
    /// all thirteen calibration scenes before this was chosen (`GrainCompositeSweep`, 2026-08-17):
    ///
    ///   - SOFT LIGHT is not actually mean-preserving. Its response is not linear in the blend
    ///     value, so a symmetric noise layer still lifts the frame: +0.0033 in the midtone band and
    ///     +0.0016 over the whole frame, about a twelfth of the bug left in place. It fails the one
    ///     requirement it was a candidate for.
    ///   - OVERLAY is mean-preserving (±0.0002 on flat patches), and it is still the wrong change
    ///     to make HERE. It cannot use the existing layer at all: because the layer is a white veil
    ///     rather than grey noise, overlay needs a different noise image built from scratch, with a
    ///     new amplitude constant that has never been looked at by anyone. At the closest scale
    ///     tried it delivered 0.11× the texture this composite delivers (median across the thirteen
    ///     scenes, measured as `localContrast` above a grainless render), so adopting it means
    ///     re-tuning grain strength and re-approving the result. Grain amplitude and placement are
    ///     their own decision, with their own measurement; they do not belong in a tone fix.
    ///
    /// This one changes the noise term not at all, so the fix stays interpretable.
    private static func precompensated(_ image: CIImage, amount: CGFloat) -> CIImage {
        let gain = 1 / (1 - amount / 2)
        let bias = -(amount / 2) * gain
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: gain, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: gain, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])
    }
}

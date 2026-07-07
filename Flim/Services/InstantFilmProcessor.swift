import CoreImage
import UIKit
import ImageIO

/// Bakes an instant-camera film look into a captured photo at capture time, so the
/// developed reveal already carries the aesthetic with no view-time processing.
enum InstantFilmProcessor {
    // CIContext is expensive to build — create once and reuse for every capture.
    private static let context = CIContext()

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
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * 2
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    /// Longest edge we store the full image at. 2048 keeps shots crisp at full-screen *and* under
    /// zoom / when saved out (a big jump from 1600), while still being ~3× smaller than raw 12MP
    /// sensor output so egress stays sane. Bump higher (2560+) if you want near-original quality.
    private static let maxStoredEdge: CGFloat = 2048

    private static func processSync(_ data: Data, stock: FilmStock) -> Data? {
        // Apply embedded EXIF orientation so the output is upright.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }

        // Dark-scene tuning: grain and lifted blacks are most visible (and least flattering) in a
        // dim room, where the whole frame is shadow. Ease both off as the scene gets darker so it
        // reads clean-dark instead of hazy/grainy. Bright scenes (brightness ≥ 0.35) are untouched.
        var params = stock.params
        let brightness = averageLuminance(of: source, extent: extent)
        if brightness < 0.35 {
            let darkness = min(1, (0.35 - brightness) / 0.35)   // 0 at 0.35 → 1 at pure black
            params.grain *= (1 - 0.65 * darkness)               // up to 65% less grain
            params.blackLift *= (1 - 0.80 * darkness)           // up to 80% deeper blacks
        }

        // Filter at FULL resolution — this matches the original look. Grain and bloom render
        // relative to the native pixel size; downscaling *before* filtering (a past egress tweak)
        // made the grain coarse and the bloom too strong. So bake the look first…
        var image = filtered(source, params: params, extent: extent, grain: true)

        // …then downscale the finished image to the storage cap (keeps egress sane, look intact).
        let longEdge = max(extent.width, extent.height)
        if longEdge > maxStoredEdge {
            image = image.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: maxStoredEdge / longEdge,
                kCIInputAspectRatioKey: 1.0
            ])
        }
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }

    /// Average perceived brightness of an image, 0 (black) … 1 (white). Uses CIAreaAverage → 1px.
    private static func averageLuminance(of image: CIImage, extent: CGRect) -> CGFloat {
        guard let avg = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent)
        ])?.outputImage else { return 0.5 }
        var px: [UInt8] = [0, 0, 0, 0]
        context.render(avg, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let r = CGFloat(px[0]) / 255, g = CGFloat(px[1]) / 255, b = CGFloat(px[2]) / 255
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    /// The film look as a pure CIImage → CIImage transform. Shared by capture (with grain) and
    /// the live viewfinder preview (grain off, so it stays smooth at 30–60fps). This is the one
    /// source of truth for the look, so the preview matches the developed shot.
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

import CoreImage
import UIKit

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

    private static func processSync(_ data: Data, stock: FilmStock) -> Data? {
        // Apply embedded EXIF orientation so the output is upright.
        guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let extent = source.extent
        guard !extent.isEmpty else { return nil }

        let image = filtered(source, params: stock.params, extent: extent, grain: true)
        guard let cgImage = context.createCGImage(image, from: extent) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.85)
    }

    /// The film look as a pure CIImage → CIImage transform. Shared by capture (with grain) and
    /// the live viewfinder preview (grain off, so it stays smooth at 30–60fps). This is the one
    /// source of truth for the look, so the preview matches the developed shot.
    static func filtered(_ input: CIImage, params p: FilmParams, extent: CGRect, grain: Bool) -> CIImage {
        // 1. Saturation + contrast.
        var image = input.applyingFilter("CIColorControls", parameters: [
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

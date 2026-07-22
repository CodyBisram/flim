import UIKit
import ImageIO

/// Crops a captured photo to match what the viewfinder actually showed. `CameraPreview` fills
/// its box (3:4, see `CameraView.swift`) with `.resizeAspectFill`, which scales the sensor's
/// feed to cover that box and center-crops the overflow — but `AVCapturePhotoOutput` always
/// delivers the FULL, uncropped sensor frame. Left as-is, the saved photo shows meaningfully
/// more scene at the edges than what was framed on screen (confirmed repro: a laptop barely in
/// frame in the viewfinder appeared fully in the saved photo).
///
/// Sensor capture in portrait is roughly 4:3 (width/height ~0.75), i.e. already close to the
/// viewfinder's 3:4 box — so in practice this crop now trims little to nothing (the epsilon
/// guard below often finds the two aspect ratios already match) instead of the large width
/// crop it made when the viewfinder was full-screen. Because the captured frame is never
/// proportionally NARROWER than the box in a portrait-only app, any crop that does happen is a
/// width crop in practice.
enum CapturedPhotoCropper {

    /// Pure center-crop math: given a captured image's VISUAL size (already accounting for
    /// any EXIF rotation — see `croppedJPEGData` below) and the aspect ratio (width / height)
    /// the live preview showed, returns the rect, in that same visual coordinate space, to
    /// crop to.
    ///
    /// `.resizeAspectFill` always scales the source to cover the destination and centers
    /// whatever overflows — never an offset crop — so this is unconditionally symmetric.
    static func centerCropRect(capturedSize: CGSize, targetAspectRatio: CGFloat) -> CGRect {
        let fullRect = CGRect(origin: .zero, size: capturedSize)
        guard capturedSize.width > 0, capturedSize.height > 0, targetAspectRatio > 0 else {
            return fullRect
        }

        let capturedAspect = capturedSize.width / capturedSize.height
        let epsilon: CGFloat = 0.001
        guard abs(capturedAspect - targetAspectRatio) >= epsilon else { return fullRect }

        if capturedAspect > targetAspectRatio {
            // Captured is proportionally WIDER than the preview — the preview's aspect-fill
            // crop trimmed the left/right edges. Crop width, keep the full height.
            let newWidth = capturedSize.height * targetAspectRatio
            let originX = (capturedSize.width - newWidth) / 2
            return CGRect(x: originX, y: 0, width: newWidth, height: capturedSize.height)
        } else {
            // Captured is proportionally NARROWER/TALLER than the preview — crop height,
            // keep the full width. Not expected in practice on a portrait-only sensor
            // against a portrait screen, but handled for completeness and testability.
            let newHeight = capturedSize.width / targetAspectRatio
            let originY = (capturedSize.height - newHeight) / 2
            return CGRect(x: 0, y: originY, width: capturedSize.width, height: newHeight)
        }
    }

    /// Crops raw captured JPEG/HEIC `Data` to `targetAspectRatio` and returns re-encoded JPEG
    /// `Data` with a plain "up" orientation baked in, removing any EXIF orientation ambiguity
    /// for `InstantFilmProcessor` and everything downstream. Returns `nil` if no crop is
    /// needed (aspect ratios already match) or if decoding/re-encoding fails — the caller
    /// falls back to the original, untouched bytes in either case, so a photo is never lost.
    ///
    /// Decodes via `UIImage(data:)` deliberately, NOT `CGImageSourceCreateImageAtIndex` /
    /// a bare `CGImage`: `AVCapturePhotoOutput`'s JPEG can carry pixel data still in
    /// sensor-native LANDSCAPE layout with an EXIF orientation tag, rather than pixels
    /// already rotated to portrait. `UIImage.size` is the accessor that correctly reports
    /// the VISUAL (human-perceived, already-oriented) size by honoring that tag, so the crop
    /// math below runs in the same space a person looking at the photo sees, matching what
    /// `InstantFilmProcessor` already assumes (it decodes via
    /// `CIImage(data:options:[.applyOrientationProperty: true])`). Cropping against raw
    /// pixel-buffer dimensions instead would risk trimming the wrong axis (top/bottom
    /// instead of left/right) whenever the buffer is landscape-native.
    static func croppedJPEGData(
        from data: Data,
        targetAspectRatio: CGFloat,
        quality: CGFloat = 0.95
    ) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let visualSize = image.size   // already accounts for imageOrientation
        let cropRect = centerCropRect(capturedSize: visualSize, targetAspectRatio: targetAspectRatio)
        guard cropRect.size != visualSize else { return nil }   // aspect already matches

        let width = Int(visualSize.width.rounded())
        let height = Int(visualSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        // This app never disables wide color, and AVCaptureSession defaults to
        // `automaticallyConfiguresCaptureDeviceForWideColor = true`, so `AVCapturePhotoOutput`
        // very likely delivers Display P3-tagged JPEGs on modern iPhones. We render into a
        // CGContext built with the DECODED image's OWN color space (not a default/sRGB
        // context), so the wide-gamut pixel data is neither lost nor silently reinterpreted —
        // `InstantFilmProcessor`'s later CIImage decode still sees the correct tag and handles
        // the eventual sRGB conversion itself, at its own declared export boundary.
        let colorSpace = image.cgImage?.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // A raw CGContext built via this initializer uses Core Graphics' native bottom-left,
        // Y-up coordinate space. `UIGraphicsPushContext` only marks this context as "current"
        // for UIKit drawing — it does NOT reconcile the coordinate space the way
        // `UIGraphicsImageRenderer`/`UIGraphicsBeginImageContext` do internally. Without this
        // flip, `image.draw(in:)` below draws correctly-oriented pixels into a buffer whose
        // Y-axis is inverted relative to what UIKit assumes, so the image comes out upside
        // down. This flips the context to the top-left, Y-down convention `image.draw(in:)`
        // expects, BEFORE any drawing happens.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)

        // Draw through UIKit's own `image.draw`, which honors `imageOrientation` and bakes in
        // any rotation, by pushing OUR color-space-preserving context as the current graphics
        // context — this is what lets us keep both the orientation normalization AND the
        // original color space, rather than falling back to `UIGraphicsImageRenderer`'s
        // default (sRGB-ish) context.
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(origin: .zero, size: visualSize))
        UIGraphicsPopContext()

        guard let normalizedCG = ctx.makeImage() else { return nil }
        // Clamp to the actual bitmap bounds in case rounding `visualSize` to whole pixels above
        // left `cropRect` fractionally outside them.
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        guard let croppedCG = normalizedCG.cropping(to: cropRect.integral.intersection(bounds))
        else { return nil }

        return encodeJPEG(croppedCG, quality: quality)
    }

    /// Encodes a `CGImage` as JPEG via `CGImageDestination`, carrying the image's OWN color
    /// space/ICC profile through untouched. Mirrors the technique `InstantFilmProcessor`
    /// already uses for the same reason (documented there: `UIImage.jpegData` does not
    /// reliably embed a color profile from a bare `CGImage`) — re-implemented locally here
    /// rather than reused, since `InstantFilmProcessor`'s version is `private` and additionally
    /// pins its output to sRGB, which this crop step must NOT do (it must preserve whatever
    /// wide-gamut tag the camera actually delivered). Falls back to `UIImage.jpegData` only if
    /// the destination can't be built at all — a photo must not be lost to this fallback path.
    private static func encodeJPEG(_ cg: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else {
            return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
        }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            return UIImage(cgImage: cg).jpegData(compressionQuality: quality)
        }
        return out as Data
    }
}

import CoreGraphics

/// The maths behind the 1:1 profile-photo cropper: mapping what the user framed in a square
/// window back to a rectangle of source pixels.
///
/// Pure and free of SwiftUI/UIKit on purpose, the same reason `CapturedPhotoCropper` is: the
/// interesting part is the coordinate mapping, and it can be asserted exactly without standing up
/// a view or a gesture. The view owns only the gestures and the pixels.
///
/// # Coordinate model
/// The window is a square of `windowSide` POINTS. At `scale` 1 the image is laid out to FILL that
/// window (its shorter edge exactly spans it), so `base = windowSide / min(imageWidth, imageHeight)`
/// is the points-per-pixel at rest, and `s = base * scale` is the points-per-pixel the user is
/// actually looking at. `offset` is how far the user has dragged the image, in points, measured
/// from centred.
enum ProfileCropGeometry {

    /// Smallest allowed zoom. 1 means "the image exactly fills the window", so going below it
    /// would expose empty space inside the crop and there is never a reason to allow that.
    static let minScale: CGFloat = 1
    /// Largest allowed zoom. 6x of a 2048px working image still leaves ~340px across the window,
    /// comfortably above the 512px an avatar is stored at only when zoomed less, so this is the
    /// point past which cropping starts visibly costing resolution.
    static let maxScale: CGFloat = 6

    /// Points-per-pixel when the image is laid out to fill the square window at zoom 1.
    static func baseScale(imageSize: CGSize, windowSide: CGFloat) -> CGFloat {
        let shortEdge = min(imageSize.width, imageSize.height)
        guard shortEdge > 0 else { return 1 }
        return windowSide / shortEdge
    }

    /// How far the image may be dragged before its edge would pull inside the window, in points.
    ///
    /// This is what stops the crop ever containing blank space: at zoom 1 the shorter axis has
    /// exactly zero slack (the image only just fills the window), and the longer axis has however
    /// much it overhangs. Zooming in adds slack on both.
    static func maxOffset(imageSize: CGSize, windowSide: CGFloat, scale: CGFloat) -> CGSize {
        let s = baseScale(imageSize: imageSize, windowSide: windowSide) * max(scale, minScale)
        return CGSize(
            width: max(0, (imageSize.width * s - windowSide) / 2),
            height: max(0, (imageSize.height * s - windowSide) / 2)
        )
    }

    /// Clamps a drag so the image can't be pulled away from the window edges.
    ///
    /// Applied on every gesture change rather than only at the end, so the image stops dead at the
    /// edge instead of rubber-banding to a position the crop can't actually use.
    static func clampedOffset(_ offset: CGSize, imageSize: CGSize, windowSide: CGFloat, scale: CGFloat) -> CGSize {
        let limit = maxOffset(imageSize: imageSize, windowSide: windowSide, scale: scale)
        return CGSize(
            width: min(limit.width, max(-limit.width, offset.width)),
            height: min(limit.height, max(-limit.height, offset.height))
        )
    }

    /// Clamps a pinch to the allowed zoom range.
    static func clampedScale(_ scale: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, scale))
    }

    /// The square of SOURCE PIXELS currently framed by the window.
    ///
    /// Dragging the image right (positive `offset.width`) reveals pixels further LEFT, hence the
    /// subtraction: the offset moves the image under a fixed window, not the window over a fixed
    /// image. Result is in the image's own pixel space with the origin at top-left, ready for
    /// `CGImage.cropping(to:)`.
    ///
    /// The returned rect is always inside the image, so a caller never has to handle a crop that
    /// runs off the edge: with `offset` clamped it already is, and it is clamped again here so a
    /// rounding error at maximum drag can't produce an out-of-bounds rect that returns nil from
    /// `cropping(to:)` and loses the user's photo.
    static func cropRect(imageSize: CGSize, windowSide: CGFloat, scale: CGFloat, offset: CGSize) -> CGRect {
        let clampedScale = max(scale, minScale)
        let s = baseScale(imageSize: imageSize, windowSide: windowSide) * clampedScale
        guard s > 0, windowSide > 0 else { return CGRect(origin: .zero, size: imageSize) }

        let side = min(windowSide / s, min(imageSize.width, imageSize.height))
        let clamped = clampedOffset(offset, imageSize: imageSize, windowSide: windowSide, scale: clampedScale)

        let centerX = imageSize.width / 2 - clamped.width / s
        let centerY = imageSize.height / 2 - clamped.height / s

        let x = min(max(0, centerX - side / 2), max(0, imageSize.width - side))
        let y = min(max(0, centerY - side / 2), max(0, imageSize.height - side))
        return CGRect(x: x, y: y, width: side, height: side)
    }
}

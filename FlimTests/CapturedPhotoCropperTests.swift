import XCTest
import UIKit
import ImageIO
import CoreGraphics
@testable import Flim

/// Covers the fix for the full-bleed viewfinder vs. saved-photo framing mismatch: the
/// `.resizeAspectFill` preview center-crops the live feed to fill the screen, but
/// `AVCapturePhotoOutput` always delivers the full, uncropped sensor frame. These tests pin
/// down the pure center-crop math (`centerCropRect`) so the real-camera behavior can't
/// regress silently.
final class CapturedPhotoCropperTests: XCTestCase {

    private let epsilon: CGFloat = 0.01

    /// Captured proportionally WIDER than the target — the diagnosed real-world case:
    /// a roughly-square/landscape-ish captured frame against a much narrower preview must
    /// crop WIDTH and keep the full height, centered.
    func testCapturedWiderThanTargetCropsWidth() {
        let captured = CGSize(width: 400, height: 300)   // aspect 1.333
        let target: CGFloat = 1.0   // narrower than captured
        let rect = CapturedPhotoCropper.centerCropRect(capturedSize: captured, targetAspectRatio: target)

        XCTAssertEqual(rect.height, 300, accuracy: epsilon, "height must stay full")
        XCTAssertEqual(rect.width, 300, accuracy: epsilon, "cropped width should equal height * targetAspectRatio")
        XCTAssertEqual(rect.origin.y, 0, accuracy: epsilon)
        // Centered: equal margin trimmed off each side.
        XCTAssertEqual(rect.origin.x, (400 - 300) / 2, accuracy: epsilon)
        XCTAssertLessThan(rect.width, captured.width, "width axis must actually be the one cropped")
    }

    /// Captured proportionally NARROWER/TALLER than the target — crops height, keeps full
    /// width, centered. Not the shape of the real camera bug, but the function must handle
    /// it symmetrically for completeness.
    func testCapturedNarrowerThanTargetCropsHeight() {
        let captured = CGSize(width: 300, height: 400)   // aspect 0.75
        let target: CGFloat = 1.5   // wider than captured
        let rect = CapturedPhotoCropper.centerCropRect(capturedSize: captured, targetAspectRatio: target)

        XCTAssertEqual(rect.width, 300, accuracy: epsilon, "width must stay full")
        XCTAssertEqual(rect.height, 200, accuracy: epsilon, "cropped height should equal width / targetAspectRatio")
        XCTAssertEqual(rect.origin.x, 0, accuracy: epsilon)
        XCTAssertEqual(rect.origin.y, (400 - 200) / 2, accuracy: epsilon)
        XCTAssertLessThan(rect.height, captured.height, "height axis must actually be the one cropped")
    }

    /// Aspect ratios already match (within epsilon) — a no-op crop, full rect returned
    /// unchanged, so `croppedJPEGData` skips re-encoding entirely.
    func testCapturedEqualToTargetIsNoOp() {
        let captured = CGSize(width: 390, height: 844)
        let target = captured.width / captured.height
        let rect = CapturedPhotoCropper.centerCropRect(capturedSize: captured, targetAspectRatio: target)

        XCTAssertEqual(rect, CGRect(origin: .zero, size: captured))
    }

    /// The real-world numbers from the diagnosed bug: a 4:3 portrait sensor capture
    /// (3024x4032) against a realistic modern-iPhone screen aspect ratio (~0.46, e.g. a
    /// 390x844 point screen). Confirms the cropped axis is WIDTH (matching "excess width in
    /// the saved photo"), the resulting width is meaningfully less than the captured width,
    /// and the height is left fully untouched.
    func testRealWorldPortraitCaptureCropsWidthMeaningfully() {
        let captured = CGSize(width: 3024, height: 4032)   // sensor 4:3 in portrait
        let target: CGFloat = 390.0 / 844.0                // ~0.4622, a typical phone screen
        let rect = CapturedPhotoCropper.centerCropRect(capturedSize: captured, targetAspectRatio: target)

        XCTAssertEqual(rect.height, captured.height, accuracy: epsilon, "height must be fully preserved")
        XCTAssertLessThan(rect.width, captured.width, "width must be the cropped axis")
        // The preview is meaningfully narrower than the 4:3 sensor capture (0.75 vs ~0.46),
        // so the trimmed width should be substantial, not a rounding sliver.
        XCTAssertLessThan(rect.width, captured.width * 0.7)
        XCTAssertEqual(rect.origin.x, (captured.width - rect.width) / 2, accuracy: epsilon, "crop must be centered")
    }

    // MARK: - croppedJPEGData end-to-end (synthetic image, no camera needed)

    /// Builds a synthetic JPEG of an exact pixel size, upright ("up") orientation, standing
    /// in for a decoded capture — the orientation-normalization / re-encode path itself is
    /// exercised here (decode → crop → bake to "up" → re-encode), not just the rect math.
    private func syntheticJPEG(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.systemRed.setFill()
            // A marker rect in the top-left so a wrong-axis crop (which would clip this
            // corner) is detectable, not just a size check.
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        return image.jpegData(compressionQuality: 0.95)!
    }

    func testCroppedJPEGDataProducesExpectedPixelWidth() throws {
        let capturedSize = CGSize(width: 400, height: 300)
        let data = syntheticJPEG(size: capturedSize)
        let cropped = try XCTUnwrap(
            CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: 1.0),
            "expected a cropped image when aspect ratios differ"
        )
        let image = try XCTUnwrap(UIImage(data: cropped))
        XCTAssertEqual(image.size.height, 300, accuracy: 1, "height must be preserved")
        XCTAssertEqual(image.size.width, 300, accuracy: 1, "width must equal height * targetAspectRatio")
        XCTAssertEqual(image.imageOrientation, .up, "output must be normalized to a plain 'up' orientation")
    }

    func testCroppedJPEGDataReturnsNilWhenAspectAlreadyMatches() {
        let capturedSize = CGSize(width: 300, height: 300)
        let data = syntheticJPEG(size: capturedSize)
        let cropped = CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: 1.0)
        XCTAssertNil(cropped, "no crop needed should skip re-encoding and signal the caller to keep the original")
    }

    // MARK: - Orientation (the upside-down regression this fix guards against)

    /// Builds a synthetic JPEG with an ASYMMETRIC top/bottom split (top half white, bottom
    /// half black) so a vertical flip is unambiguously detectable — unlike a size-only check,
    /// which a vertically-flipped image would still pass.
    private func topBottomSplitJPEG(size: CGSize) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height / 2))
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2))
        }
        return image.jpegData(compressionQuality: 0.95)!
    }

    /// Reads the raw RGBA bytes of a `UIImage` by drawing it into a known, plain top-left,
    /// Y-down sRGB buffer — independent of `CapturedPhotoCropper`'s own drawing path, so this
    /// sampling itself can't hide the same bug it's meant to catch.
    private func pixel(_ image: UIImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            XCTFail("failed to build sampling context")
            return (0, 0, 0)
        }
        // Plain top-left/Y-down flip, matching UIKit's own convention, so this helper's
        // output reflects the image's VISUAL orientation, not Quartz's native one.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(ctx)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
        UIGraphicsPopContext()

        let offset = (y * width + x) * 4
        return (buffer[offset], buffer[offset + 1], buffer[offset + 2])
    }

    /// Proves the fix: an asymmetric top(white)/bottom(black) source, run through a WIDTH
    /// crop (the real-world shape of the bug — see `testRealWorldPortraitCaptureCropsWidthMeaningfully`),
    /// must still have white on top and black on bottom in the output. Before the Y-flip fix,
    /// this would fail (output flipped: black on top, white on bottom), while the existing
    /// `testCroppedJPEGDataProducesExpectedPixelWidth` test — which only checks size and
    /// orientation tag, never pixel content — would still have passed, so it never caught this
    /// regression.
    func testCroppedJPEGDataPreservesVerticalOrientation() throws {
        let capturedSize = CGSize(width: 400, height: 300)   // forces a width-only crop
        let data = topBottomSplitJPEG(size: capturedSize)
        let cropped = try XCTUnwrap(
            CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: 1.0),
            "expected a cropped image when aspect ratios differ"
        )
        let image = try XCTUnwrap(UIImage(data: cropped))
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        XCTAssertEqual(width, 300, accuracy: 1)
        XCTAssertEqual(height, 300, accuracy: 1)

        let topSample = pixel(image, x: width / 2, y: 5)
        let bottomSample = pixel(image, x: width / 2, y: height - 5)

        XCTAssertGreaterThan(topSample.r, 200, "top of output must still be the WHITE half, not flipped")
        XCTAssertLessThan(bottomSample.r, 55, "bottom of output must still be the BLACK half, not flipped")
    }

    // MARK: - Color profile preservation (the P0 regression this fix guards against)

    /// True iff the JPEG data carries an ICC/color profile marker readable by ImageIO, and
    /// its name if present. Mirrors `ColorProfileTests`' helper.
    private func profileInfo(_ data: Data) -> (hasProfile: Bool, name: String?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (false, nil) }
        let name = props[kCGImagePropertyProfileName] as? String
        return (name != nil, name)
    }

    /// Builds a JPEG tagged with Display P3 (a real, non-sRGB color space AVCapturePhotoOutput
    /// commonly delivers on modern iPhones, since this app never disables wide color).
    /// Encodes via `CGImageDestination` directly (bypassing `UIImage.jpegData`, the exact API
    /// this fix avoids) so the fixture itself is a trustworthy, independently-built P3 JPEG.
    private func syntheticP3JPEG(size: CGSize) throws -> Data {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: 0, space: p3, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(origin: .zero, size: size))
        let cgImage = try XCTUnwrap(ctx.makeImage())

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The regression this fix targets: a bare `UIImage(cgImage:).jpegData(...)` re-encode
    /// does not reliably embed a color profile, so a Display P3-tagged capture would get
    /// silently reinterpreted as sRGB downstream (an irreversible desaturation/hue shift,
    /// since the original uncropped bytes are discarded once cropping succeeds). This asserts
    /// the crop step's own `CGImageDestination`-based re-encode carries the ORIGINAL profile
    /// through, not just "a" profile.
    func testCroppedJPEGDataPreservesNonSRGBColorProfile() throws {
        let capturedSize = CGSize(width: 400, height: 300)   // aspect differs so a crop actually happens
        let fixture = try syntheticP3JPEG(size: capturedSize)

        // Sanity: the fixture really is P3-tagged before the crop step ever touches it.
        let fixtureProfile = try XCTUnwrap(profileInfo(fixture).name, "fixture must be color-tagged")
        XCTAssertTrue(fixtureProfile.lowercased().contains("p3"), "fixture must be P3-tagged, got \(fixtureProfile)")

        let cropped = try XCTUnwrap(
            CapturedPhotoCropper.croppedJPEGData(from: fixture, targetAspectRatio: 1.0),
            "expected a cropped image when aspect ratios differ"
        )
        let croppedProfile = profileInfo(cropped)
        XCTAssertTrue(croppedProfile.hasProfile, "cropped output must still carry a color profile")
        XCTAssertTrue(
            (croppedProfile.name ?? "").lowercased().contains("p3"),
            "crop step must preserve the ORIGINAL P3 profile, not silently coerce to sRGB; got \(croppedProfile.name ?? "nil")"
        )
    }
}

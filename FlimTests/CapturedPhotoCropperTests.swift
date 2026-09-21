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

    /// Captured proportionally WIDER than the target, the diagnosed real-world case:
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

    /// Captured proportionally NARROWER/TALLER than the target, crops height, keeps full
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

    /// Aspect ratios already match (within epsilon), a no-op crop, full rect returned
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
    /// in for a decoded capture, the orientation-normalization / re-encode path itself is
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
    /// half black) so a vertical flip is unambiguously detectable, unlike a size-only check,
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
    /// Y-down sRGB buffer, independent of `CapturedPhotoCropper`'s own drawing path, so this
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
    /// crop (the real-world shape of the bug, see `testRealWorldPortraitCaptureCropsWidthMeaningfully`),
    /// must still have white on top and black on bottom in the output. Before the Y-flip fix,
    /// this would fail (output flipped: black on top, white on bottom), while the existing
    /// `testCroppedJPEGDataProducesExpectedPixelWidth` test, which only checks size and
    /// orientation tag, never pixel content, would still have passed, so it never caught this
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

    // MARK: - Implausible target guard (capture-time policy, not the geometry)

    /// The reported bug: subjects at the far left and far right missing from the saved photo
    /// while the middle looked fine. `previewAspectRatio` is written from the preview's LIVE
    /// bounds every layout pass, so a transient pass can report a near-full-screen ratio, and a
    /// 4:3 capture cropped to that loses ~40% of its width, symmetrically.
    ///
    /// The guard lives at the capture call site, not in `centerCropRect`, which stays pure
    /// geometry, hence testing the predicate rather than the crop here.
    func testTheRealViewfinderAspectIsTrusted() {
        XCTAssertTrue(CapturedPhotoCropper.isPlausibleTargetAspect(0.75))
        // Layout rounding around the real 3:4 box must keep working.
        XCTAssertTrue(CapturedPhotoCropper.isPlausibleTargetAspect(0.748))
        XCTAssertTrue(CapturedPhotoCropper.isPlausibleTargetAspect(0.752))
    }

    func testFullScreenishTargetIsRejected() {
        // ~0.46 was legitimate when the viewfinder was full-screen; it cannot be now that the
        // viewfinder is a fixed 3:4 box, so reaching capture means a bad measurement.
        XCTAssertFalse(CapturedPhotoCropper.isPlausibleTargetAspect(390.0 / 844.0))
    }

    func testOtherImpossibleTargetsAreRejected() {
        XCTAssertFalse(CapturedPhotoCropper.isPlausibleTargetAspect(1.78))   // landscape 16:9
        XCTAssertFalse(CapturedPhotoCropper.isPlausibleTargetAspect(0))
        XCTAssertFalse(CapturedPhotoCropper.isPlausibleTargetAspect(-1))
    }

    func testSkippingTheCropKeepsMoreOfThePhotoNotLess() {
        // Failing safe means the saved photo can only ever be wider than framed, never narrower.
        let sensor = CGSize(width: 3024, height: 4032)
        let framed = CapturedPhotoCropper.centerCropRect(capturedSize: sensor, targetAspectRatio: 0.75)
        XCTAssertGreaterThanOrEqual(sensor.width, framed.width)
    }
}


// MARK: - The capture path: one decode

/// What the shutter does between `AVCapturePhotoOutput` handing over bytes and a graded master
/// existing, and the proof that shortening it did not change the photograph.
///
/// Until 2026-09-21 that stretch cost three full decodes of a 12MP frame and a lossy re-encode:
/// the capture callback decoded it, redrew it to bake orientation, cropped it and re-encoded it at
/// q0.95; `gradeForCapture` decoded THAT; and `EmojiSuggestion` decoded the original a third time.
/// It is one decode now, and the JPEG generation is out of the master's path: the crop hands the
/// grade a `CGImage`. The q0.95 encode still happens, off the callback, because the shot on disk
/// has to survive a kill while it waits its turn (`CaptureQueueStore`), but nothing reads it back
/// unless that kill happens.
///
/// The master's bytes therefore CHANGE for real captures, by exactly one JPEG generation, and
/// these measure that: same geometry, same colour space, same statistics, and a per-pixel spread
/// the size of q0.95's own error.
final class CapturePathDecodeTests: XCTestCase {

    /// A capture-shaped frame with real content in it: the look fixtures, re-encoded as a camera
    /// would deliver them, at an aspect the crop actually has to trim.
    private func capture(_ fixture: LookFixture, exifFlash: Int? = nil) throws -> Data {
        let cg = try XCTUnwrap(LookMeasure.decode(fixture.pngData()))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
        if let exifFlash {
            props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifFlash: exifFlash] as [CFString: Any]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The old path, kept here as the thing the new one is measured against: crop to JPEG, then
    /// grade those bytes.
    private func masterTheOldWay(_ data: Data, aspect: CGFloat) throws -> CGImage {
        let cropped = CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: aspect) ?? data
        return try XCTUnwrap(InstantFilmProcessor.gradedPixels(cropped, stock: .original))
    }

    private func masterTheNewWay(_ data: Data, aspect: CGFloat) throws -> CGImage {
        let frame = try XCTUnwrap(CapturedPhotoCropper.prepare(from: data, targetAspectRatio: aspect))
        return try XCTUnwrap(InstantFilmProcessor.gradedPixels(
            frame.image, stock: .original, flashFired: frame.exifFlash.map { $0 & 1 == 1 } ?? false))
    }

    /// Geometry first, because a crop that moved is a bug and not a tolerance question.
    func testTheCropIsTheSameCropItAlwaysWas() throws {
        // 0.62, not 0.75: the fixtures are already 3:4, which is the case where the crop
        // correctly does nothing. A target the crop has to act on is the one worth pinning.
        for fixture in [LookFixture.daylight, .night, .gamut] {
            let data = try capture(fixture)
            let aspect: CGFloat = 0.62
            let cropped = try XCTUnwrap(LookMeasure.decode(
                try XCTUnwrap(CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: aspect))))
            let frame = try XCTUnwrap(CapturedPhotoCropper.prepare(from: data, targetAspectRatio: aspect))
            XCTAssertTrue(frame.didCrop)
            XCTAssertEqual(frame.image.width, cropped.width, "\(fixture.rawValue): the crop changed width")
            XCTAssertEqual(frame.image.height, cropped.height, "\(fixture.rawValue): the crop changed height")
        }
    }

    /// The colour space the camera delivered has to survive the decode, for the reason the crop
    /// has always given: the original bytes are gone once the shot is graded.
    func testThePreparedFrameKeepsTheCapturesColourSpace() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: p3,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.9, green: 0.2, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()),
                                   [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let frame = try XCTUnwrap(CapturedPhotoCropper.prepare(from: out as Data, targetAspectRatio: 0.75))
        let name = (frame.image.colorSpace?.name as String?) ?? ""
        XCTAssertTrue(name.lowercased().contains("p3"),
                      "the prepared frame lost the capture's wide-gamut tag, got \(name)")
    }

    /// The flash gate travels with the pixels or it stops working, silently.
    func testThePreparedFrameCarriesTheFlashTag() throws {
        let fired = try capture(.flash, exifFlash: 0x19)
        XCTAssertEqual(try XCTUnwrap(CapturedPhotoCropper.prepare(from: fired, targetAspectRatio: 0.75)).exifFlash, 0x19)
        let ambient = try capture(.flash, exifFlash: 0x10)
        XCTAssertEqual(try XCTUnwrap(CapturedPhotoCropper.prepare(from: ambient, targetAspectRatio: 0.75)).exifFlash, 0x10)
        XCTAssertNil(try XCTUnwrap(CapturedPhotoCropper.prepare(from: try capture(.flash), targetAspectRatio: 0.75)).exifFlash)
    }

    /// A capture whose pixels are still in sensor-native landscape with an EXIF orientation tag:
    /// the grade used to apply that tag itself, and now the decode bakes it in first. Same
    /// photograph, pixel for pixel, or the whole change is a rotation bug waiting to ship.
    func testAnOrientedCaptureBakesToTheSamePixelsTheGradeWouldHaveProduced() throws {
        let cg = try XCTUnwrap(LookMeasure.decode(LookFixture.daylight.pngData()))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        // 6 = rotate 90 CW on display, what an iPhone writes for a portrait shot off a
        // landscape-native buffer.
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 1.0,
                                              kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let data = out as Data

        let frame = try XCTUnwrap(CapturedPhotoCropper.prepare(from: data, targetAspectRatio: nil))
        let viaCI = try XCTUnwrap(CIImage(data: data, options: [.applyOrientationProperty: true]))
        let rendered = try XCTUnwrap(LookMeasure.context.createCGImage(viaCI, from: viaCI.extent,
                                                                      format: .RGBA8,
                                                                      colorSpace: LookMeasure.srgb))
        XCTAssertEqual(frame.image.width, rendered.width, "the baked frame is not the oriented size")
        XCTAssertEqual(frame.image.height, rendered.height, "the baked frame is not the oriented size")
        let a = try XCTUnwrap(FlashFalloffTests.pixels(of: frame.image))
        let b = try XCTUnwrap(FlashFalloffTests.pixels(of: rendered))
        var worst = 0
        for (x, y) in zip(a, b) { worst = max(worst, abs(Int(x) - Int(y))) }
        XCTAssertLessThanOrEqual(worst, 2, "baking the orientation moved pixels by \(worst) of 255")
    }

    /// What the master actually gained, measured, on synthetic captures and on the owner's real
    /// ones. Prints the per-scene table the audit asked for.
    func testTheMasterMovesByOneJPEGGenerationAndNothingElse() throws {
        var scenes: [(name: String, data: Data)] = try [LookFixture.daylight, .night, .shadowRamp,
                                                        .speculars, .gamut, .flash]
            .map { ($0.rawValue, try capture($0, exifFlash: $0.firesFlash ? 0x09 : nil)) }
        if LookPairs.isAvailable {
            scenes += LookPairs.scenes.compactMap { scene in
                LookPairs.neutralData(scene).map { (scene, $0) }
            }
        }
        // Both cases, because they are different claims. At 0.75 the capture is already the
        // viewfinder's shape, no crop runs, and the OLD path graded the camera's own bytes: the
        // master must be bit-identical, since all that changed is who decoded them. At 0.62 the
        // crop runs, and the old path put a q0.95 JPEG generation between the crop and the grade
        // that the new one does not: the master moves by that generation and by nothing else.
        let cases: [(name: String, data: Data, aspect: CGFloat)] = scenes.flatMap {
            [(name: $0.name + " nocrop", data: $0.data, aspect: CGFloat(0.75)),
             (name: $0.name + " crop", data: $0.data, aspect: CGFloat(0.62))]
        }
        for (name, data, aspect) in cases {
            let old = try masterTheOldWay(data, aspect: aspect)
            let new = try masterTheNewWay(data, aspect: aspect)
            XCTAssertEqual(new.width, old.width, "\(name): the master changed size")
            XCTAssertEqual(new.height, old.height, "\(name): the master changed size")

            let a = try XCTUnwrap(FlashFalloffTests.pixels(of: new))
            let b = try XCTUnwrap(FlashFalloffTests.pixels(of: old))
            var worst = 0, differing = 0
            var sum = 0.0
            for (x, y) in zip(a, b) {
                let d = abs(Int(x) - Int(y))
                if d > 0 { differing += 1 }
                worst = max(worst, d)
                sum += Double(d)
            }
            let oldStats = try XCTUnwrap(LookMeasure.stats(of: old))
            let newStats = try XCTUnwrap(LookMeasure.stats(of: new))
            let drift = LookRegressionTests.worstDrift(newStats, oldStats)
            print(String(format: "CAPTURE %@: max channel %d, mean |delta| %.4f, %.1f%% of channels differ, worst statistic %@ %.5f (tolerance %.5f), saturation %.5f to %.5f",
                         name, worst, sum / Double(a.count),
                         100 * Double(differing) / Double(a.count),
                         drift.field, drift.drift, drift.tolerance,
                         oldStats.meanSaturation, newStats.meanSaturation))

            guard aspect != 0.75 else {
                // No crop: the old path graded the camera's own bytes and the new one grades the
                // same bytes decoded here instead of inside Core Image. Identical, to the byte.
                XCTAssertEqual(worst, 0, "\(name): the master moved on a capture that was never cropped")
                continue
            }

            // With a crop, one q0.95 generation has left the master's path, so the master is
            // ALLOWED to move, in one direction and by a bounded amount. Tone and colour must not
            // move at all: means and percentiles stay inside the look pin's own tolerances.
            var worstOther = (name: "", drift: 0.0)
            for (field, was) in zip(newStats.fields, oldStats.fields) where field.name != "saturation" {
                let tolerance: Double
                switch field.name {
                case "lumP5", "lumP50", "lumP95": tolerance = LookRegressionTests.percentileTolerance
                case "localContrast": tolerance = LookRegressionTests.localContrastTolerance
                default:
                    // One 8-bit level, where the look pin allows half, and only here. Restoring
                    // chroma to a frame that had it subsampled away moves a channel MEAN a little
                    // wherever the lost chroma was not symmetric, and on `speculars`, a frame that
                    // is nothing but small saturated dots, that is measurably the case: meanB
                    // 0.36657 to 0.36434, 0.57 of a level, with saturation up 0.0057 on the same
                    // frame. Every other scene here, including all five of the owner's real
                    // captures, stays inside the pin's own half-level.
                    tolerance = 2 * LookRegressionTests.meanTolerance
                }
                if abs(field.value - was.value) > worstOther.drift {
                    worstOther = (field.name, abs(field.value - was.value))
                }
                XCTAssertLessThanOrEqual(
                    abs(field.value - was.value), tolerance,
                    "\(name).\(field.name) moved \(abs(field.value - was.value)) (\(was.value) to \(field.value)); that is a tone or colour shift, not a lost JPEG generation"
                )
            }
            print(String(format: "CAPTURE %@: worst non-saturation statistic %@ %.5f",
                         name, worstOther.name, worstOther.drift))
            // Saturation is the one statistic a q0.95 generation really takes, because its chroma
            // subsampling averages fine colour detail away. It may therefore come back, and only
            // come back: a DROP would mean the new path is losing chroma the old one kept, which
            // is the opposite of what removing a generation can do.
            XCTAssertGreaterThanOrEqual(
                newStats.meanSaturation,
                oldStats.meanSaturation - LookRegressionTests.saturationTolerance,
                "\(name): saturation fell from \(oldStats.meanSaturation) to \(newStats.meanSaturation) with a JPEG generation REMOVED"
            )
            XCTAssertLessThanOrEqual(
                newStats.meanSaturation - oldStats.meanSaturation, 0.01,
                "\(name): saturation rose \(newStats.meanSaturation - oldStats.meanSaturation), which is more chroma than one q0.95 generation can account for"
            )
        }
    }

    /// Shutter callback to graded master, both ways, on a 12MP capture that really crops.
    ///
    /// A simulator number is not a device number and is not offered as one: it is the same work on
    /// the same pixels, so what it measures honestly is the SHAPE of the change, how much of it
    /// runs where. The first row is the one that mattered most: that work used to run inside
    /// `photoOutput(_:didFinishProcessingPhoto:)`, on AVFoundation's own delegate queue, before
    /// the shutter could return.
    func testTheTimeFromShutterToMaster() throws {
        let data = try twelveMegapixelCapture()
        let aspect: CGFloat = 0.70
        func time(_ label: String, _ body: () throws -> Void) rethrows {
            _ = try? body()   // warm the caches, like a second shot in a burst
            var best = Duration.seconds(3600)
            var total = Duration.zero
            let runs = 5
            for _ in 0..<runs {
                let start = ContinuousClock.now
                try autoreleasepool { try body() }
                let elapsed = start.duration(to: ContinuousClock.now)
                best = min(best, elapsed)
                total += elapsed
            }
            let ms = { (d: Duration) in Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15 }
            print(String(format: "SHUTTER %@: best %.1f ms, mean %.1f ms over %d runs",
                         label, ms(best), ms(total) / Double(runs), runs))
        }
        try time("callback, old (decode, redraw, crop, encode q0.95)") {
            _ = CapturedPhotoCropper.croppedJPEGData(from: data, targetAspectRatio: aspect)
        }
        time("callback, new (hand the bytes over)") {
            _ = data.count
        }
        try time("shutter to master, old") {
            let cg = try self.masterTheOldWay(data, aspect: aspect)
            _ = InstantFilmProcessor.encodeImage(cg, InstantFilmProcessor.fullEncoding)
        }
        try time("shutter to master, new") {
            let cg = try self.masterTheNewWay(data, aspect: aspect)
            _ = InstantFilmProcessor.encodeImage(cg, InstantFilmProcessor.fullEncoding)
        }
        try time("shutter to master, new, durable copy included") {
            let frame = try XCTUnwrap(CapturedPhotoCropper.prepare(from: data, targetAspectRatio: aspect))
            _ = CapturedPhotoCropper.jpegData(from: frame)
            let cg = try XCTUnwrap(InstantFilmProcessor.gradedPixels(
                frame.image, stock: .original, flashFired: false))
            _ = InstantFilmProcessor.encodeImage(cg, InstantFilmProcessor.fullEncoding)
        }
    }

    /// Peak memory, which the look pin's harness does not expose, so it is read here from the
    /// task itself: `phys_footprint` is the number iOS actually kills a process over.
    ///
    /// The shape of the answer is known before it is measured and the measurement is here to size
    /// it: the new path holds the decoded 12MP frame alive ACROSS the grade, where the old one
    /// released it and held a 3MB JPEG instead. That is a real trade, paid once per shot on a
    /// pipeline that grades one shot at a time.
    func testTheFootprintOfEachPath() throws {
        let data = try twelveMegapixelCapture()
        func footprint() -> Double {
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { return -1 }
            return Double(info.phys_footprint) / 1_048_576
        }
        // Both orders, because whichever runs first pays for the caches both of them then use.
        for label in ["old", "new", "old", "new"] {
            autoreleasepool { _ = try? label == "old" ? self.masterTheOldWay(data, aspect: 0.70)
                                                      : self.masterTheNewWay(data, aspect: 0.70) }
            let before = footprint()
            var peak = before
            try autoreleasepool {
                let cg = label == "old" ? try self.masterTheOldWay(data, aspect: 0.70)
                                        : try self.masterTheNewWay(data, aspect: 0.70)
                peak = max(peak, footprint())
                _ = cg.width
            }
            print(String(format: "FOOTPRINT %@: %.1f MB settled, %.1f MB peak, delta %.1f MB",
                         label, before, peak, peak - before))
        }
    }

    /// A capture the size the camera actually delivers, 3024x4032, so the decode being counted is
    /// the decode the shutter pays for rather than a 1.7MP fixture's.
    private func twelveMegapixelCapture() throws -> Data {
        let source = try XCTUnwrap(CIImage(data: LookFixture.daylight.pngData()))
        let scaled = source.applyingFilter("CILanczosScaleTransform", parameters: [
            kCIInputScaleKey: 4032 / source.extent.height, kCIInputAspectRatioKey: 1.0])
        let cg = try XCTUnwrap(LookMeasure.context.createCGImage(scaled, from: scaled.extent,
                                                                 format: .RGBA8,
                                                                 colorSpace: LookMeasure.srgb))
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }
}

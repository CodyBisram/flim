import XCTest
import UIKit
import ImageIO
import CoreGraphics
@testable import Flim

/// P0 export color-management guard: every JPEG the processor writes must carry an ICC
/// color profile (sRGB), so shared photos read correctly outside the app (Messages/web/
/// Android interpret UNTAGGED JPEGs as sRGB and would otherwise mis-render our output).
final class ColorProfileTests: XCTestCase {

    /// Builds a small synthetic JPEG to feed the pipeline (stands in for a captured frame).
    private func syntheticJPEG() -> Data {
        let size = CGSize(width: 512, height: 512)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor.orange.cgColor, UIColor.blue.cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: colors, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero,
                                  end: CGPoint(x: size.width, y: size.height), options: [])
        }
        return image.jpegData(compressionQuality: 0.9)!
    }

    /// True iff the JPEG data carries an ICC/color profile marker readable by ImageIO —
    /// the exact thing external viewers look for. Also returns the named profile if present.
    private func profileInfo(_ data: Data) -> (hasProfile: Bool, name: String?) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return (false, nil) }
        let name = props[kCGImagePropertyProfileName] as? String
        // A tagged JPEG either names a profile or its decoded CGImage has a non-nil color space
        // whose name is set. ImageIO surfaces the ICC via kCGImagePropertyProfileName.
        return (name != nil, name)
    }

    func testProcessedFullImageIsTaggedSRGB() async throws {
        let out = await InstantFilmProcessor.process(syntheticJPEG(), stock: .original)
        let data = try XCTUnwrap(out, "processor returned nil")
        let info = profileInfo(data)
        XCTAssertTrue(info.hasProfile, "exported full JPEG must carry an ICC profile")
        if let name = info.name {
            XCTAssertTrue(name.lowercased().contains("srgb"),
                          "expected an sRGB profile, got \(name)")
        }
    }

    func testThumbnailRenditionIsTagged() throws {
        // Feed the rendition a properly tagged full image (what PhotoService does at runtime).
        let full = syntheticJPEG()
        let thumb = try XCTUnwrap(InstantFilmProcessor.thumbnail(from: full),
                                  "thumbnail returned nil")
        XCTAssertTrue(profileInfo(thumb).hasProfile,
                      "thumbnail rendition must stay tagged for correct off-app rendering")
    }

    func testFeedRenditionIsTagged() throws {
        let feed = try XCTUnwrap(InstantFilmProcessor.feedRendition(from: syntheticJPEG()),
                                 "feedRendition returned nil")
        XCTAssertTrue(profileInfo(feed).hasProfile, "feed rendition must stay tagged")
    }
}

import Testing
import UIKit
@testable import Flim

/// The share export's geometry.
///
/// The redesign's whole premise is that the print is ONE fixed proportion and the story places
/// that print rather than re-laying it out. Both halves are ratio claims, and a ratio claim is
/// exactly the kind of thing that quietly drifts when someone tunes a border, so they are pinned
/// here rather than trusted to a mock.
struct BrandedExportTests {

    private func solidImage(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - The print is 3:4, always

    @Test("the print's outer is exactly 3:4 for a capture")
    func printIsThreeFour() {
        // 1536x2048 is the master at full width, the case the geometry was solved for.
        let outer = BrandedExport.printSize(for: CGSize(width: 1536, height: 2048))
        #expect(abs(outer.width / outer.height - 3.0 / 4.0) < 0.000001)
        // And the handoff's stated pixel figures, within rounding.
        #expect(abs(outer.width - 1686) < 1.5)
        #expect(abs(outer.height - 2248) < 1.5)
    }

    @Test("the outer stays 3:4 whatever shape the photo is")
    func printIsThreeFourForAnyPhoto() {
        // Legacy photos predating CapturedPhotoCropper letterbox INSIDE the window; they never
        // drag the outer off ratio and they are never cropped to fit it.
        for size in [CGSize(width: 2048, height: 2048),     // square
                     CGSize(width: 2048, height: 1152),     // landscape
                     CGSize(width: 1200, height: 2400),     // very tall
                     CGSize(width: 900, height: 1200)] {    // small 3:4
            let outer = BrandedExport.printSize(for: size)
            #expect(abs(outer.width / outer.height - 3.0 / 4.0) < 0.000001,
                    "outer drifted off 3:4 for \(size)")
        }
    }

    @Test("the footer is solved from the border, not chosen independently")
    func footerIsSolved() {
        // f = (5/3)b is the only value that lands the outer on 3:4. If someone retunes the
        // border and hardcodes the old footer, this is what catches it.
        #expect(abs(BrandedExport.footerFraction - BrandedExport.borderFraction * 5 / 3) < 0.000001)

        // The relationship stated the long way, straight from the derivation.
        let b = BrandedExport.borderFraction
        let f = BrandedExport.footerFraction
        #expect(abs(b + (4.0 / 3.0) * (1 - 2 * b) + f - 4.0 / 3.0) < 0.000001)
    }

    @Test("a rendered print really is the size the geometry promises")
    func renderedPrintMatchesGeometry() {
        let photo = solidImage(CGSize(width: 300, height: 400))
        let rendered = BrandedExport.print(photo)
        let expected = BrandedExport.printSize(for: photo.size)
        #expect(abs(rendered.size.width - expected.width) < 1)
        #expect(abs(rendered.size.height - expected.height) < 1)
        #expect(abs(rendered.size.width / rendered.size.height - 3.0 / 4.0) < 0.01)
    }

    @Test("a degenerate photo is handed back untouched rather than divided by zero")
    func degeneratePhotoIsSafe() {
        #expect(BrandedExport.printSize(for: .zero) == .zero)
        #expect(BrandedExport.printSize(for: CGSize(width: 100, height: 0)) == .zero)
    }

    // MARK: - The story is 9:16, and the print is placed on it

    @Test("the story canvas is exactly 9:16")
    func storyIsNineSixteen() {
        let canvas = BrandedExport.storyCanvas
        #expect(canvas == CGSize(width: 1080, height: 1920))
        #expect(abs(canvas.width / canvas.height - 9.0 / 16.0) < 0.000001)
    }

    @Test("the print sits optically high, with the air below it")
    func storyPlacementIsHigh() {
        let canvas = BrandedExport.storyCanvas
        let printWidth = canvas.width * BrandedExport.storyPrintWidthFraction
        let printHeight = printWidth * 4 / 3
        let above = canvas.height * BrandedExport.storyTopFraction
        let below = canvas.height - above - printHeight

        #expect(abs(printWidth - 842) < 1)
        #expect(abs(printHeight - 1123) < 1)
        #expect(abs(above - 297) < 1)
        #expect(abs(below - 500) < 1)
        // The point of the placement: the bottom of a story belongs to the reply field, the
        // swipe-up and everyone's stickers, so there is more room below than above.
        #expect(below > above)
    }

    @Test("the story keeps the print's proportion instead of stretching it")
    func storyDoesNotStretchThePrint() {
        let print = BrandedExport.print(solidImage(CGSize(width: 300, height: 400)))
        let story = BrandedExport.story(print: print)
        #expect(story.size == BrandedExport.storyCanvas)
        // One print, two grounds: the story is a different canvas, never a different print.
        #expect(abs(print.size.width / print.size.height - 3.0 / 4.0) < 0.01)
    }

    // MARK: - The caption line

    @Test("a roll shot names its roll, verbatim")
    func captionNamesTheRoll() {
        let text = BrandedExport.captionText(
            BrandedExport.Caption(date: .now, rollName: "sunday film club"))
        #expect(text?.contains("sunday film club") == true)
        // Lowercased as the user typed it. Title-casing someone's roll name is a small liberty
        // that shows up on every print they share.
        #expect(text?.contains("Sunday Film Club") == false)
    }

    @Test("a photo with no roll shows the date alone")
    func captionWithoutRoll() {
        let dateOnly = BrandedExport.captionText(BrandedExport.Caption(date: .now))
        #expect(dateOnly?.isEmpty == false)
        #expect(dateOnly?.contains("·") == false)

        // A roll name that is only whitespace is no roll name, not an empty separator.
        let blank = BrandedExport.captionText(
            BrandedExport.Caption(date: .now, rollName: "   "))
        #expect(blank == dateOnly)
    }

    @Test("the date carries no year")
    func captionDateHasNoYear() {
        var components = DateComponents()
        components.year = 2024
        components.month = 8
        components.day = 24
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let text = BrandedExport.captionText(BrandedExport.Caption(date: date, rollName: "roll"))
        #expect(text?.contains("2024") == false)
        #expect(text?.contains("24") == true)
    }
}

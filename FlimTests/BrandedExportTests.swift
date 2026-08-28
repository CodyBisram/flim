import Testing
import UIKit
@testable import Flim

/// The share export.
///
/// The print is borderless now: the exported file is the master with an imprint burned into it.
/// That removes a whole class of geometry (there is no paper to solve for) and adds another: a
/// segment lattice that has to stay a constant width across a roll, and a glyph map that silently
/// draws nothing for a character it does not know.
struct BrandedExportTests {

    private func solidImage(_ size: CGSize, colour: UIColor = .darkGray) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            colour.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - Borderless

    @Test("the export is the master, untouched in size")
    func printIsTheMaster() {
        // The 3:4 rule is satisfied by doing nothing: no paper, no crop, no letterbox. If this
        // ever fails, something has started resampling the master again.
        for size in [CGSize(width: 1536, height: 2048),
                     CGSize(width: 300, height: 400),
                     CGSize(width: 2048, height: 2048),      // square legacy
                     CGSize(width: 2048, height: 1152)] {    // landscape legacy
            let rendered = BrandedExport.print(solidImage(size))
            #expect(rendered.size == size, "export resized a \(size) master")
        }
    }

    @Test("a degenerate photo is handed back rather than divided by zero")
    func degeneratePhotoIsSafe() {
        let empty = UIImage()
        #expect(BrandedExport.print(empty).size == empty.size)
    }

    // MARK: - The lattice must not jitter

    @Test("the date is zero padded so the lattice never changes width")
    func dateIsZeroPadded() {
        // Load-bearing: an unpadded month would make the mark one cell narrower in September
        // than in October, and it would visibly shift across a roll shot over a month boundary.
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 4
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let text = BrandedExport.dateText(BrandedExport.Caption(date: date))
        #expect(text == "'26 08 04")
        #expect(text.count == 9)
    }

    @Test("every date the imprint can produce is drawable")
    func everyDateIsDrawable() {
        // The cell draws nothing for an unknown character, so a date that reached it with a
        // glyph missing would export a blank corner rather than fail loudly.
        var components = DateComponents()
        components.year = 2026
        components.day = 28
        for month in 1...12 {
            components.month = month
            let date = Calendar(identifier: .gregorian).date(from: components)!
            let text = BrandedExport.dateText(BrandedExport.Caption(date: date))
            #expect(BrandedExport.canDraw(text), "\(text) has a character with no segments")
        }
    }

    @Test("the wordmark is drawable, whatever the app is called")
    func wordmarkIsDrawable() {
        // The glyph map holds exactly F, L, I, M among letters. A rename would quietly export a
        // blank corner, so this is the guard that turns that into a failing test instead.
        #expect(BrandedExport.canDraw(AppInfo.appName.uppercased()),
                "\(AppInfo.appName) contains a letter the segment cell cannot draw")
    }

    @Test("the frame index pads to the width of its total")
    func indexIsPadded() {
        let index = BrandedExport.Caption.Index(frame: 7, of: 27)
        #expect(BrandedExport.indexText(index) == "07/27")
        #expect(BrandedExport.canDraw(BrandedExport.indexText(index)))
    }

    @Test("the frame index ships off")
    func indexIsOffByDefault() {
        // Two lines in a corner start to read as a caption. Built, deliberately not wired.
        #expect(BrandedExport.Caption(date: .now).index == nil)
    }

    // MARK: - Segment wiring
    //
    // A mis-mapped segment ships as a plausible-looking wrong digit, and at 54px on a photograph
    // it is not something anyone will catch by looking. These render one cell at a time and
    // measure the ink where a given segment lives.

    /// Mean alpha in a sub-rect expressed as fractions of the CELL box, accounting for the
    /// one-cell padding `segmentImage` leaves around the block for the bloom.
    private func ink(_ text: String, cellRect: CGRect, cell: CGFloat = 100) -> CGFloat {
        let size = CGSize(width: cell * BrandedExport.cellAspect, height: cell)
        guard let image = BrandedExport.segmentImage(text, cell: size,
                                                     colour: .white, ghost: 0.17),
              let cg = image.cgImage else { return 0 }
        let pad = cell
        let region = CGRect(x: pad + cellRect.minX * size.width,
                            y: pad + cellRect.minY * size.height,
                            width: cellRect.width * size.width,
                            height: cellRect.height * size.height)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !region.isNull, let patch = cg.cropping(to: region) else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                  bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        ctx.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return CGFloat(pixel[3]) / 255
    }

    /// The middle bar band, where g1 and g2 live.
    private var middleBand: CGRect { CGRect(x: 0.19, y: 0.455, width: 0.62, height: 0.09) }

    @Test("the middle bar separates an 8 from a 0")
    func middleBarWiring() {
        // 0 lights the outline only; 8 adds g1 and g2. This is the exact difference that is
        // unreadable at export size, and the one most likely to be silently wrong.
        let eight = ink("8", cellRect: middleBand)
        let zero = ink("0", cellRect: middleBand)
        #expect(eight > zero * 2, "an 8's middle bar is not brighter than a 0's ghost")
        // A 0 still shows the resting lattice there, faintly. That is the point of the ghost.
        #expect(zero > 0.01, "the 0 lost its resting middle bar entirely")
    }

    @Test("a 1 lights only the right verticals")
    func oneIsWiredRight() {
        let leftVerticals = CGRect(x: 0, y: 0.13, width: 0.15, height: 0.74)
        let rightVerticals = CGRect(x: 0.85, y: 0.13, width: 0.15, height: 0.74)
        #expect(ink("1", cellRect: rightVerticals) > ink("1", cellRect: leftVerticals) * 2)
    }

    @Test("M lights the diagonals and L does not")
    func diagonalsAreWired() {
        // Fourteen segments exist for exactly one reason: seven cannot draw an M. If the
        // diagonals were dropped or mis-rotated, the wordmark is the thing that breaks.
        let diagonalBand = CGRect(x: 0.24, y: 0.10, width: 0.52, height: 0.39)
        #expect(ink("M", cellRect: diagonalBand) > ink("L", cellRect: diagonalBand) * 2)
    }

    @Test("letters do not rest, or the wordmark reads as 8888")
    func lettersDoNotGhost() {
        // Four ghosted 8s behind FLIM would read as a number, not a word.
        let outline = CGRect(x: 0.85, y: 0.13, width: 0.15, height: 0.285)   // b, unlit in L
        #expect(ink("L", cellRect: outline) < 0.01)
        // A digit in the same position DOES rest.
        #expect(ink("7", cellRect: CGRect(x: 0, y: 0.13, width: 0.15, height: 0.285)) > 0.01)
    }

    @Test("the apostrophe and the separator never rest")
    func narrowCellsDoNotGhost() {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        #expect(ink(" ", cellRect: whole) < 0.005)
        // The apostrophe draws its one segment and nothing else.
        #expect(ink("'", cellRect: CGRect(x: 0, y: 0.6, width: 1, height: 0.4)) < 0.01)
    }

    // MARK: - The pale-corner guard

    @Test("luminance sampling tells dark corners from pale ones")
    func luminanceSampling() {
        let canvas = CGSize(width: 100, height: 100)
        let patch = CGRect(x: 10, y: 10, width: 20, height: 20)

        let dark = BrandedExport.meanLuminance(of: solidImage(canvas, colour: .black),
                                               in: patch, canvas: canvas)
        let pale = BrandedExport.meanLuminance(of: solidImage(canvas, colour: .white),
                                               in: patch, canvas: canvas)
        #expect(dark < BrandedExport.paleCornerThreshold)
        #expect(pale > BrandedExport.paleCornerThreshold)
    }

    @Test("the guard leaves the vignetted case alone")
    func guardDoesNotFireOnFlimFrames() {
        // The measured spread across the reference library is 0.16 to 0.39 at the exact patches
        // the marks occupy, because FLIM's frames are vignetted by construction. The threshold
        // sits well above that, which is why the ink can be tuned for the dark case.
        #expect(BrandedExport.paleCornerThreshold > 0.39)
        // And the lifted ghost only matters when it does fire.
        #expect(BrandedExport.flatGhostOpacity > BrandedExport.ghostOpacity)
    }

    // MARK: - The story, unchanged by going borderless

    @Test("the story canvas is exactly 9:16")
    func storyIsNineSixteen() {
        #expect(BrandedExport.storyCanvas == CGSize(width: 1080, height: 1920))
        #expect(abs(BrandedExport.storyCanvas.width / BrandedExport.storyCanvas.height
                    - 9.0 / 16.0) < 0.000001)
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
        // The bottom of a story belongs to the reply field, the swipe-up and the stickers.
        #expect(below > above)
    }

    @Test("the story keeps the print's proportion instead of stretching it")
    func storyDoesNotStretchThePrint() {
        let print = BrandedExport.print(solidImage(CGSize(width: 1536, height: 2048)))
        let story = BrandedExport.story(print: print)
        #expect(story.size == BrandedExport.storyCanvas)
        #expect(abs(print.size.width / print.size.height - 3.0 / 4.0) < 0.001)
    }
}

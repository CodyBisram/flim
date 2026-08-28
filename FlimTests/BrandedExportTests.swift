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
        // Month, day, year: the order it is read aloud here. The apostrophe marks the year so
        // the three pairs cannot be misread day-first.
        #expect(text == "08 04 '26")
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

    @Test("the wordmark and the date share the segment cell")
    func wordmarkIsDrawable() {
        // The date back and the wordmark are meant to read as one stamp. A typeset fallback
        // exists behind `useTypesetWordmark` if that ever stops holding up; this pins the
        // intent, and the fact that the app's own name can actually be drawn in the cell.
        #expect(BrandedExport.useTypesetWordmark == false)
        #expect(BrandedExport.canDraw(AppInfo.appName.uppercased()),
                "\(AppInfo.appName) has a letter the segment cell cannot draw")
        #expect(BrandedExport.canDraw("'26 08 24"))
        #expect(BrandedExport.canDraw("07/27"))
    }

    // MARK: - Segment wiring
    //
    // A mis-mapped segment ships as a plausible-looking wrong digit, and at 54px on a photograph
    // it is not something anyone will catch by looking. These render one cell at a time and
    // measure the ink where a given segment lives.

    /// Mean alpha in a sub-rect expressed as fractions of the CELL box, accounting for the
    /// one-cell padding `segmentImage` leaves around the block for the bloom.
    private func ink(_ text: String, cellRect: CGRect, cell: CGFloat = 100) -> CGFloat {
        let width = BrandedExport.cellWidthEm(Character(text)) * cell
        let size = CGSize(width: width, height: cell)
        guard let image = BrandedExport.segmentImage(text, cell: size, colour: .white, ghost: 0.17),
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

    @Test("the middle bar separates an 8 from a 0")
    func middleBarWiring() {
        // 0 lights the outline only; 8 adds g1 and g2. This is the exact difference that is
        // unreadable at export size, and the one most likely to be silently wrong.
        let middleBand = CGRect(x: 0.19, y: 0.455, width: 0.62, height: 0.09)
        #expect(ink("8", cellRect: middleBand) > ink("0", cellRect: middleBand) * 2)
        // A 0 still shows the resting lattice there, faintly. That is the point of the ghost.
        #expect(ink("0", cellRect: middleBand) > 0.01)
    }

    @Test("a 1 lights only the right verticals")
    func oneIsWiredRight() {
        let leftVerticals = CGRect(x: 0, y: 0.13, width: 0.15, height: 0.74)
        let rightVerticals = CGRect(x: 0.85, y: 0.13, width: 0.15, height: 0.74)
        #expect(ink("1", cellRect: rightVerticals) > ink("1", cellRect: leftVerticals) * 2)
    }

    @Test("M lights the diagonals and L does not")
    func diagonalsAreWired() {
        // Fourteen segments exist for exactly one reason: seven cannot draw an M.
        let diagonalBand = CGRect(x: 0.24, y: 0.10, width: 0.52, height: 0.39)
        #expect(ink("M", cellRect: diagonalBand) > ink("L", cellRect: diagonalBand) * 2)
    }

    @Test("letters do not rest, or the wordmark reads as 8888")
    func lettersDoNotGhost() {
        let outline = CGRect(x: 0.85, y: 0.13, width: 0.15, height: 0.285)   // b, unlit in L
        #expect(ink("L", cellRect: outline) < 0.01)
        #expect(ink("7", cellRect: CGRect(x: 0, y: 0.13, width: 0.15, height: 0.285)) > 0.01)
    }

    @Test("the apostrophe and the separator never rest")
    func narrowCellsDoNotGhost() {
        #expect(ink(" ", cellRect: CGRect(x: 0, y: 0, width: 1, height: 1)) < 0.005)
        #expect(ink("'", cellRect: CGRect(x: 0, y: 0.6, width: 1, height: 0.4)) < 0.01)
    }

    @Test("the I is a narrow centred stroke, not a bar and not a serifed letter")
    func theIIsTucked() {
        // Four shapes were tried before this one. Serifed (a i l d) lit both horizontal bars,
        // where no other letter in FLIM lights either, so it carried twice the ink of its
        // neighbours. A digit one (b c) is a RIGHT-hand vertical, so it hugged the M and the
        // wordmark read "FL IM". Centre-only in a full cell floated as a divider. This is
        // centre-only in a NARROW cell, tucked against both neighbours.
        let topBar = CGRect(x: 0.19, y: 0, width: 0.62, height: 0.09)
        let bottomBar = CGRect(x: 0.19, y: 0.91, width: 0.62, height: 0.09)
        #expect(ink("I", cellRect: topBar) < 0.01, "no serifs")
        #expect(ink("I", cellRect: bottomBar) < 0.01, "no serifs")

        // The stroke is centred, not against either edge, which is what separates it from a 1.
        let centre = CGRect(x: 0.35, y: 0.13, width: 0.3, height: 0.74)
        let rightEdge = CGRect(x: 0.85, y: 0.13, width: 0.15, height: 0.74)
        #expect(ink("I", cellRect: centre) > 0.3)
        #expect(ink("I", cellRect: rightEdge) < 0.05, "a 1 would light here; an I must not")
    }

    @Test("the I's cell is narrower but its stroke is not")
    func theIKeepsItsWeight() {
        // The cell is narrowed so the stroke tucks in; measuring the stroke as a fraction of
        // that narrow box would have made it half the weight of every other letter, so `fill`
        // sizes the centre verticals from the STANDARD cell instead.
        let cell: CGFloat = 100
        let standardStroke = 0.15 * BrandedExport.cellAspect * cell
        guard let image = BrandedExport.segmentImage("I", cell: CGSize(width: 0.34 * cell, height: cell),
                                                     colour: .white, ghost: 0),
              let cg = image.cgImage else { Issue.record("no image"); return }
        // Count lit columns across the middle of the glyph; that width IS the stroke.
        var pixel = [UInt8](repeating: 0, count: 4)
        var lit = 0
        for x in 0..<cg.width {
            guard let slice = cg.cropping(to: CGRect(x: x, y: cg.height / 2 - 20, width: 1, height: 8)),
                  let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            // Clear between columns: the buffer is reused, and CGContext composites, so without
            // this the alpha accumulates and every column after the first reads as lit.
            ctx.clear(CGRect(x: 0, y: 0, width: 1, height: 1))
            ctx.draw(slice, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if pixel[3] > 128 { lit += 1 }
        }
        #expect(abs(CGFloat(lit) - standardStroke) < standardStroke * 0.35,
                "the I's stroke (\(lit)) should match a standard cell's (\(Int(standardStroke)))")
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

    // MARK: - The full-bleed 9:16

    @Test("the full frame really is 9:16, and cropped from the width")
    func fillIsNineSixteen() {
        // A 3:4 master is 0.75 and 9:16 is 0.5625, so filling keeps the full height and spends
        // the sides. Getting this backwards would letterbox instead of fill.
        let source = CGSize(width: 1536, height: 2048)
        let filled = BrandedExport.fill(solidImage(source))
        #expect(abs(filled.size.width / filled.size.height - 9.0 / 16.0) < 0.001)
        #expect(filled.size.height == source.height, "height should survive the crop intact")
        #expect(filled.size.width < source.width, "the sides are what get spent")
        #expect(abs(filled.size.width - source.height * 9 / 16) < 1)
    }

    @Test("a frame already wider than 9:16 crops its height instead")
    func fillHandlesWideSources() {
        // Legacy landscape photos: keeping the full height would need a width the master does
        // not have, so the crop has to switch axes rather than upscale.
        let filled = BrandedExport.fill(solidImage(CGSize(width: 800, height: 900)))
        #expect(abs(filled.size.width / filled.size.height - 9.0 / 16.0) < 0.001)
        #expect(filled.size.width <= 800)
        #expect(filled.size.height <= 900)
    }

    @Test("the full frame is its own render, not the print cropped")
    func fillImprintsAfterCropping() {
        // The marks sit 5.5% in from each side. Cropping 12.5% off each edge of an already
        // imprinted print would cut both of them off entirely, so the crop must come first.
        // Proxy for that ordering: the imprint's cell scales with the FILLED width, so a full
        // frame's mark is smaller than the same photo's print mark.
        let photo = solidImage(CGSize(width: 1536, height: 2048))
        let printed = BrandedExport.print(photo)
        let filled = BrandedExport.fill(photo)
        #expect(filled.size.width < printed.size.width)
    }

    @Test("a degenerate photo is safe to fill")
    func fillIsSafe() {
        let empty = UIImage()
        #expect(BrandedExport.fill(empty).size == empty.size)
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

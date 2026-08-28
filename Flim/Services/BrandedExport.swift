import UIKit

/// The shareable artifacts: a borderless print carrying a date-back imprint, and that same print
/// placed on a 9:16 story ground.
///
/// **One print, two grounds.** The print renders once and the story places it rather than
/// re-laying it out, which is why `story(print:)` takes the rendered print and not the raw photo.
///
/// **The imprint is the only thing drawn.** There used to be paper here: a warm off-white border
/// with the wordmark in the margin, and before that a footer band whose height had to be solved
/// so the outer landed on 3:4. All of it is gone. The exported file is the master, untouched, and
/// the mark is burned into the exposure the way a disposable camera's date back burned it into
/// the negative. That trades away the app's own "never overlay the photographs" rule, deliberately
/// and permanently: the frame is no longer only the exposure, and a burned-in mark cannot be
/// removed later. What it buys is a file that is all photograph, and a mark that is about the gap
/// between shooting and seeing, which is the product.
enum BrandedExport {

    /// What the imprint says about a photograph.
    ///
    /// Just the date now. The roll name used to print in the paper's footer and has nowhere to go
    /// on a borderless frame; it belongs to the roll contact sheet, which is the next artifact.
    struct Caption: Equatable {
        let date: Date
        /// Frame index, drawn as `07/27` on a second line above the date.
        ///
        /// Built because the `/` glyph is cheap once the segment cell exists, and shipped OFF:
        /// two lines in a corner start to read as a caption rather than as a stamp. Deliberately
        /// not wired to a setting.
        let index: Index?

        struct Index: Equatable {
            let frame: Int
            let of: Int
        }

        init(date: Date, index: Index? = nil) {
            self.date = date
            self.index = index
        }
    }

    // MARK: - Imprint geometry
    //
    // Every value is a fraction of the OUTER WIDTH, so the mark scales with any master.

    /// The em box of one segment cell.
    static let cellHeightFraction: CGFloat = 0.036
    /// A cell is this much wider than it is tall.
    static let cellAspect: CGFloat = 0.58
    /// Between cells, as a fraction of cell height.
    static let cellGapFraction: CGFloat = 0.085
    /// The date's left edge and the wordmark's right edge.
    static let sideInsetFraction: CGFloat = 0.055
    /// Both blocks' bottom edge, one shared baseline. Of WIDTH, not height.
    static let bottomInsetFraction: CGFloat = 0.050

    /// Unlit segments of a digit, so the lattice is a constant shape and the numerals drop into
    /// it: the clock in a dark room sitting at `88 88 88`.
    static let ghostOpacity: CGFloat = 0.17
    /// The pale-corner guard lifts the ghost, because a flat ink with no bloom loses it entirely.
    static let flatGhostOpacity: CGFloat = 0.32
    /// Mean luminance above which a mark switches to the flat ink.
    static let paleCornerThreshold: CGFloat = 0.50

    static let ink = UIColor(red: 1.0, green: 0.541, blue: 0.169, alpha: 1)        // #FF8A2B
    static let flatInk = UIColor(red: 0.878, green: 0.325, blue: 0.039, alpha: 1)  // #E0530A

    // MARK: - The print

    /// The master with the imprint burned in. No paper, no border, no resampling: the outer
    /// canvas IS the photo, so the 3:4 rule is satisfied by doing nothing.
    ///
    /// `caption` nil draws the wordmark alone, in its normal place, with nothing moved to
    /// compensate. That is a strict superset of the old behaviour, so this ships before the
    /// metadata plumbing does.
    static func print(_ photo: UIImage, caption: Caption? = nil) -> UIImage {
        let size = photo.size
        guard size.width > 0, size.height > 0 else { return photo }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = photo.scale
        format.opaque = true

        let cell = CGSize(width: size.width * cellHeightFraction * cellAspect,
                          height: size.width * cellHeightFraction)
        let sideInset = size.width * sideInsetFraction
        let bottomInset = size.width * bottomInsetFraction

        let dateText = caption.map(dateText) ?? ""
        let markText = AppInfo.appName.uppercased()

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            photo.draw(in: CGRect(origin: .zero, size: size))

            let baseline = size.height - bottomInset

            if !markText.isEmpty {
                let width = blockWidth(markText, cell: cell)
                draw(text: markText,
                     at: CGPoint(x: size.width - sideInset - width, y: baseline - cell.height),
                     cell: cell, in: ctx.cgContext, over: photo, canvas: size)
            }

            if !dateText.isEmpty {
                draw(text: dateText,
                     at: CGPoint(x: sideInset, y: baseline - cell.height),
                     cell: cell, in: ctx.cgContext, over: photo, canvas: size)

                // The index sits a line above the date, when it is asked for at all.
                if let index = caption?.index {
                    let text = indexText(index)
                    draw(text: text,
                         at: CGPoint(x: sideInset,
                                     y: baseline - cell.height * 2 - cell.height * 0.3),
                         cell: cell, in: ctx.cgContext, over: photo, canvas: size)
                }
            }
        }
    }

    /// `'26 08 24`. Zero-padded throughout and load-bearing: the lattice must not change width
    /// between frames, or the mark jitters across a roll.
    static func dateText(_ caption: Caption) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")   // Arabic numerals, always
        formatter.dateFormat = "yy MM dd"
        return "'" + formatter.string(from: caption.date)
    }

    /// `07/27`, zero-padded to the width of the total for the same reason the date is.
    static func indexText(_ index: Caption.Index) -> String {
        let width = String(max(0, index.of)).count
        let frame = String(format: "%0\(width)d", max(0, index.frame))
        return "\(frame)/\(index.of)"
    }

    // MARK: - Segment cell

    private enum Segment: CaseIterable {
        case a, b, c, d, e, f, g1, g2, h, i, j, k, l, m
    }

    /// Only these characters are ever drawn. Anything else renders as blank space, which is why
    /// `AppInfo.appName` is covered by a test rather than by hope.
    private static let glyphs: [Character: Set<Segment>] = [
        "0": [.a, .b, .c, .d, .e, .f],
        "1": [.b, .c],
        "2": [.a, .b, .g1, .g2, .e, .d],
        "3": [.a, .b, .c, .d, .g1, .g2],
        "4": [.f, .g1, .g2, .b, .c],
        "5": [.a, .f, .g1, .g2, .c, .d],
        "6": [.a, .f, .g1, .g2, .e, .c, .d],
        "7": [.a, .b, .c],
        "8": [.a, .b, .c, .d, .e, .f, .g1, .g2],
        "9": [.a, .b, .c, .d, .f, .g1, .g2],
        "F": [.a, .f, .e, .g1, .g2],
        "L": [.f, .e, .d],
        "I": [.a, .i, .l, .d],
        "M": [.f, .e, .h, .j, .b, .c],
        "/": [.j, .m],
        "'": [.i],
        " ": []
    ]

    /// Whether every character in `text` has a segment set.
    ///
    /// The cell draws nothing at all for a character it does not know, so a renamed app would
    /// export a blank corner rather than fail. This is what a test holds on to.
    static func canDraw(_ text: String) -> Bool {
        text.allSatisfy { glyphs[$0] != nil }
    }

    /// What a digit rests at. Fourteen segments would rest as a shape no clock ever showed, and
    /// the diagonals and centre verticals are what make it a letter rather than a numeral.
    private static let restingSegments: Set<Segment> = [.a, .b, .c, .d, .e, .f, .g1, .g2]

    /// Cell widths in em. The apostrophe and the separator are narrower than a digit.
    private static func cellWidthEm(_ character: Character) -> CGFloat {
        switch character {
        case "'": 0.22
        case " ": 0.26
        default: cellAspect
        }
    }

    private static func blockWidth(_ text: String, cell: CGSize) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let em = cell.height
        let cells = text.reduce(0) { $0 + cellWidthEm($1) * em }
        let gaps = CGFloat(text.count - 1) * cellGapFraction * em
        return cells + gaps
    }

    // MARK: - Drawing

    /// Draws one block of segment cells, deciding its ink from what it is sitting on.
    private static func draw(text: String, at origin: CGPoint, cell: CGSize,
                             in context: CGContext, over photo: UIImage, canvas: CGSize) {
        let width = blockWidth(text, cell: cell)
        let bounds = CGRect(origin: origin, size: CGSize(width: width, height: cell.height))

        // The pale-corner guard. Built expecting never to fire: FLIM's frames are vignetted by
        // construction, which is exactly why the corners are the right place for the mark. If the
        // vignette ever weakens, this is what stops the mark disappearing, so it is not dead code.
        let pale = meanLuminance(of: photo, in: bounds, canvas: canvas) > paleCornerThreshold
        let colour = pale ? flatInk : ink
        let ghost = pale ? flatGhostOpacity : ghostOpacity

        // Rendered once and composited once. Drawing the segments straight into the page with a
        // shadow would lay the ink down twice and turn the ghost lattice to mud.
        guard let marks = segmentImage(text, cell: cell, colour: colour, ghost: ghost) else { return }
        let bloomed = pale ? marks : bloom(marks, cell: cell)
        (bloomed ?? marks).draw(in: bounds.insetBy(dx: -cell.height, dy: -cell.height))
    }

    /// The segment set on transparency, with a one-cell margin so the bloom has room.
    ///
    /// Internal rather than private so the wiring can be tested: which segments a character lights
    /// is the kind of thing that is impossible to check by looking at a 54px mark on a photograph,
    /// and a mis-mapped segment would ship as a plausible-looking wrong digit.
    static func segmentImage(_ text: String, cell: CGSize,
                             colour: UIColor, ghost: CGFloat) -> UIImage? {
        let pad = cell.height
        let size = CGSize(width: blockWidth(text, cell: cell) + pad * 2, height: cell.height + pad * 2)
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            var x = pad
            for character in text {
                let em = cell.height
                let box = CGRect(x: x, y: pad, width: cellWidthEm(character) * em, height: em)
                let lit = glyphs[character] ?? []
                // Letters never rest: four ghosted 8s behind FLIM reads as 8888, not as a word.
                let rests = character.isNumber
                for segment in Segment.allCases {
                    let on = lit.contains(segment)
                    let resting = rests && restingSegments.contains(segment)
                    guard on || resting else { continue }
                    colour.withAlphaComponent(on ? 1 : ghost).setFill()
                    fill(segment, in: box, context: ctx.cgContext)
                }
                x += box.width + cellGapFraction * em
            }
        }
    }

    /// Two soft glows, chained: the outer one is cast around the result of the inner one, which is
    /// what the board's two stacked drop-shadows do. Each pixel of ink is still laid down once.
    private static func bloom(_ marks: UIImage, cell: CGSize) -> UIImage? {
        func glow(_ image: UIImage, blur: CGFloat, colour: UIColor) -> UIImage? {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = image.scale
            format.opaque = false
            return UIGraphicsImageRenderer(size: image.size, format: format).image { ctx in
                ctx.cgContext.setShadow(offset: .zero, blur: blur, color: colour.cgColor)
                image.draw(at: .zero)
            }
        }
        let inner = glow(marks, blur: cell.height * 0.05,
                         colour: UIColor(red: 1, green: 0.510, blue: 0.157, alpha: 0.75))
        guard let inner else { return nil }
        return glow(inner, blur: cell.height * 0.17,
                    colour: UIColor(red: 1, green: 0.314, blue: 0.039, alpha: 0.30))
    }

    /// One segment's rect inside its cell box, rotated for the diagonals.
    ///
    /// Percentages are of the cell box: horizontal ones of its width, vertical ones of its
    /// height. Taken from the design's own segment board rather than re-derived, including the
    /// rotation SIGNS, which are the opposite of what the shapes suggest.
    private static func fill(_ segment: Segment, in box: CGRect, context: CGContext) {
        let w = box.width, h = box.height
        var rect: CGRect
        var rotation: CGFloat = 0

        switch segment {
        case .a:  rect = CGRect(x: 0.19 * w, y: 0, width: 0.62 * w, height: 0.09 * h)
        case .d:  rect = CGRect(x: 0.19 * w, y: h - 0.09 * h, width: 0.62 * w, height: 0.09 * h)
        case .f:  rect = CGRect(x: 0, y: 0.13 * h, width: 0.15 * w, height: 0.285 * h)
        case .b:  rect = CGRect(x: w - 0.15 * w, y: 0.13 * h, width: 0.15 * w, height: 0.285 * h)
        case .e:  rect = CGRect(x: 0, y: h - 0.13 * h - 0.285 * h, width: 0.15 * w, height: 0.285 * h)
        case .c:  rect = CGRect(x: w - 0.15 * w, y: h - 0.13 * h - 0.285 * h,
                                width: 0.15 * w, height: 0.285 * h)
        case .g1: rect = CGRect(x: 0.19 * w, y: 0.455 * h, width: 0.195 * w, height: 0.09 * h)
        case .g2: rect = CGRect(x: 0.615 * w, y: 0.455 * h, width: 0.195 * w, height: 0.09 * h)
        case .i:  rect = CGRect(x: 0.425 * w, y: 0.13 * h, width: 0.15 * w, height: 0.285 * h)
        case .l:  rect = CGRect(x: 0.425 * w, y: h - 0.13 * h - 0.285 * h,
                                width: 0.15 * w, height: 0.285 * h)
        case .h:
            rect = CGRect(x: 0.24 * w, y: 0.1045 * h, width: 0.15 * w, height: 0.381 * h)
            rotation = -.pi / 6
        case .j:
            rect = CGRect(x: w - 0.24 * w - 0.15 * w, y: 0.1045 * h,
                          width: 0.15 * w, height: 0.381 * h)
            rotation = .pi / 6
        case .k:
            rect = CGRect(x: w - 0.24 * w - 0.15 * w, y: h - 0.1045 * h - 0.381 * h,
                          width: 0.15 * w, height: 0.381 * h)
            rotation = -.pi / 6
        case .m:
            rect = CGRect(x: 0.24 * w, y: h - 0.1045 * h - 0.381 * h,
                          width: 0.15 * w, height: 0.381 * h)
            rotation = .pi / 6
        }

        rect = rect.offsetBy(dx: box.minX, dy: box.minY)
        guard rotation != 0 else {
            context.fill(rect)
            return
        }
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.rotate(by: rotation)
        context.fill(CGRect(x: -rect.width / 2, y: -rect.height / 2,
                            width: rect.width, height: rect.height))
        context.restoreGState()
    }

    // MARK: - Pale-corner sampling

    /// Mean luminance of the patch a mark will occupy, by averaging it down to one pixel.
    ///
    /// Reads the backing `cgImage` directly, whose pixels ignore `imageOrientation` even though
    /// `UIImage.draw` honours it. Every master reaching here is built `UIImage(cgImage:)` with no
    /// orientation (see `InstantFilmProcessor` and `CapturedPhotoCropper`), so the two agree, but
    /// that is an invariant this function depends on rather than one anything enforces. A rotated
    /// image would have us sampling the wrong corner, so it reports 0 instead: dark is the
    /// bloomed ink, which is the right answer for every frame the app actually produces.
    static func meanLuminance(of photo: UIImage, in rect: CGRect, canvas: CGSize) -> CGFloat {
        guard photo.imageOrientation == .up else { return 0 }
        guard let cg = photo.cgImage, canvas.width > 0, canvas.height > 0 else { return 0 }
        let sx = CGFloat(cg.width) / canvas.width
        let sy = CGFloat(cg.height) / canvas.height
        let source = CGRect(x: rect.minX * sx, y: rect.minY * sy,
                            width: rect.width * sx, height: rect.height * sy)
            .integral
            .intersection(CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard !source.isNull, source.width >= 1, source.height >= 1,
              let patch = cg.cropping(to: source) else { return 0 }

        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }
        context.interpolationQuality = .medium
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        let r = CGFloat(pixel[0]) / 255, g = CGFloat(pixel[1]) / 255, b = CGFloat(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    // MARK: - The full-bleed 9:16

    /// The photograph itself at 9:16, filling the frame, imprinted.
    ///
    /// The sibling of `story(print:)` and the opposite bargain. `story` keeps the whole frame and
    /// spends the leftover canvas on ground; this keeps the whole canvas and spends the sides of
    /// the frame. A 3:4 master is 0.75 wide-to-tall and 9:16 is 0.5625, so filling costs 25% of
    /// the width, centre-cropped.
    ///
    /// **This is the one place the export crops**, which every other path here refuses to do. It
    /// earns the exception by being what a story actually is: a full-bleed canvas someone puts
    /// stickers on. The choice stays the reader's, next to a placed version that crops nothing.
    ///
    /// Imprinted AFTER the crop, never before: the marks sit 5.5% in from the sides, and cropping
    /// 12.5% off each edge of an already-imprinted print would cut both of them clean off.
    static func fill(_ photo: UIImage, caption: Caption? = nil) -> UIImage {
        let source = photo.size
        guard source.width > 0, source.height > 0 else { return photo }

        let targetAspect = storyCanvas.width / storyCanvas.height
        // Fit the widest 9:16 rect that the master contains, then centre it.
        var cropSize = CGSize(width: source.height * targetAspect, height: source.height)
        if cropSize.width > source.width {
            cropSize = CGSize(width: source.width, height: source.width / targetAspect)
        }
        let crop = CGRect(x: (source.width - cropSize.width) / 2,
                          y: (source.height - cropSize.height) / 2,
                          width: cropSize.width, height: cropSize.height)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = photo.scale
        format.opaque = true

        let cropped = UIGraphicsImageRenderer(size: cropSize, format: format).image { _ in
            photo.draw(in: CGRect(x: -crop.minX, y: -crop.minY,
                                  width: source.width, height: source.height))
        }
        return print(cropped, caption: caption)
    }

    // MARK: - The story (9:16)

    /// Canvas, in pixels. Fixed, because a story is a designed canvas rather than a photograph.
    static let storyCanvas = CGSize(width: 1080, height: 1920)
    /// The print's width as a fraction of the canvas: 78%, which is 842px.
    static let storyPrintWidthFraction: CGFloat = 0.78
    /// Air above the print, as a fraction of canvas height: 297 of 1920.
    static let storyTopFraction: CGFloat = 297.0 / 1920.0

    /// Places an already-rendered print on the story ground.
    ///
    /// Optically high, not centred: the bottom of a story is where the reply field, the swipe-up
    /// and everyone's stickers go, so the print sits above all of it.
    ///
    /// The drop shadow matters more than it used to. With no paper, the imprint sits about 46px
    /// from the print's edge with nothing between it and the dark ground, and the shadow is what
    /// separates the ink from the backdrop.
    static func story(print: UIImage) -> UIImage {
        let canvas = storyCanvas
        guard print.size.width > 0, print.size.height > 0 else { return print }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // the canvas is specified in pixels, not points
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            let cg = ctx.cgContext
            drawStoryGround(in: canvas, context: cg)
            drawGrain(in: canvas, context: cg)

            let printWidth = canvas.width * storyPrintWidthFraction
            let printHeight = printWidth * print.size.height / print.size.width
            let rect = CGRect(x: (canvas.width - printWidth) / 2,
                              y: canvas.height * storyTopFraction,
                              width: printWidth, height: printHeight)

            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: canvas.width * 0.041),
                         blur: canvas.width * 0.099,
                         color: UIColor.black.withAlphaComponent(0.6).cgColor)
            print.draw(in: rect)
            cg.restoreGState()
        }
    }

    /// A dark surface with one warm lift behind where the print sits.
    ///
    /// Deliberately NOT a blurred copy of the photograph: that reads as every other app, and it
    /// competes with the print instead of holding it.
    private static func drawStoryGround(in canvas: CGSize, context: CGContext) {
        let stops: [(CGColor, CGFloat)] = [
            (UIColor(red: 0.118, green: 0.125, blue: 0.196, alpha: 1).cgColor, 0),     // #1E2032
            (UIColor(red: 0.071, green: 0.075, blue: 0.122, alpha: 1).cgColor, 0.62),  // #12131F
            (UIColor(red: 0.059, green: 0.063, blue: 0.102, alpha: 1).cgColor, 1)      // #0F101A
        ]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: stops.map(\.0) as CFArray,
                                        locations: stops.map(\.1)) else { return }
        // An ellipse of 120% width by 70% height centred at (50%, 34%), drawn as a unit-radius
        // radial gradient under a scaled transform.
        context.saveGState()
        context.translateBy(x: canvas.width * 0.5, y: canvas.height * 0.34)
        context.scaleBy(x: canvas.width * 1.2, y: canvas.height * 0.7)
        context.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0,
                                   endCenter: .zero, endRadius: 1,
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        context.restoreGState()
    }

    /// One 120x120 noise tile, generated once and tiled, at 7% over the ground.
    private static func drawGrain(in canvas: CGSize, context: CGContext) {
        guard let tile = grainTile.cgImage else { return }
        context.saveGState()
        context.setBlendMode(.overlay)
        context.setAlpha(0.07)
        context.draw(tile, in: CGRect(origin: .zero, size: CGSize(width: 120, height: 120)),
                     byTiling: true)
        context.restoreGState()
    }

    /// Deterministic, so two exports of the same photograph are byte-identical, and built once
    /// rather than per export.
    private static let grainTile: UIImage = {
        let side = 120
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func nextUnit() -> CGFloat {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return CGFloat(seed % 1000) / 1000
        }
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
            .image { ctx in
                for y in 0..<side {
                    for x in 0..<side {
                        let v = 0.35 + nextUnit() * 0.3
                        ctx.cgContext.setFillColor(UIColor(white: v, alpha: 1).cgColor)
                        ctx.cgContext.fill(CGRect(x: x, y: y, width: 1, height: 1))
                    }
                }
            }
    }()
}

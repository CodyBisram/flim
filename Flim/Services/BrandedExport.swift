import UIKit

/// The shareable artifacts: an instant print at a fixed 3:4, and that same print placed on a
/// 9:16 story ground.
///
/// **One print, two grounds.** The print is rendered once, at one fixed proportion, and the story
/// does not re-lay-it-out — it places the already-rendered print on a different canvas. That is
/// why `story(print:)` takes the rendered print rather than the raw photo: it makes the rule
/// structural instead of a thing to remember, and it keeps the two paths from drifting apart.
///
/// The print used to be whatever shape the photo happened to be plus padding (about 0.72 for a
/// 3:4 capture), and its bottom margin was a large blank band carrying a centered wordmark. Both
/// changed: the outer is now exactly 3:4 so a feed's grid crop has nothing to eat, and the band
/// is a caption line rather than an advertisement.
enum BrandedExport {

    /// What the footer says about a photograph, when the caller knows.
    ///
    /// Optional throughout: `SharePreviewSheet` takes a bare `UIImage` at every call site today,
    /// so the no-caption path is the live one and the geometry ships without waiting on the
    /// metadata plumbing. `rollName` is separately optional because a personal shot has a date
    /// but no roll.
    struct Caption: Equatable {
        let date: Date
        let rollName: String?

        init(date: Date, rollName: String? = nil) {
            self.date = date
            self.rollName = rollName
        }
    }

    // MARK: - Geometry

    /// Border on the top and both sides, as a fraction of the print's OUTER width.
    static let borderFraction: CGFloat = 0.0446

    /// The footer band, as a fraction of the outer width.
    ///
    /// **Solved, not chosen.** Given an uncropped 3:4 photo, requiring the outer to be exactly 3:4
    /// leaves exactly one value:
    ///
    ///     b + (4/3)(1 - 2b) + f = 4/3   =>   f = (5/3)b
    ///
    /// which is 7.43%, and `printSize` asserts the result. The handoff's table rounds this to
    /// "7.5% = 126px"; taking that literally puts the outer 1px off 3:4 at export size, and the
    /// ratio is the whole point of the redesign, so the derived value wins over the printed one.
    static let footerFraction: CGFloat = borderFraction * 5 / 3

    /// Paper and ink, unchanged from the original frame.
    private static let paper = UIColor(red: 0.955, green: 0.945, blue: 0.915, alpha: 1)
    private static let ink = UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1)

    /// The outer size of the print for a photo of `photoSize`.
    ///
    /// The image window is 3:4 and as wide as the photo, so a capture (already 3:4, see
    /// `CapturedPhotoCropper`) fills it exactly and is never cropped. Pure, so the 3:4 invariant
    /// is testable without rendering anything.
    static func printSize(for photoSize: CGSize) -> CGSize {
        guard photoSize.width > 0, photoSize.height > 0 else { return .zero }
        let windowWidth = photoSize.width
        let outerWidth = windowWidth / (1 - 2 * borderFraction)
        return CGSize(width: outerWidth, height: outerWidth * 4 / 3)
    }

    // MARK: - The print (3:4)

    /// The instant print: paper to all four edges, the photograph at full width, a caption line
    /// in the footer. `caption` nil draws the centered wordmark alone, which is exactly what the
    /// frame did before and is what every call site gets until the metadata is plumbed through.
    static func print(_ photo: UIImage, caption: Caption? = nil) -> UIImage {
        let pw = photo.size.width
        let ph = photo.size.height
        guard pw > 0, ph > 0 else { return photo }

        let outer = printSize(for: photo.size)
        let border = outer.width * borderFraction
        let footer = outer.width * footerFraction
        let windowWidth = outer.width - border * 2
        let windowHeight = windowWidth * 4 / 3

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = photo.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: outer, format: format).image { ctx in
            paper.setFill()
            UIRectFill(CGRect(origin: .zero, size: outer))

            // Aspect-FIT inside the window, never fill. A capture is already 3:4 and lands on the
            // window exactly; a legacy photo from before the cropper letterboxes on paper rather
            // than losing its edges or dragging the outer off 3:4.
            let fit = min(windowWidth / pw, windowHeight / ph)
            let drawSize = CGSize(width: pw * fit, height: ph * fit)
            let imageRect = CGRect(
                x: border + (windowWidth - drawSize.width) / 2,
                y: border + (windowHeight - drawSize.height) / 2,
                width: drawSize.width,
                height: drawSize.height)
            photo.draw(in: imageRect)

            // The inner shadow along the image's top edge. Real prints have one, and with the
            // margin this thin it is what still reads as paper at thumbnail size.
            drawTopInnerShadow(in: imageRect, context: ctx.cgContext, width: outer.width)

            drawFooter(caption: caption,
                       band: CGRect(x: border, y: border + windowHeight,
                                    width: outer.width - border * 2, height: footer),
                       outerWidth: outer.width,
                       context: ctx.cgContext)
        }
    }

    /// A soft dark band just inside the image's top edge, fading to nothing.
    private static func drawTopInnerShadow(in rect: CGRect, context: CGContext, width: CGFloat) {
        let depth = width * 0.004
        guard depth > 0.5, rect.width > 0 else { return }
        let colors = [ink.withAlphaComponent(0.30).cgColor, ink.withAlphaComponent(0).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                        colors: colors as CFArray, locations: [0, 1]) else { return }
        context.saveGState()
        context.clip(to: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: depth))
        context.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.minX, y: rect.minY + depth),
                                   options: [])
        context.restoreGState()
    }

    // MARK: - Footer

    /// Date and roll flush left, wordmark flush right, sharing a baseline. Without a caption the
    /// wordmark returns to the centre and the band is what it always was.
    ///
    /// The wordmark never shrinks and the line never wraps: an overlong roll name truncates with
    /// a tail ellipsis, because the alternative is a second line that breaks the 3:4 solve.
    private static func drawFooter(caption: Caption?, band: CGRect, outerWidth: CGFloat,
                                   context: CGContext) {
        let markSize = outerWidth * 0.0250
        let markFont = UIFont.systemFont(ofSize: markSize, weight: .light)
        let markAttrs: [NSAttributedString.Key: Any] = [
            .font: markFont,
            .foregroundColor: ink,
            .kern: markSize * 0.4
        ]
        let mark = AppInfo.appName as NSString

        // Centre on cap height rather than the full line box: the two fonts differ in size, and
        // centring their boxes would sit the pair visibly high in the band.
        let baseline = band.midY + markFont.capHeight / 2

        guard let caption, let text = captionText(caption) else {
            let centred = NSMutableParagraphStyle()
            centred.alignment = .center
            var attrs = markAttrs
            attrs[.paragraphStyle] = centred
            mark.draw(in: CGRect(x: 0, y: baseline - markFont.ascender,
                                 width: outerWidth, height: markFont.lineHeight),
                      withAttributes: attrs)
            return
        }

        // The wordmark keeps its full width; the caption gets what is left.
        let markWidth = mark.size(withAttributes: markAttrs).width
        mark.draw(at: CGPoint(x: band.maxX - markWidth, y: baseline - markFont.ascender),
                  withAttributes: markAttrs)

        let capSize = outerWidth * 0.0281
        let capFont = UIFont.systemFont(ofSize: capSize, weight: .regular)
        let truncating = NSMutableParagraphStyle()
        truncating.lineBreakMode = .byTruncatingTail
        let capAttrs: [NSAttributedString.Key: Any] = [
            .font: capFont,
            .foregroundColor: ink,
            .kern: capSize * 0.01,
            .paragraphStyle: truncating
        ]
        let gap = outerWidth * 0.02
        let available = max(0, band.width - markWidth - gap)
        (text as NSString).draw(
            in: CGRect(x: band.minX, y: baseline - capFont.ascender,
                       width: available, height: capFont.lineHeight),
            withAttributes: capAttrs)
    }

    /// `24 Aug · sunday film club`, or just the date when there is no roll. The roll name is drawn
    /// exactly as it was typed, never title-cased.
    static func captionText(_ caption: Caption) -> String? {
        let formatter = DateFormatter()
        // `d MMM` as specified, not a localized template. The template resolves to "Aug 27" in
        // en_US, and this is one artifact shared into everyone's feed rather than a date shown
        // back to its author: the day-first order stays put and only the month name localizes.
        formatter.locale = .current
        formatter.dateFormat = "d MMM"
        let date = formatter.string(from: caption.date)
        guard let roll = caption.rollName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !roll.isEmpty else { return date }
        // Hairspaces around the separator, so it reads as punctuation rather than a bullet.
        return "\(date)\u{200A}·\u{200A}\(roll)"
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
    /// and everyone's stickers go, so the print sits above all of it and the air below is usable
    /// rather than wasted.
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

    /// A dark surface with one warm lift behind where the paper sits.
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

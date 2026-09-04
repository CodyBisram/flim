import UIKit

/// The chapter recap's "Share as a contact sheet": the month's curated deck laid out 3 across by
/// 5 down on the export's own dark ground, with a header strip in the film-edge's own register
/// (chapter number, month name, stats line) and the app's mark at the foot.
///
/// Sibling to `BrandedExport`, not a mode of it: a single print's imprint geometry is expressed
/// as fractions of ONE photograph's own width, and a contact sheet is a page of many photographs
/// on a fixed canvas, which is a different kind of layout problem. `Layout` is the pure half
/// (cell rects for N photos, tested directly with no image ever touching it); `render` is the
/// only piece that draws.
enum ChapterContactSheet {

    // MARK: - Canvas

    /// Fixed pixel width, matching `BrandedExport.storyCanvas`'s own width: the app's other
    /// fixed-canvas export. A second export artifact at a different width would be the one thing
    /// that looks obviously off shared side by side with a story.
    static let width: CGFloat = 1080
    static let columns = 3
    static let rows = 5
    /// The curated deck's own cap (`ChapterCurator`), so a full month always fits exactly.
    static let capacity = columns * rows

    static let outerMargin: CGFloat = 40
    /// Thin, by design brief: a contact sheet's whole point is density, not a picture-frame
    /// margin between shots.
    static let gutter: CGFloat = 6

    // MARK: - Header strip

    static let headerTopPadding: CGFloat = 56
    static let chapterLabelHeight: CGFloat = 30
    static let chapterLabelGap: CGFloat = 14
    static let monthNameHeight: CGFloat = 84
    static let monthNameGap: CGFloat = 10
    static let statsLineHeight: CGFloat = 32
    static let headerBottomGap: CGFloat = 36

    /// Constant regardless of `photoCount`: the header is a fixed strip, only the grid below it
    /// grows or shrinks.
    static let headerHeight: CGFloat =
        headerTopPadding + chapterLabelHeight + chapterLabelGap +
        monthNameHeight + monthNameGap + statsLineHeight + headerBottomGap

    // MARK: - Footer mark

    static let footerTopGap: CGFloat = 28
    static let footerMarkHeight: CGFloat = 24
    static let footerBottomPadding: CGFloat = 36
    /// Also constant, the same reason as `headerHeight`.
    static let footerHeight: CGFloat = footerTopGap + footerMarkHeight + footerBottomPadding

    // MARK: - Cells

    /// One cell's size at `width`, fixed regardless of how many photos actually fill the grid: a
    /// partial last row leaves its remaining cells empty rather than stretching what's there to
    /// fill the width (see `layout(photoCount:width:)`).
    static func cellSize(width: CGFloat = width) -> CGSize {
        let cellWidth = (width - outerMargin * 2 - CGFloat(columns - 1) * gutter) / CGFloat(columns)
        return CGSize(width: cellWidth, height: cellWidth / FlimTheme.frameAspect)
    }

    struct Layout: Equatable {
        /// One rect per photo actually placed, row-major, left to right then down:
        /// `cellRects[0]` is always the top-left cell, matching the deck's own chronological
        /// order, so the first shot of the month is always read first.
        let cellRects: [CGRect]
        let headerHeight: CGFloat
        let gridHeight: CGFloat
        let footerHeight: CGFloat
        let totalSize: CGSize
    }

    /// The grid geometry for `photoCount` photos (capped at `capacity`, matching the recap's own
    /// curated deck size). A partial last row leaves its remaining cells empty rather than
    /// stretching what's there to fill the width: the cell size never depends on `photoCount`.
    ///
    /// Pure: no image ever touches this function, which is what makes it directly testable.
    static func layout(photoCount: Int, width: CGFloat = width) -> Layout {
        let count = max(0, min(photoCount, capacity))
        let cell = cellSize(width: width)
        let rowsUsed = count == 0 ? 0 : Int(ceil(Double(count) / Double(columns)))

        var rects: [CGRect] = []
        rects.reserveCapacity(count)
        for i in 0..<count {
            let row = i / columns
            let col = i % columns
            let x = outerMargin + CGFloat(col) * (cell.width + gutter)
            let y = headerHeight + CGFloat(row) * (cell.height + gutter)
            rects.append(CGRect(x: x, y: y, width: cell.width, height: cell.height))
        }

        let gridHeight = rowsUsed == 0 ? 0 : CGFloat(rowsUsed) * cell.height + CGFloat(rowsUsed - 1) * gutter
        let totalHeight = headerHeight + gridHeight + footerHeight
        return Layout(cellRects: rects, headerHeight: headerHeight, gridHeight: gridHeight,
                      footerHeight: footerHeight, totalSize: CGSize(width: width, height: totalHeight))
    }

    // MARK: - Colours

    private static let ground = UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
    private static let textPrimary = UIColor.white
    private static let textSecondary = UIColor(white: 0.62, alpha: 1)
    private static let footerMarkColour = UIColor(white: 0.48, alpha: 1)

    /// The user's own picked accent, matching the opening card's "CHAPTER NN" label so the
    /// export reads as the same product rather than a fixed brand colour nobody chose.
    private static func accentInk() -> UIColor {
        let raw = UserDefaults.standard.string(forKey: FlimTheme.accentKey)
        let rgb = FlimAccentPalette.rgb(raw)
        return UIColor(red: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1)
    }

    // MARK: - Render

    /// Renders the sheet at a fixed pixel size (`layout`'s own `totalSize`), from images already
    /// decoded to roughly cell size: this aspect-fills and crops to each cell exactly like every
    /// other frame in the app, it never upscales what it's given.
    ///
    /// `images` must already be in the deck's own chronological order and may be shorter than
    /// the full curated count: a photo that failed to resolve is simply left out, filling the
    /// grid left to right, row by row, rather than a placeholder cell drawn for the gap. `nil`
    /// only when there is truly nothing to show.
    static func render(images: [UIImage], chapterCode: String, monthName: String,
                       statsLine: String, appName: String) -> UIImage? {
        guard !images.isEmpty else { return nil }
        let capped = Array(images.prefix(capacity))
        let pageLayout = layout(photoCount: capped.count)
        guard pageLayout.totalSize.width > 0, pageLayout.totalSize.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1          // the canvas is specified in pixels, not points
        format.opaque = true

        return UIGraphicsImageRenderer(size: pageLayout.totalSize, format: format).image { ctx in
            let cg = ctx.cgContext
            ground.setFill()
            cg.fill(CGRect(origin: .zero, size: pageLayout.totalSize))

            drawHeader(chapterCode: chapterCode, monthName: monthName, statsLine: statsLine)

            for (image, rect) in zip(capped, pageLayout.cellRects) {
                cg.saveGState()
                cg.addRect(rect)
                cg.clip()
                drawAspectFilling(image, in: rect)
                cg.restoreGState()
            }

            drawFooter(appName: appName, canvas: pageLayout.totalSize)
        }
    }

    /// Centre-crops `image` to fill `rect` exactly, the same "never stretch, never letterbox"
    /// rule every grid and card in the app uses for a photograph.
    private static func drawAspectFilling(_ image: UIImage, in rect: CGRect) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let scale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))
    }

    private static func drawHeader(chapterCode: String, monthName: String, statsLine: String) {
        var y = headerTopPadding

        let labelKern: CGFloat = 3.2
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 22, weight: .semibold),
            .kern: labelKern,
            .foregroundColor: accentInk()
        ]
        ("CHAPTER \(chapterCode)" as NSString).draw(at: CGPoint(x: outerMargin, y: y), withAttributes: labelAttrs)
        y += chapterLabelHeight + chapterLabelGap

        let monthAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 64, weight: .ultraLight),
            .foregroundColor: textPrimary
        ]
        (monthName as NSString).draw(at: CGPoint(x: outerMargin, y: y), withAttributes: monthAttrs)
        y += monthNameHeight + monthNameGap

        let statsAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 24),
            .foregroundColor: textSecondary
        ]
        (statsLine as NSString).draw(at: CGPoint(x: outerMargin, y: y), withAttributes: statsAttrs)
    }

    private static func drawFooter(appName: String, canvas: CGSize) {
        let kern: CGFloat = 3
        let text = appName.uppercased() as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 18, weight: .light),
            .kern: kern,
            .foregroundColor: footerMarkColour
        ]
        // The trailing letter's kerning is real trailing space; drop it so the mark centres on
        // its last stroke, not on the invisible gap after it (matches `BrandedExport`'s own
        // wordmark centring).
        let measured = text.size(withAttributes: attrs)
        let width = measured.width - kern
        let origin = CGPoint(x: (canvas.width - width) / 2,
                             y: canvas.height - footerBottomPadding - footerMarkHeight)
        text.draw(at: origin, withAttributes: attrs)
    }
}

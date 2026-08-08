import UIKit

/// Composites a developed roll's frames into a single 9:16 "contact sheet" image, sized to drop
/// straight into a Stories canvas without cropping.
///
/// The reveal is the emotional peak of the app and, until this feature, nothing about it survived
/// past the moment it played. This turns a developed roll into something that can be posted:
/// the frames, the roll's name, the date it developed, and the join link for anyone who sees it.
///
/// # Why this reads from cache first
///
/// The person calling this has, in the overwhelmingly common case, just watched the reveal or is
/// standing on the roll's own grid, so the frames are already decoded and sitting in
/// `ImageLoader`'s memory/disk caches. Re-downloading them to build a share image would be egress
/// spent on bytes already on the device, and egress is the metered resource this backend runs on.
/// `resolveImage` below only reaches the network as a last resort, and even then asks for
/// `viewPath` (the ~1400px rendition), never `storagePath` (the 2048px master).
///
/// # Why this runs off the main actor
///
/// Compositing up to `maxFrames` decoded bitmaps plus text into one large canvas is real CPU work.
/// Doing it inline on the caller's actor would hitch the reveal at the exact moment (its closing
/// beat) this whole feature exists to make more shareable. The actual drawing happens inside
/// `Task.detached` in `render(_:photoService:scale:)`; everything before that is just async cache
/// lookups and a batched URL sign, cheap enough to run wherever the caller already is.
enum ContactSheetRenderer {
    /// Instagram/Snapchat Stories' native canvas, so the exported image drops in without cropping
    /// or letterboxing.
    static let canvasSize = CGSize(width: 1080, height: 1920)

    /// However big a roll gets, and there are 75-shot rolls in the field, the sheet stops here.
    /// Past this point the grid stops reading as a contact sheet and starts reading as a wall of
    /// static. `render` says so in the footer instead of silently dropping frames with no
    /// explanation.
    static let maxFrames = 30

    struct Input {
        let rollName: String
        /// When the roll developed. `Roll.revealAt`, not `.now`, so the sheet is accurate even if
        /// generated a while after the reveal itself.
        let developedAt: Date
        let joinURL: URL
        /// Every developed photo in the roll, in any order; `render` sorts and gates them.
        let photos: [Photo]
        /// Whoever tapped Share. Only consulted by `framesToInclude` below.
        let sharerId: UUID
    }

    /// Whose photos go into the sheet.
    ///
    /// The whole roll, on purpose: a contact sheet of only the sharer's own frames is not a roll
    /// recap, the roll is the product. A roll's photos belong to everyone in it though, so if the
    /// owner decides this should be restricted to the sharer's own shots instead, that is this ONE
    /// line to change (to `photos.filter { $0.userId == sharerId }`). Nothing else in this file, or
    /// in either caller, assumes one answer over the other.
    static func framesToInclude(_ photos: [Photo], sharerId: UUID) -> [Photo] {
        photos
    }

    /// Renders the sheet, or nil if there was nothing to draw (no developed photos, or every frame
    /// failed to resolve an image, e.g. fully offline with a cold cache).
    static func render(_ input: Input, photoService: PhotoService, scale: CGFloat) async -> UIImage? {
        // Undeveloped shots must never appear in something meant to be posted. This is the same
        // time-based check every other screen in the app uses (`Photo.isReady`), applied BEFORE
        // the "who's included" filter above, so that decision can never accidentally let an
        // undeveloped frame through.
        let developed = input.photos.filter(\.isReady).sorted { $0.takenAt < $1.takenAt }
        let included = framesToInclude(developed, sharerId: input.sharerId)
        guard !included.isEmpty else { return nil }

        let shown = Array(included.prefix(maxFrames))
        let truncated = included.count > shown.count

        // One batched sign for every frame, not one round trip per photo.
        let signed = await photoService.signedURLs(for: shown.map(\.viewPath))

        var images: [UIImage] = []
        images.reserveCapacity(shown.count)
        for photo in shown {
            guard let url = signed[photo.viewPath] else { continue }
            if let image = await resolveImage(photo: photo, url: url, scale: scale) {
                images.append(image)
            }
        }
        guard !images.isEmpty else { return nil }

        return await Task.detached(priority: .userInitiated) {
            draw(images: images, input: input, shownCount: images.count, totalCount: included.count,
                 truncated: truncated || images.count < shown.count)
        }.value
    }

    /// Bytes already on the device first, in the order they're most likely to already be there:
    /// the reveal's own cache (URL-keyed, the ~1400px rendition at reveal size), then the roll
    /// grid's (stable-path-keyed, thumbnail size). Only reaches the network if neither hit, and
    /// even then asks for `viewPath`, never the 2048px master.
    private static func resolveImage(photo: Photo, url: URL, scale: CGFloat) async -> UIImage? {
        if let cached = await ImageLoader.peek(url: url, maxPixel: 1600, scale: scale) {
            return cached
        }
        if let cached = await ImageLoader.peek(url: url, maxPixel: 400, scale: scale, cacheKey: photo.displayPath) {
            return cached
        }
        return await ImageLoader.fetch(url: url, maxPixel: 600, scale: scale, cacheKey: photo.displayPath)
    }

    // MARK: - Drawing (off the main actor; Core Graphics only, no SwiftUI)

    private static func draw(images: [UIImage], input: Input, shownCount: Int, totalCount: Int,
                             truncated: Bool) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1   // canvasSize is already the target pixel size
        let renderer = UIGraphicsImageRenderer(size: canvasSize, format: format)
        let regions = ContactSheetLayout.regions(canvas: canvasSize)
        let rects = ContactSheetLayout.frameRects(count: images.count, in: regions.grid)

        return renderer.image { ctx in
            UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: canvasSize))

            drawHeader(rollName: input.rollName, developedAt: input.developedAt, in: regions.header)
            for (image, rect) in zip(images, rects) {
                drawFrame(image, in: rect, cg: ctx.cgContext)
            }
            drawFooter(joinURL: input.joinURL, shown: shownCount, total: totalCount, truncated: truncated,
                      in: regions.footer)
        }
    }

    private static func drawFrame(_ image: UIImage, in rect: CGRect, cg: CGContext) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        cg.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 6).addClip()

        // scaledToFill: scale up to cover the cell on the shorter axis, then center-crop.
        let coverScale = max(rect.width / image.size.width, rect.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * coverScale, height: image.size.height * coverScale)
        let origin = CGPoint(x: rect.midX - drawSize.width / 2, y: rect.midY - drawSize.height / 2)
        image.draw(in: CGRect(origin: origin, size: drawSize))

        cg.restoreGState()
    }

    private static func drawHeader(rollName: String, developedAt: Date, in rect: CGRect) {
        drawCentered("DEVELOPED", font: .systemFont(ofSize: 22, weight: .semibold),
                    color: UIColor(FlimTheme.accent), tracking: 4,
                    in: CGRect(x: rect.minX, y: rect.minY + 48, width: rect.width, height: 30))

        drawCentered(rollName, font: .systemFont(ofSize: 54, weight: .light), color: .white,
                    in: CGRect(x: rect.minX + 48, y: rect.minY + 96, width: rect.width - 96, height: 132),
                    maxLines: 2)

        let dateText = "Developed \(dateFormatter.string(from: developedAt))"
        drawCentered(dateText, font: .systemFont(ofSize: 24), color: UIColor(white: 0.6, alpha: 1),
                    in: CGRect(x: rect.minX, y: rect.maxY - 56, width: rect.width, height: 30))
    }

    private static func drawFooter(joinURL: URL, shown: Int, total: Int, truncated: Bool, in rect: CGRect) {
        var y = rect.minY + 8
        if truncated {
            drawCentered("Showing \(shown) of \(total) photos", font: .systemFont(ofSize: 19),
                        color: UIColor(white: 0.5, alpha: 1),
                        in: CGRect(x: rect.minX, y: y, width: rect.width, height: 26))
            y += 32
        }
        drawCentered("Join this roll", font: .systemFont(ofSize: 21, weight: .medium),
                    color: UIColor(white: 0.72, alpha: 1),
                    in: CGRect(x: rect.minX, y: y, width: rect.width, height: 28))
        y += 34
        drawCentered(joinURL.absoluteString, font: .systemFont(ofSize: 23, weight: .semibold), color: .white,
                    in: CGRect(x: rect.minX + 48, y: y, width: rect.width - 96, height: 32))

        // The mark, quiet: small, low-contrast, at the very bottom, not a logo lockup.
        drawCentered(AppInfo.appName, font: .systemFont(ofSize: 17, weight: .semibold),
                    color: UIColor(FlimTheme.accent).withAlphaComponent(0.65), tracking: 4,
                    in: CGRect(x: rect.minX, y: rect.maxY - 44, width: rect.width, height: 22))
    }

    private static func drawCentered(_ text: String, font: UIFont, color: UIColor, tracking: CGFloat = 0,
                                     in rect: CGRect, maxLines: Int = 1) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = maxLines == 1 ? .byTruncatingTail : .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph
        ]
        if tracking != 0 { attributes[.kern] = tracking }
        NSAttributedString(string: text, attributes: attributes)
            .draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()
}

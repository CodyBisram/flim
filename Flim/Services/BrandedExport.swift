import UIKit

/// Wraps a photo in a subtle instant-print frame with the FLIM wordmark, so anything shared out of
/// the app quietly markets it. Warm off-white border, a wider bottom margin, centered wordmark.
enum BrandedExport {
    static func framed(_ photo: UIImage) -> UIImage {
        let w = photo.size.width
        let h = photo.size.height
        guard w > 0, h > 0 else { return photo }

        let short = min(w, h)
        let inset = short * 0.045          // even border on top + sides
        let footer = short * 0.135         // wider bottom margin for the wordmark
        let canvas = CGSize(width: w + inset * 2, height: h + inset + footer)

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = photo.scale
        format.opaque = true

        return UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
            // Warm off-white "print" paper.
            UIColor(red: 0.955, green: 0.945, blue: 0.915, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: canvas))

            // The photo.
            photo.draw(in: CGRect(x: inset, y: inset, width: w, height: h))

            // The wordmark, centered in the footer, letter-spaced like the in-app logo.
            let size = footer * 0.34
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size, weight: .light),
                .foregroundColor: UIColor(red: 0.12, green: 0.11, blue: 0.10, alpha: 1),
                .kern: size * 0.4,
                .paragraphStyle: paragraph
            ]
            let text = AppInfo.appName as NSString
            let textHeight = size * 1.3
            let rect = CGRect(x: 0,
                              y: h + inset + (footer - textHeight) / 2,
                              width: canvas.width,
                              height: textHeight)
            text.draw(in: rect, withAttributes: attrs)
        }
    }
}

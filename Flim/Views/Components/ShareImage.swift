import SwiftUI
import UIKit

/// Identifiable wrapper so a shared image can drive `.sheet(item:)`. Framing (the FLIM print
/// border) is the user's choice, made live in SharePreviewSheet; this holds the untouched photo.
/// Shared by every surface that can share a photo out (the photo pager, feed, post detail, roll
/// carousel).
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
    /// What the print's footer writes: the date the shot was taken, and the roll it belongs to
    /// when the surface knows one. Carried here rather than passed alongside, so each surface
    /// fills in what it already has in scope and the sheet's signature changed exactly once.
    /// Nil draws the centred wordmark alone, which is what the frame always did.
    var caption: BrandedExport.Caption?
}

/// Bridges UIKit's share sheet (Save to Photos, AirDrop, Messages, …) into SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    /// Called once, only when the sheet closes having actually completed an activity (not on a
    /// plain cancel/dismiss). Optional and unused by most callers; the roll-invite share sheets
    /// use it to log `invite_sent` at the point the invite is actually sent, not the moment the
    /// button was tapped.
    var onComplete: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            guard completed else { return }
            onComplete?()
        }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

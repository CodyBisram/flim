import SwiftUI
import UIKit

/// Identifiable wrapper so a shared image can drive `.sheet(item:)`. Framing (the FLIM print
/// border) is the user's choice, made live in SharePreviewSheet; this holds the untouched photo.
/// Shared by every surface that can share a photo out (the photo pager, feed, post detail, roll
/// carousel).
struct ShareImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Bridges UIKit's share sheet (Save to Photos, AirDrop, Messages, …) into SwiftUI.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

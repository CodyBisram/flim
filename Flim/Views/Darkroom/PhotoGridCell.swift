import SwiftUI
import UIKit

struct PhotoGridCell: View {
    let photo: Photo
    let signedURL: URL?

    var body: some View {
        ZStack {
            if photo.isReady, let url = signedURL {
                CachedImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color(red: 0.08, green: 0.06, blue: 0.05)
                }
                .clipped()
            } else {
                developingPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fill)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private var developingPlaceholder: some View {
        ZStack {
            Color(red: 0.08, green: 0.06, blue: 0.05)
            GrainOverlay()
            VStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .font(.system(size: 14, weight: .ultraLight))
                    .foregroundStyle(FlimTheme.accent.opacity(0.8))

                // TimelineView fires once per second — no external timer needed
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    Text(countdown(at: timeline.date))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(white: 0.35))
                }

                Text("DEVELOPING")
                    .font(.system(size: 8, weight: .medium))
                    .tracking(2)
                    .foregroundStyle(Color(white: 0.25))
            }
        }
    }

    private func countdown(at date: Date) -> String {
        let seconds = max(0, Int(photo.developsAt.timeIntervalSince(date)))
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

// MARK: - Cached image

/// Drop-in async image that caches the decoded `UIImage` in memory. Scrolling back to a
/// cell — or opening a photo full-screen — becomes instant instead of re-downloading and
/// re-decoding the JPEG every time. First load fades in; cache hits appear immediately.
enum ImageCache {
    static let shared: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 250
        return cache
    }()
}

struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var shown = false

    var body: some View {
        ZStack {
            if let uiImage {
                content(Image(uiImage: uiImage)).opacity(shown ? 1 : 0)
            } else {
                placeholder()
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { uiImage = nil; return }
        let key = url as NSURL

        if let cached = ImageCache.shared.object(forKey: key) {
            uiImage = cached
            shown = true                     // cache hit → instant
            return
        }

        uiImage = nil
        shown = false
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = UIImage(data: data) else { return }
        ImageCache.shared.setObject(image, forKey: key)
        uiImage = image
        withAnimation(.easeIn(duration: 0.3)) { shown = true }   // first load → gentle fade
    }
}

// MARK: - Film grain

struct GrainOverlay: View {
    var body: some View {
        Canvas { context, size in
            let count = Int(size.width * size.height / 80)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0...size.width)
                let y = CGFloat.random(in: 0...size.height)
                let dot = CGRect(x: x, y: y, width: 1.2, height: 1.2)
                let alpha = Double.random(in: 0.03...0.12)
                context.fill(Path(dot), with: .color(.white.opacity(alpha)))
            }
        }
        .allowsHitTesting(false)
        .blendMode(.screen)
    }
}

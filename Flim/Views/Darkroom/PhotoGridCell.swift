import SwiftUI
import UIKit
import ImageIO

struct PhotoGridCell: View {
    let photo: Photo
    let signedURL: URL?

    var body: some View {
        // A clear square anchor sizes each cell to exactly 1/3 of the grid width; the image
        // fills it as an overlay and is clipped, so a `scaledToFill` photo can never overflow
        // its slot and overlap neighbours.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if photo.isReady, let url = signedURL {
                    CachedImage(url: url, maxPixel: 400) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color(red: 0.08, green: 0.06, blue: 0.05)
                    }
                } else {
                    developingPlaceholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
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

// MARK: - Loading skeleton

/// A shimmering placeholder grid shown while the Darkroom loads — feels faster and more
/// finished than a bare spinner.
struct LoadingGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shimmer = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<12, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(white: 0.1))
                    .aspectRatio(1, contentMode: .fill)
                    .opacity(shimmer ? 0.45 : 1)
            }
        }
        .padding(.horizontal, 2)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { shimmer = true }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Cached image

/// In-memory cache of *downsampled* decoded images, keyed by URL + target size. Full-res
/// camera photos are many megabytes decoded; caching a screen-sized (or thumbnail-sized)
/// version keeps memory low so entries aren't evicted — which is what made opening a photo
/// slow (the full image had to be re-downloaded and re-decoded every time).
enum ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()
}

struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Longest-edge target in points; the image is downsampled to this (× screen scale).
    var maxPixel: CGFloat = 1600
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

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
        let key = "\(url.absoluteString)|\(Int(maxPixel))" as NSString

        if let cached = ImageCache.shared.object(forKey: key) {
            uiImage = cached
            shown = true                     // cache hit → instant
            return
        }

        uiImage = nil
        shown = false
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        // Downsample off the main actor; ImageIO decodes straight to the target size.
        guard let image = await Self.downsample(data: data, maxPixel: maxPixel, scale: displayScale) else { return }
        ImageCache.shared.setObject(image, forKey: key)
        uiImage = image
        if reduceMotion {
            shown = true
        } else {
            withAnimation(.easeIn(duration: 0.3)) { shown = true }   // first load → gentle fade
        }
    }

    /// Decodes `data` directly to a thumbnail no larger than `maxPixel` (× scale) on its
    /// longest edge — fast and low-memory, without ever fully decoding the original.
    private static func downsample(data: Data, maxPixel: CGFloat, scale: CGFloat) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, srcOptions) else {
                return UIImage(data: data)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel * scale
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return UIImage(data: data)
            }
            return UIImage(cgImage: cg)
        }.value
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

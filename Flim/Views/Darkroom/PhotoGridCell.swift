import SwiftUI
import UIKit
import ImageIO

struct PhotoGridCell: View {
    @Environment(\.flimAccent) private var accent
    let photo: Photo
    let signedURL: URL?
    /// The roll this shot belongs to (shown so roll photos are distinguishable in the Darkroom).
    var rollName: String? = nil
    /// Whether this tile should show its own "develops in HH:MM:SS" countdown. The personal
    /// Darkroom grid has no other time display, so its tiles keep the real countdown; roll
    /// detail screens already show "Develops in Xh Xm" for the whole roll in a header (every
    /// shot in a roll develops together), so their tiles pass `false` and get a quiet animated
    /// hourglass instead of repeating the same number on every tile.
    var showsCountdown: Bool = true

    var body: some View {
        // A clear square anchor sizes each cell to exactly 1/3 of the grid width; the image
        // fills it as an overlay and is clipped, so a `scaledToFill` photo can never overflow
        // its slot and overlap neighbours.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if photo.isReady {
                    CachedImage(url: signedURL, maxPixel: 400, cacheKey: photo.displayPath) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ShimmerPlaceholder(cornerRadius: 4)
                    }
                } else {
                    developingPlaceholder
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
            // A small roll tag on developed roll shots, so you know which are shared.
            .overlay(alignment: .bottomLeading) {
                if photo.isReady, let rollName {
                    Label(rollName, systemImage: "film.stack")
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(photo.isReady
                ? "Photo\(rollName.map { " from \($0)" } ?? ""), \(photo.takenAt.formatted(date: .abbreviated, time: .omitted))"
                : "Developing photo")
            .accessibilityAddTraits(photo.isReady ? .isButton : [])
    }

    private var developingPlaceholder: some View {
        ZStack {
            Color(red: 0.08, green: 0.06, blue: 0.05)
            GrainOverlay()
            VStack(spacing: 6) {
                if showsCountdown {
                    Image(systemName: "hourglass")
                        .font(.system(size: 14, weight: .ultraLight))
                        .foregroundStyle(accent.opacity(0.8))

                    // TimelineView fires once per second, no external timer needed
                    TimelineView(.periodic(from: .now, by: 1)) { timeline in
                        Text(countdown(at: timeline.date))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(white: 0.35))
                    }
                } else {
                    AnimatedHourglass(size: 16, color: FlimTheme.textTertiary)
                }

                // Tell the user which roll this shot is developing for (or just "DEVELOPING").
                if let rollName {
                    Label(rollName, systemImage: "film.stack")
                        .font(.system(size: 8, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(accent.opacity(0.9))
                        .padding(.horizontal, 6)
                } else {
                    Text("DEVELOPING")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(Color(white: 0.25))
                }
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

/// A shimmering placeholder grid shown while the Darkroom loads, feels faster and more
/// finished than a bare spinner.
struct LoadingGrid: View {
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(0..<12, id: \.self) { _ in
                ShimmerPlaceholder(cornerRadius: 4)
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityHidden(true)
    }
}

// MARK: - Cached image

/// In-memory cache of *downsampled* decoded images, keyed by URL + target size. Full-res
/// camera photos are many megabytes decoded; caching a screen-sized (or thumbnail-sized)
/// version keeps memory low so entries aren't evicted, which is what made opening a photo
/// slow (the full image had to be re-downloaded and re-decoded every time).
enum ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        // A count limit alone doesn't bound memory: these entries are DECODED bitmaps, and a
        // feed-card image (1400px long edge) is ~10MB decoded, so 300 of them is gigabytes.
        // Without a cost limit, NSCache only sheds under system memory pressure, which for a
        // foreground app tends to arrive as a jetsam kill rather than a graceful eviction.
        //
        // DO NOT TIGHTEN THIS WITHOUT DOING THE ARITHMETIC. It is a backstop against the
        // pathological case, NOT a working-set target. A Darkroom grid thumbnail is requested at
        // maxPixel 400, which `downsample` multiplies by the screen scale, so it decodes to
        // ~1200px: about 4MB each, and a 3-column grid keeps a dozen-plus on screen at once. An
        // earlier 96MB limit here held barely ~20 of them, so cells were evicted while still
        // near the viewport and reloaded from disk asynchronously, which showed up as tiles that
        // stayed blank until you scrolled them off and back. 300MB leaves the normal working set
        // untouched while still capping the 300-entry worst case at something survivable.
        cache.totalCostLimit = 300 * 1024 * 1024
        return cache
    }()

    /// Inserts with the image's decoded byte size as its cost, so `totalCostLimit` is meaningful.
    /// Always use this instead of `setObject(_:forKey:)`, an entry inserted without a cost counts
    /// as zero and can never trigger eviction.
    static func set(_ image: UIImage, forKey key: NSString) {
        let cost = image.cgImage.map { $0.bytesPerRow * $0.height } ?? 0
        shared.setObject(image, forKey: key, cost: cost)
    }
}

/// A persistent, on-disk cache of downsampled JPEGs. Keyed by the storage PATH (not the signed
/// URL, whose token changes each session) + target size, so a photo you've already seen loads
/// instantly on the next scroll-back or app launch instead of re-downloading.
enum DiskImageCache {
    private static let dir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("flim-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A stable (across-launch) filename hash, String.hashValue is randomized per process.
    private static func file(_ key: String) -> URL {
        var h: UInt64 = 5381
        for b in key.utf8 { h = (h &* 33) &+ UInt64(b) }
        return dir.appendingPathComponent(String(h, radix: 16))
    }

    static func load(_ key: String) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: file(key)) else { return nil }
            return UIImage(data: data)
        }.value
    }

    static func save(_ image: UIImage, key: String) {
        Task.detached(priority: .background) {
            guard let data = image.jpegData(compressionQuality: 0.9) else { return }
            try? data.write(to: file(key), options: .atomic)
        }
    }

    /// The ORIGINAL downloaded bytes for a storage path, before any downsampling.
    ///
    /// The sized caches above key on `path|maxPixel`, so the same file requested at two sizes was
    /// two entries and, more importantly, two DOWNLOADS. The Activity list asks for `displayPath`
    /// at 88 while every grid asks for the same file at 400, so opening Activity re-fetched
    /// thumbnails already sitting on the device. Keeping the raw bytes under a size-independent
    /// key means the second size downsamples locally instead of going back to the network.
    ///
    /// Deliberately in the same directory as the sized entries, so `trim()` bounds it too without
    /// a second budget to keep in sync.
    static func loadRaw(path: String) async -> Data? {
        await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: file("raw|" + path))
        }.value
    }

    static func saveRaw(_ data: Data, path: String) {
        Task.detached(priority: .background) {
            try? data.write(to: file("raw|" + path), options: .atomic)
        }
    }

    /// Keep the cache bounded, delete the oldest files if it exceeds `maxBytes`. Run at launch.
    static func trim(maxBytes: Int = 200 * 1024 * 1024) {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
            var infos: [(url: URL, date: Date, size: Int)] = files.compactMap {
                guard let v = try? $0.resourceValues(forKeys: Set(keys)),
                      let d = v.contentModificationDate, let s = v.fileSize else { return nil }
                return ($0, d, s)
            }
            var total = infos.reduce(0) { $0 + $1.size }
            guard total > maxBytes else { return }
            infos.sort { $0.date < $1.date }   // oldest first
            for info in infos where total > maxBytes {
                try? fm.removeItem(at: info.url)
                total -= info.size
            }
        }
    }
}

struct CachedImage<Content: View, Placeholder: View>: View {
    let url: URL?
    /// Longest-edge target in points; the image is downsampled to this (× screen scale).
    var maxPixel: CGFloat = 1600
    /// A stable storage path, if known, lets the image load from cache before a URL is resolved
    /// (instant on cold launch) and survive new signed-URL tokens.
    var cacheKey: String? = nil
    /// Called once when the load fails (network error, or the object no longer exists, e.g. it
    /// was deleted after a caller resolved its signed URL). Most call sites just show the built-in
    /// retry tile; a slideshow can use this to skip the frame instead.
    var onFailure: (() -> Void)? = nil
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var shown = false
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let uiImage {
                content(Image(uiImage: uiImage)).opacity(shown ? 1 : 0)
            } else if failed {
                // Graceful failure instead of shimmering forever, tap to retry.
                Rectangle().fill(Color.white.opacity(0.04))
                    .overlay {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await load() } }
            } else {
                placeholder()
            }
        }
        // Re-run when the URL resolves (nil → signed) too, not just when the stable key changes.
        .task(id: "\(cacheKey ?? "")|\(url?.absoluteString ?? "")") { await load() }
    }

    private func load() async {
        failed = false
        // Try the caches by stable key first, this can hit before any URL is resolved.
        if let key = cacheKey {
            let memKey = "\(key)|\(Int(maxPixel))" as NSString
            if let cached = ImageCache.shared.object(forKey: memKey) { uiImage = cached; shown = true; return }
            if let disk = await DiskImageCache.load("\(key)|\(Int(maxPixel))") {
                ImageCache.set(disk, forKey: memKey)
                uiImage = disk; shown = true; return
            }
        }
        guard let url else { uiImage = nil; return }
        if cacheKey == nil {
            let memKey = "\(url.absoluteString)|\(Int(maxPixel))" as NSString
            if let cached = ImageCache.shared.object(forKey: memKey) { uiImage = cached; shown = true; return }
        }
        uiImage = nil
        shown = false
        guard let image = await ImageLoader.fetch(url: url, maxPixel: maxPixel, scale: displayScale, cacheKey: cacheKey) else {
            failed = true   // network/decode failed → show retry, not endless shimmer
            onFailure?()
            return
        }
        uiImage = image
        if reduceMotion {
            shown = true
        } else {
            withAnimation(.easeIn(duration: 0.3)) { shown = true }   // first load → gentle fade
        }
    }
}

// MARK: - Image loading (shared by CachedImage + prefetch)

/// Loads a downsampled image through memory → disk → network, caching in both. Shared so a
/// prefetcher can warm the cache for cells that aren't visible yet.
enum ImageLoader {
    /// `cacheKey` (a stable storage path) keys both caches when provided, so a photo survives
    /// new signed-URL tokens AND can be found before a URL is even resolved. Falls back to the
    /// URL when nil.
    static func fetch(url: URL, maxPixel: CGFloat, scale: CGFloat, cacheKey: String? = nil) async -> UIImage? {
        if let cached = await peek(url: url, maxPixel: maxPixel, scale: scale, cacheKey: cacheKey) {
            return cached
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        guard let image = await downsample(data: data, maxPixel: maxPixel, scale: scale) else { return nil }
        let memKey = (cacheKey.map { "\($0)|\(Int(maxPixel))" } ?? "\(url.absoluteString)|\(Int(maxPixel))") as NSString
        let diskKey = cacheKey.map { "\($0)|\(Int(maxPixel))" } ?? "\(url.path)|\(Int(maxPixel))"
        ImageCache.set(image, forKey: memKey)
        DiskImageCache.save(image, key: diskKey)
        if let cacheKey { DiskImageCache.saveRaw(data, path: cacheKey) }
        return image
    }

    /// The cache-only portion of `fetch`: memory, then disk, then the same photo's raw bytes
    /// downsampled locally for a DIFFERENT size, never the network. Split out so a caller that
    /// must not spend new egress under any circumstance (compositing the roll's contact sheet
    /// from whatever the reveal or grid already downloaded this session) can ask for exactly
    /// that, while `fetch` still falls all the way through to a real download for every other
    /// caller in the app.
    static func peek(url: URL, maxPixel: CGFloat, scale: CGFloat, cacheKey: String? = nil) async -> UIImage? {
        let memKeyStr = cacheKey.map { "\($0)|\(Int(maxPixel))" } ?? "\(url.absoluteString)|\(Int(maxPixel))"
        let memKey = memKeyStr as NSString
        if let cached = ImageCache.shared.object(forKey: memKey) { return cached }

        let diskKey = cacheKey.map { "\($0)|\(Int(maxPixel))" } ?? "\(url.path)|\(Int(maxPixel))"
        if let disk = await DiskImageCache.load(diskKey) {
            ImageCache.set(disk, forKey: memKey)
            return disk
        }

        // Before giving up, check whether these exact bytes were already downloaded for a
        // DIFFERENT size. Only possible with a stable path; a URL-keyed entry carries a token
        // that changes, so there'd be nothing to match on.
        if let cacheKey, let raw = await DiskImageCache.loadRaw(path: cacheKey),
           let image = await downsample(data: raw, maxPixel: maxPixel, scale: scale) {
            ImageCache.set(image, forKey: memKey)
            DiskImageCache.save(image, key: diskKey)
            return image
        }
        return nil
    }

    /// Warm the cache for upcoming cells (fire-and-forget, low priority). Pass the same cacheKey
    /// the views use, or the prefetched image won't be found.
    ///
    /// Capped at `maxConcurrent` in flight. This used to spawn one detached task per item with no
    /// limit, so warming a 75-shot roll queued 75 downloads at once; URLSession allows ~6
    /// connections per host, so the cells the user is actually looking at ended up waiting behind
    /// a queue of images they hadn't scrolled to yet, and prefetching made first paint SLOWER.
    /// The cap leaves headroom under that limit for the visible cells' own requests.
    static func prefetch(_ items: [(url: URL, cacheKey: String?)], maxPixel: CGFloat, scale: CGFloat,
                         maxConcurrent: Int = 4) {
        guard !items.isEmpty else { return }
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                let limit = min(maxConcurrent, items.count)
                while next < limit {
                    let item = items[next]
                    group.addTask { _ = await fetch(url: item.url, maxPixel: maxPixel, scale: scale, cacheKey: item.cacheKey) }
                    next += 1
                }
                // Start the next item only as one finishes, keeping `limit` in flight.
                while await group.next() != nil, next < items.count {
                    let item = items[next]
                    group.addTask { _ = await fetch(url: item.url, maxPixel: maxPixel, scale: scale, cacheKey: item.cacheKey) }
                    next += 1
                }
            }
        }
    }

    /// Decodes `data` directly to a thumbnail no larger than `maxPixel` (× scale) on its longest
    /// edge, fast and low-memory, without ever fully decoding the original.
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
        // A single pre-rendered noise tile, reused everywhere, vs a Canvas that re-drew
        // hundreds of random dots on every render (costly while scrolling a grid).
        Image(uiImage: Self.tile)
            .resizable(resizingMode: .tile)
            .allowsHitTesting(false)
            .accessibilityHidden(true)   // decorative grain
            .blendMode(.screen)
    }

    private static let tile: UIImage = {
        let side: CGFloat = 160
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { ctx in
            let count = Int(side * side / 80)
            for _ in 0..<count {
                let x = CGFloat.random(in: 0...side)
                let y = CGFloat.random(in: 0...side)
                ctx.cgContext.setFillColor(UIColor.white.withAlphaComponent(CGFloat.random(in: 0.03...0.12)).cgColor)
                ctx.cgContext.fill(CGRect(x: x, y: y, width: 1.2, height: 1.2))
            }
        }
    }()
}

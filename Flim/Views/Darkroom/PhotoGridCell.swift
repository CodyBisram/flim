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
    /// Whether this photo already has a post on the signed-in user's page. Quiet on purpose: most
    /// tiles in a Darkroom grid are unshared, so only the minority (shared) state gets a mark
    /// rather than every tile carrying a badge.
    var isShared: Bool = false

    var body: some View {
        // A clear 3:4 anchor sizes each cell from the COLUMN width, never from the image
        // fills it as an overlay and is clipped, so a `scaledToFill` photo can never overflow
        // its slot and overlap neighbours.
        Color.clear
            .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
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
            // A quiet mark on the shared minority, not the unshared majority: matches the roll
            // tag's corner-scrim treatment so the grid doesn't grow a second visual language.
            // Fixed size rather than `flimFont`, same reasoning as the roll tag right above: a
            // glyph living in a small fixed badge just clips if Dynamic Type scales it, and the
            // app-wide `flimDynamicTypeCeiling()` already bounds how far that growth can go.
            .overlay(alignment: .topTrailing) {
                if photo.isReady, isShared {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(Circle().fill(.black.opacity(0.45)))
                        .padding(5)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement()
            .accessibilityLabel(photo.isReady
                ? "Photo\(rollName.map { " from \($0)" } ?? ""), \(photo.takenAt.formatted(date: .abbreviated, time: .omitted))\(isShared ? ", shared to your page" : "")"
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

                // The word that used to sit here is gone. The tile said "developing" twice, once
                // as the animated hourglass above and once as an 8pt label at `white(0.25)`,
                // which measures about 1.7:1 and is the only genuinely illegible type in the
                // app. Raising it to the 11pt floor would have fixed the contrast and made
                // things worse: at tracking 2 it runs about 100pt wide in a 128pt cell, on every
                // developing tile in the grid at once. Deleting it removes the problem instead
                // of amplifying it, the hourglass already carries the meaning as texture, and
                // VoiceOver reads "Developing photo" from the cell's own label either way.
                //
                // The `rollName` branch it replaced was unreachable: the component's one call
                // site (`RollDetailView.photoGrid`) passes no `rollName` at all.
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
                    .aspectRatio(FlimTheme.frameAspect, contentMode: .fit)
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
            let url = file(key)
            guard let data = try? Data(contentsOf: url) else { return nil }
            touch(url)
            return UIImage(data: data)
        }.value
    }

    static func save(_ image: UIImage, key: String) {
        Task.detached(priority: .background) {
            guard let data = image.jpegData(compressionQuality: 0.9) else { return }
            try? data.write(to: file(key), options: .atomic)
        }
    }

    /// Bumps a cache file's modification date on a hit, so `trim`'s oldest-first eviction is
    /// LRU-ish rather than pure FIFO-by-write-time. Reads never used to touch the file at all, so
    /// a tile revisited constantly (the newest night's thumbnails, the one photo everyone keeps
    /// reopening) aged out on exactly the same schedule as one nobody has looked at since the day
    /// it was written, the file that ends up evicted first at scale is the one most likely to be
    /// re-downloaded again immediately after.
    ///
    /// Only touches files older than a day, so a session that reads the same tile repeatedly (a
    /// grid scroll passing back over already-visible cells) doesn't turn into constant metadata
    /// churn for no ordering benefit within that same day.
    private static func touch(_ url: URL) {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let modified = attrs[.modificationDate] as? Date,
                  modified.timeIntervalSinceNow < -86400
            else { return }
            try? fm.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
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
            let url = file("raw|" + path)
            guard let data = try? Data(contentsOf: url) else { return nil }
            touch(url)
            return data
        }.value
    }

    static func saveRaw(_ data: Data, path: String) {
        Task.detached(priority: .background) {
            try? data.write(to: file("raw|" + path), options: .atomic)
        }
    }

    /// Deletes every cached image. Exists for one reason: a bug can write the WRONG photo's
    /// bytes under a path's keys (the feed's index-keyed URL bug did exactly that, and the
    /// profile grid then served the wrong photograph from cache, indefinitely), and there is
    /// no way to tell a poisoned entry from an honest one after the fact. The caller gates
    /// this behind a one-shot flag; the cost is one cold re-download of whatever is looked
    /// at next.
    static func purgeAll() {
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Keep the cache bounded, delete the oldest files if it exceeds `maxBytes`. Run at launch.
    ///
    /// "Oldest" is modification date, which `load`/`loadRaw` now bump on every cache hit (via
    /// `touch`, throttled to once a day per file), so this is LRU-ish rather than pure
    /// FIFO-by-write-time: a file that keeps getting read stays fresh and survives a trim, a file
    /// nobody has revisited since it was written ages out first, regardless of which one was
    /// downloaded earlier.
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
    /// The curve the image fades in on when it arrives from the network. Default everywhere is
    /// the app's long-standing `easeIn`; the REVEAL passes an `easeOut` instead, because it is
    /// the one surface where the arrival lands under a clearing blur and an easeIn holds the
    /// photograph near-invisible and then rushes it in at the very end. Opt-in on purpose: this
    /// is a reveal decision, not an app-wide one.
    var fadeIn: Animation = .easeIn(duration: 0.3)
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
            withAnimation(fadeIn) { shown = true }
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

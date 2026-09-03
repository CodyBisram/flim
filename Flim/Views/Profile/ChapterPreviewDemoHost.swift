#if DEBUG
import SwiftUI
import UIKit

/// Simulator-only harness for the Chapters shelf + recap, launched with `-chaptersPreviewDemo`.
///
/// FLIM signs in with an emailed code and is invite-only, so there is no way to reach a real
/// signed-in profile from a script (the same problem `FeedPreviewDemoHost` solves for the feed
/// redesign, see its own doc). This renders `UserPageView` for a fixture profile id whose
/// `ChapterService` is pre-seeded directly, and whose cover/photo bytes are generated in-process
/// and planted straight into `ImageCache` under the exact keys `CachedImage` will ask for, so the
/// shelf and the recap have something real to paint with no network and no signed-in account.
struct ChapterPreviewDemoHost: View {
    @State private var auth = AuthService()
    @State private var photos = PhotoService()
    @State private var feed = FeedService()
    @State private var chapters = ChapterService()

    static let profileId = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1") ?? UUID()

    var body: some View {
        NavigationStack {
            UserPageView(userId: Self.profileId)
        }
        .environment(auth)
        .environment(photos)
        .environment(feed)
        .environment(chapters)
        .preferredColorScheme(.dark)
        .task {
            ChapterPreviewFixtures.seed(into: chapters, profileId: Self.profileId)
        }
        // `-openChapterRecap`, alongside `-chaptersPreviewDemo`: jumps straight past the shelf
        // to the recap's opening card, for screenshotting it without a tap the Simulator's own
        // CLI cannot deliver.
        .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-openChapterRecap"))) {
            if let chapter = chapters.chaptersByProfile[Self.profileId]?.first {
                ChapterRecapView(profileId: Self.profileId, chapter: chapter, chapterCoverURLs: [:])
                    .environment(feed)
                    .environment(chapters)
            }
        }
    }
}

@MainActor
enum ChapterPreviewFixtures {
    /// Every `maxPixel` a Chapters view asks `CachedImage` for, across the shelf and the recap:
    /// the shelf card, the recap's fanned covers, and the player's thumb-under/full-over pair.
    /// A fixture image is planted at every one of these so whichever view renders first always
    /// hits the in-memory cache, never the placeholder.
    private static let maxPixels: [CGFloat] = [340, 500, 400, 1400]

    private static var seeded = false

    static func seed(into chapters: ChapterService, profileId: UUID) {
        guard !seeded else { return }
        seeded = true
        chapters.markUsesDemoFixture()

        let hues: [CGFloat] = [0.08, 0.55, 0.85, 0.33, 0.02, 0.68]
        let paths = hues.enumerated().map { index, hue -> String in
            let path = "chaptersDemo/p\(index).jpg"
            if let image = makeImage(hue: hue, label: "\(index + 1)") { plant(image, path: path) }
            return path
        }

        let calendar = Calendar.current
        let now = Date.now
        // The live current month first (owner call: months are live and growing), then a few
        // closed ones, going back far enough to exercise both the shelf's scroll and the
        // recap's curation path (more than fifteen candidate shots).
        let monthsBack = [0, 1, 2, 5]
        var summaries: [ChapterSummary] = []

        for (index, back) in monthsBack.enumerated() {
            guard let monthDate = calendar.date(byAdding: .month, value: -back, to: now),
                  let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate))
            else { continue }

            let shotTotal = back == 0 ? 22 : 8 + index * 5   // > 15 for the live month, so curation actually trims it
            let chapterPhotos: [ChapterPhoto] = (0..<shotTotal).map { i in
                let path = paths[i % paths.count]
                let takenAt = min(monthStart.addingTimeInterval(TimeInterval(i) * 5 * 3600), now)
                return ChapterPhoto(id: UUID(), takenAt: takenAt, thumbPath: path, feedPath: path,
                                     storagePath: path, rollId: nil, rollName: nil)
            }

            summaries.append(ChapterSummary(
                monthStart: monthStart, shotCount: shotTotal, rollCount: back == 0 ? 1 : index % 2,
                coverPaths: Array(paths.prefix(4)),
                firstShotAt: chapterPhotos.first?.takenAt ?? monthStart,
                lastShotAt: chapterPhotos.last?.takenAt ?? monthStart))
            chapters.photosByChapter[.init(profileId: profileId, monthStart: monthStart)] = chapterPhotos
        }

        chapters.chaptersByProfile[profileId] = summaries
    }

    private static func plant(_ image: UIImage, path: String) {
        for maxPixel in maxPixels {
            let key = "\(path)|\(Int(maxPixel))" as NSString
            ImageCache.set(image, forKey: key)
        }
    }

    private static func makeImage(hue: CGFloat, label: String) -> UIImage? {
        let size = CGSize(width: 900, height: 1200)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colors = [
                UIColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.7, brightness: 0.28, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero,
                                      end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let text = label as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 220, weight: .thin),
                .foregroundColor: UIColor.white.withAlphaComponent(0.85),
            ]
            let ts = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2),
                      withAttributes: attrs)
        }
    }
}
#endif

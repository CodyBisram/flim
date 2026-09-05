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
            // `ChapterRecapView.isOwnRecap` compares `auth.currentUser?.id` to the profile being
            // viewed, so the harness's own fixture profile has to actually BE "signed in" for the
            // recap's first-run line to have anything to key off; this also makes `-openChapterRecap`
            // exercise the one-time flag exactly the way a real own-profile visit would.
            auth.currentUser = AppUser(id: Self.profileId, createdAt: .now)
            ChapterPreviewFixtures.seed(into: chapters, profileId: Self.profileId)
            // `-chapterContactSheetDemo`, alongside `-chaptersPreviewDemo`: renders one contact
            // sheet straight from the fixture images (no network, no signed URLs to wait on) and
            // writes it to disk, since the Simulator's own CLI has no way to tap "Share as a
            // contact sheet" and read back the result.
            if ProcessInfo.processInfo.arguments.contains("-chapterContactSheetDemo") {
                ChapterPreviewFixtures.renderContactSheetDemo()
            }
        }
        // `-openChapterRecap`, alongside `-chaptersPreviewDemo`: jumps straight past the shelf
        // to the recap's opening card, for screenshotting it without a tap the Simulator's own
        // CLI cannot deliver.
        .fullScreenCover(isPresented: .constant(ProcessInfo.processInfo.arguments.contains("-openChapterRecap"))) {
            if let chapter = chapters.chaptersByProfile[Self.profileId]?.first {
                // `.fullScreenCover`'s presented content does not pick up `.environment(auth)`
                // from the NavigationStack above just by being chained after it; re-injected here
                // the same way `feed`/`chapters` already are, or `ChapterRecapView.isOwnRecap`
                // reads a default, signed-out `AuthService` and the first-run line never has
                // anything to key off.
                ChapterRecapView(profileId: Self.profileId, chapter: chapter, chapterCoverURLs: [:])
                    .environment(auth)
                    .environment(feed)
                    .environment(chapters)
            }
        }
    }
}

@MainActor
enum ChapterPreviewFixtures {
    /// Every `maxPixel` a Chapters view asks `CachedImage` for, across the shelf and the recap:
    /// the shelf card (340), the recap's fanned covers (500), the closing card's own thumb row
    /// (200, `ChapterClosingCardView.lineContent`), `PhotoPagerView`'s roll-rack film strip (120,
    /// `DarkroomFrameView`'s own request), and its full-screen page (1400). A fixture image is
    /// planted at every one of these so whichever view renders first always hits the in-memory
    /// cache, never the placeholder.
    private static let maxPixels: [CGFloat] = [340, 500, 200, 120, 1400]

    private static var seeded = false
    /// Fixture ids for the two person-backed lines ("Biggest fan", "Roll MVP"); nobody real, but
    /// stable so both lines render a tappable-looking row without crashing if ever actually
    /// tapped in the demo harness (it would just push an empty `UserPageView`).
    private static let fanId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FA") ?? UUID()
    private static let mvpId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FB") ?? UUID()

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
            let key = ChapterService.ChapterKey(profileId: profileId, monthStart: monthStart)
            chapters.photosByChapter[key] = chapterPhotos
            // Only the live current month gets fabricated `chapter_stats`, so `-chapterClosingDemo`
            // (which jumps to the first, i.e. live, chapter) has something to render; the closed
            // months stay stat-less, exercising the "no closing card" path for those.
            if back == 0, let mostReacted = chapterPhotos.first, let mostCommented = chapterPhotos.last,
               chapterPhotos.count > 2 {
                let gapPhoto = chapterPhotos[chapterPhotos.count / 2]
                chapters.statsByChapter[key] = [
                    .shots: ChapterStatRow(statKey: "shots", valueInt: shotTotal),
                    .mostReacted: ChapterStatRow(statKey: "most_reacted", valueInt: 12,
                                                  photoId: mostReacted.id, photoThumbPath: mostReacted.thumbPath),
                    .topReaction: ChapterStatRow(statKey: "top_reaction", valueInt: 12, valueText: "❤️"),
                    .mostCommented: ChapterStatRow(statKey: "most_commented", valueInt: 5,
                                                    photoId: mostCommented.id, photoThumbPath: mostCommented.thumbPath),
                    .busiestDay: ChapterStatRow(statKey: "busiest_day", valueInt: 9,
                                                 valueText: bareDateString(monthStart.addingTimeInterval(11 * 86_400))),
                    .nightShots: ChapterStatRow(statKey: "night_shots", valueInt: 7),
                    .streakDays: ChapterStatRow(statKey: "streak_days", valueInt: 6),
                    .rollsCount: ChapterStatRow(statKey: "rolls_count", valueInt: 3),
                    .peopleShotWith: ChapterStatRow(statKey: "people_shot_with", valueInt: 7),
                    .biggestFan: ChapterStatRow(statKey: "biggest_fan", valueInt: 34, valueText: "sabs",
                                                 userId: Self.fanId),
                    .topGivenReaction: ChapterStatRow(statKey: "top_given_reaction", valueInt: 219, valueText: "❤️"),
                    .goldenHour: ChapterStatRow(statKey: "golden_hour", valueInt: 20, valueText: "9"),
                    .rollMVP: ChapterStatRow(statKey: "roll_mvp", valueInt: 10, valueText: "tristan",
                                              userId: Self.mvpId),
                    .longestGap: ChapterStatRow(statKey: "longest_gap", valueInt: 5, photoId: gapPhoto.id,
                                                 photoThumbPath: gapPhoto.thumbPath),
                ]
            }
        }

        chapters.chaptersByProfile[profileId] = summaries
    }

    /// A bare `"yyyy-MM-dd"` string, the same shape `busiest_day` arrives in for real, from a
    /// concrete date, for this fixture's own use only.
    private static func bareDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func plant(_ image: UIImage, path: String) {
        for maxPixel in maxPixels {
            let key = "\(path)|\(Int(maxPixel))" as NSString
            ImageCache.set(image, forKey: key)
        }
    }

    /// Renders one contact sheet from fifteen fresh fixture images and writes it to the app's own
    /// temporary directory, printing the path so it can be pulled off the simulator's host
    /// filesystem afterwards. Deliberately independent of `ChapterRecapViewModel`: that path
    /// needs real signed URLs (`FeedService.signedURLs`), which have nothing to sign against in
    /// an offline harness, so this calls `ChapterContactSheet.render` directly with the same kind
    /// of generated tiles the shelf/recap covers already use.
    static func renderContactSheetDemo() {
        let images = (0..<15).compactMap { i in
            makeImage(hue: CGFloat(i) / 15, label: "\(i + 1)")
        }
        guard let sheet = ChapterContactSheet.render(
            images: images, chapterCode: "08", monthName: "August",
            statsLine: "34 shared · 2 rolls", appName: AppInfo.appName
        ), let data = sheet.pngData() else {
            print("CONTACT_SHEET_DEMO_FAILED")
            return
        }
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-contact-sheet-demo.png")
        do {
            try data.write(to: path, options: .atomic)
            print("CONTACT_SHEET_DEMO_PATH: \(path.path)")
        } catch {
            print("CONTACT_SHEET_DEMO_FAILED: \(error)")
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

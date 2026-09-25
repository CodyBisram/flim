#if DEBUG
import SwiftUI
import UIKit

/// Simulator-only harness for Spotlight, launched with `-spotlightPreviewDemo`.
///
/// The fixture feed from `FeedPreviewDemoHost`, plus Spotlight state no server was asked for: a
/// strip week of five frames placed among the feed's units, a sheet of three past weeks, and a
/// SPOTLIGHT shelf on every page with a chosen frame (the fixture viewer, @you, has exactly one).
/// One frame per week belongs to someone the viewer does not follow, so opening it shows the
/// stranger's view of a chosen frame: the photograph, the "In Spotlight" note, no composer.
///
/// Reads that would go to the server (`fetchSpotlightWeeks`, `fetchOwnSpotlightEntry`,
/// `openSpotlightFrame`, `fetchProfile(id:)`) answer from `SpotlightPreviewDemo.data` while it
/// is set, each behind `#if DEBUG` at its call site. Frame images are generated here and
/// remembered as file URLs under the exact paths the app would sign, so nothing is fetched.
struct SpotlightPreviewDemoHost: View {
    @State private var auth = AuthService()
    @State private var photos = PhotoService()
    @State private var chapters = ChapterService()
    @State private var feed: FeedService

    init() {
        let service = FeedService()
        FeedPreviewFixtures.seed(into: service)
        SpotlightPreviewFixtures.seed(into: service)
        _feed = State(initialValue: service)
    }

    var body: some View {
        NavigationStack {
            FeedView()
        }
        .undoCapsuleHost()
        .environment(auth)
        .environment(photos)
        .environment(feed)
        .environment(chapters)
        .preferredColorScheme(.dark)
        .task {
            // A signed-in fixture viewer, so "your" chosen frame has an owner: the shelf on
            // @you's page and the own-post menu's "Take it out of Spotlight" both key off it.
            // An account from long ago, so no new-account prompt covers the feed.
            var viewer = AppUser(id: SpotlightPreviewFixtures.viewerId,
                                 createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            viewer.username = "you"
            auth.currentUser = viewer
            await SpotlightPreviewFixtures.plantImages(into: feed)
        }
    }
}

/// What the Spotlight reads answer with while the harness runs.
struct SpotlightDemoData {
    /// Everyone's published weeks, newest first.
    var published: [SpotlightWeek]
    var entry: OwnSpotlightEntry?
    /// Post id to the post as it opens.
    var items: [UUID: FeedItem]
    var profiles: [UUID: UserProfile]
}

@MainActor
enum SpotlightPreviewDemo {
    /// Set once by `SpotlightPreviewFixtures.seed`; nil in every other run.
    static var data: SpotlightDemoData?

    /// The same shape `spotlight_published` / `spotlight_frames` return.
    static func weeks(userId: UUID?, before: String?, limit: Int) -> [SpotlightWeek]? {
        guard let data else { return nil }
        var weeks = data.published
        if let before { weeks = weeks.filter { $0.weekKey < before } }
        if let userId { weeks = SpotlightWeek.pruned(weeks) { $0.userId != userId } }
        return Array(weeks.prefix(limit))
    }
}

@MainActor
enum SpotlightPreviewFixtures {
    /// The fixture viewer. The same id `FeedPreviewFixtures` activates the seen store under.
    static let viewerId = demoId(1)

    private static func demoId(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n)) ?? UUID()
    }

    private static func profile(_ n: Int, _ name: String) -> UserProfile {
        UserProfile(id: demoId(9000 + n), username: name, avatarPath: nil, bio: nil,
                    displayName: nil, coverPath: nil, createdAt: .now,
                    hiddenFromDiscovery: false, signupOrdinal: nil)
    }

    private static func path(_ n: Int) -> String { "spotlightDemo/f\(n).jpg" }

    /// Every frame path, with the hue its generated image is drawn in.
    private static var paths: [(path: String, hue: CGFloat)] = []

    private static var seeded = false

    static func seed(into service: FeedService) {
        guard !seeded else { return }
        seeded = true

        // mira, dev.k, noor and ricky are the feed fixture's people (followed); juno and sam
        // are not followed; "you" is the viewer.
        let mira = profile(1, "mira")
        let dev = profile(2, "dev.k")
        let noor = profile(3, "noor")
        let ricky = profile(4, "ricky")
        let juno = profile(5, "juno")
        let sam = profile(6, "sam")
        let you = UserProfile(id: viewerId, username: "you", avatarPath: nil, bio: nil,
                              displayName: nil, coverPath: nil, createdAt: .now,
                              hiddenFromDiscovery: false, signupOrdinal: nil)

        // The following set the Spotlight rules read is the CONFIRMED one: the fixture feed
        // seeds only the optimistic set.
        service.confirmedFollowingIds = service.followingIds

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let thisMonday = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        func monday(weeksBack: Int) -> Date {
            calendar.date(byAdding: .day, value: -7 * weeksBack, to: thisMonday) ?? thisMonday
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        // The strip's week was published this morning, just after the 04:00 boundary, so it
        // falls between today's units and ricky's day in the fixture feed.
        let morning = FeedUnit.dayKey(for: .now).addingTimeInterval(FeedUnit.dayBoundaryHour)
        let publishTimes = [morning.addingTimeInterval(1800),
                            monday(weeksBack: 1).addingTimeInterval(13 * 3600),
                            monday(weeksBack: 2).addingTimeInterval(13 * 3600)]

        let captions: [String: String] = [
            "juno": "the ferry at six, before anyone else was up",
            "you": "kept this one for a week before posting it",
            "sam": "found the light at the end of the platform",
        ]
        let rosters: [[UserProfile]] = [
            [mira, juno, dev, you, noor],
            [ricky, sam, juno],
            [noor, dev, sam],
        ]

        var items: [UUID: FeedItem] = [:]
        var weeks: [SpotlightWeek] = []
        var next = 1
        for (index, roster) in rosters.enumerated() {
            let weekStart = monday(weeksBack: index + 1)
            let weekKey = formatter.string(from: weekStart)
            var frames: [SpotlightFrame] = []
            for author in roster {
                let postId = demoId(70_000 + next)
                let posted = weekStart.addingTimeInterval(Double(next % 6) * 86_400 + 15 * 3600)
                let framePath = path(next)
                paths.append((framePath, CGFloat(next % 11) / 11))
                let post = Post(id: postId, userId: author.id, photoId: demoId(71_000 + next),
                                storagePath: framePath, thumbPath: framePath, feedPath: framePath,
                                takenAt: posted, caption: author.username.flatMap { captions[$0] },
                                createdAt: posted)
                items[postId] = FeedItem(post: post, author: author)
                frames.append(SpotlightFrame(
                    postId: postId, photoId: post.photoId, userId: author.id,
                    username: author.username, displayName: nil, avatarPath: nil,
                    thumbPath: framePath, feedPath: framePath, storagePath: framePath,
                    postCreatedAt: posted, chosenAt: publishTimes[index]))
                next += 1
            }
            weeks.append(SpotlightWeek(weekKey: weekKey, publishedAt: publishTimes[index], frames: frames))
        }

        let entry = OwnSpotlightEntry(
            weekKey: formatter.string(from: thisMonday),
            weekStartsAt: thisMonday.addingTimeInterval(FeedUnit.dayBoundaryHour),
            weekClosesAt: monday(weeksBack: -1).addingTimeInterval(FeedUnit.dayBoundaryHour),
            canPutUp: true, postId: nil, photoId: nil, postCreatedAt: nil, putUpAt: nil)

        var profiles: [UUID: UserProfile] = [:]
        for person in [mira, dev, noor, ricky, juno, sam, you] { profiles[person.id] = person }
        SpotlightPreviewDemo.data = SpotlightDemoData(published: weeks, entry: entry,
                                                      items: items, profiles: profiles)

        // What a reload would have loaded, in hand before the feed first places the strip.
        service.spotlightStripWeeks = [weeks[0]]
        service.spotlightPastWeeks = weeks
        service.spotlightPastWeeksHasMore = false
        service.ownSpotlightEntry = entry
        for person in [mira, dev, noor, ricky, juno, sam, you] {
            let shelf = SpotlightWeek.pruned(weeks) { $0.userId != person.id }
            if !shelf.isEmpty { service.spotlightShelves[person.id] = shelf }
        }
        service.ownSpotlightChosen = Dictionary(
            SpotlightActivity.ownFrames(in: weeks, ownId: viewerId).map { ($0.frame.postId, $0.week.weekKey) },
            uniquingKeysWith: { first, _ in first })
        for profile in profiles.values { service.tagProfiles[profile.id] = profile }
    }

    /// Draws each frame and remembers it as a file URL under its path, the way a signed URL
    /// would be remembered, so every size any surface asks for loads with no network.
    static func plantImages(into service: FeedService) async {
        for (path, hue) in paths {
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("spotlightDemo-\(path.replacingOccurrences(of: "/", with: "-"))")
            if !FileManager.default.fileExists(atPath: file.path) {
                guard let data = makeImage(hue: hue)?.jpegData(compressionQuality: 0.85) else { continue }
                try? data.write(to: file)
            }
            await SignedURLStore.shared.store(file, for: path)
            service.spotlightURLs[path] = file
        }
    }

    private static func makeImage(hue: CGFloat) -> UIImage? {
        let size = CGSize(width: 600, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let colors = [
                UIColor(hue: hue, saturation: 0.45, brightness: 0.85, alpha: 1).cgColor,
                UIColor(hue: hue, saturation: 0.7, brightness: 0.25, alpha: 1).cgColor,
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(gradient, start: .zero,
                                                 end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }
}
#endif

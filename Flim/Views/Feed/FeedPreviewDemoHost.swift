#if DEBUG
import SwiftUI

/// Simulator-only harness for the per-author feed, launched with `-feedPreviewDemo`.
///
/// The feed redesign is otherwise unwatchable without a signed-in account, and sign-in is
/// OTP-only. This boots `FeedView` against its OWN service instances, pre-seeded with the
/// fixture feed the design itself was built around: mira's 14-shot Italy day (two unseen, so
/// it opens mid-day with a pill), dev.k's 2 and noor's 1, and ricky's fully-seen 40-shot day
/// below the caught-up seam to show the strip's `+N` cap and the archive below the block.
///
/// Images come from the disk cache, planted from outside by the run script before launch
/// (`DiskImageCache` keys on storage path, not signed URL, which is what makes this
/// possible). Nothing here touches the network on purpose; anything that tries fails quietly
/// exactly as it does offline.
struct FeedPreviewDemoHost: View {
    @State private var auth = AuthService()
    @State private var photos = PhotoService()
    @State private var feed: FeedService

    init() {
        let service = FeedService()
        FeedPreviewFixtures.seed(into: service)
        _feed = State(initialValue: service)
    }

    var body: some View {
        NavigationStack {
            FeedView()
        }
        .environment(auth)
        .environment(photos)
        .environment(feed)
        .preferredColorScheme(.dark)
    }
}

@MainActor
enum FeedPreviewFixtures {
    /// Deterministic ids, so seen-marks seeded into the shared store line up with the posts
    /// across relaunches instead of accumulating garbage.
    private static func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    private static func profile(_ n: Int, _ name: String) -> UserProfile {
        UserProfile(id: uuid(9000 + n), username: name, avatarPath: nil, bio: nil,
                    displayName: nil, coverPath: nil, createdAt: .now,
                    hiddenFromDiscovery: false, signupOrdinal: nil)
    }

    private static func photoPath(_ n: Int) -> String { "demo/p\(String(format: "%02d", n % 15 + 1)).jpg" }

    /// A View's init runs on every render of its parent, and this seed has SIDE EFFECTS (it
    /// resets and re-marks the shared seen store). Unguarded, every ContentView re-render
    /// wiped the marks the demo session had just made, so pills never moved. Once per
    /// process.
    private static var seeded = false

    static func seed(into service: FeedService) {
        guard !seeded else { return }
        seeded = true
        let mira = profile(1, "mira")
        let dev = profile(2, "dev.k")
        let noor = profile(3, "noor")
        let ricky = profile(4, "ricky")

        // Anchor to the most recent 04:00 so today's units stay one unit and ricky's day
        // lands whole in yesterday's bucket, whatever hour this runs.
        let morning = FeedUnit.dayKey(for: .now).addingTimeInterval(FeedUnit.dayBoundaryHour)
        let span = max(600.0, Date.now.timeIntervalSince(morning) - 3600)

        var items: [FeedItem] = []
        var nextId = 1

        func post(author: UserProfile, at date: Date, photo: Int, caption: String? = nil) -> FeedItem {
            let id = uuid(nextId); nextId += 1
            let item = FeedItem(
                post: Post(id: id, userId: author.id, photoId: uuid(5000 + nextId),
                           storagePath: photoPath(photo), thumbPath: nil, feedPath: nil,
                           takenAt: date, caption: caption, createdAt: date),
                author: author)
            items.append(item)
            return item
        }

        // mira: the 14-shot Italy flood, 8-ish to late, captions where the design put them.
        let miraCaptions: [Int: String] = [
            5: "day four. we found the good pasta, the place with no sign on the door and the guy who kept refilling the carafe without asking. we walked back the long way and it was worth it.",
            8: "walked the wrong way for an hour.",
            12: "last night, the square emptied out and nobody wanted to go home, so we stayed until the chairs went up.",
        ]
        let miraItems: [FeedItem] = (0..<14).map { i in
            let offset: TimeInterval = 1800 + span * Double(i) / 13
            return post(author: mira, at: morning.addingTimeInterval(offset),
                        photo: i, caption: miraCaptions[i])
        }

        // dev.k: two shots mid-day, one caption.
        let devItems = [
            post(author: dev, at: morning.addingTimeInterval(span * 0.4), photo: 3, caption: "the good bench"),
            post(author: dev, at: morning.addingTimeInterval(span * 0.45), photo: 4),
        ]

        // noor: one shot, so the solo state (no strip, inert photograph) is on screen too.
        let noorItems = [
            post(author: noor, at: morning.addingTimeInterval(span * 0.7), photo: 9,
                 caption: "she waited all afternoon for this one"),
        ]

        // ricky: 40 shots YESTERDAY, all seen: the +N overflow tile, and the archive day
        // that sits below the caught-up seam.
        let rickyItems: [FeedItem] = (0..<40).map { i in
            let offset: TimeInterval = TimeInterval(-20 * 3600) + TimeInterval(i * 480)
            let caption: String? = i == 0 ? "first light, and it did not stop all day" : nil
            return post(author: ricky, at: morning.addingTimeInterval(offset),
                        photo: i, caption: caption)
        }

        service.feed = items
        service.followingIds = [mira.id, dev.id, noor.id, ricky.id]
        // Everything the fixture holds is already here; no pagination against a server that
        // was never asked.
        service.hasMoreFeed = false

        // Reactions: counts across the six default slots, no row belonging to the (signed
        // out) viewer, so nothing renders as already-reacted.
        var reactions: [UUID: [PostReaction]] = [:]
        var reactionId = 100_000
        for (index, item) in items.enumerated() {
            var rows: [PostReaction] = []
            for (emoji, count) in [("❤️", 2 + index % 4), ("🔥", index % 3), ("😮", index % 2)] where count > 0 {
                for _ in 0..<count {
                    rows.append(PostReaction(id: uuid(reactionId), postId: item.post.id,
                                             userId: uuid(8000 + reactionId % 50), emoji: emoji))
                    reactionId += 1
                }
            }
            reactions[item.post.id] = rows
        }
        service.reactionsByPost = reactions

        // Threads where the design drew them: on mira's captioned late shot and a couple more.
        func comment(_ n: Int, on item: FeedItem, by author: UserProfile, _ body: String,
                     likes: Int = 0) -> CommentInfo {
            CommentInfo(
                comment: PostComment(id: uuid(200_000 + n), postId: item.post.id,
                                     userId: author.id, body: body,
                                     createdAt: item.post.createdAt.addingTimeInterval(1800)),
                author: author, likeCount: likes, likedByMe: false)
        }
        service.commentsByPost = [
            miraItems[12].post.id: [
                comment(1, on: miraItems[12], by: noor, "the chairs going up is such a detail", likes: 1),
                comment(2, on: miraItems[12], by: dev, "stayed till close, respect"),
                comment(3, on: miraItems[12], by: mira, "@noor come next time"),
                comment(4, on: miraItems[12], by: noor, "booking flights"),
            ],
            miraItems[5].post.id: [
                comment(5, on: miraItems[5], by: dev, "ok this is the one"),
                comment(6, on: miraItems[5], by: noor, "where is this exactly"),
            ],
            devItems[0].post.id: [
                comment(7, on: devItems[0], by: mira, "the good bench indeed"),
            ],
        ]

        // Seen state: everything read except mira's last two (her unit opens on 12 and pills
        // "2 new" → "1 new" the moment it appears), one of dev.k's, and noor's. Ricky's whole
        // day is seen, which is what puts the caught-up seam above him. Reset first: a
        // previous demo run's marks would otherwise read as already-caught-up.
        //
        // This harness never runs through ContentView's real sign-in wiring, so nothing else
        // ever sets `activeUserId`; without it every mark below would silently no-op against
        // the now account-scoped store.
        //
        // Simulator only: `activeUserId`'s `didSet` runs `FeedSeenStore`'s one-shot legacy-marks
        // migration (guarded by a flag that survives forever, see its own doc) the very first
        // time ANY account activates the store. `-feedPreviewDemo` is a launch argument, not
        // something the simulator alone can enforce, so a DEBUG build launched on a real device
        // with it set could otherwise consume that one-shot migration into this fixture's fake
        // id, permanently losing the chance to fold the real signed-in account's legacy marks in.
        #if targetEnvironment(simulator)
        FeedSeenStore.shared.activeUserId = uuid(1)
        FeedSeenStore.shared.resetForDemo()
        let unseen: Set<UUID> = [miraItems[12].post.id, miraItems[13].post.id,
                                 devItems[1].post.id, noorItems[0].post.id]
        for item in items where !unseen.contains(item.post.id) {
            FeedSeenStore.shared.markSeen(item.post.id)
        }
        #endif
    }
}
#endif

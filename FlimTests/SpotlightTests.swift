import Testing
import Foundation
@testable import Flim

/// Spotlight's pure rules: where the strip sits, which menu item a post gets, the push rider,
/// the week's words in other zones, the write queue's revision rule, and the Activity count.
/// Calendars and stores are pinned or injected, so nothing here depends on the machine.
@MainActor
struct SpotlightTests {

    // MARK: - Fixtures

    private static func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone) ?? .gmt
        return cal
    }

    private let newYork = SpotlightTests.calendar("America/New_York")

    private func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0,
                      in cal: Calendar? = nil) -> Date {
        let cal = cal ?? newYork
        return cal.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func profile(_ id: UUID = UUID(), name: String = "someone") -> UserProfile {
        UserProfile(id: id, username: name, avatarPath: nil, bio: nil, displayName: nil,
                    coverPath: nil, createdAt: .distantPast)
    }

    private func post(owner: UUID, createdAt: Date, id: UUID = UUID(), photoId: UUID = UUID()) -> Post {
        Post(id: id, userId: owner, photoId: photoId, storagePath: "p/\(id).jpg", thumbPath: nil,
             feedPath: nil, takenAt: createdAt, caption: nil, createdAt: createdAt)
    }

    /// One unit per author per day, newest first, from (author, post time) pairs.
    private func units(_ times: [Date]) -> [FeedUnit] {
        let items = times.map { time in
            let author = profile()
            return FeedItem(post: post(owner: author.id, createdAt: time), author: author)
        }
        return FeedUnit.units(from: items, calendar: newYork)
    }

    private func frame(user: UUID = UUID(), postId: UUID = UUID(), photoId: UUID = UUID(),
                       thumb: String? = "t.jpg", feed: String? = "f.jpg") -> SpotlightFrame {
        SpotlightFrame(postId: postId, photoId: photoId, userId: user, username: "mira",
                       displayName: nil, avatarPath: nil, thumbPath: thumb, feedPath: feed,
                       storagePath: "s.jpg", postCreatedAt: date(9, 15, 12), chosenAt: date(9, 22, 12))
    }

    private func week(_ key: String, publishedAt: Date, frames: [SpotlightFrame]) -> SpotlightWeek {
        SpotlightWeek(weekKey: key, publishedAt: publishedAt, frames: frames)
    }

    private func entry(postId: UUID? = nil, postCreatedAt: Date? = nil, canPutUp: Bool = true) -> OwnSpotlightEntry {
        OwnSpotlightEntry(weekKey: "2026-09-21",
                          weekStartsAt: date(9, 21, 4), weekClosesAt: date(9, 28, 4),
                          canPutUp: canPutUp, postId: postId, photoId: nil,
                          postCreatedAt: postCreatedAt, putUpAt: nil)
    }

    // MARK: - Placement

    @Test("no units and more pages to come: the strip waits")
    func placementEmptyWithMorePages() {
        #expect(SpotlightPlacement.place(units: [], publishedAt: date(9, 22, 9), hasMoreFeed: true) == .notYet)
    }

    @Test("no units and nothing more: the strip is the end of the list")
    func placementEmptyWithNoMorePages() {
        #expect(SpotlightPlacement.place(units: [], publishedAt: date(9, 22, 9), hasMoreFeed: false) == .afterLast)
    }

    @Test("published after every unit: above the first")
    func placementNewerThanEveryUnit() {
        let list = units([date(9, 22, 8), date(9, 21, 20)])
        #expect(SpotlightPlacement.place(units: list, publishedAt: date(9, 22, 9), hasMoreFeed: true)
                == .beforeUnit(list[0].id))
    }

    @Test("published between units: above the first unit older than it")
    func placementBetweenUnits() {
        let list = units([date(9, 22, 12), date(9, 22, 6), date(9, 21, 20)])
        #expect(SpotlightPlacement.place(units: list, publishedAt: date(9, 22, 9), hasMoreFeed: true)
                == .beforeUnit(list[1].id))
    }

    @Test("older than every loaded unit, more pages to come: not rendered yet")
    func placementOlderWithMorePages() {
        let list = units([date(9, 22, 12), date(9, 22, 10)])
        #expect(SpotlightPlacement.place(units: list, publishedAt: date(9, 20, 9), hasMoreFeed: true) == .notYet)
    }

    @Test("older than every unit and the window is loaded: below the last")
    func placementOlderWithNoMorePages() {
        let list = units([date(9, 22, 12), date(9, 22, 10)])
        #expect(SpotlightPlacement.place(units: list, publishedAt: date(9, 20, 9), hasMoreFeed: false) == .afterLast)
    }

    // MARK: - Slot (the caught-up block)

    @Test("caught up at the top, unseen strip at the first unit: above the block")
    func slotUnseenAboveTopBlock() {
        let ids = ["a", "b", "c"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("a"), seam: .top, unitIds: ids, unseen: true) == .top)
    }

    @Test("caught up at the top, unseen strip deeper in the seen days: still lifted above the block")
    func slotUnseenDeepLiftedToTop() {
        let ids = ["a", "b", "c"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("c"), seam: .top, unitIds: ids, unseen: true) == .top)
    }

    @Test("caught up at the top, seen strip: stays at its own place, below the block")
    func slotSeenBelowTopBlock() {
        let ids = ["a", "b", "c"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("a"), seam: .top, unitIds: ids, unseen: false) == .beforeUnit("a"))
        #expect(SpotlightSlot.slot(placement: .beforeUnit("c"), seam: .top, unitIds: ids, unseen: false) == .beforeUnit("c"))
    }

    @Test("caught up after a unit, unseen strip on the seen side: just above the block")
    func slotUnseenAfterUnitLifted() {
        let ids = ["a", "b", "c", "d"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("d"), seam: .after("b"), unitIds: ids, unseen: true)
                == .aboveCaughtUpBlock(afterUnit: "b"))
        #expect(SpotlightSlot.slot(placement: .afterLast, seam: .after("b"), unitIds: ids, unseen: true)
                == .aboveCaughtUpBlock(afterUnit: "b"))
    }

    @Test("caught up after a unit, unseen strip already on the new side: stays in place")
    func slotUnseenAboveSeamStays() {
        let ids = ["a", "b", "c", "d"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("b"), seam: .after("b"), unitIds: ids, unseen: true)
                == .beforeUnit("b"))
    }

    @Test("caught up after a unit, seen strip on the seen side: stays in place")
    func slotSeenAfterUnitStays() {
        let ids = ["a", "b", "c", "d"]
        #expect(SpotlightSlot.slot(placement: .beforeUnit("d"), seam: .after("b"), unitIds: ids, unseen: false)
                == .beforeUnit("d"))
        #expect(SpotlightSlot.slot(placement: .afterLast, seam: .after("b"), unitIds: ids, unseen: false) == .afterLast)
    }

    @Test("a strip waiting on an unloaded page is hidden, unless it is unseen over a caught-up top")
    func slotNotYetHidden() {
        #expect(SpotlightSlot.slot(placement: .notYet, seam: .none, unitIds: ["a"], unseen: false) == .hidden)
        #expect(SpotlightSlot.slot(placement: .notYet, seam: .none, unitIds: ["a"], unseen: true) == .hidden)
        #expect(SpotlightSlot.slot(placement: .notYet, seam: .top, unitIds: ["a"], unseen: false) == .hidden)
        #expect(SpotlightSlot.slot(placement: .notYet, seam: .after("a"), unitIds: ["a"], unseen: true) == .hidden)
    }

    @Test("unseen on a caught-up feed shows at the reload, never drops in above the reader later")
    func slotUnseenCaughtUpNeverWaits() {
        #expect(SpotlightSlot.slot(placement: .notYet, seam: .top, unitIds: ["a", "b"], unseen: true) == .top)
        #expect(SpotlightSlot.slot(placement: .beforeUnit("gone"), seam: .top, unitIds: ["a"], unseen: true) == .top)
    }

    @Test("an anchor that no longer exists is hidden, never pointed at nothing")
    func slotMissingAnchorHidden() {
        #expect(SpotlightSlot.slot(placement: .beforeUnit("gone"), seam: .none, unitIds: ["a"], unseen: false) == .hidden)
    }

    // MARK: - Menu eligibility

    private let me = UUID()

    @Test("someone else's post never shows the item")
    func menuHiddenForOthers() {
        let other = post(owner: UUID(), createdAt: date(9, 22, 12))
        #expect(SpotlightMenuItem.resolve(post: other, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: true, calendar: newYork) == .hidden)
    }

    @Test("hidden while the server's state is unknown")
    func menuHiddenWhileUnknown() {
        let mine = post(owner: me, createdAt: date(9, 22, 12))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: nil, chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: true, calendar: newYork) == .hidden)
    }

    @Test("an earlier week's post says why it can't go up; past the close hides; the bounds are half-open")
    func menuOutsideTheWeek() {
        let before = post(owner: me, createdAt: date(9, 21, 3, 59))
        let atStart = post(owner: me, createdAt: date(9, 21, 4))
        let atClose = post(owner: me, createdAt: date(9, 28, 4))
        func item(_ p: Post) -> SpotlightMenuItem {
            SpotlightMenuItem.resolve(post: p, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                      isTagged: false, isPhotographer: true, calendar: newYork)
        }
        #expect(item(before) == .disabled(reason: "Only this week's frames can go up"))
        #expect(item(atStart) == .putUp)
        #expect(item(atClose) == .hidden)
    }

    @Test("a covered account sees no item at all")
    func menuHiddenWhenCovered() {
        let mine = post(owner: me, createdAt: date(9, 22, 12))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(canPutUp: false), chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: true, calendar: newYork) == .hidden)
    }

    @Test("the three server states: nothing up, this one up, another one up")
    func menuThreeStates() {
        let mine = post(owner: me, createdAt: date(9, 23, 12))
        let other = UUID()
        // Pinned to Saturday, so neither swap below reads as today or yesterday.
        let now = date(9, 26, 12)
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: true, now: now, calendar: newYork) == .putUp)
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(postId: mine.id, postCreatedAt: mine.createdAt),
                                          chosenWeekKey: nil, isTagged: false, isPhotographer: true, now: now, calendar: newYork) == .takeDown)
        // Tuesday 01:30 files under Monday: the swap names the day the feed shows it on.
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(postId: other, postCreatedAt: date(9, 22, 1, 30)),
                                          chosenWeekKey: nil, isTagged: false, isPhotographer: true, now: now, calendar: newYork)
                == .swap(fromDay: "Monday"))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(postId: other, postCreatedAt: date(9, 22, 14)),
                                          chosenWeekKey: nil, isTagged: false, isPhotographer: true, now: now, calendar: newYork)
                == .swap(fromDay: "Tuesday"))
    }

    @Test("a swap names today and yesterday as such, through the 04:00 boundary")
    func swapTodayYesterday() {
        let mine = post(owner: me, createdAt: date(9, 24, 12))
        let other = UUID()
        let now = date(9, 24, 20)
        func swap(_ replacedAt: Date) -> SpotlightMenuItem {
            SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(postId: other, postCreatedAt: replacedAt),
                                      chosenWeekKey: nil, isTagged: false, isPhotographer: true, now: now, calendar: newYork)
        }
        #expect(swap(date(9, 24, 9)) == .swap(fromDay: "today"))
        // 02:00 on the 24th files under the 23rd.
        #expect(swap(date(9, 24, 2)) == .swap(fromDay: "yesterday"))
        #expect(swap(date(9, 23, 15)) == .swap(fromDay: "yesterday"))
        #expect(swap(date(9, 22, 15)) == .swap(fromDay: "Tuesday"))
    }

    @Test("another frame up with no posting time offers nothing, never a plain put-up")
    func menuHiddenWhenReplacedTimeUnknown() {
        let mine = post(owner: me, createdAt: date(9, 23, 12))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(postId: UUID(), postCreatedAt: nil),
                                          chosenWeekKey: nil, isTagged: false, isPhotographer: true, calendar: newYork) == .hidden)
    }

    @Test("the put-up capsule names a swapped-out frame by its day")
    func putUpCapsule() {
        let mine = post(owner: me, createdAt: date(9, 24, 12))
        let now = date(9, 24, 20)
        let plain = SpotlightPutUpCapsule.text(previous: entry(), post: mine, now: now, calendar: newYork)
        #expect(plain.title == "Up for Spotlight")
        let swapped = SpotlightPutUpCapsule.text(previous: entry(postId: UUID(), postCreatedAt: date(9, 22, 14)),
                                                 post: mine, now: now, calendar: newYork)
        #expect(swapped.title == "Swapped into Spotlight")
        #expect(swapped.subtitle == "Your frame from Tuesday came down")
        let today = SpotlightPutUpCapsule.text(previous: entry(postId: UUID(), postCreatedAt: date(9, 24, 9)),
                                               post: mine, now: now, calendar: newYork)
        #expect(today.subtitle == "Your frame from today came down")
    }

    @Test("tagging is off while a frame is up this week or chosen, with the reason")
    func tagLock() {
        let postId = UUID()
        #expect(SpotlightTagLock.reason(postId: postId, entry: entry(), chosen: [:]) == nil)
        #expect(SpotlightTagLock.reason(postId: postId, entry: entry(postId: postId), chosen: [:])
                == "Take it down from Spotlight to tag people")
        #expect(SpotlightTagLock.reason(postId: postId, entry: entry(), chosen: [postId: "2026-09-14"])
                == "Frames put up for Spotlight can't be tagged")
        #expect(SpotlightTagLock.reason(postId: postId, entry: nil, chosen: [:]) == nil)
    }

    @Test("tagged and not-shot-by-you frames are disabled with their reason")
    func menuDisabledReasons() {
        let mine = post(owner: me, createdAt: date(9, 23, 12))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                          isTagged: true, isPhotographer: true, calendar: newYork)
                == .disabled(reason: "Frames with people tagged can't go up"))
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: false, calendar: newYork)
                == .disabled(reason: "Only frames you shot can go up"))
        // Unknown photographer offers the item; the server refuses by name if it must.
        #expect(SpotlightMenuItem.resolve(post: mine, viewerId: me, entry: entry(), chosenWeekKey: nil,
                                          isTagged: false, isPhotographer: nil, calendar: newYork) == .putUp)
    }

    @Test("your own published frame offers taking it out, whatever week it was")
    func menuTakeOut() {
        let old = post(owner: me, createdAt: date(9, 1, 12))
        #expect(SpotlightMenuItem.resolve(post: old, viewerId: me, entry: entry(), chosenWeekKey: "2026-08-31",
                                          isTagged: false, isPhotographer: true, calendar: newYork)
                == .takeOut(weekKey: "2026-08-31"))
    }

    // MARK: - Refusals

    @Test("each refusal speaks in words, and anything unnamed reads as the connection")
    func refusalMessages() {
        #expect(SpotlightRefusal.message(refusal: "week_closed", action: .putUp)
                == "This week closed before your frame went up.")
        #expect(SpotlightRefusal.message(refusal: "tagged", action: .putUp) == "Frames with people tagged can't go up")
        #expect(SpotlightRefusal.message(refusal: "not_photographer", action: .putUp) == "Only frames you shot can go up")
        #expect(SpotlightRefusal.message(refusal: "hidden", action: .putUp) == "This frame can't go up.")
        #expect(SpotlightRefusal.message(refusal: "covered", action: .putUp) == "This frame can't go up.")
        #expect(SpotlightRefusal.message(refusal: "not_found", action: .putUp) == "This frame can't go up.")
        #expect(SpotlightRefusal.message(refusal: nil, action: .putUp)
                == "Couldn't put it up. Check your connection and try again.")
        #expect(SpotlightRefusal.message(refusal: "week_closed", action: .takeDown)
                == "This week has closed, so it can't come down now.")
        // Already down: nothing to say, the caller only reads the entry again.
        #expect(SpotlightRefusal.message(refusal: "not_found", action: .takeDown) == nil)
        #expect(SpotlightRefusal.message(refusal: nil, action: .takeDown)
                == "Couldn't take it down. Check your connection and try again.")
    }

    @Test("no Spotlight copy uses an em dash or an exclamation mark")
    func copyRules() {
        let lines = [SpotlightRefusal.weekClosedPutUp, SpotlightRefusal.weekClosedTakeDown,
                     SpotlightRefusal.cantGoUp, SpotlightRefusal.putUpNetwork,
                     SpotlightMenuItem.earlierWeekReason, SpotlightTagLock.upThisWeek, SpotlightTagLock.chosen,
                     SpotlightRefusal.takeDownNetwork, SpotlightRefusal.takeOutNetwork,
                     SpotlightRefusal.taggedOnSpotlight, SpotlightRefusal.gone, SpotlightRefusal.openNetwork,
                     SpotlightMenuItem.taggedReason, SpotlightMenuItem.notPhotographerReason,
                     ProfileBadgeKind.spotlight.explanation, ProfileBadgeKind.spotlight.howToEarn]
        for line in lines {
            #expect(!line.contains("\u{2014}"), "\(line)")
            #expect(!line.contains("!"), "\(line)")
        }
    }

    // MARK: - Push rider

    @Test("feed with a week rider opens that week's sheet")
    func parseWithRider() {
        let info: [AnyHashable: Any] = ["flim": ["t": "feed", "week": "2026-09-21"]]
        #expect(PushDestination.parse(userInfo: info) == .spotlightWeek(weekKey: "2026-09-21"))
    }

    @Test("feed without a rider is the plain feed, as before")
    func parseWithoutRider() {
        let info: [AnyHashable: Any] = ["flim": ["t": "feed"]]
        #expect(PushDestination.parse(userInfo: info) == .feed)
    }

    @Test("a malformed rider still opens the feed")
    func parseMalformedRider() {
        #expect(PushDestination.parse(userInfo: ["flim": ["t": "feed", "week": "soon"]]) == .feed)
        #expect(PushDestination.parse(userInfo: ["flim": ["t": "feed", "week": 7]]) == .feed)
    }

    @Test("the wire value round-trips through parse")
    func wireRoundTrip() {
        let destination = PushDestination.spotlightWeek(weekKey: "2026-09-14")
        #expect(PushDestination.parse(userInfo: ["flim": destination.wireValue]) == destination)
    }

    @Test("a .feed persisted by an older build still decodes, and the new case survives the store")
    func persistedDecoding() throws {
        let legacy = try JSONEncoder().encode(PushDestination.feed)
        #expect(try JSONDecoder().decode(PushDestination.self, from: legacy) == .feed)
        let week = try JSONEncoder().encode(PushDestination.spotlightWeek(weekKey: "2026-09-14"))
        #expect(try JSONDecoder().decode(PushDestination.self, from: week) == .spotlightWeek(weekKey: "2026-09-14"))
    }

    // MARK: - Week labels

    @Test("the week's words come from the string, the same in Los Angeles and Makassar")
    func weekLabelsAcrossZones() {
        for zone in ["America/Los_Angeles", "Asia/Makassar", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let cal = Self.calendar(zone)
            #expect(SpotlightWeekLabel.phrase("2026-09-14", calendar: cal) == "the week of September 14", "\(zone)")
            #expect(SpotlightWeekLabel.sentence("2026-09-14", calendar: cal) == "The week of September 14", "\(zone)")
            #expect(SpotlightWeekLabel.shortSentence("2026-09-14", calendar: cal) == "The week of Sep 14", "\(zone)")
            #expect(SpotlightWeekLabel.rule("2026-09-14", calendar: cal) == "THE WEEK OF SEPTEMBER 14", "\(zone)")
        }
    }

    @Test("an unreadable key is shown as itself, never as an invented date")
    func weekLabelFallback() {
        #expect(SpotlightWeekLabel.monthDay("soon", calendar: newYork) == "soon")
        #expect(SpotlightWeekLabel.components("2026-13-01") == nil)
    }

    // MARK: - The write queue's revision rule

    /// Main-actor state the queued closures write to (the closures are main-actor too).
    @MainActor private final class Recorder {
        var screen = "before"
        var reverted = false
        var order: [Int] = []
    }

    /// A door a queued write waits at until the test opens it: ordering by an explicit
    /// signal, never by how long a sleep happened to take on a loaded runner.
    @MainActor private final class Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            let pending = waiters
            waiters = []
            for waiter in pending { waiter.resume() }
        }
    }

    @Test("a failure that lands after a newer intent does not revert the screen")
    func revisionRuleSkipsStaleRevert() async {
        let queue = RevisionedWriteQueue()
        let recorder = Recorder()
        let failureLands = Gate()
        let first = queue.claim()
        recorder.screen = "A"
        let firstWrite = queue.submit {
            await failureLands.wait()
            // The write failed; roll back only if this intent still owns the screen.
            if queue.isCurrent(first) {
                recorder.screen = "before"
                recorder.reverted = true
            }
            queue.settle(first)
        }
        // The newer intent takes the screen while the first write is still on the wire.
        let second = queue.claim()
        recorder.screen = "B"
        #expect(!queue.isQuiet)
        failureLands.open()
        await firstWrite.value
        #expect(!recorder.reverted)
        #expect(recorder.screen == "B")
        #expect(!queue.isSettled)
        await queue.enqueue { queue.settle(second) }
        #expect(queue.isQuiet)
    }

    @Test("a late failure behind an intent that already resolved sees the queue settled")
    func lateFailureAfterUndoIsSettled() async {
        let queue = RevisionedWriteQueue()
        let failureLands = Gate()
        let first = queue.claim()
        var settledAtFailure: Bool?
        let firstWrite = queue.submit {
            await failureLands.wait()
            queue.settle(first)
            if !queue.isCurrent(first) { settledAtFailure = queue.isSettled }
        }
        // A newer intent staged and undone inside its window: resolved without ever running.
        let undone = queue.claim()
        queue.settle(undone)
        failureLands.open()
        await firstWrite.value
        #expect(settledAtFailure == true)
    }

    @Test("a failure that is still the current intent reverts")
    func revisionRuleRevertsCurrent() async {
        let queue = RevisionedWriteQueue()
        let recorder = Recorder()
        recorder.screen = "A"
        let only = queue.claim()
        await queue.enqueue {
            if queue.isCurrent(only) { recorder.screen = "before" }
            queue.settle(only)
        }
        #expect(recorder.screen == "before")
        #expect(queue.isQuiet)
    }

    @Test("writes run one at a time, in the order they were asked for")
    func queueSerializes() async {
        let queue = RevisionedWriteQueue()
        let recorder = Recorder()
        let release = Gate()
        // Both are in line before either runs; the first is held until the second is queued,
        // so the second could only finish first if the queue let it jump.
        let slow = queue.submit {
            await release.wait()
            recorder.order.append(1)
        }
        let fast = queue.submit { recorder.order.append(2) }
        // Give a queue that failed to serialize every chance to run the second write early.
        // The assertion never depends on these: a correct queue passes however they go.
        for _ in 0..<10 { await Task.yield() }
        #expect(recorder.order.isEmpty)
        release.open()
        await slow.value
        await fast.value
        #expect(recorder.order == [1, 2])
    }

    @Test("an optimistic intent not yet enqueued (the undo window) keeps the queue unquiet")
    func claimedButUnsettledIsNotQuiet() {
        let queue = RevisionedWriteQueue()
        let staged = queue.claim()
        #expect(!queue.isQuiet)
        queue.settle(staged)
        #expect(queue.isQuiet)
        _ = queue.claim()
        queue.reset()
        #expect(queue.isQuiet)
    }

    // MARK: - Activity count

    @Test("only your own frames, only weeks published after the watermark")
    func activityCount() {
        let since = date(9, 20, 12)
        let weeks = [
            week("2026-09-14", publishedAt: date(9, 22, 9), frames: [frame(user: me), frame()]),
            week("2026-09-07", publishedAt: date(9, 15, 9), frames: [frame(user: me)]),
            week("2026-08-31", publishedAt: date(9, 21, 9), frames: [frame()]),
        ]
        #expect(SpotlightActivity.unreadCount(weeks: weeks, ownId: me, since: since) == 1)
        #expect(SpotlightActivity.ownFrames(in: weeks, ownId: me).count == 2)
    }

    // MARK: - Pruning and blocks

    @Test("a pruned frame leaves its week; an emptied week leaves the list")
    func pruning() {
        let goneId = UUID()
        let weeks = [
            week("2026-09-14", publishedAt: date(9, 22, 9), frames: [frame(postId: goneId)]),
            week("2026-09-07", publishedAt: date(9, 15, 9), frames: [frame(postId: goneId), frame()]),
        ]
        let pruned = SpotlightWeek.pruned(weeks) { $0.postId == goneId }
        #expect(pruned.map(\.weekKey) == ["2026-09-07"])
        #expect(pruned.first?.frames.count == 1)
    }

    @Test("a week whose frames are all blocked is hidden")
    func blockedWeekHidden() {
        let blocked = UUID()
        let weeks = [
            week("2026-09-14", publishedAt: date(9, 22, 9), frames: [frame(user: blocked)]),
            week("2026-09-07", publishedAt: date(9, 15, 9), frames: [frame(user: blocked), frame()]),
        ]
        let visible = SpotlightWeek.visible(weeks, blocked: [blocked])
        #expect(visible.map(\.weekKey) == ["2026-09-07"])
        #expect(visible.first?.frames.count == 1)
    }

    @Test("a frame signs its thumbnail, else the mid-size rendition, never the master")
    func framePathNeverMaster() {
        #expect(frame(thumb: "t.jpg", feed: "f.jpg").cardPath == "t.jpg")
        #expect(frame(thumb: nil, feed: "f.jpg").cardPath == "f.jpg")
        #expect(frame(thumb: nil, feed: nil).cardPath == nil)
    }

    // MARK: - Decoding

    @Test("week_key decodes as the server's string, never a date")
    func weekKeyIsAString() throws {
        let json = """
        [{"week_key":"2026-09-14","published_at":"2026-09-22T13:00:00Z","frames":[]}]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let weeks = try decoder.decode([SpotlightWeek].self, from: Data(json.utf8))
        #expect(weeks.first?.weekKey == "2026-09-14")
    }

    // MARK: - Badge

    @Test("the Spotlight badge: gold, the flashlight, never in a locked list")
    func badge() {
        let kind = ProfileBadgeKind(rawValue: "spotlight")
        #expect(kind == .spotlight)
        #expect(ProfileBadgeKind.spotlight.tier == .gold)
        #expect(ProfileBadgeKind.spotlight.isEarnable == false)
        #expect(ProfileBadgeKind.spotlight.emoji == "\u{1F526}")
        #expect(ProfileBadgeKind.spotlight.label == "Spotlight")
        #expect(ProfileBadgeKind.spotlight.explanation == "One of your frames was in Spotlight.")
    }

    // MARK: - Per-account marks

    @Test("the first-time sheet and the seen weeks are per account")
    func perAccountMarks() {
        let suite = "SpotlightTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("no defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let previousFirst = SpotlightFirstTime.store
        let previousSeen = SpotlightSeenMark.store
        SpotlightFirstTime.store = defaults
        SpotlightSeenMark.store = defaults
        defer {
            SpotlightFirstTime.store = previousFirst
            SpotlightSeenMark.store = previousSeen
        }
        let a = UUID(), b = UUID()
        #expect(!SpotlightFirstTime.hasSeen(userId: a))
        SpotlightFirstTime.markSeen(userId: a)
        #expect(SpotlightFirstTime.hasSeen(userId: a))
        #expect(!SpotlightFirstTime.hasSeen(userId: b))

        SpotlightSeenMark.mark("2026-09-14", userId: a)
        #expect(SpotlightSeenMark.seen(userId: a) == ["2026-09-14"])
        #expect(SpotlightSeenMark.seen(userId: b).isEmpty)
        #expect(SpotlightSeenMark.seen(userId: nil).isEmpty)
    }
}

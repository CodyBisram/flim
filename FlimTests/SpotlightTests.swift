import Testing
import Foundation
@testable import Flim

/// Spotlight's pure rules: where the strip sits, which menu item a post gets, the push rider,
/// the week's words in other zones and calendars, the notices, and the Activity count.
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

    // MARK: - Snapshot across a page load

    private func items(_ times: [Date]) -> [FeedItem] {
        times.map { time in
            let author = profile()
            return FeedItem(post: post(owner: author.id, createdAt: time), author: author)
        }
    }

    @Test("an unseen strip older than every loaded unit, seam after a unit: a page load places it at its own place, never above the reader")
    func snapshotGrowOnlyNeverLifts() {
        let firstPage = items([date(9, 22, 12), date(9, 22, 10), date(9, 21, 20)])
        let pageOne = FeedUnit.units(from: firstPage, calendar: newYork)
        let seamUnit = pageOne[0].id
        let old = week("2026-09-14", publishedAt: date(9, 20, 9), frames: [frame()])
        // The reload: the strip's place is below a page not loaded yet.
        let atReload = SpotlightSlot.snapshot(previous: [:], weeks: [old], units: pageOne, seam: .after(seamUnit),
                                              hasMoreFeed: true, seen: [], growOnly: false)
        #expect(atReload[old.weekKey] == .hidden)
        // The next page lands with a unit older than the publish instant. The strip is still
        // unseen, and its place is on the seen side of the seam, but lifting it now would drop
        // it in above someone already reading.
        let pageTwo = FeedUnit.units(from: firstPage + items([date(9, 19, 20)]), calendar: newYork)
        let olderUnit = pageTwo[3].id
        let afterPage = SpotlightSlot.snapshot(previous: atReload, weeks: [old], units: pageTwo, seam: .after(seamUnit),
                                               hasMoreFeed: true, seen: [], growOnly: true)
        #expect(afterPage[old.weekKey] == .beforeUnit(olderUnit))
        // The window fully loaded with nothing older: below the last unit, still not lifted.
        let lastPage = SpotlightSlot.snapshot(previous: atReload, weeks: [old], units: pageOne, seam: .after(seamUnit),
                                              hasMoreFeed: false, seen: [], growOnly: true)
        #expect(lastPage[old.weekKey] == .afterLast)
    }

    @Test("a full snapshot still lifts an unseen strip over the seam, and a grow-only pass keeps it there")
    func snapshotFullLiftsAndHolds() {
        let pageOne = FeedUnit.units(from: items([date(9, 22, 12), date(9, 22, 10), date(9, 21, 20)]), calendar: newYork)
        let seamUnit = pageOne[0].id
        let recent = week("2026-09-14", publishedAt: date(9, 21, 22), frames: [frame()])
        let atReload = SpotlightSlot.snapshot(previous: [:], weeks: [recent], units: pageOne, seam: .after(seamUnit),
                                              hasMoreFeed: true, seen: [], growOnly: false)
        #expect(atReload[recent.weekKey] == .aboveCaughtUpBlock(afterUnit: seamUnit))
        let held = SpotlightSlot.snapshot(previous: atReload, weeks: [recent], units: pageOne, seam: .after(seamUnit),
                                          hasMoreFeed: true, seen: [recent.weekKey], growOnly: true)
        #expect(held[recent.weekKey] == .aboveCaughtUpBlock(afterUnit: seamUnit))
    }

    @Test("a grow-only pass re-places a strip whose anchor unit left, at its own place")
    func snapshotOrphanReplacedInPlace() {
        let pageOne = FeedUnit.units(from: items([date(9, 22, 12), date(9, 22, 10), date(9, 21, 20)]), calendar: newYork)
        let strip = week("2026-09-14", publishedAt: date(9, 22, 11), frames: [frame()])
        let previous = [strip.weekKey: SpotlightSlot.aboveCaughtUpBlock(afterUnit: "gone")]
        let next = SpotlightSlot.snapshot(previous: previous, weeks: [strip], units: pageOne, seam: .top,
                                          hasMoreFeed: true, seen: [], growOnly: true)
        #expect(next[strip.weekKey] == .beforeUnit(pageOne[1].id))
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

    @Test("the put-up notice: a plain line, or a swap that names the frame's day")
    func putUpNotice() {
        let postId = UUID()
        let now = date(9, 24, 20)
        #expect(SpotlightPutUpNotice.text(postId: postId, replacedPostId: nil, replacedAt: nil, now: now, calendar: newYork)
                == "Up for Spotlight. Only the team at \(AppInfo.appName) sees it.")
        // The server naming the same post is a re-put-up, not a swap.
        #expect(SpotlightPutUpNotice.text(postId: postId, replacedPostId: postId, replacedAt: date(9, 22, 14),
                                          now: now, calendar: newYork)
                == "Up for Spotlight. Only the team at \(AppInfo.appName) sees it.")
        #expect(SpotlightPutUpNotice.text(postId: postId, replacedPostId: UUID(), replacedAt: date(9, 22, 14),
                                          now: now, calendar: newYork)
                == "Swapped into Spotlight. Your frame from Tuesday came down.")
        #expect(SpotlightPutUpNotice.text(postId: postId, replacedPostId: UUID(), replacedAt: date(9, 24, 9),
                                          now: now, calendar: newYork)
                == "Swapped into Spotlight. Your frame from today came down.")
        #expect(SpotlightPutUpNotice.text(postId: postId, replacedPostId: UUID(), replacedAt: date(9, 23, 15),
                                          now: now, calendar: newYork)
                == "Swapped into Spotlight. Your frame from yesterday came down.")
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

    @Test("the closed, unpublished week's frame can come down until publish; the others still say why not")
    func menuPendingTakeDown() {
        let pending = post(owner: me, createdAt: date(9, 17, 12))
        let other = post(owner: me, createdAt: date(9, 18, 12))
        var withPending = entry()
        withPending.pendingWeekKey = "2026-09-14"
        withPending.pendingPostId = pending.id
        withPending.pendingPhotoId = pending.photoId
        func item(_ p: Post, _ e: OwnSpotlightEntry) -> SpotlightMenuItem {
            SpotlightMenuItem.resolve(post: p, viewerId: me, entry: e, chosenWeekKey: nil,
                                      isTagged: false, isPhotographer: true, calendar: newYork)
        }
        #expect(item(pending, withPending) == .takeDownPending(weekKey: "2026-09-14"))
        #expect(item(other, withPending) == .disabled(reason: "Only this week's frames can go up"))
        // Consent holds even while this week allows nothing new.
        var covered = entry(canPutUp: false)
        covered.pendingWeekKey = "2026-09-14"
        covered.pendingPostId = pending.id
        covered.pendingPhotoId = pending.photoId
        #expect(item(pending, covered) == .takeDownPending(weekKey: "2026-09-14"))
        // Chosen and published wins: that is a take-out, not a take-down.
        #expect(SpotlightMenuItem.resolve(post: pending, viewerId: me, entry: withPending, chosenWeekKey: "2026-09-14",
                                          isTagged: false, isPhotographer: true, calendar: newYork)
                == .takeOut(weekKey: "2026-09-14"))
        // A take-down clears only the week it came down from.
        #expect(withPending.clearingPending(postId: pending.id).pendingPostId == nil)
        #expect(withPending.clearingPending(postId: pending.id).pending.isEmpty)
        #expect(withPending.clearingPending(postId: pending.id).weekKey == withPending.weekKey)
        #expect(withPending.clearingPending(postId: other.id).pendingPostId == pending.id)
        #expect(withPending.cleared.pendingPostId == pending.id)
        // Deletes match the pending frame by post id and by photo id.
        #expect(withPending.holds(postId: pending.id))
        #expect(withPending.holds(photoIdIn: [pending.photoId]))
        #expect(!withPending.holds(photoIdIn: [other.photoId]))
    }

    @Test("the pending subtitle names the week, never a weekday")
    func pendingSubtitleWords() {
        #expect("Until the team publishes \(SpotlightWeekLabel.phrase("2026-09-14", calendar: newYork))"
                == "Until the team publishes the week of September 14")
    }

    @Test("caption editing is off while a frame is up this week or chosen, with the reason")
    func captionLock() {
        let postId = UUID()
        #expect(SpotlightCaptionLock.reason(postId: postId, entry: entry(), chosen: [:]) == nil)
        #expect(SpotlightCaptionLock.reason(postId: postId, entry: entry(postId: postId), chosen: [:])
                == "Take it down from Spotlight to edit the caption")
        #expect(SpotlightCaptionLock.reason(postId: postId, entry: entry(), chosen: [postId: "2026-09-14"])
                == "Frames put up for Spotlight can't be edited")
        #expect(SpotlightCaptionLock.reason(postId: postId, entry: nil, chosen: [:]) == nil)
        #expect(SpotlightRefusal.captionOnSpotlight == "Frames put up for Spotlight can't be edited.")
    }

    @Test("a refused caption save keeps the old caption on screen, like any failure")
    func captionOutcomeMapping() {
        #expect(CaptionSaveOutcome.saved.saved == true)
        #expect(CaptionSaveOutcome.failed.saved == false)
        #expect(CaptionSaveOutcome.refusedInSpotlight.saved == false)
        #expect(CaptionSaveOutcome.cancelled.saved == nil)
        #expect(resolvedCaption(afterSaving: CaptionSaveOutcome.refusedInSpotlight.saved,
                                attempted: "new", previous: "old") == "old")
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
                     ProfileBadgeKind.spotlight.explanation, ProfileBadgeKind.spotlight.howToEarn,
                     SpotlightCaptionLock.upThisWeek, SpotlightCaptionLock.chosen,
                     SpotlightRefusal.captionOnSpotlight, SpotlightPostedHint.text,
                     SpotlightPutUpNotice.text(postId: UUID(), replacedPostId: nil, replacedAt: nil),
                     SpotlightPutUpNotice.text(postId: UUID(), replacedPostId: UUID(), replacedAt: nil)]
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

    @Test("the week's words are Gregorian whatever calendar the phone is set to")
    func weekLabelsAcrossCalendars() {
        let identifiers: [Calendar.Identifier] = [.persian, .islamic, .islamicUmmAlQura, .hebrew, .buddhist, .japanese]
        for identifier in identifiers {
            for zone in ["Asia/Tehran", "America/Los_Angeles", "Pacific/Kiritimati"] {
                var cal = Calendar(identifier: identifier)
                cal.timeZone = TimeZone(identifier: zone) ?? .gmt
                #expect(SpotlightWeekLabel.phrase("2026-09-14", calendar: cal) == "the week of September 14", "\(identifier) \(zone)")
                #expect(SpotlightWeekLabel.shortSentence("2026-09-14", calendar: cal) == "The week of Sep 14", "\(identifier) \(zone)")
                #expect(SpotlightWeekLabel.rule("2026-09-14", calendar: cal) == "THE WEEK OF SEPTEMBER 14", "\(identifier) \(zone)")
            }
        }
        // The swap's weekday is the same day under a Persian or Islamic calendar.
        for identifier in [Calendar.Identifier.persian, .islamic] {
            var cal = Calendar(identifier: identifier)
            cal.timeZone = newYork.timeZone
            #expect(SpotlightMenuItem.weekday(of: date(9, 22, 14), calendar: cal) == "Tuesday", "\(identifier)")
        }
    }

    @Test("formatters are built once per pattern and zone")
    func formattersCached() {
        let zone = TimeZone(identifier: "Asia/Makassar") ?? .gmt
        let first = SpotlightDateFormatters.formatter("MMMM d", zone: zone)
        let second = SpotlightDateFormatters.formatter("MMMM d", zone: zone)
        #expect(first === second)
        #expect(first !== SpotlightDateFormatters.formatter("MMM d", zone: zone))
        #expect(first.calendar.identifier == .gregorian)
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

    @Test("the own entry decodes with and without the pending fields")
    func ownEntryPendingDecoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let before = """
        [{"week_key":"2026-09-21","week_starts_at":"2026-09-21T08:00:00Z","week_closes_at":"2026-09-28T08:00:00Z",
          "can_put_up":true,"post_id":null,"photo_id":null,"post_created_at":null,"put_up_at":null}]
        """
        let old = try decoder.decode([OwnSpotlightEntry].self, from: Data(before.utf8))
        #expect(old.first?.pendingPostId == nil)
        #expect(old.first?.pendingWeekKey == nil)
        let postId = UUID(), photoId = UUID()
        let after = """
        [{"week_key":"2026-09-21","week_starts_at":"2026-09-21T08:00:00Z","week_closes_at":"2026-09-28T08:00:00Z",
          "can_put_up":true,"post_id":null,"photo_id":null,"post_created_at":null,"put_up_at":null,
          "pending_week_key":"2026-09-14","pending_post_id":"\(postId.uuidString)","pending_photo_id":"\(photoId.uuidString)"}]
        """
        let new = try decoder.decode([OwnSpotlightEntry].self, from: Data(after.utf8))
        #expect(new.first?.pendingWeekKey == "2026-09-14")
        #expect(new.first?.pendingPostId == postId)
        #expect(new.first?.pendingPhotoId == photoId)
        #expect(new.first?.pending == [PendingSpotlightEntry(weekKey: "2026-09-14", postId: postId, photoId: photoId)])
    }

    @Test("the base shape, with no pending columns at all, reads as nothing waiting")
    func ownEntryBaseShapeDecoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let postId = UUID(), photoId = UUID()
        let base = """
        [{"week_key":"2026-09-21","week_starts_at":"2026-09-21T08:00:00Z","week_closes_at":"2026-09-28T08:00:00Z",
          "can_put_up":true,"post_id":"\(postId.uuidString)","photo_id":"\(photoId.uuidString)",
          "post_created_at":"2026-09-22T12:00:00Z","put_up_at":"2026-09-22T12:05:00Z"}]
        """
        let rows = try decoder.decode([OwnSpotlightEntry].self, from: Data(base.utf8))
        #expect(rows.first?.postId == postId)
        #expect(rows.first?.pendingEntries == nil)
        #expect(rows.first?.pending.isEmpty == true)
        #expect(rows.first?.holds(postId: postId) == true)
    }

    @Test("the hardened shape carries every waiting week, and pending_entries wins over the single fields")
    func ownEntryHardenedShapeDecoding() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let newerPost = UUID(), newerPhoto = UUID(), olderPost = UUID(), olderPhoto = UUID()
        let hardened = """
        [{"week_key":"2026-09-21","week_starts_at":"2026-09-21T08:00:00Z","week_closes_at":"2026-09-28T08:00:00Z",
          "can_put_up":true,"post_id":null,"photo_id":null,"post_created_at":null,"put_up_at":null,
          "pending_week_key":"2026-09-14","pending_post_id":"\(newerPost.uuidString)",
          "pending_photo_id":"\(newerPhoto.uuidString)",
          "pending_entries":[
            {"week_key":"2026-09-14","post_id":"\(newerPost.uuidString)","photo_id":"\(newerPhoto.uuidString)"},
            {"week_key":"2026-09-07","post_id":"\(olderPost.uuidString)","photo_id":"\(olderPhoto.uuidString)"}]}]
        """
        let rows = try decoder.decode([OwnSpotlightEntry].self, from: Data(hardened.utf8))
        let entry = try #require(rows.first)
        #expect(entry.pending.map(\.weekKey) == ["2026-09-14", "2026-09-07"])
        #expect(entry.pendingEntry(for: olderPost)?.photoId == olderPhoto)
        #expect(entry.holds(postId: olderPost))
        #expect(entry.holds(photoIdIn: [olderPhoto]))
        // Taking the older week down leaves the newer one waiting, and vice versa.
        #expect(entry.clearingPending(postId: olderPost).pending.map(\.postId) == [newerPost])
        let newerDown = entry.clearingPending(postId: newerPost)
        #expect(newerDown.pending.map(\.postId) == [olderPost])
        #expect(newerDown.pendingPostId == nil)

        // An empty list is authoritative: nothing waiting, whatever else is on the row.
        let none = """
        [{"week_key":"2026-09-21","week_starts_at":"2026-09-21T08:00:00Z","week_closes_at":"2026-09-28T08:00:00Z",
          "can_put_up":true,"post_id":null,"photo_id":null,"post_created_at":null,"put_up_at":null,
          "pending_week_key":null,"pending_post_id":null,"pending_photo_id":null,"pending_entries":[]}]
        """
        let empty = try decoder.decode([OwnSpotlightEntry].self, from: Data(none.utf8))
        #expect(empty.first?.pendingEntries == [])
        #expect(empty.first?.pending.isEmpty == true)
    }

    @Test("an older waiting week's frame offers take-down too, not only the newest")
    func menuTakeDownOlderPendingWeek() {
        let newer = post(owner: me, createdAt: date(9, 17, 12))
        let older = post(owner: me, createdAt: date(9, 9, 12))
        let unrelated = post(owner: me, createdAt: date(9, 10, 12))
        var withTwo = entry()
        withTwo.pendingWeekKey = "2026-09-14"
        withTwo.pendingPostId = newer.id
        withTwo.pendingPhotoId = newer.photoId
        withTwo.pendingEntries = [
            PendingSpotlightEntry(weekKey: "2026-09-14", postId: newer.id, photoId: newer.photoId),
            PendingSpotlightEntry(weekKey: "2026-09-07", postId: older.id, photoId: older.photoId),
        ]
        func item(_ p: Post, _ e: OwnSpotlightEntry) -> SpotlightMenuItem {
            SpotlightMenuItem.resolve(post: p, viewerId: me, entry: e, chosenWeekKey: nil,
                                      isTagged: false, isPhotographer: true, calendar: newYork)
        }
        #expect(item(newer, withTwo) == .takeDownPending(weekKey: "2026-09-14"))
        #expect(item(older, withTwo) == .takeDownPending(weekKey: "2026-09-07"))
        #expect(item(unrelated, withTwo) == .disabled(reason: "Only this week's frames can go up"))
        // Still offered inside a covered window.
        var covered = entry(canPutUp: false)
        covered.pendingEntries = withTwo.pendingEntries
        #expect(item(older, covered) == .takeDownPending(weekKey: "2026-09-07"))
        // Once the older week comes down, only the newer one is offered.
        let afterTakeDown = withTwo.clearingPending(postId: older.id)
        #expect(item(older, afterTakeDown) == .disabled(reason: "Only this week's frames can go up"))
        #expect(item(newer, afterTakeDown) == .takeDownPending(weekKey: "2026-09-14"))
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

    @Test("the posted line: once per account, only for a post that could go up")
    func postedHint() {
        let suite = "SpotlightTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("no defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let previous = SpotlightPostedHint.store
        SpotlightPostedHint.store = defaults
        defer { SpotlightPostedHint.store = previous }
        let a = UUID(), b = UUID()
        let now = date(9, 23, 12)
        func show(_ user: UUID, owner: UUID? = nil, tagged: Bool = false,
                  entry e: OwnSpotlightEntry? = nil, at time: Date? = nil) -> Bool {
            SpotlightPostedHint.shouldShow(userId: user, photoOwnerId: owner ?? user, isTagged: tagged,
                                           entry: e ?? entry(), postedAt: time ?? now)
        }
        #expect(show(a))
        #expect(!show(a, owner: UUID()))
        #expect(!show(a, tagged: true))
        #expect(!show(a, entry: entry(canPutUp: false)))
        #expect(!show(a, at: date(9, 28, 5)))
        #expect(!SpotlightPostedHint.shouldShow(userId: a, photoOwnerId: a, isTagged: false, entry: nil, postedAt: now))
        // Another frame already up still leaves this one able to swap in.
        #expect(show(a, entry: entry(postId: UUID(), postCreatedAt: date(9, 22, 12))))
        SpotlightPostedHint.markShown(userId: a)
        #expect(!show(a))
        #expect(show(b))
    }
}

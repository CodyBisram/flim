import Foundation
import Supabase

/// Spotlight's reads and writes. State lives on `FeedService` itself (see its "Spotlight
/// state" block); this file is the only place that changes it.
///
/// Every write that follows an `await` is guarded by the account epoch AND the generation of the
/// cache it writes, one guard per write, so a load that lands after an account switch, or after
/// a newer load of the same cache, is dropped rather than written.
extension FeedService {

    /// Weeks per page of the sheet of past weeks and of Activity's read.
    static let spotlightPageSize = 12
    /// A shelf is one page of up to a year of weeks.
    static let spotlightShelfLimit = 52
    /// The strip never needs more than a few: only weeks published inside the feed's window.
    static let spotlightStripLimit = 6

    // MARK: - Reads (no state)

    /// One page of published weeks, newest first: everyone's (`userId` nil, the strip and the
    /// sheet) or one person's chosen frames (a shelf, Activity). nil on failure, distinct from
    /// an empty page, so a dropped request never reads as "nothing chosen".
    func fetchSpotlightWeeks(userId: UUID?, before: String?, limit: Int) async -> [SpotlightWeek]? {
        struct Published: Encodable { let p_before: String?; let p_limit: Int }
        struct Frames: Encodable { let p_user_id: UUID; let p_before: String?; let p_limit: Int }
        #if DEBUG
        if let demo = SpotlightPreviewDemo.weeks(userId: userId, before: before, limit: limit) { return demo }
        #endif
        do {
            if let userId {
                return try await supabase
                    .rpc("spotlight_frames", params: Frames(p_user_id: userId, p_before: before, p_limit: limit))
                    .execute().value
            }
            return try await supabase
                .rpc("spotlight_published", params: Published(p_before: before, p_limit: limit))
                .execute().value
        } catch {
            return nil
        }
    }

    /// This week's bounds and entry. nil on failure (and with no session), never a guess.
    func fetchOwnSpotlightEntry() async -> OwnSpotlightEntry? {
        #if DEBUG
        if let demo = SpotlightPreviewDemo.data { return demo.entry }
        #endif
        let rows: [OwnSpotlightEntry]? = try? await supabase.rpc("own_spotlight_entry").execute().value
        return rows?.first
    }

    /// One batch of signed URLs for a page of weeks, keyed by exactly the path signed. Asks for
    /// every path, including ones already in `spotlightURLs`: `signedURLs(for:)` answers an
    /// unexpired one from `SignedURLStore` without a request, and re-signs one past its TTL, so
    /// a strip left open for more than an hour does not keep handing out dead links.
    func signSpotlightFrames(_ weeks: [SpotlightWeek]) async -> [String: URL] {
        let paths = Set(weeks.flatMap(\.frames).compactMap(\.cardPath))
        guard !paths.isEmpty else { return [:] }
        return await signedURLs(for: Array(paths))
    }

    /// Signs every Spotlight frame in memory again (the strip, the sheet of past weeks, the
    /// shelves), on returning to the foreground. The strip is read only at a reload, so without
    /// this a frame not yet in the image cache kept its first URL past the hour it lives and
    /// stayed a placeholder. An unexpired URL answers from `SignedURLStore` without a request.
    func refreshSpotlightURLs() async {
        let epoch = AccountEpoch.current
        let weeks = spotlightStripWeeks + spotlightPastWeeks + spotlightShelves.values.flatMap { $0 }
        let urls = await signSpotlightFrames(weeks)
        guard AccountEpoch.isCurrent(epoch), !urls.isEmpty else { return }
        spotlightURLs.merge(urls) { _, new in new }
    }

    /// The server's refusal name for a Spotlight RPC error, nil for anything that is not a named
    /// refusal (offline, timeout, server error).
    nonisolated static func spotlightRefusal(_ error: Error) -> String? {
        guard let postgrest = error as? PostgrestError, postgrest.code == "P0001" else { return nil }
        return postgrest.message
    }

    // MARK: - The strip

    /// The feed strip's weeks. Called by the feed's explicit reloads only, concurrently with
    /// `loadFeed`, so it is in hand before the ledger and the strip's place are snapshotted.
    /// A failed read keeps what the strip already showed.
    func loadSpotlightStrip(now: Date = .now) async {
        spotlightStripGeneration += 1
        let generation = spotlightStripGeneration
        let epoch = AccountEpoch.current
        guard let weeks = await fetchSpotlightWeeks(userId: nil, before: nil, limit: Self.spotlightStripLimit) else { return }
        let horizon = now.addingTimeInterval(-FeedUnit.retentionWindow)
        let recent = weeks.filter { $0.publishedAt >= horizon }
        guard AccountEpoch.isCurrent(epoch), generation == spotlightStripGeneration else { return }
        spotlightStripWeeks = recent
        let urls = await signSpotlightFrames(recent)
        guard AccountEpoch.isCurrent(epoch), generation == spotlightStripGeneration else { return }
        spotlightURLs.merge(urls) { _, new in new }
    }

    // MARK: - Own entry and shelf

    /// The menu's state. Refetched on every feed reload, on returning to the foreground, after
    /// any own-post delete, and after any failed Spotlight write. Never lands over a write
    /// still on the wire, nor with a read that began before a write did: the write owns the
    /// menu until it answers.
    func refreshOwnSpotlightEntry() async {
        spotlightEntryGeneration += 1
        let generation = spotlightEntryGeneration
        let epoch = AccountEpoch.current
        let writeGeneration = spotlightWriteGeneration
        guard let entry = await fetchOwnSpotlightEntry() else { return }
        guard AccountEpoch.isCurrent(epoch), generation == spotlightEntryGeneration,
              writeGeneration == spotlightWriteGeneration, !spotlightWriteInFlight else { return }
        ownSpotlightEntry = entry
    }

    /// The entry and the account's own shelf (which is also what marks its published frames
    /// for "Take it out of Spotlight"), side by side.
    func refreshOwnSpotlight(userId: UUID) async {
        async let entry: Void = refreshOwnSpotlightEntry()
        async let shelf: Void = loadSpotlightShelf(userId: userId, isSelf: true)
        _ = await (entry, shelf)
    }

    /// One profile's SPOTLIGHT shelf. Shown to everyone, strangers included: the shelf is the
    /// public record, the grid and Chapters keep the follower rule.
    func loadSpotlightShelf(userId: UUID, isSelf: Bool) async {
        let generation = (spotlightShelfGenerations[userId] ?? 0) + 1
        spotlightShelfGenerations[userId] = generation
        let epoch = AccountEpoch.current
        guard let weeks = await fetchSpotlightWeeks(userId: userId, before: nil, limit: Self.spotlightShelfLimit) else { return }
        guard AccountEpoch.isCurrent(epoch), spotlightShelfGenerations[userId] == generation else { return }
        spotlightShelves[userId] = weeks
        if isSelf {
            ownSpotlightChosen = Dictionary(
                SpotlightActivity.ownFrames(in: weeks, ownId: userId).map { ($0.frame.postId, $0.week.weekKey) },
                uniquingKeysWith: { first, _ in first })
        }
        let urls = await signSpotlightFrames(weeks)
        guard AccountEpoch.isCurrent(epoch), spotlightShelfGenerations[userId] == generation else { return }
        spotlightURLs.merge(urls) { _, new in new }
    }

    // MARK: - The sheet of past weeks

    /// A page of past weeks: `reset` starts over from the newest, otherwise the next page after
    /// the last loaded week. One batch of signed URLs per page. Returns false when the page
    /// failed, so the sheet can offer a retry rather than stall.
    ///
    /// A next-page call made while another next page is already loading waits for that load and
    /// returns its result, rather than returning at once as if a page had landed: the focus-week
    /// loop and the sentinel both page, and neither may count a page that never came.
    @discardableResult
    func loadSpotlightPastWeeks(reset: Bool) async -> Bool {
        if !reset, let inFlight = spotlightPastWeeksInFlight { return await inFlight.value }
        if reset {
            spotlightPastGeneration += 1
        } else {
            guard spotlightPastWeeksHasMore else { return true }
        }
        let generation = spotlightPastGeneration
        let task = Task { @MainActor [weak self] () -> Bool in
            guard let self else { return false }
            return await self.loadSpotlightPastWeeksPage(reset: reset, generation: generation)
        }
        spotlightPastWeeksInFlight = task
        let result = await task.value
        if spotlightPastWeeksInFlight == task { spotlightPastWeeksInFlight = nil }
        return result
    }

    private func loadSpotlightPastWeeksPage(reset: Bool, generation: Int) async -> Bool {
        let epoch = AccountEpoch.current
        let before = reset ? nil : spotlightPastWeeks.last?.weekKey
        spotlightPastWeeksLoading = true
        defer {
            if AccountEpoch.isCurrent(epoch), generation == spotlightPastGeneration { spotlightPastWeeksLoading = false }
        }
        guard let page = await fetchSpotlightWeeks(userId: nil, before: before, limit: Self.spotlightPageSize) else {
            return false
        }
        guard AccountEpoch.isCurrent(epoch), generation == spotlightPastGeneration else { return true }
        if reset {
            spotlightPastWeeks = page
        } else {
            let known = Set(spotlightPastWeeks.map(\.weekKey))
            spotlightPastWeeks.append(contentsOf: page.filter { !known.contains($0.weekKey) })
        }
        // A short page is the end (the server applies the limit after dropping empty weeks).
        spotlightPastWeeksHasMore = page.count == Self.spotlightPageSize
        let urls = await signSpotlightFrames(page)
        guard AccountEpoch.isCurrent(epoch), generation == spotlightPastGeneration else { return true }
        spotlightURLs.merge(urls) { _, new in new }
        return true
    }

    // MARK: - Opening a frame

    enum SpotlightOpenResult {
        case item(FeedItem)
        /// Deleted, hidden, taken out or blocked since the page was read. Already pruned.
        case gone
        case failed
    }

    /// Fetches the post by id before opening it, the way a `.post` push does, so a frame that
    /// went away since the week was read says so instead of opening a stale copy.
    func openSpotlightFrame(_ frame: SpotlightFrame) async -> SpotlightOpenResult {
        #if DEBUG
        if let demo = SpotlightPreviewDemo.data {
            // A beat, so the frame's spinner is on screen long enough to be seen.
            try? await Task.sleep(for: .milliseconds(600))
            return demo.items[frame.postId].map { .item($0) } ?? .gone
        }
        #endif
        let epoch = AccountEpoch.current
        async let postRows: [Post]? = try? await supabase.from("posts").select()
            .eq("id", value: frame.postId.uuidString).limit(1).execute().value
        async let author = fetchProfile(id: frame.userId)
        let rows = await postRows
        let profile = await author
        guard AccountEpoch.isCurrent(epoch) else { return .failed }
        guard let rows else { return .failed }
        guard let post = rows.first else {
            // Guarded by the epoch above. No cache generation applies: removing a frame the
            // server says is gone is right for every cache, whichever load filled it.
            pruneSpotlightFrames { $0.postId == frame.postId }
            return .gone
        }
        guard let profile else { return .failed }
        return .item(FeedItem(post: post, author: profile))
    }

    // MARK: - The menu

    /// Photo id to "shot by the signed-in account", for the menu's photographer rule. Asks only
    /// about photos it does not know yet, and only which of them are the caller's own, so no
    /// other person's photo row is ever read. A failed read leaves them unknown, which offers
    /// the item and lets the server refuse by name.
    func ensureSpotlightPhotographer(photoIds: [UUID], userId: UUID) async {
        let unknown = Array(Set(photoIds).subtracting(spotlightPhotographer.keys))
        guard !unknown.isEmpty else { return }
        let generation = spotlightPhotographerGeneration
        let epoch = AccountEpoch.current
        struct Row: Decodable { let id: UUID }
        guard let rows: [Row] = try? await supabase.from("photos").select("id")
            .in("id", values: unknown.map(\.uuidString))
            .eq("user_id", value: userId.uuidString)
            .execute().value else { return }
        guard AccountEpoch.isCurrent(epoch), generation == spotlightPhotographerGeneration else { return }
        let mine = Set(rows.map(\.id))
        for id in unknown { spotlightPhotographer[id] = mine.contains(id) }
    }

    /// The Spotlight item for one post's own-post menu.
    func spotlightMenuItem(for post: Post, viewerId: UUID?) -> SpotlightMenuItem {
        SpotlightMenuItem.resolve(
            post: post, viewerId: viewerId, entry: ownSpotlightEntry,
            chosenWeekKey: ownSpotlightChosen[post.id],
            isTagged: !(tagsByPost[post.id] ?? []).isEmpty,
            isPhotographer: spotlightPhotographer[post.photoId])
    }

    /// Why "Tag people" is off for one of your own posts, nil when it is open. See
    /// `SpotlightTagLock`.
    func spotlightTagLockReason(for postId: UUID) -> String? {
        SpotlightTagLock.reason(postId: postId, entry: ownSpotlightEntry, chosen: ownSpotlightChosen)
    }

    /// Why "Edit caption" is off for one of your own posts, nil when it is open. See
    /// `SpotlightCaptionLock`.
    func spotlightCaptionLockReason(for postId: UUID) -> String? {
        SpotlightCaptionLock.reason(postId: postId, entry: ownSpotlightEntry, chosen: ownSpotlightChosen)
    }

    // MARK: - Writes

    /// "Put it up" or "Swap it in": the menu flips at once, the server answers, and only then
    /// does the capsule's slot say it is up (or say why not, with the menu flipped back). No
    /// undo window: taking a frame down is always one menu item away until the week closes.
    /// One Spotlight write at a time for the account; the menu item is disabled meanwhile.
    func putUpForSpotlight(_ post: Post) async {
        guard !spotlightWriteInFlight, let previous = ownSpotlightEntry else {
            Haptics.error()
            return
        }
        let epoch = beginSpotlightWrite()
        var optimistic = previous
        optimistic.postId = post.id
        optimistic.photoId = post.photoId
        optimistic.postCreatedAt = post.createdAt
        optimistic.putUpAt = .now
        ownSpotlightEntry = optimistic
        struct Params: Encodable { let p_post_id: UUID }
        do {
            let result: SpotlightPutUpResult = try await supabase
                .rpc("put_up_for_spotlight", params: Params(p_post_id: post.id)).single().execute().value
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightWriteInFlight = false
            Usage.log(.spotlightPutUp)
            ownSpotlightEntry = OwnSpotlightEntry(
                weekKey: result.weekKey, weekStartsAt: result.weekStartsAt,
                weekClosesAt: result.weekClosesAt, canPutUp: true,
                postId: result.postId, photoId: post.photoId,
                postCreatedAt: post.createdAt, putUpAt: result.putUpAt,
                pendingWeekKey: previous.pendingWeekKey, pendingPostId: previous.pendingPostId,
                pendingPhotoId: previous.pendingPhotoId)
            Haptics.success()
            // The server says what it swapped out; the menu's entry only fills in the day.
            let replacedAt = result.replacedPostCreatedAt
                ?? (result.replacedPostId == previous.postId ? previous.postCreatedAt : nil)
            UndoCenter.shared.showConfirmation(SpotlightPutUpNotice.text(
                postId: post.id, replacedPostId: result.replacedPostId, replacedAt: replacedAt))
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightWriteInFlight = false
            ownSpotlightEntry = previous
            Haptics.error()
            UndoCenter.shared.showNotice(SpotlightRefusal.message(
                refusal: Self.spotlightRefusal(error), action: .putUp) ?? SpotlightRefusal.putUpNetwork)
            // The server may know something the menu does not (the week closed, a tag was
            // added from another phone): read it again.
            await refreshOwnSpotlightEntry()
        }
    }

    /// "Take it down from Spotlight", this week's frame or the one still waiting on its closed
    /// week's publish: no capsule, the menu flips at once and flips back if the server refuses.
    /// Nothing is flushed first: with no put-up ever held in an undo window, there is nothing
    /// of Spotlight's staged for this to overtake, and flushing would commit someone else's
    /// staged action (a post just deleted) out from under its Undo.
    func takeDownFromSpotlight(_ post: Post) async {
        guard !spotlightWriteInFlight, let previous = ownSpotlightEntry, previous.holds(postId: post.id) else { return }
        let epoch = beginSpotlightWrite()
        ownSpotlightEntry = previous.postId == post.id ? previous.cleared : previous.clearedPending
        struct Params: Encodable { let p_post_id: UUID }
        do {
            try await supabase.rpc("withdraw_from_spotlight", params: Params(p_post_id: post.id)).execute()
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightWriteInFlight = false
            Usage.log(.spotlightWithdraw)
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightWriteInFlight = false
            if let message = SpotlightRefusal.message(refusal: Self.spotlightRefusal(error), action: .takeDown) {
                ownSpotlightEntry = previous
                Haptics.error()
                UndoCenter.shared.showNotice(message)
            }
            // A take-down the server cannot find is already down (no message, the cleared menu
            // stands); either way, read the server's state again.
            await refreshOwnSpotlightEntry()
        }
    }

    /// Marks a put-up, swap or take-down as started: the in-flight guard, and a generation
    /// that makes any menu read already on the wire land as stale. Returns the account epoch
    /// the write belongs to.
    private func beginSpotlightWrite() -> Int {
        spotlightWriteInFlight = true
        spotlightWriteGeneration += 1
        return AccountEpoch.current
    }

    /// "Take it out of Spotlight", after publish: final, so it waits for the server before
    /// anything leaves the screen. The badge stays; the frame leaves the strip, the sheet and
    /// the shelf. A second tap while one is in flight does nothing.
    func takeOutOfSpotlight(postId: UUID) async {
        guard !spotlightTakeOutsInFlight.contains(postId) else { return }
        spotlightTakeOutsInFlight.insert(postId)
        let epoch = AccountEpoch.current
        struct Params: Encodable { let p_post_id: UUID }
        do {
            try await supabase.rpc("take_out_of_spotlight", params: Params(p_post_id: postId)).execute()
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightTakeOutsInFlight.remove(postId)
            pruneSpotlightFrames { $0.postId == postId }
            Haptics.success()
        } catch {
            guard AccountEpoch.isCurrent(epoch) else { return }
            spotlightTakeOutsInFlight.remove(postId)
            // not_found means it is not in Spotlight any more (taken out from another phone,
            // or removed by the team): the end state already holds.
            if Self.spotlightRefusal(error) == "not_found" {
                pruneSpotlightFrames { $0.postId == postId }
                return
            }
            Haptics.error()
            UndoCenter.shared.showNotice(SpotlightRefusal.takeOutNetwork)
        }
    }

    // MARK: - Pruning

    /// Drops matching frames from the strip, the sheet, every shelf and the own-frame map, and
    /// any week left with nothing in it. Deletes (by post or by photo) and blocks call this.
    func pruneSpotlightFrames(_ gone: (SpotlightFrame) -> Bool) {
        var removedPostIds = Set<UUID>()
        let everyWeek = spotlightStripWeeks + spotlightPastWeeks + spotlightShelves.values.flatMap { $0 }
        for frame in everyWeek.flatMap(\.frames) where gone(frame) { removedPostIds.insert(frame.postId) }
        guard !removedPostIds.isEmpty else { return }
        spotlightStripWeeks = SpotlightWeek.pruned(spotlightStripWeeks) { removedPostIds.contains($0.postId) }
        spotlightPastWeeks = SpotlightWeek.pruned(spotlightPastWeeks) { removedPostIds.contains($0.postId) }
        for (userId, weeks) in spotlightShelves {
            spotlightShelves[userId] = SpotlightWeek.pruned(weeks) { removedPostIds.contains($0.postId) }
        }
        for postId in removedPostIds { ownSpotlightChosen.removeValue(forKey: postId) }
    }
}

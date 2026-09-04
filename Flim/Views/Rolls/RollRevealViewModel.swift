import Foundation
import Observation
import SwiftUI

/// Orchestration for the roll reveal: loading and re-verifying the deck, the playback state
/// machine (develop → auto-advance → pause/resume/hold), the cover card's own beat, reactions,
/// and the save-all export. Pulled out of `RollRevealView` once that single `View` carried all
/// of it directly alongside the pixels.
///
/// `@MainActor @Observable`, matching `DarkroomViewModel` and `FeedService`, not left unisolated.
/// This codebase's one production `EXC_BAD_ACCESS` was an `@Observable` view model with no
/// class-level isolation, where a background read raced a main-actor write on the same tracked
/// property (see `DarkroomViewModel`'s header for the symbolicated report). This view model is
/// written to from timers, gesture callbacks and awaited network results, the same shape, so it
/// gets the same isolation from the start.
///
/// Gesture recognition (the pending hold timer, its cancellation latch), the pinch-zoom, and
/// profile-sheet routing stay in `RollRevealView`. They are about reading one finger on the
/// glass or presenting a screen, not about the reveal's own state, and moving them here would
/// only add indirection between a gesture callback and the view that owns it.
///
/// Durations, thresholds and gesture-outcome resolution stay in `RevealPacing`, which is pure
/// and tested. This type owns when things happen; `RevealPacing` owns how long they take.
@MainActor
@Observable
final class RollRevealViewModel {
    let rollId: UUID
    /// The caller's own fetch (`RollDetailView`'s already-loaded, possibly-paginated photos).
    /// Used only as a fallback if the fresh re-fetch in `loadDeck` fails, and as the cover
    /// card's source until the fresh deck lands, so the card can render before any network work.
    private let fallbackPhotos: [Photo]

    init(rollId: UUID, photos: [Photo]) {
        self.rollId = rollId
        self.fallbackPhotos = photos
    }

    /// Synced from the view's environment (`.task` on appear, `.onChange` for Reduce Motion,
    /// which can flip mid-reveal via the accessibility shortcut). Read directly by every
    /// playback method below rather than threaded through each call, the same values SwiftUI
    /// itself reads to lay out the reveal.
    var reduceMotion = false
    var displayScale: CGFloat = 3

    // MARK: - Deck

    // The deck actually being played, starts empty and is populated by the fresh fetch, so a
    // photo deleted between the caller's fetch and this view opening never gets a frame. Kept as
    // the FULL roll (every frame, burst extras included) for `Save all` and the ordinary
    // post-reveal viewer; `playedDeck` below is what the pager, the rack, and the credit line
    // actually walk.
    var deck: [Photo] = []
    /// One sharpest frame per burst run in `deck`, plus every non-burst frame, same order `deck`
    /// is already sorted in (`BurstGrouping.playback`, shared with the grid's own grouping). This
    /// is the reveal's actual playlist: the sharpest frame of each burst plays, the rest are
    /// skipped, never removed from `deck` itself.
    var playedDeck: [Photo] = []
    /// `photoId` → how many further frames its burst holds, keyed by the COVER's id (the one
    /// frame in `playedDeck` that represents the burst). Absent for a photo that isn't itself a
    /// burst cover, the "and N more like it" credit line reads this directly.
    var burstExtraCount: [UUID: Int] = [:]
    var index = 0
    var urls: [String: URL] = [:]
    /// Which frames have already played their develop beat, keyed by PHOTO ID and never by
    /// index: `skipDeadFrame` mutates the deck mid-reveal, and an index-keyed set would hand
    /// one photo's developed state to whichever frame inherited its slot (the same poisoning
    /// `FeedUnitCard`'s per-frame plumbing records). A frame develops once, on first reach,
    /// and is sharp on every later visit.
    var developedFrameIds: Set<UUID> = []
    var showSummary = false
    /// Set when the reader genuinely reached the end: paging past the last frame, or tapping
    /// Done. THIS, not opening the reveal, is what writes `rollRevealSeen.<id>`, so a reveal
    /// abandoned at frame 2 of 47 stays unwatched and replays from the cover.
    var completed = false
    var isEmpty = false
    /// Reactions across the whole deck, keyed by photo id, batch-loaded once in `loadDeck`.
    /// Includes the reactions others left BEFORE you opened the reveal, so the moment feels
    /// communal, you see the group's response accreting even though everyone arrives at their
    /// own time.
    var reactionsByPhoto: [UUID: [PhotoReaction]] = [:]
    /// The group's progress through this reveal ("you're the Nth of M to open it"), recorded and
    /// fetched on open. Shown on the summary card so the roll feels shared, not solitary.
    var presence: RollService.RevealPresence?

    // MARK: - Opening card
    //
    // The reveal opened cold on photo 1, behind a spinner. Two problems in one: nothing said what
    // you were about to see, and the wait was represented by the one thing that cannot develop
    // into anything. The cover card solves both, because it needs no network (the caller already
    // passed the photos) and can therefore be on screen instantly, with the deck loading behind
    // it. The anticipation IS the loading state.

    var showCover = true
    /// The deck is loaded (or known to be empty) and the show can actually start.
    var deckReady = false
    /// The minimum beat has been served.
    var beatElapsed = false
    /// Someone tapped to get on with it.
    var viewerTappedCover = false
    /// When the card came on screen, so the fill line measures the real elapsed beat rather than
    /// restarting whenever SwiftUI rebuilds the view.
    var coverAppearedAt: Date?

    /// What the cover card says about this roll. Falls back to the caller's photos until the
    /// fresh deck lands, which is what lets the card render before any network work.
    var cover: RevealCover { RevealCover(photos: deck.isEmpty ? fallbackPhotos : deck) }

    // MARK: - Closing actions

    var savingAll = false
    /// File URLs, not UIImages. See PhotoExport.
    var shareImages: [URL] = []
    var showShareAll = false
    /// A TOTAL failure, shown inline beside the Save all button with a retry (rule 4 of the
    /// confirmations redesign: failures land where the action was, never as a modal). A
    /// partial result doesn't set this; it proceeds to the share sheet with `partialNotice`.
    var saveAllError: String?
    /// The some-of-them line ("Only 4 of 9..."), shown alongside the share sheet rather than
    /// as a modal in front of it. Cleared when the sheet closes.
    var partialNotice: String?


    // MARK: - Load

    /// Re-fetches the roll's CURRENT photos so a shot deleted after the caller's own fetch (but
    /// before this reveal opened) never enters the deck, then resolves signed URLs and starts
    /// playback. Falls back to `fallbackPhotos` if the re-fetch itself fails (e.g. offline); an
    /// empty deck should mean "everything was deleted", not "the network hiccuped".
    ///
    /// The deck is built from the fresh fetch, not the fallback: the fallback is
    /// `RollDetailView`'s paginated `vm.developedPhotos`, capped at PhotoService's 30-photo page
    /// size until the grid has been scrolled far enough to load more. The snapshot fetch has no
    /// such cap, it's the roll's complete current row set, so a roll of 60+ shots showed only the
    /// ~30 loaded so far back when this intersected the fresh fetch against the truncated
    /// fallback instead of using the fresh fetch directly.
    ///
    /// Multi-await, and every write below is behind its own `AccountEpoch` check taken right
    /// after the await that could have let the account change underneath it, not once at the
    /// top: a stale response is internally consistent, it's just consistent with an account that
    /// isn't signed in anymore. See `AccountEpoch`.
    func loadDeck(photoService: PhotoService, auth: AuthService, rollService: RollService) async {
        let epoch = AccountEpoch.current
        let fresh: [Photo]
        do {
            fresh = try await photoService.fetchRollPhotosSnapshot(rollId: rollId)
        } catch {
            fresh = fallbackPhotos
        }
        guard AccountEpoch.isCurrent(epoch) else { return }
        deck = fresh.sorted { $0.takenAt < $1.takenAt }
        let playback = BurstGrouping.playback(deck)
        playedDeck = playback.played
        burstExtraCount = playback.extraCount

        guard !playedDeck.isEmpty else {
            isEmpty = true
            deckReady = true
            beginIfReady()
            return
        }

        // Sign the display paths AND the thumbnails in one batched call, so the progressive first
        // frame below costs no extra round trip.
        async let signed = photoService.signedURLs(for: deck.map(\.viewPath) + deck.compactMap(\.thumbPath))
        // Reactions don't gate the first frame, so they no longer sit in front of it. This used to
        // be a third sequential round trip before anything could be drawn.
        async let reactions = photoService.fetchReactions(photoIds: deck.map(\.id))
        // Batched for the whole deck, same as `reactions`, and cached ON `photoService` itself
        // (nothing here to assign back), so the reaction bar reads it straight off
        // `photoService.reactionDefaults(for:)` once this lands.
        async let suggestions: () = photoService.fetchSuggestedEmoji(photoIds: deck.map(\.id))
        let resolvedURLs = await signed
        let resolvedReactions = await reactions
        _ = await suggestions
        guard AccountEpoch.isCurrent(epoch) else { return }
        urls = resolvedURLs
        reactionsByPhoto = resolvedReactions

        // Warm the FIRST print before starting the show, but warm the cheap one.
        //
        // `develop()` opens at blur radius 26 and takes 1.4s to resolve. At that blur a ~30KB
        // thumbnail and the full rendition are indistinguishable, and the thumbnail is usually
        // already in cache from the roll grid the viewer just came from, so this typically
        // returns instantly and the reveal starts on a real photograph instead of a spinner.
        //
        // Each warm passes the EXACT cacheKey and maxPixel the view asks for at that phase
        // (thumbPath at 400 for the underlay, viewPath at 1400 for the full-size layer). Warm
        // and view must agree on key+size or the warm files bytes under an entry the view never
        // looks for, and CachedImage falls through to a second, redundant download.
        // `playedDeck.first`, not `deck.first`: the burst cover, not necessarily the earliest
        // frame in the run, is what the reveal actually opens on.
        if let first = playedDeck.first {
            if let thumbPath = first.thumbPath, let thumbURL = urls[thumbPath] {
                _ = await ImageLoader.fetch(url: thumbURL, maxPixel: 400, scale: displayScale, cacheKey: thumbPath)
            } else if let url = urls[first.viewPath] {
                // No thumbnail (an older photo, or a rendition upload that failed): fall back to
                // waiting on the full image, which is the old behaviour rather than a blank frame.
                _ = await ImageLoader.fetch(url: url, maxPixel: 1400, scale: displayScale, cacheKey: first.viewPath)
            }
        }
        // Full renditions warm in the background, the first one included: it has the develop
        // animation to arrive in, and only has to beat the blur clearing, not the frame appearing.
        // Bounded to a sliding window, see prefetchAhead.
        prefetchAhead(from: 0)
        // Record that we opened it and learn the group's progress, shown on the summary card.
        if let uid = auth.currentUser?.id {
            let recorded = await rollService.recordRevealView(rollId: rollId, userId: uid)
            // Alongside the DB record above, not inside RollService, so the two can never drift:
            // this fires exactly when the reveal open is recorded, whether or not `recorded`
            // itself came back non-nil (a nil presence just means the viewer count read failed,
            // the view was still recorded).
            Activation.log(.revealWatched)
            Usage.log(.revealWatched)
            guard AccountEpoch.isCurrent(epoch) else { return }
            presence = recorded
        }
        guard AccountEpoch.isCurrent(epoch) else { return }
        deckReady = true
        beginIfReady()
    }

    // MARK: - Opening card

    /// The beat before the first frame. Owns the chime too: it belongs at the moment the reveal
    /// becomes an event, not three network round trips later when the first frame happens to be
    /// ready.
    func startCoverBeat() async {
        coverAppearedAt = .now
        SoundFX.reveal()
        try? await Task.sleep(for: .seconds(RevealCover.holdDuration))
        beatElapsed = true
        beginIfReady()
    }

    /// Someone tapped the cover to get on with it.
    func tapCover() {
        viewerTappedCover = true
        beginIfReady()
    }

    /// Starts the show once the deck is there and the beat has been served or skipped.
    ///
    /// Called from three places (the beat timer, a tap, and the deck finishing) because any of
    /// them can be last, and the guard makes the other two harmless.
    func beginIfReady() {
        guard showCover,
              RevealCover.canBegin(deckReady: deckReady, beatElapsed: beatElapsed,
                                   viewerTapped: viewerTappedCover)
        else { return }
        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.45)) { showCover = false }
        guard !isEmpty else { return }
        develop(at: 0)
    }

    // MARK: - Paging

    /// Plays the develop beat for the frame at `index`, once ever. Reduce Motion marks it
    /// developed immediately: the beat is the one part of the reveal that IS motion, so the
    /// setting removes it rather than shortening it.
    ///
    /// Doesn't touch the pinch-zoom: that's view-local state, reset by the view whenever the
    /// photo on screen changes.
    func develop(at index: Int) {
        guard playedDeck.indices.contains(index) else { return }
        let photo = playedDeck[index]
        prefetchAhead(from: index)
        guard !developedFrameIds.contains(photo.id) else { return }
        guard !reduceMotion else {
            developedFrameIds.insert(photo.id)
            return
        }
        withAnimation(.easeOut(duration: RevealPacing.developDuration)) {
            _ = developedFrameIds.insert(photo.id)
        }
    }

    /// Whether the frame at `index` has already developed. The view reads this per page, so a
    /// frame ahead of the reader stays a well until they actually reach it.
    func hasDeveloped(_ photo: Photo) -> Bool { developedFrameIds.contains(photo.id) }

    /// The reader paged to a new frame.
    func moved(to newIndex: Int) {
        guard newIndex != index, playedDeck.indices.contains(newIndex) else { return }
        index = newIndex
        Haptics.tap()
        develop(at: newIndex)
    }

    /// Warms a bounded window of upcoming slides instead of the whole deck.
    ///
    /// Already-cached entries are cheap no-ops in ImageLoader, so re-calling this on every step
    /// costs nothing and keeps the runway ahead of the viewer however they move through the roll.
    private func prefetchAhead(from index: Int) {
        let range = RevealPacing.prefetchRange(from: index, count: playedDeck.count)
        // cacheKey: photo.viewPath, matching exactly what the view's CachedImage keys the
        // full-size layer under (see RollRevealView). A nil key here would warm a URL-only
        // entry the view never looks for, downloading the same bytes twice.
        let items: [(url: URL, cacheKey: String?)] = playedDeck[range].compactMap { photo in
            urls[photo.viewPath].map { (url: $0, cacheKey: photo.viewPath) }
        }
        ImageLoader.prefetch(items, maxPixel: 1400, scale: displayScale)
    }

    /// The current frame's image failed to load (deleted between fetch and play, or any other
    /// load failure), drop it and move straight to the next one. No dead frame, no stall on
    /// the auto-advance timer.
    ///
    /// Removed from BOTH `deck` (it's genuinely gone, `Save all` must not try it either) and
    /// `playedDeck` (what's actually being paged). Mutates them mid-playback, which is exactly why
    /// the view reads the current frame through a bounds-safe subscript rather than trusting
    /// `index` to still be valid.
    func skipDeadFrame(_ photoId: UUID) {
        deck.removeAll { $0.id == photoId }
        burstExtraCount[photoId] = nil
        guard let deadIndex = playedDeck.firstIndex(where: { $0.id == photoId }) else { return }
        playedDeck.remove(at: deadIndex)
        developedFrameIds.remove(photoId)
        guard !playedDeck.isEmpty else {
            isEmpty = true
            deckReady = true
            beginIfReady()
            return
        }
        // Keep pointing at the SAME photograph. Removing a frame from before the reader's
        // position shifts every later frame down one slot, so an unchanged `index` now names the
        // NEXT photo: the reveal would silently jump forward a frame, and `develop(at:)` below
        // would burn that frame's once-ever develop beat for a frame nobody has reached. The old
        // clamp only caught the other case, an index left past the end of a shrunk deck.
        //
        // Three cases, and only the first two move anything:
        //   dead BEFORE us  -> everything shifted down, follow it down
        //   dead IS us      -> the next frame slid into this slot, stay put and develop it
        //   dead AFTER us   -> nothing before us moved, stay put
        if deadIndex < index {
            index -= 1
        } else if index >= playedDeck.count {
            index = playedDeck.count - 1
        }
        develop(at: index)
    }

    /// The end of the reveal, and the ONLY thing that counts as having watched it: reached by
    /// paging past the last frame or by tapping Done. See `completed`.
    func finish() {
        completed = true
        withAnimation(.easeInOut(duration: 0.3)) { showSummary = true }
    }

    // MARK: - Reactions

    /// Optimistically toggle the current user's reaction, then persist. Mirrors the carousel /
    /// full-screen viewer, and the same reaction feeds Piece 2's pull-back notification server-side.
    func toggleReaction(_ emoji: String, on photo: Photo, auth: AuthService, photoService: PhotoService) {
        guard let uid = auth.currentUser?.id else { return }
        var list = reactionsByPhoto[photo.id] ?? []
        let mine = list.contains { $0.emoji == emoji && $0.userId == uid }
        if mine {
            list.removeAll { $0.emoji == emoji && $0.userId == uid }
            reactionsByPhoto[photo.id] = list
            Task { await photoService.removeReaction(photoId: photo.id, emoji: emoji, userId: uid) }
        } else {
            list.append(PhotoReaction(id: UUID(), photoId: photo.id, userId: uid, emoji: emoji))
            reactionsByPhoto[photo.id] = list
            Task { await photoService.addReaction(photoId: photo.id, emoji: emoji, userId: uid) }
        }
    }

    // MARK: - Save all / share

    /// Collects every frame in the roll and hands them to the share sheet.
    ///
    /// Reads through `ImageLoader`, which means the frames already shown come straight from cache
    /// and only a skipped tail costs anything.
    func saveAll() {
        guard !savingAll else { return }
        savingAll = true
        saveAllError = nil
        partialNotice = nil
        Haptics.tap()
        Task {
            // Same streaming export as the roll's own Save all, for the same reason: a reveal can
            // be a 75-shot roll, and collecting that as UIImages is a jetsam kill. See PhotoExport.
            let exportDir = PhotoExport.begin()
            var images: [URL] = []
            for (i, photo) in deck.enumerated() {
                guard let url = urls[photo.viewPath] else { continue }
                if let file = await PhotoExport.download(url, into: exportDir, index: i, total: deck.count) {
                    images.append(file)
                }
            }
            shareImages = images
            savingAll = false
            if images.isEmpty {
                // Silence here is indistinguishable from a broken button.
                Haptics.error()
                saveAllError = "Couldn't load the photos. Check your connection."
            } else {
                if images.count < deck.count {
                    // Some photos IS better than none, but claiming "all" when it was 4 of 9
                    // would be a lie discovered later in the camera roll. Said beside the
                    // sheet, not as a modal in front of it.
                    partialNotice = "Only \(images.count) of \(deck.count) photos could be loaded. Saving those now."
                }
                showShareAll = true
            }
        }
    }
}

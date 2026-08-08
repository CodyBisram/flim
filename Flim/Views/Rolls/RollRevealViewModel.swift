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
    // photo deleted between the caller's fetch and this view opening never gets a frame.
    var deck: [Photo] = []
    var index = 0
    var urls: [String: URL] = [:]
    var developed = false          // current photo's develop animation
    var showSummary = false
    var isEmpty = false
    /// Reactions across the whole deck, keyed by photo id, batch-loaded once in `loadDeck`.
    /// Includes the reactions others left BEFORE you opened the reveal, so the moment feels
    /// communal, you see the group's response accreting even though everyone arrives at their
    /// own time.
    var reactionsByPhoto: [UUID: [PhotoReaction]] = [:]
    /// Set once you interact with the current shot (react, or open the picker). While true, the
    /// auto-advance timer is held off so a slide never yanks away mid-reaction. Reset per photo.
    var engaged = false
    /// The group's progress through this reveal ("you're the Nth of M to open it"), recorded and
    /// fetched on open. Shown on the summary card so the roll feels shared, not solitary.
    var presence: RollService.RevealPresence?

    private var advanceTask: Task<Void, Never>?

    // MARK: - Playback pacing
    //
    // A slide used to be a fixed 3.4s with no way to stop it, and the progress bar filled a whole
    // segment at a time, so it showed WHERE you were and never how long you had. Between them, a
    // photo you were still looking at just left, with no warning and no recourse. The fix is all
    // three together: longer, visible, and holdable.

    /// This slide's length. Reduce Motion skips the develop animation entirely, so there is no
    /// unreadable phase to allow for and the slide is just the viewing time.
    var currentSlideDuration: TimeInterval {
        reduceMotion ? RevealPacing.viewingDuration : RevealPacing.slideDuration
    }

    /// When the current slide is due to advance. Drives the filling progress segment, and is
    /// rewritten on resume so a paused slide gets its remaining time back rather than restarting.
    var slideEndsAt: Date?
    /// Time left on the current slide while paused.
    var pausedRemaining: TimeInterval = RevealPacing.slideDuration
    var paused = false

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
    var saveAllError: String?
    /// The alert is a warning, not a failure: open the sheet once it is dismissed. Presenting
    /// both at once means SwiftUI shows one and silently drops the other.
    var shareAfterAlert = false

    /// Cancels the auto-advance. Call from the view's `onDisappear`; the gesture layer's own hold
    /// timer is view-local and cancels alongside this one, not through here.
    func stopPlayback() {
        advanceTask?.cancel()
    }

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

        guard !deck.isEmpty else {
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
        let resolvedURLs = await signed
        let resolvedReactions = await reactions
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
        // No cacheKey on any of these, matching what the view's CachedImage asks for; a
        // different key would warm an entry the view never looks for.
        if let first = deck.first {
            if let thumbPath = first.thumbPath, let thumbURL = urls[thumbPath] {
                _ = await ImageLoader.fetch(url: thumbURL, maxPixel: 400, scale: displayScale)
            } else if let url = urls[first.viewPath] {
                // No thumbnail (an older photo, or a rendition upload that failed): fall back to
                // waiting on the full image, which is the old behaviour rather than a blank frame.
                _ = await ImageLoader.fetch(url: url, maxPixel: 1600, scale: displayScale)
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
        develop()
    }

    // MARK: - Playback

    /// Runs the develop animation for the current photo, then auto-advances, unless you've
    /// engaged with this shot (started reacting), in which case it waits for you to step forward.
    ///
    /// Doesn't touch the pinch-zoom: that's view-local state, reset by the view whenever the
    /// photo on screen changes.
    private func develop() {
        developed = false
        engaged = false
        paused = false
        pausedRemaining = currentSlideDuration
        withAnimation(.easeOut(duration: reduceMotion ? 0 : RevealPacing.developDuration)) { developed = true }
        armAdvance(after: currentSlideDuration)
    }

    func step(_ delta: Int) {
        Haptics.tap()
        let next = index + delta
        if next >= deck.count {
            finish()
        } else if next >= 0 {
            index = next
            prefetchAhead(from: next)
            develop()
        }
    }

    /// Warms a bounded window of upcoming slides instead of the whole deck.
    ///
    /// Already-cached entries are cheap no-ops in ImageLoader, so re-calling this on every step
    /// costs nothing and keeps the runway ahead of the viewer however they move through the roll.
    private func prefetchAhead(from index: Int) {
        let range = RevealPacing.prefetchRange(from: index, count: deck.count)
        let items: [(url: URL, cacheKey: String?)] = deck[range].compactMap { photo in
            urls[photo.viewPath].map { (url: $0, cacheKey: nil) }
        }
        ImageLoader.prefetch(items, maxPixel: 1600, scale: displayScale)
    }

    /// The current frame's image failed to load (deleted between fetch and play, or any other
    /// load failure), drop it and move straight to the next one. No dead frame, no stall on
    /// the auto-advance timer.
    ///
    /// Mutates `deck` mid-playback, which is exactly why the view reads it through a bounds-safe
    /// subscript rather than trusting `index` to still be valid.
    func skipDeadFrame(_ photoId: UUID) {
        guard let deadIndex = deck.firstIndex(where: { $0.id == photoId }) else { return }
        advanceTask?.cancel()
        deck.remove(at: deadIndex)
        guard !deck.isEmpty else {
            isEmpty = true
            deckReady = true
            beginIfReady()
            return
        }
        if index >= deck.count { index = deck.count - 1 }
        develop()
    }

    func finish() {
        advanceTask?.cancel()
        withAnimation(.easeInOut(duration: 0.3)) { showSummary = true }
    }

    /// Holds the current shot up until the finger lifts.
    func pausePlayback() {
        guard !paused, !showSummary else { return }
        paused = true
        advanceTask?.cancel()
        pausedRemaining = RevealPacing.remaining(endsAt: slideEndsAt, now: .now, fallback: currentSlideDuration)
        Haptics.tap()
    }

    /// Gives the slide its REMAINING time back rather than restarting it, so holding to look at a
    /// photo four seconds in doesn't hand you another five.
    func resumePlayback() {
        guard paused else { return }
        paused = false
        guard !engaged else { return }
        armAdvance(after: pausedRemaining)
    }

    /// Arms the auto-advance for `seconds` and records the deadline the progress bar reads from.
    private func armAdvance(after seconds: TimeInterval) {
        advanceTask?.cancel()
        guard seconds > 0 else { step(1); return }
        slideEndsAt = Date.now.addingTimeInterval(seconds)
        advanceTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, !engaged, !paused else { return }
            step(1)
        }
    }

    /// Cancels the current shot's auto-advance so it stays put while you're reacting. You step
    /// forward yourself (tap the right zone) when ready. Engaged viewers set their own pace;
    /// passive viewers keep the auto-play.
    func holdAutoAdvance() {
        engaged = true
        advanceTask?.cancel()
        // Freeze the bar where it stands, rather than leaving it mid-animation against a deadline
        // that will never arrive.
        pausedRemaining = RevealPacing.remaining(endsAt: slideEndsAt, now: .now, fallback: currentSlideDuration)
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
        shareAfterAlert = false
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
                saveAllError = "Couldn't load the photos. Check your connection and try again."
            } else {
                if images.count < deck.count {
                    saveAllError = "Only \(images.count) of \(deck.count) photos could be loaded. Saving those now."
                    shareAfterAlert = true
                } else {
                    showShareAll = true
                }
            }
        }
    }
}

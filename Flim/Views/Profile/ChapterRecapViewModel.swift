import Foundation
import Observation
import SwiftUI
import os

/// Orchestration for one chapter's recap: loading the month's photos, curating the playback deck,
/// and resolving the URLs the pager needs. The pinch/gesture handling and the view hierarchy
/// itself stay in `ChapterRecapView`, same split `RollRevealViewModel`/`RollRevealView` use.
///
/// `@MainActor @Observable`, matching `RollRevealViewModel` and `DarkroomViewModel`: written from
/// awaited network and curation results, never left unisolated.
@MainActor
@Observable
final class ChapterRecapViewModel {
    let profileId: UUID
    let chapter: ChapterSummary

    private static let log = Logger(subsystem: "com.flim.app", category: "chapters")

    /// How many shots `ChapterCuration` is asked to trim down to, and the size of the provisional
    /// deck shown before it finishes. One shared constant so the two never drift apart: a
    /// provisional deck bigger than curation's own `limit` would visibly SHRINK the instant
    /// curation lands, for anyone still on the opening card when it does.
    static let curationLimit = 15

    init(profileId: UUID, chapter: ChapterSummary) {
        self.profileId = profileId
        self.chapter = chapter
    }

    var displayScale: CGFloat = 3

    /// Every photo in the month, `taken_at` ascending, as `chapter_photos` returned it.
    private(set) var monthPhotos: [ChapterPhoto] = []
    /// The subset actually played, chronological order. Set TWICE: a provisional pick (the
    /// month's first `curationLimit` shots, or all of them if fewer) the instant `chapter_photos`
    /// itself returns, so the recap is playable immediately, then replaced with `ChapterCuration`'s
    /// real quality/diversity pick, UNION any photo a stat line on the closing card points at (see
    /// `load()`), so tapping "Most reacted"/"Most commented"/"Longest gap" can always land on a
    /// real page in this same deck rather than a photo curation dropped. The second write is skipped for as
    /// long as `isPlayerMounted` stays true: see that property's own doc.
    private(set) var deck: [ChapterPhoto] = []
    var urls: [String: URL] = [:]
    /// Whether `ChapterCuration`'s real pick is still being computed. `deck` is already playable
    /// the whole time this is true (the provisional pick), so this no longer gates the opening
    /// card or the pager at all; the ONE thing it still gates is "Share as a contact sheet",
    /// which wants the final, curated pick, not a naive first-N, and shows its own spinner while
    /// this is true instead of building from whatever `deck` happens to hold yet.
    private(set) var isLoadingDeck = false
    /// `true` once `chapter_photos`/`chapter_stats` have both returned, whether or not the month
    /// had anything in it, so the empty state can tell "still loading" apart from "genuinely
    /// nothing here". Set well before curation finishes, see `deck`'s own doc.
    private(set) var loaded = false
    /// Whether `PhotoPagerView` is currently mounted inside `ChapterRecapView.player`. While true,
    /// `deck` must never change under it: `TabView(.page)` requires every page to stay
    /// structurally stable, and swapping the backing array out from under a live pager corrupts
    /// its paging state (see the swipe-pattern rule this codebase already follows everywhere
    /// else). Set by `ChapterRecapView` alongside its own `isPlayerPresented`; when curation
    /// finishes while this is true, the real pick is stashed in `pendingCuratedDeck` instead of
    /// applied immediately, and only adopted once this goes false again.
    private(set) var isPlayerMounted = false
    private var pendingCuratedDeck: [ChapterPhoto]?

    func setPlayerMounted(_ mounted: Bool) {
        isPlayerMounted = mounted
        guard !mounted, let pending = pendingCuratedDeck else { return }
        pendingCuratedDeck = nil
        deck = pending
    }

    /// This month's `chapter_stats`, already visibility-resolved server-side by the time they
    /// arrive here (see `ChapterService.stats(for:monthStart:)`).
    private(set) var stats: ChapterStats = [:]
    /// The closing card's lines, in priority order, capped at five. Empty exactly when the
    /// closing card should not show at all: a private month for this viewer, or a month with
    /// nothing worth calling out.
    var closingLines: [ChapterStatLine] { ChapterStatsFormatting.lines(from: stats) }
    var hasClosingCard: Bool { !closingLines.isEmpty }

    var isEmpty: Bool { loaded && deck.isEmpty }

    /// `deck`, reshaped into what `PhotoPagerView` actually takes: one `Photo` per curated shot,
    /// in the same (chronological) order. Pure and free of the view model's own state beyond
    /// `deck` itself, so the mapping is testable without a load, a network, or a view.
    ///
    /// `userId` is always `profileId`: every row `chapter_photos` returns belongs to this one
    /// profile's month (their own full month on their own page, their posted shots only on
    /// anyone else's, per that RPC's own contract), never a mix of authors the way a roll's
    /// photos are.
    ///
    /// `rollId` is deliberately dropped rather than carried through, even for a shot that did
    /// come from a roll: `PhotoPagerView`'s roll-rack footer treats a non-nil `rollId` as
    /// license to post the shot to your own page (an assumption that holds in `RollDetailView`,
    /// where only members ever open the pager, but not here, where the recap can be another
    /// profile's and this client has no way to confirm roll membership). Dropping it also makes
    /// `showsDelete: false`'s protection redundant rather than load-bearing in exactly one place.
    /// `developsAt` is backdated so `PhotoPagerView.isReady` (which gates its own full-res
    /// fetch) is never false for a shot that, by definition, already developed and posted.
    var pagerPhotos: [Photo] { Self.pagerPhotos(from: deck, profileId: profileId) }

    /// `urls`, reshaped into the pager's per-photo-id seed dictionary: the thumbnail
    /// (`displayPath`) URL already resolved for each curated shot, so every page has something
    /// to show the instant it mounts, matching `PhotoPagerView.signedURLs`'s own contract (the
    /// grid's seed) even though this recap has no grid behind it.
    var pagerSignedURLs: [UUID: URL] { Self.pagerSignedURLs(from: deck, urls: urls) }

    /// `deck`'s posts, keyed by photo id, for the photos that were actually shared as posts
    /// (`ChapterPhoto.postId`, absent on an older server, see that property's own doc). Handed to
    /// `PhotoPagerView.posts` so reactions and comments for a chapter photo read and write
    /// `post_reactions`/`post_comments`, the tables they were actually written to, rather than the
    /// roll-photo ones a chapter photo never touches. `caption`/`createdAt` are placeholders
    /// (`nil`/`takenAt`): `chapter_photos` doesn't carry them and nothing this pager shows reads
    /// them for a post opened this way.
    var pagerPosts: [UUID: Post] { Self.pagerPosts(from: deck, profileId: profileId) }

    // `nonisolated`: pure functions of their arguments, no instance state touched, so tests can
    // call them directly without hopping to the main actor for what is otherwise ordinary data
    // reshaping.
    nonisolated static func pagerPhotos(from deck: [ChapterPhoto], profileId: UUID) -> [Photo] {
        deck.map { photo in
            Photo(id: photo.id, userId: profileId, rollId: nil, storagePath: photo.storagePath,
                  thumbPath: photo.thumbPath, feedPath: photo.feedPath, takenAt: photo.takenAt,
                  developsAt: .distantPast, isDeveloped: true, caption: nil, isSorted: true)
        }
    }

    nonisolated static func pagerSignedURLs(from deck: [ChapterPhoto], urls: [String: URL]) -> [UUID: URL] {
        Dictionary(uniqueKeysWithValues: deck.compactMap { photo in
            urls[photo.displayPath].map { (photo.id, $0) }
        })
    }

    nonisolated static func pagerPosts(from deck: [ChapterPhoto], profileId: UUID) -> [UUID: Post] {
        Dictionary(uniqueKeysWithValues: deck.compactMap { photo -> (UUID, Post)? in
            guard let postId = photo.postId else { return nil }
            let post = Post(id: postId, userId: profileId, photoId: photo.id, storagePath: photo.storagePath,
                             thumbPath: photo.thumbPath, feedPath: photo.feedPath, takenAt: photo.takenAt,
                             caption: nil, createdAt: photo.takenAt)
            return (photo.id, post)
        })
    }

    /// The month's first `limit` shots (chronological), or every shot when there are `limit` or
    /// fewer. What `load()` shows the instant `chapter_photos` returns, before `ChapterCuration`'s
    /// Vision pass has had a chance to run at all: a naive but genuinely playable stand-in, so
    /// "Play the month" and the fanned prints are live immediately rather than blocked on a
    /// scoring pass that used to take one sequential network round trip PER PHOTO. Pure so the
    /// exact selection (which end of the month survives, whether it's a no-op under `limit`) is
    /// tested without a network or a curation actor.
    nonisolated static func provisionalDeck(from photos: [ChapterPhoto], limit: Int) -> [ChapterPhoto] {
        guard photos.count > limit else { return photos }
        return Array(photos.prefix(limit))
    }

    /// Loads the month, curates it, and resolves every URL the pager will need.
    ///
    /// `deck` is set TWICE (see its own doc): a provisional pick the moment `chapter_photos`
    /// returns, so the opening card is interactive immediately, then the real curated pick once
    /// `ChapterCuration` finishes, UNLESS a pager is already mid-flight on the provisional one
    /// (`isPlayerMounted`), in which case the swap waits for `setPlayerMounted(false)`.
    ///
    /// A completed month's curated pick is also fetched from, and saved to,
    /// `ChapterCurationCache`: the month can never gain or lose photos once it has ended, so its
    /// pick can never go stale, and a SECOND session opening the same month skips
    /// `ChapterCuration` (the network signing + Vision pass) entirely.
    func load(feed: FeedService, chapters: ChapterService) async {
        guard !loaded else { return }
        let clock = ContinuousClock()
        let overallStart = clock.now

        async let photosResult = chapters.photos(for: profileId, monthStart: chapter.monthStart)
        async let statsResult = chapters.stats(for: profileId, monthStart: chapter.monthStart)
        let photos = await photosResult
        let photosElapsed = overallStart.duration(to: clock.now)
        monthPhotos = photos
        stats = await statsResult
        let statsElapsed = overallStart.duration(to: clock.now)

        guard !photos.isEmpty else {
            deck = []
            loaded = true
            Self.log.info("chapter load (empty): photos=\(photosElapsed, privacy: .public) total=\(overallStart.duration(to: clock.now), privacy: .public)")
            return
        }

        // Interactive immediately: "Play the month" and the fanned prints have something real the
        // instant the month's own photo list is in hand, no waiting on curation.
        deck = Self.provisionalDeck(from: photos, limit: Self.curationLimit)
        loaded = true

        let isCompletedMonth = !chapter.isCurrentMonth()
        // `longestGap` joins `mostReacted`/`mostCommented` here for the same reason: whatever the
        // closing card can point a tap at must actually survive curation's trim.
        let highlightIds = [stats[.mostReacted]?.photoId, stats[.mostCommented]?.photoId, stats[.longestGap]?.photoId]
            .compactMap { $0 }

        isLoadingDeck = true
        defer { isLoadingDeck = false }

        var pickedIds: [UUID]
        let signStart = clock.now
        var signElapsed = Duration.zero
        var scoreElapsed = Duration.zero
        if isCompletedMonth, let cached = ChapterCurationCache.load(profileId: profileId, monthStart: chapter.monthStart) {
            // A month that has ended never gains or loses photos, so a pick cached from an
            // earlier session is still exactly right; skip signing AND scoring entirely.
            pickedIds = cached
        } else {
            // ONE batched sign for every candidate's thumb path, rather than curation resolving
            // one at a time: this is what made a 60-shot month sixty sequential round trips.
            let thumbPaths = Array(Set(photos.map(\.displayPath)))
            let thumbURLs = await feed.signedURLs(for: thumbPaths)
            for (path, url) in thumbURLs { urls[path] = url }
            signElapsed = signStart.duration(to: clock.now)

            let scoreStart = clock.now
            pickedIds = await ChapterCuration.shared.curate(
                photos: photos, displayScale: displayScale, thumbURLs: thumbURLs, limit: Self.curationLimit)
            scoreElapsed = scoreStart.duration(to: clock.now)

            if isCompletedMonth {
                ChapterCurationCache.save(pickedIds, profileId: profileId, monthStart: chapter.monthStart)
            }
        }

        var pickedSet = Set(pickedIds)
        // Whatever the closing card can point a tap at must actually be in the deck, even when
        // curation would otherwise have dropped it: a month with more than fifteen candidates
        // trims aggressively, and the most-reacted/most-commented/longest-gap shot is exactly the
        // kind of single photo that trim has no reason to keep on its own merits.
        pickedSet.formUnion(highlightIds)
        // `photos` is already `taken_at` ascending, so filtering it (rather than reassembling
        // from `pickedIds`' own order) is what keeps the deck chronological.
        let curatedDeck = photos.filter { pickedSet.contains($0.id) }

        // Never swap the backing array out from under a pager that's already mid-flight on the
        // provisional pick; `setPlayerMounted(false)` adopts it once the pager closes instead.
        if isPlayerMounted {
            pendingCuratedDeck = curatedDeck
        } else {
            deck = curatedDeck
        }

        var paths = Set(deck.flatMap { [$0.displayPath, $0.viewPath] })
        // The closing card's own thumb, straight off the stat row: usually the same value as the
        // matching `ChapterPhoto.thumbPath` above, but resolved explicitly in case the RPC ever
        // hands back a different rendition for it.
        let highlightThumbPaths = [stats[.mostReacted]?.photoThumbPath, stats[.mostCommented]?.photoThumbPath,
                                    stats[.longestGap]?.photoThumbPath]
            .compactMap { $0 }
        paths.formUnion(highlightThumbPaths)
        if !paths.isEmpty {
            let resolved = await feed.signedURLs(for: Array(paths))
            for (path, url) in resolved { urls[path] = url }
        }

        let summary = "chapter load: photos=\(photosElapsed) stats=\(statsElapsed) sign=\(signElapsed) score=\(scoreElapsed) total=\(overallStart.duration(to: clock.now)) count=\(photos.count)"
        Self.log.info("\(summary, privacy: .public)")
        #if DEBUG
        print("CHAPTER_TIMING: \(summary)")
        #endif
    }

    /// The deck index of `photoId`, if it's actually in this session's deck. `load()` guarantees
    /// any photo a closing-card line points at is unioned into the deck, so this only fails for a
    /// month whose photos never finished loading at all. Used by `ChapterRecapView` to seed
    /// `PhotoPagerView.startIndex` when a closing-card thumb is tapped; the pager owns its own
    /// selection from there, so this view model tracks no index of its own.
    func deckIndex(ofPhoto photoId: UUID) -> Int? {
        deck.firstIndex { $0.id == photoId }
    }

    // MARK: - Contact sheet share

    var isBuildingContactSheet = false
    /// Rule 4 of the confirmations redesign, same as `RollRevealViewModel.saveAllError`: a
    /// failure lands right where the action was, with the button still there to retry, never a
    /// modal in front of it.
    var contactSheetError: String?
    /// A file URL, not a `UIImage`, matching `PhotoExport`'s own contract: this is a single PNG,
    /// not a whole roll, but reusing the file-based path means it can share out through the same
    /// `ActivityView` every other export uses with no UIKit-share special case for this one.
    var contactSheetFile: URL?
    var showContactSheetShare = false

    /// Builds "Share as a contact sheet": the curated deck (`pagerPhotos`'s own source, `deck`)
    /// laid out on `ChapterContactSheet`'s grid, from whatever rendition the recap already
    /// resolved (`urls[photo.viewPath]`, the ~1400px feed card or the original when no feed
    /// rendition exists), decoded down to roughly cell size through `ImageLoader`'s own decode
    /// budget rather than a raw `UIImage(data:)`.
    ///
    /// Written to its own `PhotoExport` directory, the same reasoning as `RollRevealViewModel`'s
    /// save-all: two exports in flight at once must never be able to hand one share sheet the
    /// other's file.
    func buildContactSheet() async {
        guard !isBuildingContactSheet else { return }
        isBuildingContactSheet = true
        contactSheetError = nil
        Haptics.tap()
        defer { isBuildingContactSheet = false }

        let cell = ChapterContactSheet.cellSize()
        var images: [UIImage] = []
        for photo in deck.prefix(ChapterContactSheet.capacity) {
            guard let url = urls[photo.viewPath] else { continue }
            // scale: 1, because the contact sheet's canvas is specified in pixels, exactly like
            // `BrandedExport.storyCanvas`; a display-scale multiplier here would decode every
            // tile several times larger than the cell it's about to be clipped into.
            if let image = await ImageLoader.fetch(url: url, maxPixel: cell.height, scale: 1,
                                                    cacheKey: photo.viewPath) {
                images.append(image)
            }
        }

        guard let sheet = ChapterContactSheet.render(
            images: images, chapterCode: chapter.chapterCode(), monthName: chapter.monthName(),
            statsLine: chapter.statsLine, appName: AppInfo.appName
        ), let data = sheet.pngData() else {
            Haptics.error()
            contactSheetError = "Couldn't build the contact sheet. Try again."
            return
        }

        let directory = PhotoExport.begin()
        let file = directory.appendingPathComponent("contact-sheet.png")
        do {
            try data.write(to: file, options: .atomic)
            contactSheetFile = file
            showContactSheetShare = true
        } catch {
            Haptics.error()
            contactSheetError = "Couldn't build the contact sheet. Try again."
        }
    }
}

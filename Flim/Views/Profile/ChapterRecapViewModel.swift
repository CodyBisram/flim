import Foundation
import Observation
import SwiftUI

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

    init(profileId: UUID, chapter: ChapterSummary) {
        self.profileId = profileId
        self.chapter = chapter
    }

    var displayScale: CGFloat = 3

    /// Every photo in the month, `taken_at` ascending, as `chapter_photos` returned it.
    private(set) var monthPhotos: [ChapterPhoto] = []
    /// The subset actually played, chronological order. Equal to `monthPhotos` when the month
    /// has fifteen shots or fewer; otherwise `ChapterCuration`'s pick, UNION any photo a stat line
    /// on the closing card points at (see `load()`), so tapping "Most reacted"/"Most commented"
    /// can always land on a real page in this same deck rather than a photo curation dropped.
    private(set) var deck: [ChapterPhoto] = []
    var urls: [String: URL] = [:]
    private(set) var isLoadingDeck = false
    /// `true` once `load()` has run, whether or not it found anything, so the empty state can
    /// tell "still loading" apart from "genuinely nothing here".
    private(set) var loaded = false

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

    /// Loads the month, curates it, and resolves every URL the pager will need, all before
    /// playback starts: the pager's own structural-stability rule means every page mounts at
    /// once, so every photo's URL should already be in hand rather than racing in per page.
    func load(feed: FeedService, chapters: ChapterService) async {
        guard !loaded else { return }
        isLoadingDeck = true
        defer { isLoadingDeck = false; loaded = true }

        async let photosResult = chapters.photos(for: profileId, monthStart: chapter.monthStart)
        async let statsResult = chapters.stats(for: profileId, monthStart: chapter.monthStart)
        let photos = await photosResult
        monthPhotos = photos
        stats = await statsResult
        guard !photos.isEmpty else { deck = []; return }

        let pickedIds = await ChapterCuration.shared.curate(
            photos: photos, displayScale: displayScale,
            resolveThumbURL: { [feed] photo in await feed.signedURL(for: photo.displayPath) })
        var pickedSet = Set(pickedIds)
        // Whatever the closing card can point a tap at must actually be in the deck, even when
        // curation would otherwise have dropped it: a month with more than fifteen candidates
        // trims aggressively, and the most-reacted/most-commented shot is exactly the kind of
        // single photo that trim has no reason to keep on its own merits.
        let highlightIds = [stats[.mostReacted]?.photoId, stats[.mostCommented]?.photoId].compactMap { $0 }
        pickedSet.formUnion(highlightIds)
        // `photos` is already `taken_at` ascending, so filtering it (rather than reassembling
        // from `pickedIds`' own order) is what keeps the deck chronological.
        deck = photos.filter { pickedSet.contains($0.id) }

        var paths = Set(deck.flatMap { [$0.displayPath, $0.viewPath] })
        // The closing card's own thumb, straight off the stat row: usually the same value as the
        // matching `ChapterPhoto.thumbPath` above, but resolved explicitly in case the RPC ever
        // hands back a different rendition for it.
        let highlightThumbPaths = [stats[.mostReacted]?.photoThumbPath, stats[.mostCommented]?.photoThumbPath]
            .compactMap { $0 }
        paths.formUnion(highlightThumbPaths)
        guard !paths.isEmpty else { return }
        let resolved = await feed.signedURLs(for: Array(paths))
        for (path, url) in resolved { urls[path] = url }
    }

    /// The deck index of `photoId`, if it's actually in this session's deck. `load()` guarantees
    /// any photo a closing-card line points at is unioned into the deck, so this only fails for a
    /// month whose photos never finished loading at all. Used by `ChapterRecapView` to seed
    /// `PhotoPagerView.startIndex` when a closing-card thumb is tapped; the pager owns its own
    /// selection from there, so this view model tracks no index of its own.
    func deckIndex(ofPhoto photoId: UUID) -> Int? {
        deck.firstIndex { $0.id == photoId }
    }
}

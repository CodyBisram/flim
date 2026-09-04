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
    /// has fifteen shots or fewer; otherwise `ChapterCuration`'s pick.
    private(set) var deck: [ChapterPhoto] = []
    var urls: [String: URL] = [:]
    private(set) var isLoadingDeck = false
    /// `true` once `load()` has run, whether or not it found anything, so the empty state can
    /// tell "still loading" apart from "genuinely nothing here".
    private(set) var loaded = false

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

        let photos = await chapters.photos(for: profileId, monthStart: chapter.monthStart)
        monthPhotos = photos
        guard !photos.isEmpty else { deck = []; return }

        let pickedIds = await ChapterCuration.shared.curate(
            photos: photos, displayScale: displayScale,
            resolveThumbURL: { [feed] photo in await feed.signedURL(for: photo.displayPath) })
        let pickedSet = Set(pickedIds)
        // `photos` is already `taken_at` ascending, so filtering it (rather than reassembling
        // from `pickedIds`' own order) is what keeps the deck chronological.
        deck = photos.filter { pickedSet.contains($0.id) }

        let paths = Set(deck.flatMap { [$0.displayPath, $0.viewPath] })
        guard !paths.isEmpty else { return }
        let resolved = await feed.signedURLs(for: Array(paths))
        for (path, url) in resolved { urls[path] = url }
    }
}

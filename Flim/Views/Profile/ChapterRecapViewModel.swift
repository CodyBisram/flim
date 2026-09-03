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
    var index = 0

    var isEmpty: Bool { loaded && deck.isEmpty }
    var currentPhoto: ChapterPhoto? { deck[safe: index] }

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

    func moved(to newIndex: Int) {
        guard deck.indices.contains(newIndex) else { return }
        index = newIndex
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

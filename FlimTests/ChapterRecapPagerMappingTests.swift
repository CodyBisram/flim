import Testing
import Foundation
@testable import Flim

/// The pure seam between the recap's curated deck and `PhotoPagerView`'s own input shape:
/// `ChapterRecapViewModel.pagerPhotos`/`pagerSignedURLs`. Pins that the viewer is handed exactly
/// the curated ids, in the deck's own (chronological) order, never the whole month, and that the
/// mapping never leaks a `rollId` or a stale `developsAt` the pager could misread.
struct ChapterRecapPagerMappingTests {
    private func photo(_ id: UUID, takenAt: Date, thumbPath: String? = "thumb", feedPath: String? = "feed",
                        storagePath: String = "storage", rollId: UUID? = nil, postId: UUID? = nil) -> ChapterPhoto {
        ChapterPhoto(id: id, takenAt: takenAt, thumbPath: thumbPath, feedPath: feedPath,
                     storagePath: storagePath, rollId: rollId, rollName: nil, postId: postId)
    }

    @Test("the pager gets exactly the curated deck's ids, in the deck's own order")
    func handsOverExactlyTheCuratedIdsInOrder() {
        let base = Date(timeIntervalSince1970: 0)
        let ids = (0..<5).map { _ in UUID() }
        let deck = ids.enumerated().map { index, id in
            photo(id, takenAt: base.addingTimeInterval(TimeInterval(index) * 60))
        }
        let profileId = UUID()

        let pagerPhotos = ChapterRecapViewModel.pagerPhotos(from: deck, profileId: profileId)

        #expect(pagerPhotos.map(\.id) == ids)
    }

    @Test("an empty deck produces an empty pager input")
    func emptyDeckProducesEmptyPagerInput() {
        #expect(ChapterRecapViewModel.pagerPhotos(from: [], profileId: UUID()).isEmpty)
    }

    @Test("every mapped photo carries the chapter's own profile id, never a mix of authors")
    func everyPhotoIsAttributedToTheChapterProfile() {
        let profileId = UUID()
        let deck = [photo(UUID(), takenAt: .now), photo(UUID(), takenAt: .now.addingTimeInterval(60))]

        let pagerPhotos = ChapterRecapViewModel.pagerPhotos(from: deck, profileId: profileId)

        #expect(pagerPhotos.allSatisfy { $0.userId == profileId })
    }

    @Test("rollId is dropped even for a shot that came from a roll")
    func rollIdIsDroppedEvenWhenSourcedFromARoll() {
        let rollId = UUID()
        let deck = [photo(UUID(), takenAt: .now, rollId: rollId)]

        let pagerPhotos = ChapterRecapViewModel.pagerPhotos(from: deck, profileId: UUID())

        #expect(pagerPhotos.first?.rollId == nil)
    }

    @Test("every mapped photo is already \"ready\", so the pager's own develop gate never blocks it")
    func everyPhotoIsAlreadyReady() {
        let deck = [photo(UUID(), takenAt: .now)]

        let pagerPhotos = ChapterRecapViewModel.pagerPhotos(from: deck, profileId: UUID())

        #expect(pagerPhotos.allSatisfy { $0.isReady })
    }

    @Test("signed URLs are keyed by photo id, read off each photo's own displayPath")
    func signedURLsAreKeyedByPhotoId() {
        let a = photo(UUID(), takenAt: .now, thumbPath: "a-thumb", storagePath: "a-storage")
        let b = photo(UUID(), takenAt: .now, thumbPath: nil, storagePath: "b-storage")
        let deck = [a, b]
        let aURL = URL(string: "https://example.com/a")!
        let bURL = URL(string: "https://example.com/b")!
        // Keyed by `displayPath`: `a`'s is its thumbPath, `b`'s falls back to its storagePath
        // (no thumbPath), matching `ChapterPhoto.displayPath`'s own rule.
        let urls: [String: URL] = ["a-thumb": aURL, "b-storage": bURL]

        let signedURLs = ChapterRecapViewModel.pagerSignedURLs(from: deck, urls: urls)

        #expect(signedURLs[a.id] == aURL)
        #expect(signedURLs[b.id] == bURL)
    }

    @Test("a photo with no resolved URL yet is simply absent, not a crash or a placeholder entry")
    func unresolvedPhotoIsAbsentFromSignedURLs() {
        let deck = [photo(UUID(), takenAt: .now, thumbPath: "missing")]

        let signedURLs = ChapterRecapViewModel.pagerSignedURLs(from: deck, urls: [:])

        #expect(signedURLs.isEmpty)
    }

    // MARK: - pagerPosts (the reaction/comment fix)
    //
    // A chapter photo IS a post; `PhotoPagerView.posts` is what makes its reactions/comments read
    // `post_reactions`/`post_comments` instead of the roll-photo tables it was never written to.

    @Test("a photo carrying post_id maps to a Post keyed by its own photo id")
    func photoWithPostIdMapsToAPost() {
        let profileId = UUID()
        let postId = UUID()
        let deck = [photo(UUID(), takenAt: .now, postId: postId)]

        let posts = ChapterRecapViewModel.pagerPosts(from: deck, profileId: profileId)

        #expect(posts.count == 1)
        #expect(posts[deck[0].id]?.id == postId)
        #expect(posts[deck[0].id]?.userId == profileId)
        #expect(posts[deck[0].id]?.photoId == deck[0].id)
    }

    @Test("a photo with no post_id (older server) is simply absent, not a crash or a placeholder entry")
    func photoWithoutPostIdIsAbsentFromPosts() {
        let deck = [photo(UUID(), takenAt: .now, postId: nil)]

        let posts = ChapterRecapViewModel.pagerPosts(from: deck, profileId: UUID())

        #expect(posts.isEmpty)
    }

    @Test("a mixed deck maps only the photos that carry post_id, preserving every id correctly")
    func mixedDeckMapsOnlyPostBackedPhotos() {
        let profileId = UUID()
        let withPost = photo(UUID(), takenAt: .now, postId: UUID())
        let withoutPost = photo(UUID(), takenAt: .now.addingTimeInterval(60), postId: nil)
        let deck = [withPost, withoutPost]

        let posts = ChapterRecapViewModel.pagerPosts(from: deck, profileId: profileId)

        #expect(posts.count == 1)
        #expect(posts[withPost.id] != nil)
        #expect(posts[withoutPost.id] == nil)
    }

    @Test("the mapped Post carries the photo's own storage/thumb/feed paths and taken date through")
    func mappedPostCarriesPhotoFieldsThrough() {
        let takenAt = Date(timeIntervalSince1970: 1_000_000)
        let p = photo(UUID(), takenAt: takenAt, thumbPath: "t.jpg", feedPath: "f.jpg",
                      storagePath: "s.jpg", postId: UUID())

        let posts = ChapterRecapViewModel.pagerPosts(from: [p], profileId: UUID())

        let post = posts[p.id]
        #expect(post?.storagePath == "s.jpg")
        #expect(post?.thumbPath == "t.jpg")
        #expect(post?.feedPath == "f.jpg")
        #expect(post?.takenAt == takenAt)
    }

    // MARK: - provisionalDeck (the load-time fix)
    //
    // `ChapterRecapViewModel.load()` sets this immediately, before curation runs at all, so the
    // recap is playable the instant `chapter_photos` returns rather than after a Vision pass over
    // the whole month.

    @Test("a month at or under the limit is returned whole, unchanged")
    func monthAtOrUnderLimitIsReturnedWhole() {
        let base = Date(timeIntervalSince1970: 0)
        let deck = (0..<10).map { photo(UUID(), takenAt: base.addingTimeInterval(TimeInterval($0))) }

        let provisional = ChapterRecapViewModel.provisionalDeck(from: deck, limit: 15)

        #expect(provisional.map(\.id) == deck.map(\.id))
    }

    @Test("a month over the limit is trimmed to exactly the first `limit` shots, chronological")
    func monthOverLimitIsTrimmedToTheFirstN() {
        let base = Date(timeIntervalSince1970: 0)
        let deck = (0..<40).map { photo(UUID(), takenAt: base.addingTimeInterval(TimeInterval($0))) }

        let provisional = ChapterRecapViewModel.provisionalDeck(from: deck, limit: 15)

        #expect(provisional.count == 15)
        #expect(provisional.map(\.id) == Array(deck.prefix(15)).map(\.id))
    }

    @Test("an empty month produces an empty provisional deck")
    func emptyMonthProducesEmptyProvisionalDeck() {
        #expect(ChapterRecapViewModel.provisionalDeck(from: [], limit: 15).isEmpty)
    }
}

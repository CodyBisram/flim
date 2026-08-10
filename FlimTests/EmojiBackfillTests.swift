import XCTest
@testable import Flim

/// `PhotoService.shouldAttemptEmojiBackfill`, the pure gate in front of
/// `backfillSuggestedEmoji`'s side effects (disk read, classify, RPC write).
///
/// Two failure modes this gate exists to prevent: spamming a guaranteed-failing write RPC for
/// every roll-mate's photo (`set_photo_suggested_emoji` only succeeds for the OWNER), and silently
/// overwriting a photo's real, capture-time suggestion with a worse one classified off the graded
/// bytes, `set_photo_suggested_emoji` upserts, so a second write is not a no-op.
final class EmojiBackfillTests: XCTestCase {
    private func photo(userId: UUID) -> Photo {
        Photo(
            id: UUID(), userId: userId, rollId: nil, storagePath: "u/p.jpg",
            takenAt: Date(timeIntervalSince1970: 0), developsAt: Date(timeIntervalSince1970: 0),
            isDeveloped: true
        )
    }

    func testOwnPhotoWithNoExistingSuggestionIsAttempted() {
        let owner = UUID()
        XCTAssertTrue(PhotoService.shouldAttemptEmojiBackfill(
            photo: photo(userId: owner), viewerId: owner, existingSuggestion: []
        ))
    }

    func testSomeoneElsesPhotoIsNeverAttempted() {
        // A roll-mate's photo: the write RPC would just fail server-side, so this must bail
        // before ever reading the disk cache or classifying anything.
        XCTAssertFalse(PhotoService.shouldAttemptEmojiBackfill(
            photo: photo(userId: UUID()), viewerId: UUID(), existingSuggestion: []
        ))
    }

    func testAFailedSessionLookupIsTreatedLikeAMismatchNotAFreePass() {
        let owner = UUID()
        XCTAssertFalse(PhotoService.shouldAttemptEmojiBackfill(
            photo: photo(userId: owner), viewerId: nil, existingSuggestion: []
        ))
    }

    func testAPhotoThatAlreadyHasASuggestionIsNeverOverwritten() {
        let owner = UUID()
        XCTAssertFalse(PhotoService.shouldAttemptEmojiBackfill(
            photo: photo(userId: owner), viewerId: owner, existingSuggestion: ["🐶", "🐾"]
        ))
    }

    func testAPhotoNeverFetchedYetIsNotAttempted() {
        // `nil` means "we don't know yet", not "confirmed empty". Attempting here would risk the
        // exact overwrite this gate exists to prevent, on a photo that might turn out to already
        // have one once the fetch actually lands.
        let owner = UUID()
        XCTAssertFalse(PhotoService.shouldAttemptEmojiBackfill(
            photo: photo(userId: owner), viewerId: owner, existingSuggestion: nil
        ))
    }
}

import XCTest
import Supabase
@testable import Flim

/// `PhotoService.isRollDevelopedRefusal`, the precise test that decides whether a failed capture
/// falls back to a personal instant (see `captureAsPersonalFallback`) or keeps the ordinary
/// queued-retry behaviour.
///
/// This must be narrow. A capture into a roll can be refused for exactly one un-retryable reason,
/// the roll finished developing mid-upload, and every other failure (a network drop, some other
/// RLS refusal, a personal capture's own insert failing) must NOT be mistaken for it: doing so
/// would silently strip a photo out of a roll that is still open.
final class PhotoServiceFallbackTests: XCTestCase {
    private let rollId = UUID()

    /// The exact shape `captureAndUpload` sees: a roll id present, and Postgres's RLS refusal
    /// code for the roll-developed INSERT policy.
    func testRollDevelopedRefusalIsDetected() {
        let error = PostgrestError(
            detail: nil, code: "42501",
            message: "new row violates row-level security policy for table \"photos\""
        )
        XCTAssertTrue(PhotoService.isRollDevelopedRefusal(rollId: rollId, error: error))
    }

    /// A personal capture (`rollId == nil`) never hits the roll-developed policy at all, so even
    /// an (impossible in practice) 42501 on one must not trigger the fallback.
    func testNoRollIdNeverMatchesEvenWithTheSameCode() {
        let error = PostgrestError(detail: nil, code: "42501", message: "permission denied")
        XCTAssertFalse(PhotoService.isRollDevelopedRefusal(rollId: nil, error: error))
    }

    /// A network error mid-upload must keep the ORDINARY retry path. This is the one requirement
    /// that must never regress: a transient failure must not be treated as a permanently stuck
    /// roll-developed refusal and silently reroute someone's roll shot to their personal deck.
    func testNetworkErrorIsNotMistakenForTheRefusal() {
        struct FakeNetworkError: Error {}
        XCTAssertFalse(PhotoService.isRollDevelopedRefusal(rollId: rollId, error: FakeNetworkError()))
    }

    /// A DIFFERENT Postgres error on a roll insert (e.g. a genuine permissions problem unrelated
    /// to `is_roll_developed`) must not be swept into the fallback just because it's also a
    /// `PostgrestError` on a roll shot; only this one specific code counts.
    func testDifferentPostgresCodeOnARollInsertIsNotMistakenForIt() {
        let error = PostgrestError(detail: nil, code: "23505", message: "duplicate key value")
        XCTAssertFalse(PhotoService.isRollDevelopedRefusal(rollId: rollId, error: error))
    }

    // MARK: - PhotoService.isDuplicatePhotoId

    /// The exact shape Postgres reports for a re-inserted primary key: the constraint name in the
    /// detail. This is what tells a retry "the row already exists, fetch it and call the capture
    /// a success" rather than queuing yet another retry that would only collide again.
    func testDuplicatePrimaryKeyIsDetectedFromDetail() {
        let error = PostgrestError(
            detail: "Key (id)=(11111111-1111-1111-1111-111111111111) already exists.",
            code: "23505", message: "duplicate key value violates unique constraint \"photos_pkey\""
        )
        XCTAssertTrue(PhotoService.isDuplicatePhotoId(error))
    }

    /// A 23505 whose message names a different constraint must not be classified as the id
    /// conflict this retry path is built to self-heal from.
    func testDifferentUniqueConstraintIsNotMistakenForTheDuplicateId() {
        let error = PostgrestError(
            detail: "Key (photo_id, user_id, emoji)=(...) already exists.",
            code: "23505", message: "duplicate key value violates unique constraint \"reactions_unique\""
        )
        XCTAssertFalse(PhotoService.isDuplicatePhotoId(error))
    }

    // MARK: - PhotoService.shouldDiscardFailedUpload

    /// The exact case this exists for: a sidecar left behind after its own upload actually
    /// succeeded (see `restoreFailedUploads`) must be discarded once a row with that id is
    /// confirmed to exist, not resurrected as a retry forever.
    func testDiscardsARecordWhosePhotoAlreadyExistsOnTheServer() {
        let photoId = UUID()
        XCTAssertTrue(PhotoService.shouldDiscardFailedUpload(
            photoId: photoId, storagePath: nil,
            existingPhotoIds: [photoId], existingStoragePaths: []))
    }

    /// A genuinely still-pending capture, whose id the server has never seen, must never be
    /// discarded: that would silently lose the only copy of an un-uploaded photograph.
    func testKeepsARecordThatIsNotOnTheServer() {
        let photoId = UUID()
        XCTAssertFalse(PhotoService.shouldDiscardFailedUpload(
            photoId: photoId, storagePath: nil,
            existingPhotoIds: [], existingStoragePaths: []))
    }

    /// A record queued before `photoId` existed (an old sidecar, see `FailedUpload.photoId`'s own
    /// doc) never reached Storage on any prior attempt, so there is nothing to look up on the
    /// server and it must never be discarded by this check.
    func testNeverDiscardsARecordWithNoPhotoIdOrStoragePath() {
        XCTAssertFalse(PhotoService.shouldDiscardFailedUpload(
            photoId: nil, storagePath: nil,
            existingPhotoIds: [], existingStoragePaths: []))
    }

    /// `photoId` wins when both are present: it's the primary, more precise identity, so a
    /// stale (or coincidentally matching) storage path can never override a confirmed absence.
    func testPhotoIdTakesPrecedenceOverStoragePath() {
        let photoId = UUID()
        let path = "user/\(photoId).jpg"
        XCTAssertFalse(PhotoService.shouldDiscardFailedUpload(
            photoId: photoId, storagePath: path,
            existingPhotoIds: [], existingStoragePaths: [path]))
    }

    /// The fallback case: a sidecar with a storage path but no photo id (a shape that should not
    /// occur given the two are always written together today, but is checked anyway, see
    /// `shouldDiscardFailedUpload`'s own doc) is discarded once that exact path is confirmed to
    /// already name a row on the server.
    func testDiscardsARecordByStoragePathWhenNoPhotoIdIsPresent() {
        let path = "user123/abc.jpg"
        XCTAssertTrue(PhotoService.shouldDiscardFailedUpload(
            photoId: nil, storagePath: path,
            existingPhotoIds: [], existingStoragePaths: [path]))
    }
}

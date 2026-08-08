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
}

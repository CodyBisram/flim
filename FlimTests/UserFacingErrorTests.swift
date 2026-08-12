import XCTest
@testable import Flim

/// `UserFacingError`'s pure classification: no network, no account, just an `Error` in and either
/// `nil` (say nothing, this was superseded, not failed) or the one generic, actionable message out.
///
/// This pins the exact regression reported from a device: pulling to refresh surfaced "The
/// operation couldn't be completed. (Swift.CancellationError error 1.)" as a full-screen error.
/// That string is what `CancellationError().localizedDescription` actually reads on iOS, so the
/// tests below assert against `messageIfNotCancelled` directly rather than duplicating it.
final class UserFacingErrorTests: XCTestCase {

    func testCancellationErrorProducesNoUserFacingMessage() {
        XCTAssertNil(UserFacingError.messageIfNotCancelled(for: CancellationError()))
    }

    func testURLErrorCancelledProducesNoUserFacingMessage() {
        // `URLError.cancelled` is the networking-layer equivalent of `CancellationError`: an
        // `URLSession` task torn down by a cancelled parent `Task` throws this, not
        // `CancellationError` itself, so both have to be treated the same way.
        XCTAssertNil(UserFacingError.messageIfNotCancelled(for: URLError(.cancelled)))
    }

    func testAGenuineFailureProducesTheGenericMessage() {
        XCTAssertEqual(UserFacingError.messageIfNotCancelled(for: URLError(.notConnectedToInternet)),
                       UserFacingError.genericMessage)
    }

    func testAnArbitraryThrownErrorProducesTheGenericMessage() {
        struct SomeFailure: Error {}
        XCTAssertEqual(UserFacingError.messageIfNotCancelled(for: SomeFailure()),
                       UserFacingError.genericMessage)
    }

    func testTheGenericMessageIsNeverTheRawSwiftDescription() {
        // The regression itself: a raw `CancellationError().localizedDescription` reads like a
        // stack trace, not a sentence a user can act on.
        XCTAssertFalse(UserFacingError.genericMessage.contains("CancellationError"))
        XCTAssertFalse(UserFacingError.genericMessage.contains("Swift."))
    }

    func testIsCancellationRecognizesBothCancellationShapes() {
        XCTAssertTrue(UserFacingError.isCancellation(CancellationError()))
        XCTAssertTrue(UserFacingError.isCancellation(URLError(.cancelled)))
        XCTAssertFalse(UserFacingError.isCancellation(URLError(.timedOut)))
    }
}

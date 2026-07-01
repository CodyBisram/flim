import XCTest
@testable import Flim

/// Whether a photo counts as "developed" is purely a function of its develop time.
final class PhotoReadinessTests: XCTestCase {
    private func photo(developsAt: Date) -> Photo {
        Photo(
            id: UUID(), userId: UUID(), rollId: nil, storagePath: "x/y.jpg",
            takenAt: Date(timeIntervalSince1970: 0), developsAt: developsAt, isDeveloped: false
        )
    }

    func testReadyOnceDevelopTimeHasPassed() {
        XCTAssertTrue(photo(developsAt: .now.addingTimeInterval(-1)).isReady)
    }

    func testNotReadyBeforeDevelopTime() {
        XCTAssertFalse(photo(developsAt: .now.addingTimeInterval(3600)).isReady)
    }

    func testTimeUntilDevelopedIsPositiveForFutureShots() {
        XCTAssertGreaterThan(photo(developsAt: .now.addingTimeInterval(120)).timeUntilDeveloped, 0)
    }
}

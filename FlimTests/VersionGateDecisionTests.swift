import XCTest
@testable import Flim

/// `versionGateDecision`, the pure comparison behind the app-update gate, and
/// `shouldPresentVersionNudge`, the once-per-version rule for its dismissible nudge.
///
/// The two things this pins hardest: the compare must be SEMANTIC, not lexical (a string compare
/// puts "1.10.0" behind "1.9.0", which is exactly backwards, and it would happen the moment the
/// app reaches 1.10 — this table has an explicit case for it), and the decision must FAIL OPEN
/// on every kind of doubt. This is the one screen in the app that can make it unusable, so an
/// unparseable or missing value must never resolve to `.blocked` or even `.nudge`; it must
/// resolve to `.none`, same as if the server said "you're fine."
final class VersionGateDecisionTests: XCTestCase {

    // MARK: - The inert ship state: both versions "0.0.0"

    func testTheInertDefaultRowShowsNothing() {
        XCTAssertEqual(
            versionGateDecision(current: "1.4.1", minimum: "0.0.0", latest: "0.0.0"),
            .none)
    }

    // MARK: - Ordinary blocked / nudge / none

    func testBelowMinimumIsBlocked() {
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "1.2.0", latest: "1.4.0"),
            .blocked)
    }

    func testAtMinimumIsNotBlocked() {
        // "below minimum" must be strict; the minimum itself is still usable.
        XCTAssertEqual(
            versionGateDecision(current: "1.2.0", minimum: "1.2.0", latest: "1.4.0"),
            .nudge)
    }

    func testBetweenMinimumAndLatestIsANudge() {
        XCTAssertEqual(
            versionGateDecision(current: "1.3.0", minimum: "1.2.0", latest: "1.4.0"),
            .nudge)
    }

    func testAtLatestIsNone() {
        XCTAssertEqual(
            versionGateDecision(current: "1.4.0", minimum: "1.2.0", latest: "1.4.0"),
            .none)
    }

    func testAboveLatestIsNone() {
        // A build ahead of the server's own "latest" (e.g. an internal build not yet reflected
        // server-side) must never be treated as behind.
        XCTAssertEqual(
            versionGateDecision(current: "1.5.0", minimum: "1.2.0", latest: "1.4.0"),
            .none)
    }

    // MARK: - Semantic compare, not lexical

    func testDoubleDigitMinorVersionSortsAfterSingleDigit() {
        // The exact regression a string compare would reintroduce: "1.10.0" < "1.9.0" lexically
        // (the character '1' sorts before '9'), which would wrongly nudge or even block a build
        // that is actually newer.
        XCTAssertEqual(
            versionGateDecision(current: "1.10.0", minimum: "0.0.0", latest: "1.9.0"),
            .none)
        XCTAssertEqual(
            versionGateDecision(current: "1.9.0", minimum: "0.0.0", latest: "1.10.0"),
            .nudge)
    }

    // MARK: - Differing component counts

    func testShorterComponentCountIsPaddedWithZeros() {
        // "1.4" == "1.4.0", which is below "1.4.1".
        XCTAssertEqual(
            versionGateDecision(current: "1.4", minimum: "0.0.0", latest: "1.4.1"),
            .nudge)
        XCTAssertEqual(
            versionGateDecision(current: "1.4.1", minimum: "0.0.0", latest: "1.4"),
            .none)
        XCTAssertEqual(
            versionGateDecision(current: "1.4.0", minimum: "0.0.0", latest: "1.4"),
            .none)
    }

    // MARK: - Fail open: the cases that matter most

    func testAnUnparseableCurrentVersionNeverBlocksOrNudges() {
        XCTAssertEqual(
            versionGateDecision(current: "not-a-version", minimum: "1.0.0", latest: "1.0.0"),
            .none)
    }

    func testAnEmptyCurrentVersionNeverBlocksOrNudges() {
        XCTAssertEqual(
            versionGateDecision(current: "", minimum: "1.0.0", latest: "1.0.0"),
            .none)
    }

    func testAnUnparseableMinimumIsTreatedAsNoRequirement() {
        // A malformed `minimum_version` (a typo made server-side) must not lock out every install
        // until it's fixed; it degrades to "no minimum", not "block everyone".
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "not-a-version", latest: "1.0.0"),
            .none)
    }

    func testAnUnparseableLatestIsTreatedAsNoRequirement() {
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "0.0.0", latest: "not-a-version"),
            .none)
    }

    func testAnUnparseableMinimumStillAllowsARealNudgeFromLatest() {
        // The minimum failing to parse must not swallow a perfectly valid latest-version nudge.
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "garbage", latest: "1.1.0"),
            .nudge)
    }

    func testANegativeComponentIsUnparseable() {
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "-1.0.0", latest: "0.0.0"),
            .none)
    }

    func testATrailingDotIsUnparseable() {
        XCTAssertEqual(
            versionGateDecision(current: "1.0.0", minimum: "1.0.", latest: "0.0.0"),
            .none)
    }
}

/// `shouldPresentVersionNudge`, the once-per-`latest_version` rule for the dismissible nudge.
final class VersionGateNudgePresentationTests: XCTestCase {
    func testAFreshNudgeWithNothingDismissedPresents() {
        XCTAssertTrue(shouldPresentVersionNudge(decision: .nudge, latestVersion: "1.4.0", dismissedVersion: ""))
    }

    func testADismissedVersionDoesNotRepresent() {
        XCTAssertFalse(shouldPresentVersionNudge(decision: .nudge, latestVersion: "1.4.0", dismissedVersion: "1.4.0"))
    }

    func testAGenuinelyNewerLatestVersionRepresentsDespiteAnOlderDismissal() {
        // The whole point of keying on the version string rather than a bool: dismissing 1.4.0's
        // nudge must not swallow 1.5.0's.
        XCTAssertTrue(shouldPresentVersionNudge(decision: .nudge, latestVersion: "1.5.0", dismissedVersion: "1.4.0"))
    }

    func testNoneNeverPresentsRegardlessOfDismissalState() {
        XCTAssertFalse(shouldPresentVersionNudge(decision: .none, latestVersion: "1.4.0", dismissedVersion: ""))
    }

    func testBlockedNeverPresentsAsANudge() {
        // Blocked has its own undismissable screen; it must never also show the soft nudge.
        XCTAssertFalse(shouldPresentVersionNudge(decision: .blocked, latestVersion: "1.4.0", dismissedVersion: ""))
    }
}

/// The off-App-Store softening. A hard block must be unreachable on TestFlight and DEBUG, but the
/// rest of the path has to still run there, or the gate's first real execution is in production.
final class VersionGateSofteningTests: XCTestCase {
    func testBlockBecomesNudgeOffTheAppStore() {
        XCTAssertEqual(softenedOffAppStore(.blocked, isAppStore: false), .nudge)
    }

    func testBlockSurvivesOnTheAppStore() {
        XCTAssertEqual(softenedOffAppStore(.blocked, isAppStore: true), .blocked)
    }

    func testNudgeAndNoneAreUntouchedEitherWay() {
        for isAppStore in [true, false] {
            XCTAssertEqual(softenedOffAppStore(.nudge, isAppStore: isAppStore), .nudge)
            XCTAssertEqual(softenedOffAppStore(.none, isAppStore: isAppStore), VersionGateDecision.none)
        }
    }
}

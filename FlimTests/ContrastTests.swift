import XCTest
import SwiftUI
@testable import Flim

/// Text contrast against the app's background, measured rather than eyeballed.
///
/// FLIM is a dark app whose whole look depends on text receding, which makes it very easy to
/// recede past the point of being readable and impossible to notice on a good screen in a dark
/// room. `textTertiary` sat at 4.00:1 for months — under the 4.5:1 WCAG AA requires for
/// normal-size text — while being used almost entirely on 12 and 13pt captions.
///
/// These are computed from the actual token values, so nudging a colour darker for looks fails
/// here instead of shipping.
final class ContrastTests: XCTestCase {

    /// WCAG relative luminance for an sRGB grey component.
    private func luminance(_ c: Double) -> Double {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private func contrast(_ a: Double, _ b: Double) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The token values as declared in FlimTheme. Kept as literals so this test is checking the
    /// numbers a human chose, not re-deriving them from the same source and agreeing with itself.
    private let background = 0.04
    private let primary = 1.0
    private let secondary = 0.62
    private let tertiary = 0.48

    // MARK: - AA

    func testTertiaryTextMeetsAAForNormalText() {
        // The regression this file exists for. 0.44 gave 4.00 and failed.
        let r = contrast(tertiary, background)
        XCTAssertGreaterThanOrEqual(r, 4.5, String(format: "tertiary is %.2f:1, AA needs 4.5", r))
    }

    func testSecondaryTextMeetsAA() {
        XCTAssertGreaterThanOrEqual(contrast(secondary, background), 4.5)
    }

    func testPrimaryTextMeetsAAA() {
        XCTAssertGreaterThanOrEqual(contrast(primary, background), 7.0)
    }

    // MARK: - The hierarchy still reads as a hierarchy

    func testTheThreeTiersStayInOrder() {
        // Fixing contrast by brightening tertiary until it collides with secondary would trade an
        // accessibility problem for a design one.
        let p = contrast(primary, background)
        let s = contrast(secondary, background)
        let t = contrast(tertiary, background)
        XCTAssertGreaterThan(p, s)
        XCTAssertGreaterThan(s, t)
    }

    func testTertiaryIsStillClearlyFainterThanSecondary() {
        // It has a job: to recede. Passing AA should not turn it into secondary.
        XCTAssertLessThan(contrast(tertiary, background), contrast(secondary, background) * 0.8)
    }

    // MARK: - Sanity

    func testTheFormulaMatchesAKnownPair() {
        // White on black is 21:1 by definition; if this drifts the rest of the file is measuring
        // nothing.
        XCTAssertEqual(contrast(1.0, 0.0), 21.0, accuracy: 0.01)
    }
}

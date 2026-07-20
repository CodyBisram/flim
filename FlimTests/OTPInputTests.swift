import XCTest
@testable import Flim

/// `OTPView.sanitizeOTPInput` backs both the digit field's live-typed/autofill binding and the
/// paste button, so both take identical input from the system's one-time-code autofill and the
/// clipboard.
final class OTPInputTests: XCTestCase {
    func testStripsNonDigitCharacters() {
        XCTAssertEqual(OTPView.sanitizeOTPInput("1a2b3c", length: 6), "123")
    }

    func testClampsToLength() {
        XCTAssertEqual(OTPView.sanitizeOTPInput("1234567890", length: 6), "123456")
    }

    /// The original autofill bug: iOS sometimes delivers the one-time code with a trailing
    /// space appended.
    func testHandlesTrailingSpaceFromAutofill() {
        XCTAssertEqual(OTPView.sanitizeOTPInput("123456 ", length: 6), "123456")
    }

    func testExactLengthInputPassesThroughUnchanged() {
        XCTAssertEqual(OTPView.sanitizeOTPInput("123456", length: 6), "123456")
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertEqual(OTPView.sanitizeOTPInput("", length: 6), "")
    }
}

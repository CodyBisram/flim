import XCTest
import UIKit
@testable import Flim

/// `KeyboardDismissPolicy`, the pure rule behind the app-level "tap anywhere to dismiss the
/// keyboard" gesture.
///
/// The gesture recognizer itself is UIKit wiring with no independent logic worth pinning (it just
/// forwards to this policy and calls `endEditing`), so these tests exercise the policy directly:
/// given what was actually touched, should the keyboard go away.
final class KeyboardDismissPolicyTests: XCTestCase {

    // MARK: - Ordinary background taps

    func testATapWithNoSpecialViewDismisses() {
        let plainView = UIView()
        XCTAssertTrue(KeyboardDismissPolicy.shouldDismiss(
            touchedView: plainView, location: .zero, exemptRects: []))
    }

    func testATapOnAnotherControlLikeAReactionChipOrTheLikeHeartStillDismisses() {
        // Regression guard for requirement 4: buttons elsewhere in the feed are ordinary views as
        // far as this policy is concerned, so a tap on one both dismisses the keyboard AND (via
        // `cancelsTouchesInView = false` on the recognizer itself) still fires the button.
        let button = UIButton()
        XCTAssertTrue(KeyboardDismissPolicy.shouldDismiss(
            touchedView: button, location: .zero, exemptRects: []))
    }

    // MARK: - The field being edited

    func testATapDirectlyOnATextFieldDoesNotDismiss() {
        let field = UITextField()
        XCTAssertFalse(KeyboardDismissPolicy.shouldDismiss(
            touchedView: field, location: .zero, exemptRects: []))
    }

    func testATapDirectlyOnATextViewDoesNotDismiss() {
        let field = UITextView()
        XCTAssertFalse(KeyboardDismissPolicy.shouldDismiss(
            touchedView: field, location: .zero, exemptRects: []))
    }

    func testATapOnAnInternalSubviewOfAFocusedFieldDoesNotDismiss() {
        // What actually hits a tap gesture recognizer inside a focused field is rarely the field
        // itself; SwiftUI's TextField, like UITextField, has internal subviews (the field editor,
        // a clear button). The policy has to walk up to find the field.
        let field = UITextField()
        let caret = UIView()
        let glyph = UIView()
        field.addSubview(caret)
        caret.addSubview(glyph)
        XCTAssertFalse(KeyboardDismissPolicy.shouldDismiss(
            touchedView: glyph, location: .zero, exemptRects: []))
    }

    func testATapOutsideAnyTextFieldWithNoSharedAncestryDismisses() {
        // Two unrelated view trees: a tap inside one must not be fooled by an unrelated text field
        // existing elsewhere on screen.
        let unrelatedField = UITextField()
        let card = UIView()
        let label = UIView()
        card.addSubview(label)
        _ = unrelatedField
        XCTAssertTrue(KeyboardDismissPolicy.shouldDismiss(
            touchedView: label, location: .zero, exemptRects: []))
    }

    // MARK: - Exempt zones (mention suggestions)

    func testATapInsideAnExemptRectDoesNotDismiss() {
        let plainView = UIView()
        let mentionRow = CGRect(x: 0, y: 500, width: 400, height: 44)
        let tapInsideRow = CGPoint(x: 120, y: 515)
        XCTAssertFalse(KeyboardDismissPolicy.shouldDismiss(
            touchedView: plainView, location: tapInsideRow, exemptRects: [mentionRow]))
    }

    func testATapOutsideAllExemptRectsStillDismisses() {
        let plainView = UIView()
        let mentionRow = CGRect(x: 0, y: 500, width: 400, height: 44)
        let tapElsewhere = CGPoint(x: 120, y: 200)
        XCTAssertTrue(KeyboardDismissPolicy.shouldDismiss(
            touchedView: plainView, location: tapElsewhere, exemptRects: [mentionRow]))
    }

    func testAnExemptRectDoesNotSuppressDismissalWhenTheMentionListHasClosed() {
        // Once matches go empty, MentionSuggestions stops rendering and its probe deregisters, so
        // by the time this runs there should be no exempt rect left to check against — modelled
        // here as an empty list, since that deregistration itself is UIKit lifecycle, not a rule
        // this policy makes.
        let plainView = UIView()
        let formerMentionRowLocation = CGPoint(x: 120, y: 515)
        XCTAssertTrue(KeyboardDismissPolicy.shouldDismiss(
            touchedView: plainView, location: formerMentionRowLocation, exemptRects: []))
    }

    // MARK: - Both rules at once

    func testATextFieldTapWinsEvenInsideAnExemptRectsBounds() {
        // Belt and suspenders: even if a text field happened to sit inside a registered exempt
        // rect, tapping the field itself must never dismiss.
        let field = UITextField()
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        XCTAssertFalse(KeyboardDismissPolicy.shouldDismiss(
            touchedView: field, location: CGPoint(x: 10, y: 10), exemptRects: [rect]))
    }
}

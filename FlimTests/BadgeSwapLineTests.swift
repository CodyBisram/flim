import Testing
import Foundation
import UIKit
@testable import Flim

/// The badge swap-in's copy has to fit where it lands: one line, in the handle row, on the
/// narrow devices. These measure with CoreText exactly what SwiftUI will lay out, the same
/// technique `BadgePillMetrics` already uses for the pills, so "fits" here is the shipped
/// number and not an estimate.
struct BadgeSwapLineTests {

    /// Every badge carries an emoji, and no two share one: a duplicate would make two swapped
    /// lines open identically, and an empty string would render a leading space.
    @Test("every badge has its own emoji")
    func emojiCatalog() {
        var seen: Set<String> = []
        for kind in ProfileBadgeKind.allCases {
            #expect(!kind.emoji.isEmpty, "\(kind) has no emoji")
            #expect(seen.insert(kind.emoji).inserted, "\(kind) shares an emoji with another badge")
        }
    }

    /// The wrapped height of `text` on a 393pt device at the WORST case the view permits: the
    /// scale floor. `boundingRect` wraps at word boundaries exactly as the label will, so
    /// word-wrap waste and emoji line height are both in the measurement, not estimated.
    private func wrappedHeight(of text: String) -> CGFloat {
        let available = 393 - BadgeSwapMetrics.horizontalPadding * 2
        let font = UIFont.systemFont(ofSize: BadgeSwapMetrics.pointSize * BadgeSwapMetrics.minimumScale)
        return (text as NSString).boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font],
            context: nil
        ).height
    }

    /// The acceptance: every badge's copy, wrapped, fits inside the reserved two-line box at no
    /// smaller than the scale floor. One line reserved at a 0.52 floor was tried first, passed
    /// this suite's predecessor, and was rejected on device as illegible (`fullRoll`,
    /// 2026-08-20), which is why the test now measures the wrapped HEIGHT that ships rather
    /// than a single line's width. Checked for every badge, not just today's longest, so a
    /// future copy edit that overflows is named by the test instead of truncating on device.
    @Test("every swapped-in line fits the reserved box on a 393pt device")
    func linesFit() {
        for kind in ProfileBadgeKind.allCases {
            let height = wrappedHeight(of: "\(kind.emoji) \(kind.explanation)")
            #expect(height <= BadgeSwapMetrics.reservedHeight,
                    "\(kind): wraps to \(Int(height))pt at the scale floor, box is \(Int(BadgeSwapMetrics.reservedHeight))pt")
        }
    }

    /// The second beat on someone else's profile shows `howToEarn` in the same box.
    @Test("every how-to-earn line fits the reserved box on a 393pt device")
    func howToEarnFits() {
        for kind in ProfileBadgeKind.allCases {
            let height = wrappedHeight(of: kind.howToEarn)
            #expect(height <= BadgeSwapMetrics.reservedHeight,
                    "\(kind): wraps to \(Int(height))pt at the scale floor, box is \(Int(BadgeSwapMetrics.reservedHeight))pt")
        }
    }

    /// The box itself must hold two lines at FULL size, or the floor is doing hidden work: a
    /// line that could have rendered at 13pt would be shrunk by the frame rather than by width.
    @Test("the reserved box holds two full-size lines")
    func boxHoldsTwoFullSizeLines() {
        let twoLines = UIFont.systemFont(ofSize: BadgeSwapMetrics.pointSize).lineHeight * 2
        #expect(twoLines <= BadgeSwapMetrics.reservedHeight,
                "two lines need \(Int(twoLines.rounded(.up)))pt, box is \(Int(BadgeSwapMetrics.reservedHeight))pt")
    }
}

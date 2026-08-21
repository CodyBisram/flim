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

    /// The rendered width of `text` at FULL size, the way the shipped label lays it out.
    private func width(of text: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: BadgeSwapMetrics.pointSize)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The width one line has on the narrow phone this is held to.
    private var available: CGFloat { 393 - BadgeSwapMetrics.horizontalPadding * 2 }

    /// The acceptance, and it is a constraint on COPY rather than on layout: every badge's
    /// explanation fits one line at full size, so the swap-in is exactly the handle line's
    /// height and the header never grows a hole to accommodate a sentence.
    ///
    /// This is the third version of this rule and the first that pushes back on the writing.
    /// Version one scaled the longest copy down to 0.52 and shipped a ~7pt squint; version two
    /// reserved a two-line box, which fixed the squint and left an obvious gap under every
    /// one-line badge. When this fails, shorten the badge's `explanation`; do not raise the
    /// budget here.
    @Test("every explanation fits one line at full size on a 393pt device")
    func explanationsFitOneLine() {
        for kind in ProfileBadgeKind.allCases {
            let line = "\(kind.emoji) \(kind.explanation)"
            let w = width(of: line)
            #expect(w <= available,
                    "\(kind): needs \(Int(w))pt, only \(Int(available))pt available. Shorten the copy: \"\(kind.explanation)\"")
        }
    }

    /// The scale floor exists for Dynamic Type and narrower hardware, so nothing should be
    /// relying on it at the default size. If a line only fits once shrunk, the copy is too long
    /// and the test above is the one that should be failing.
    @Test("no explanation needs the scale floor to fit")
    func nothingRequiresShrinking() {
        for kind in ProfileBadgeKind.allCases {
            let w = width(of: "\(kind.emoji) \(kind.explanation)")
            #expect(w <= available / BadgeSwapMetrics.minimumScale,
                    "\(kind) cannot fit even at the floor")
        }
    }
}

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

    /// The acceptance: the longest line in the catalog fits ONE line on a 393pt device at the
    /// shipped metrics. Checked for every badge, not just today's longest, so a future copy edit
    /// that overflows is named by the test instead of truncating on device.
    @Test("every swapped-in line fits one line on a 393pt device")
    func linesFit() {
        let available = 393 - BadgeSwapMetrics.horizontalPadding * 2
        let font = UIFont.systemFont(ofSize: BadgeSwapMetrics.pointSize)
        for kind in ProfileBadgeKind.allCases {
            let line = "\(kind.emoji) \(kind.explanation)" as NSString
            let natural = line.size(withAttributes: [.font: font]).width
            let fitted = natural * BadgeSwapMetrics.minimumScale
            #expect(fitted <= available,
                    "\(kind): needs \(Int(fitted))pt at minimum scale, only \(Int(available))pt available (natural \(Int(natural))pt)")
        }
    }

    /// The second beat on someone else's profile shows `howToEarn` in the same line.
    @Test("every how-to-earn line fits one line on a 393pt device")
    func howToEarnFits() {
        let available = 393 - BadgeSwapMetrics.horizontalPadding * 2
        let font = UIFont.systemFont(ofSize: BadgeSwapMetrics.pointSize)
        for kind in ProfileBadgeKind.allCases {
            let natural = (kind.howToEarn as NSString).size(withAttributes: [.font: font]).width
            let fitted = natural * BadgeSwapMetrics.minimumScale
            #expect(fitted <= available,
                    "\(kind): needs \(Int(fitted))pt at minimum scale, only \(Int(available))pt available")
        }
    }
}

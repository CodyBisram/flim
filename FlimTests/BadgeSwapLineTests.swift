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

/// The 1.6.2 silver trio: Recruiter (automatic), Feedback and Bug Catcher (awarded by hand from
/// the admin dashboard). Rung, glyphs, the copy exactly as the plan's table has it, and that copy
/// against the house rules. See docs/PLAN_1_6_2_BADGES_AND_RATING.md.
struct SilverTrioBadgeTests {
    private let trio: [ProfileBadgeKind] = [.recruiter, .feedback, .bugCatcher]

    @Test("the three decode from their server ids")
    func rawValues() {
        #expect(ProfileBadgeKind(rawValue: "recruiter") == .recruiter)
        #expect(ProfileBadgeKind(rawValue: "feedback") == .feedback)
        #expect(ProfileBadgeKind(rawValue: "bug_catcher") == .bugCatcher)
    }

    @Test("all three are silver, and silver never glows")
    func tier() {
        for kind in trio {
            #expect(kind.tier == .silver, "\(kind) is \(kind.tier.name)")
            #expect(kind.tier.glow(accent: .orange) == .clear, "\(kind) glows")
            #expect(kind.sweepPhaseOffset == 0)
        }
    }

    @Test("titles and glyphs")
    func labelsAndEmoji() {
        #expect(ProfileBadgeKind.recruiter.label == "Recruiter")
        #expect(ProfileBadgeKind.feedback.label == "Feedback")
        #expect(ProfileBadgeKind.bugCatcher.label == "Bug Catcher")
        #expect(ProfileBadgeKind.feedback.emoji == "\u{1F4AC}")
        #expect(ProfileBadgeKind.bugCatcher.emoji == "\u{1F41E}")
        // Not the handshake: Plus One already has it (see `emojiCatalog` above).
        #expect(ProfileBadgeKind.recruiter.emoji != ProfileBadgeKind.broughtSomeone.emoji)
    }

    /// The plan's table, except two explanations trimmed to fit the one-line swap-in (see the
    /// comment on `ProfileBadgeKind.explanation`'s `.recruiter` case).
    @Test("copy is the plan's, with the app's name where the plan says FLIM")
    func copy() {
        let app = AppInfo.appName
        #expect(ProfileBadgeKind.recruiter.explanation == "Three people you invited still shoot a month later.")
        #expect(ProfileBadgeKind.feedback.explanation == "What you told us changed \(app). Given by Cody.")
        #expect(ProfileBadgeKind.bugCatcher.explanation == "You found a bug, and it got fixed. Given by Cody.")
        #expect(ProfileBadgeKind.recruiter.howToEarn == "Invite people who stay: three still shooting a month after they join.")
        #expect(ProfileBadgeKind.feedback.howToEarn == "Use Send feedback in Settings. When it changes \(app), Cody gives you this.")
        #expect(ProfileBadgeKind.bugCatcher.howToEarn == "Report a bug with Send feedback in Settings. When it is fixed, Cody gives you this.")
    }

    @Test("\"Given by Cody\" is on the two hand-given badges and nowhere else")
    func givenByCody() {
        for kind in ProfileBadgeKind.allCases {
            let hasLine = kind.explanation.contains("Given by Cody.")
            #expect(hasLine == (kind == .feedback || kind == .bugCatcher), "\(kind)")
        }
    }

    @Test("house rules: no em or en dashes, no exclamation marks")
    func houseRules() {
        for kind in trio {
            for line in [kind.label, kind.explanation, kind.howToEarn] {
                #expect(!line.contains("\u{2014}"), "em dash in \(kind): \(line)")
                #expect(!line.contains("\u{2013}"), "en dash in \(kind): \(line)")
                #expect(!line.contains("!"), "exclamation mark in \(kind): \(line)")
            }
        }
    }

    /// The app's name reaches this copy only through `AppInfo.appName`: the two Feedback lines
    /// carry it, and the other four never name the app at all ("Cody" is the owner, on purpose).
    @Test("the app's name appears only where the plan says FLIM")
    func appName() {
        #expect(ProfileBadgeKind.feedback.explanation.contains(AppInfo.appName))
        #expect(ProfileBadgeKind.feedback.howToEarn.contains(AppInfo.appName))
        for line in [ProfileBadgeKind.recruiter.explanation, ProfileBadgeKind.recruiter.howToEarn,
                     ProfileBadgeKind.bugCatcher.explanation, ProfileBadgeKind.bugCatcher.howToEarn] {
            #expect(!line.contains(AppInfo.appName), "\(line) names the app")
        }
    }

    /// Hand-given like Founder, but an open door: the locked catalogue lists them with a real
    /// instruction. Founder, Founding Crew, Founding 100 and Spotlight stay out.
    @Test("the hand-given pair stays in the locked catalogue; the closed doors stay out")
    func earnable() {
        #expect(ProfileBadgeKind.recruiter.isEarnable)
        #expect(ProfileBadgeKind.feedback.isEarnable)
        #expect(ProfileBadgeKind.bugCatcher.isEarnable)
        for closed in [ProfileBadgeKind.founder, .foundingCrew, .founding100, .spotlight] {
            #expect(!closed.isEarnable, "\(closed)")
        }
    }
}

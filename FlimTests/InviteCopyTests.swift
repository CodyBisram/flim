import Testing
@testable import Flim

/// The rules this screen's copy has to obey, enforced rather than remembered.
struct InviteCopyTests {

    @Test("nothing on the invite screen says \"roll\"")
    func neverSaysRoll() {
        // The design handed this over as "You have 3 invites left on this roll." A roll is a real,
        // different object in FLIM, and the Rolls screen ships its own Share invite meaning invite
        // somebody INTO a roll. Borrowing the word here names a shipped feature this screen has
        // nothing to do with. Owner called it out directly, so it is pinned.
        for line in InviteCopy.all {
            #expect(!line.lowercased().contains("roll"), "invite copy must not say roll: \(line)")
        }
    }

    @Test("no em dashes anywhere in the copy")
    func noEmDashes() {
        // House rule across all user-facing copy in this app.
        for line in InviteCopy.all {
            #expect(!line.contains("\u{2014}"), "em dash in: \(line)")
        }
    }

    @Test("the earn-back line describes what the server actually does")
    func earnBackCopyMatchesTheMechanism() {
        // The mechanism credits the INVITER only, on the invitee's first PHOTO. The design said
        // "you both get one back when they shoot their first roll", which is wrong on both counts:
        // the invitee half was never built, and "roll" names the wrong thing. Copy that promises
        // a payout nobody wrote is a lie with a delivery date.
        #expect(InviteCopy.earnBack.contains("photo"))
        #expect(!InviteCopy.earnBack.lowercased().contains("both"))
    }

    @Test("a count is only ever claimed when one is actually known")
    func unknownClaimsNoNumber() {
        // `.unknown` is what a failed lookup AND a client running ahead of the server migration
        // both look like. Rendering a number there would tell someone they are out of invites
        // when they are not.
        // Computed outside the macro: `contains(where:)` is rethrows, which `#expect` cannot see
        // through and reports as an unhandled throwing call.
        let headlineHasDigit = InviteCopy.headline(for: .unknown).filter(\.isNumber).isEmpty == false
        let subheadHasDigit = InviteCopy.subhead(for: .unknown).filter(\.isNumber).isEmpty == false
        #expect(!headlineHasDigit)
        #expect(!subheadHasDigit)
    }

    @Test("one invite is singular, everything else is plural")
    func singularReadsLikeEnglish() {
        #expect(InviteCopy.headline(for: .remaining(1)) == "You have 1 invite left.")
        #expect(InviteCopy.headline(for: .remaining(2)) == "You have 2 invites left.")
    }

    @Test("being out of invites promises nothing with a date on it")
    func exhaustedCopyPromisesNothing() {
        // An invite CAN come back, but only if somebody already brought in picks up a camera,
        // which may never happen. Copy implying a refill is coming would be a promise the app
        // cannot keep on any timeline.
        let both = InviteCopy.headline(for: .remaining(0)) + " " + InviteCopy.subhead(for: .remaining(0))
        for forbidden in ["soon", "tomorrow", "next week", "check back"] {
            #expect(!both.lowercased().contains(forbidden), "implies a refill schedule: \(both)")
        }
    }

    @Test("the front door never accuses someone of a typo it cannot have detected")
    func redeemFailureDoesNotAssertATypo() {
        // `redeem_invite` returns the SAME false for "no such code" and for "real code, owner
        // is out", on purpose, so nobody can probe which codes exist. Copy that says only
        // "check it and try again" is therefore wrong half the time, and wrong at the worst
        // moment: someone holding a genuinely valid code from a real friend, told to re-check
        // something that is not wrong, where re-typing can never work.
        let line = InviteCopy.redeemFailed
        #expect(line.lowercased().contains("run out"),
                "must name the exhausted-inviter case, not just a typo")
        // And it must stay ONE string for both cases, or it becomes an enumeration oracle.
        #expect(!line.lowercased().contains("does not exist"))
        #expect(!line.lowercased().contains("invalid"))
    }

    @Test("front door copy obeys the same rules as the rest")
    func frontDoorFollowsTheHouseRules() {
        for line in InviteCopy.frontDoor {
            #expect(!line.lowercased().contains("roll"))
            #expect(!line.contains("\u{2014}"))
        }
    }

    // MARK: - The strip's geometry

    @Test("a strip is as long as its frames, gaps and margins")
    func stripWidthCountsGapsAndBothMargins() {
        // n frames carry n - 1 gaps BETWEEN them, plus one gap of film margin at each end, so
        // n + 1 gaps in total. Getting this wrong by one gap is what makes a strip's last frame
        // sit flush against the cut edge with no film around it.
        let m = FilmStripMetrics.self
        #expect(m.width(frameCount: 1) == m.frameWidth + 2 * m.frameGap)
        #expect(m.width(frameCount: 3) == 3 * m.frameWidth + 4 * m.frameGap)
    }

    @Test("an empty strip has no width, rather than two margins of nothing")
    func emptyStripIsZero() {
        // Reachable: an unlimited account with no spent invites has zero frames, and the sheet
        // must not draw a bare sliver of film base with nothing in it.
        #expect(FilmStripMetrics.width(frameCount: 0) == 0)
        #expect(FilmStripMetrics.width(frameCount: -2) == 0)
    }

    @Test("a frame is taller than it is wide, or it stops reading as film")
    func framesAreNotSquare() {
        // The first pass drew 92x104, close enough to square that it read as a row of cards.
        #expect(FilmStripMetrics.frameHeight > FilmStripMetrics.frameWidth)
        let ratio = FilmStripMetrics.frameWidth / FilmStripMetrics.frameHeight
        #expect(ratio > 0.6 && ratio < 0.9, "frame proportion drifted to \(ratio)")
    }

    @Test("sprocket holes are wider than they are tall and sit clear of each other")
    func sprocketProportions() {
        let m = FilmStripMetrics.self
        // Real perforations are landscape rectangles, not dots.
        #expect(m.holeWidth > m.holeHeight)
        // And the pitch must leave film between them, or the edge reads as a dashed line, which
        // is exactly the thing this replaced.
        #expect(m.holePitch > m.holeWidth)
        // The rail has to be tall enough to contain a hole with margin above and below.
        #expect(m.railHeight > m.holeHeight)
    }

    // MARK: - The reveal's own invite

    @Test("the reveal offer is hidden only when the count is a genuine, known zero")
    func revealOfferHiddenOnlyAtGenuineZero() {
        // Same rule as the profile sheet and the feed empty state: a failed lookup (`.unknown`)
        // and a deliberately unmetered account (`.unlimited`) must never hide a code that still
        // works. Only `.remaining(0)`, a real known count, may hide it.
        #expect(InviteCopy.revealOfferVisible(for: .remaining(3)))
        #expect(InviteCopy.revealOfferVisible(for: .remaining(1)))
        #expect(!InviteCopy.revealOfferVisible(for: .remaining(0)))
        #expect(InviteCopy.revealOfferVisible(for: .unlimited))
        #expect(InviteCopy.revealOfferVisible(for: .unknown))
    }

    @Test("the reveal's quota line never claims a number it does not have")
    func revealQuotaLineClaimsNoUnearnedNumber() {
        // `.remaining(0)` is never shown in the first place (the offer is hidden), and `.unknown`
        // must not be dressed up as a real count either.
        #expect(InviteCopy.revealQuotaLine(for: .remaining(0)) == nil)
        #expect(InviteCopy.revealQuotaLine(for: .unknown) == nil)
        #expect(InviteCopy.revealQuotaLine(for: .remaining(1)) == "1 invite left")
        #expect(InviteCopy.revealQuotaLine(for: .remaining(2)) == "2 invites left")
    }

    @Test("the reveal prompt names the next roll without saying the banned word")
    func revealPromptFollowsHouseRules() {
        #expect(!InviteCopy.revealPrompt.lowercased().contains("roll"))
        #expect(!InviteCopy.revealPrompt.contains("\u{2014}"))
    }
}

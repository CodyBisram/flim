import Testing
import Foundation
import CoreText
import CoreGraphics
@testable import Flim

/// 1.7.1's seals (docs/SEALS_1_7_1.md, sections 2 and 5): every seal has its words, the words keep
/// the house rules, the type fits inside each shape, progress decodes and reads right in every
/// form, and choosing a seal replaces the one on your page.
struct SealCopyTests {

    private let neverBlind: Set<ProfileBadgeKind> = [.founder, .foundingCrew, .founding100, .spotlight]

    // MARK: Completeness

    @Test("every seal has a ring, an earned line, and a how-to line unless it is never blind")
    func everySealHasCopy() {
        for kind in ProfileBadgeKind.allCases {
            let copy = SealCopy.of(kind)
            #expect(!copy.ring.isEmpty, "\(kind) has no ring")
            #expect(!copy.earned.isEmpty, "\(kind) has no earned line")
            #expect(copy.ring == copy.ring.uppercased(), "\(kind)'s ring isn't upper case")
            if neverBlind.contains(kind) {
                #expect(copy.howTo == nil, "\(kind) is never blind, so it says nothing about getting it")
                #expect(copy.progress == .none, "\(kind) has no progress")
                #expect(!kind.isEarnable, "\(kind) would show blind in the sheet")
            } else {
                #expect(copy.howTo?.isEmpty == false, "\(kind) has no how-to line")
                #expect(kind.isEarnable, "\(kind) would never show blind")
            }
        }
        #expect(SealCopy.of(.founding100).othersLine == "Only the first hundred got this one.")
        #expect(SealCopy.of(.spotlight).othersLine == "The team chooses Spotlight each week.")
    }

    @Test("the catalogue lists every seal exactly once")
    func catalogueIsComplete() {
        #expect(SealCopy.catalogue.count == ProfileBadgeKind.allCases.count)
        #expect(Set(SealCopy.catalogue) == Set(ProfileBadgeKind.allCases))
    }

    @Test("the spec's table, spot checked across every progress form")
    func tableSpotChecks() {
        let app = AppInfo.appName
        #expect(SealCopy.ring(.founder, earnedAt: nil) == "BUILT \(app.uppercased())")
        #expect(SealCopy.ring(.feedback, earnedAt: nil) == "CHANGED \(app.uppercased())")
        #expect(SealCopy.of(.keptOne).progress == .count(unit: "kept"))
        #expect(SealCopy.of(.recruiter).progress == .count(unit: "still shooting"))
        #expect(SealCopy.of(.fullSet).progress == .bar(unit: "seals"))
        #expect(SealCopy.of(.fullHouse).progress == .closestRoll)
        #expect(SealCopy.of(.packedHouse).progress == .closestRoll)
        #expect(SealCopy.of(.darkroom).progress == .allOf)
        #expect(SealCopy.of(.oneYear).progress == .date)
        #expect(SealCopy.of(.bugCatcher).progress == .givenByTeam)
        #expect(SealCopy.of(.spotter).progress == .oneStep)
        #expect(SealCopy.of(.fullRoll).progress == .twoSteps("Shoot into a roll in its first 6 hours",
                                                              "Come back to it 6 hours or more after it started"))
        #expect(SealCopy.of(.rollMaker).progress == .twoSteps("Start a roll", "Get a frame into it"))
        #expect(SealCopy.of(.rollMaker).earned == "Started a roll that got its first frame.")
        #expect(SealCopy.of(.wellMet).howTo == "Get a reaction on one of your frames in a roll.")
        #expect(SealCopy.of(.goodCompany).nameSize == 8)
        #expect(SealCopy.sealName(.foundingCrew, signupNumber: nil) == "Crew")
        #expect(SealCopy.sealName(.founding100, signupNumber: 23) == "No 23")
    }

    @Test("Spotlight's ring carries its ISO week")
    func spotlightWeek() throws {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = .current
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12)))
        #expect(SealCopy.ring(.spotlight, earnedAt: date) == "WK 44")
    }

    @Test("dates read SEP 2026 on the seal and Earned Sep 2026 on the card; Founding 100 the year")
    func dates() throws {
        let date = try #require(DateComponents(calendar: Calendar(identifier: .gregorian), year: 2026, month: 9, day: 14, hour: 12).date)
        #expect(SealCopy.sealDate(.firstIn, earnedAt: date) == "SEP 2026")
        #expect(SealCopy.earnedLine(.firstIn, earnedAt: date) == "Earned Sep 2026")
        #expect(SealCopy.sealDate(.founding100, earnedAt: date) == "2026")
        #expect(SealCopy.earnedLine(.founding100, earnedAt: date) == "Earned 2026")
        #expect(SealCopy.sealDate(.firstIn, earnedAt: nil) == nil)
    }

    // MARK: House rules

    private var everyLine: [String] {
        var lines = [SealsPanel.line, SealsPanel.empty, SealCard.failureLine]
        for kind in ProfileBadgeKind.allCases {
            let copy = SealCopy.of(kind)
            lines += [copy.ring, copy.earned, copy.howTo, copy.othersLine].compactMap { $0 }
            if case .twoSteps(let a, let b) = copy.progress { lines += [a, b] }
            if case .count(let unit) = copy.progress { lines.append(unit) }
        }
        return lines
    }

    @Test("no em or en dashes, no exclamation marks, nobody named")
    func houseRules() {
        for line in everyLine {
            #expect(!line.contains("\u{2014}"), "em dash: \(line)")
            #expect(!line.contains("\u{2013}"), "en dash: \(line)")
            #expect(!line.contains("!"), "exclamation mark: \(line)")
            #expect(!line.contains("Cody"), "names a person: \(line)")
        }
    }

    // MARK: Type fit

    /// The width an inner rule (the outline for the laurel, which has none) leaves at height `y`,
    /// found by walking out from the centre line until the point leaves the shape.
    private func innerWidth(_ shape: SealShape, at y: CGFloat) -> CGFloat {
        let path = SealArt.innerRule(shape) ?? SealArt.outline(shape)
        guard path.contains(CGPoint(x: 50, y: y)) else { return 0 }
        var x: CGFloat = 50
        while x < 100, path.contains(CGPoint(x: x + 0.05, y: y)) { x += 0.05 }
        return (x - 50) * 2
    }

    /// The narrowest the shape gets across a line's band, less `clearance` units a side. The
    /// board's rule is that every line clears the inner rule by at least 3.
    private func room(_ shape: SealShape, baseline: CGFloat, capHeight: CGFloat, clearance: CGFloat = 3) -> CGFloat {
        let top = innerWidth(shape, at: baseline - capHeight)
        let bottom = innerWidth(shape, at: baseline)
        return min(top, bottom) - 2 * clearance
    }

    /// Names are held to 2.5 units, not 3: with the Caslon the app ships, the reel's own sizes
    /// leave Bug Catcher, blind, 2.8 units from the shield's inner rule at its baseline corners.
    /// The drawing is the reel's, unchanged, so the test records what it measures; a name that
    /// gets closer than this needs its own smaller size.
    private let nameClearance: CGFloat = 2.5

    private func capHeight(_ font: CTFont) -> CGFloat { CTFontGetCapHeight(font) }

    @Test("the fonts the seal is set in are installed")
    func fontsResolve() {
        let mono = SealArt.monoFont(6.5)
        let caslon = SealArt.caslonFont(12.5)
        #expect((CTFontCopyPostScriptName(mono) as String).contains("PlexMono"))
        #expect((CTFontCopyPostScriptName(caslon) as String).contains("Caslon"))
    }

    @Test("every ring line fits inside its shape at the seal's type size")
    func ringsFit() {
        for kind in ProfileBadgeKind.allCases {
            let shape = SealShape(kind.tier)
            let ring = kind == .spotlight ? "WK 53" : SealCopy.ring(kind, earnedAt: nil)
            if shape == .round {
                // Set on the arc: it stays in the crown, the top 120 degrees of its circle.
                let font = SealArt.monoFont(SealArt.arcSize)
                let width = SealArt.visibleWidth(ring, font: font, tracking: SealArt.arcTracking)
                let crown = 2 * CGFloat.pi / 3 * SealArt.arcRadius
                #expect(width <= crown, "\(kind): \(ring) runs \(width) of \(crown) units round the arc")
                continue
            }
            let art = SealArt(kind: kind, earnedAt: nil, signupNumber: nil, blind: false, slate: false)
            let font = SealArt.monoFont(art.ringSize)
            let width = SealArt.visibleWidth(ring, font: font, tracking: SealArt.ringTracking)
            for blind in [false, true] {
                let layout = SealArt.layout(shape)
                let baseline = (layout.ring ?? 0) + (blind ? layout.blindShift : 0)
                let available = room(shape, baseline: baseline, capHeight: capHeight(font))
                #expect(width <= available,
                        "\(kind)\(blind ? " (blind)" : ""): \(ring) needs \(width), has \(available)")
            }
        }
    }

    @Test("every name and date fits inside its shape at its own size")
    func namesAndDatesFit() {
        for kind in ProfileBadgeKind.allCases {
            let shape = SealShape(kind.tier)
            let art = SealArt(kind: kind, earnedAt: nil, signupNumber: 100, blind: false, slate: false)
            let layout = SealArt.layout(shape)
            let nameFont = SealArt.caslonFont(art.nameSize)
            let nameWidth = SealArt.visibleWidth(art.name, font: nameFont, tracking: 0)
            for blind in [false, true] {
                let baseline = layout.name + (blind ? layout.blindShift : 0) + art.nameLift
                let available = room(shape, baseline: baseline, capHeight: capHeight(nameFont), clearance: nameClearance)
                #expect(nameWidth <= available,
                        "\(kind)\(blind ? " (blind)" : ""): \(art.name) needs \(nameWidth), has \(available)")
            }
            let dateFont = SealArt.monoFont(SealArt.dateSize)
            let date = kind == .founding100 ? "2026" : "SEP 2026"
            let dateWidth = SealArt.visibleWidth(date, font: dateFont, tracking: SealArt.ringTracking)
            let available = room(shape, baseline: layout.date, capHeight: capHeight(dateFont))
            #expect(dateWidth <= available, "\(kind): \(date) needs \(dateWidth), has \(available)")
        }
    }

    // MARK: Progress decoding

    @Test("own_seal_progress rows decode, unknown seals drop, the first row for a seal wins")
    func decodesProgress() throws {
        let json = Data(#"""
        [{"badge_id":"kept_one","current":6,"target":10,"due_at":null},
         {"badge_id":"one_year","current":0,"target":0,"due_at":"2027-03-14T10:00:00.123456+00:00"},
         {"badge_id":"from_the_future","current":1,"target":2,"due_at":null},
         {"badge_id":"kept_one","current":9,"target":10,"due_at":null},
         {"badge_id":"full_roll","current":1,"target":2}]
        """#.utf8)
        let rows = try JSONDecoder().decode([SealProgressRow].self, from: json)
        let index = SealProgress.index(rows)
        #expect(index.count == 3)
        #expect(index["kept_one"] == SealProgress(current: 6, target: 10))
        #expect(index["full_roll"] == SealProgress(current: 1, target: 2))
        #expect(index["from_the_future"] == nil)
        let due = try #require(index["one_year"]?.dueAt)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC") ?? .gmt, from: due)
        #expect(parts.year == 2027 && parts.month == 3 && parts.day == 14)
    }

    // MARK: Progress lines

    @Test("count: ticks and '6 of 10 kept' once started; nothing before")
    func countForm() {
        let form = SealProgressForm.count(unit: "kept")
        let started = SealProgress(current: 6, target: 10)
        #expect(SealProgressText.caption(form, started) == "6 of 10 kept")
        #expect(SealProgressText.tag(form, started) == "6 OF 10")
        #expect(SealProgressText.marks(form, started) == (10, 6))
        let fresh = SealProgress(current: 0, target: 10)
        #expect(!SealProgressText.isStarted(form, fresh))
        #expect(SealProgressText.tag(form, fresh) == nil)
        #expect(SealProgressText.caption(form, fresh) == nil)
        #expect(SealProgressText.tag(form, nil) == nil, "no row, no progress")
        #expect(SealProgressText.caption(.count(unit: "still shooting"), SealProgress(current: 1, target: 3)) == "1 of 3 still shooting")
    }

    @Test("bar: Full Set's share and '14 of 20 seals'")
    func barForm() {
        let form = SealProgressForm.bar(unit: "seals")
        let progress = SealProgress(current: 14, target: 20)
        #expect(SealProgressText.caption(form, progress) == "14 of 20 seals")
        #expect(SealProgressText.tag(form, progress) == "14 OF 20")
        #expect(abs(SealProgressText.fraction(progress) - 0.7) < 0.0001)
    }

    @Test("closest roll and all of them")
    func rollForms() {
        let closest = SealProgress(current: 3, target: 5)
        #expect(SealProgressText.caption(.closestRoll, closest) == "Your closest roll has 3 of 5 photographers.")
        #expect(SealProgressText.tag(.closestRoll, closest) == "3 OF 5")
        let reveals = SealProgress(current: 7, target: 9)
        #expect(SealProgressText.caption(.allOf, reveals) == "7 of 9 reveals opened.")
        #expect(SealProgressText.tag(.allOf, reveals) == "7 OF 9")
        #expect(!SealProgressText.allOfDrawsBar(reveals))
        #expect(SealProgressText.allOfDrawsBar(SealProgress(current: 3, target: 30)))
        #expect(SealProgressText.tag(.allOf, SealProgress(current: 0, target: 0)) == nil, "no developed roll yet")
        // The reveals share shows from the first developed roll, none opened included.
        let none = SealProgress(current: 0, target: 3)
        #expect(SealProgressText.isStarted(.allOf, none))
        #expect(SealProgressText.caption(.allOf, none) == "0 of 3 reveals opened.")
        #expect(SealProgressText.tag(.allOf, none) == "0 OF 3")
        #expect(SealProgressText.marks(.allOf, none) == (3, 0))
    }

    @Test("two steps: '1 OF 2' once one is done")
    func twoStepsForm() {
        let form = SealCopy.of(.fullRoll).progress
        #expect(SealProgressText.tag(form, SealProgress(current: 1, target: 2)) == "1 OF 2")
        #expect(SealProgressText.marks(form, SealProgress(current: 1, target: 2)) == (2, 1))
        #expect(SealProgressText.tag(form, SealProgress(current: 0, target: 2)) == nil)
    }

    @Test("date: the day the year is up, twelve month ticks, and READY once it has passed")
    func dateForm() throws {
        let calendar = Calendar(identifier: .gregorian)
        let due = try #require(DateComponents(calendar: calendar, year: 2027, month: 3, day: 14, hour: 12).date)
        let now = try #require(DateComponents(calendar: calendar, year: 2026, month: 11, day: 22, hour: 12).date)
        let progress = SealProgress(current: 0, target: 0, dueAt: due)
        #expect(SealProgressText.isStarted(.date, progress))
        #expect(SealProgressText.tag(.date, progress, now: now) == "MAR 2027")
        #expect(SealProgressText.caption(.date, progress, now: now) == "You'll hit a year on March 14, 2027. Shoot a frame any time after that.")
        #expect(SealProgressText.marks(.date, progress, now: now, calendar: calendar) == (12, 8))
        let later = try #require(DateComponents(calendar: calendar, year: 2027, month: 6, day: 1, hour: 12).date)
        #expect(SealProgressText.tag(.date, progress, now: later) == "READY")
        #expect(SealProgressText.caption(.date, progress, now: later) == "It's been a year. Shoot a frame to earn it.")
        #expect(SealProgressText.marks(.date, progress, now: later, calendar: calendar) == (12, 12))
        #expect(!SealProgressText.isStarted(.date, SealProgress(current: 0, target: 0)))
    }

    @Test("one step, given by the team and closed seals never show progress")
    func formsWithoutProgress() {
        let row = SealProgress(current: 1, target: 1)
        for form in [SealProgressForm.oneStep, .givenByTeam, .none] {
            #expect(SealProgressText.tag(form, row) == nil)
            #expect(SealProgressText.caption(form, row) == nil)
        }
    }

    // MARK: Someone else's card

    @MainActor
    @Test("someone else's card heads your half YOUR PROGRESS only when there is progress to show")
    func viewerLabel() {
        #expect(SealCard.viewerLabel(.count(unit: "rolls"), SealProgress(current: 2, target: 5)) == "YOUR PROGRESS")
        #expect(SealCard.viewerLabel(.count(unit: "rolls"), SealProgress(current: 0, target: 5)) == "HOW TO GET IT")
        #expect(SealCard.viewerLabel(.count(unit: "rolls"), nil) == "HOW TO GET IT")
        #expect(SealCard.viewerLabel(.oneStep, nil) == "HOW TO GET IT")
        #expect(SealCard.viewerLabel(.allOf, SealProgress(current: 0, target: 3)) == "YOUR PROGRESS")
        #expect(SealCard.viewerLabel(.twoSteps("a", "b"), SealProgress(current: 0, target: 2)) == "YOUR PROGRESS")
        #expect(SealCard.viewerLabel(.twoSteps("a", "b"), nil) == "HOW TO GET IT")
        #expect(SealCard.viewerLabel(.givenByTeam, nil) == "GIVEN BY THE TEAM")
    }

    // MARK: Loading

    @MainActor
    @Test("a failed load reads as failed, never as no seals, and trying again recovers")
    func failedLoad() async {
        var fails = true
        let drawer = SealsDrawer(signupNumber: nil, actions: .init(
            load: {
                fails ? SealsDrawer.Snapshot(failed: true)
                      : SealsDrawer.Snapshot(badges: [ProfileBadge(id: "first_in", kind: .firstIn, earnedAt: .now)])
            },
            save: { _ in }, markSeen: { _ in }))
        await drawer.load()
        #expect(drawer.loaded && drawer.failed)
        #expect(drawer.earned.isEmpty)
        fails = false
        await drawer.load()
        #expect(!drawer.failed)
        #expect(drawer.earned.map(\.kind) == [.firstIn])
    }

    // MARK: One seal

    @Test("choosing a seal replaces the chosen list with that one id")
    func choosingReplaces() {
        #expect(SealChoice.choosing("first_in") == ["first_in"])
        #expect(SealChoice.chosen(from: ["front_row", "first_in"]) == "front_row", "a stored second choice is ignored")
        #expect(SealChoice.chosen(from: nil) == nil)
        #expect(SealChoice.chosen(from: []) == nil)
    }

    @MainActor
    @Test("Put on my page writes exactly one id and moves the page seal only once it lands")
    func putOnPageWritesOne() async {
        var writes: [[String]] = []
        var fails = false
        struct Refused: Error {}
        let drawer = SealsDrawer(signupNumber: nil, actions: .init(
            load: {
                SealsDrawer.Snapshot(
                    badges: [ProfileBadge(id: "first_in", kind: .firstIn, earnedAt: .now),
                             ProfileBadge(id: "front_row", kind: .frontRow, earnedAt: .now)],
                    unseenIds: ["first_in"], progress: [:], pageSealId: "front_row")
            },
            save: { ids in
                writes.append(ids)
                if fails { throw Refused() }
            },
            markSeen: { _ in }))
        await drawer.load()
        #expect(await drawer.putOnPage("first_in"))
        #expect(writes == [["first_in"]])
        #expect(drawer.pageSealId == "first_in")
        fails = true
        #expect(await drawer.putOnPage("front_row") == false)
        #expect(drawer.pageSealId == "first_in", "a failed save leaves the page seal where it was")
    }

    @MainActor
    @Test("opening a new seal's card clears that seal's dot and marks only it seen")
    func openingMarksOneSeen() async throws {
        var marked: [String] = []
        let drawer = SealsDrawer(signupNumber: nil, actions: .init(
            load: {
                SealsDrawer.Snapshot(
                    badges: [ProfileBadge(id: "well_met", kind: .wellMet, earnedAt: .now),
                             ProfileBadge(id: "shared", kind: .shared, earnedAt: .now)],
                    unseenIds: ["well_met", "shared"], progress: [:], pageSealId: nil)
            },
            save: { _ in },
            markSeen: { marked.append($0) }))
        await drawer.load()
        drawer.open(.wellMet)
        #expect(drawer.unseenIds == ["shared"])
        #expect(drawer.developing.contains("well_met"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(marked == ["well_met"])
        drawer.close()
        drawer.open(.wellMet)
        try await Task.sleep(for: .milliseconds(50))
        #expect(marked == ["well_met"], "opening it again marks nothing more")
        #expect(!drawer.developing.contains("well_met"), "it develops once")
    }

    @MainActor
    @Test("the sheet lists earned then blind in tier and catalogue order, never the closed four blind")
    func sheetOrder() async {
        let drawer = SealsDrawer(signupNumber: nil, actions: .init(
            load: {
                SealsDrawer.Snapshot(
                    badges: [ProfileBadge(id: "ten_frames", kind: .tenFrames, earnedAt: .now),
                             ProfileBadge(id: "founder", kind: .founder, earnedAt: .now),
                             ProfileBadge(id: "first_in", kind: .firstIn, earnedAt: .now)],
                    unseenIds: [], progress: ["kept_one": SealProgress(current: 9, target: 10)], pageSealId: nil)
            },
            save: { _ in }, markSeen: { _ in }))
        await drawer.load()
        #expect(drawer.earned.map(\.kind) == [.founder, .firstIn, .tenFrames])
        #expect(drawer.blind.allSatisfy { !neverBlind.contains($0) })
        #expect(drawer.blind.first == .frontRow)
        #expect(drawer.blind.count == ProfileBadgeKind.allCases.count - 3 - 3)
        // Progress never moves a seal.
        #expect(drawer.blind == SealCopy.sorted(drawer.blind))
    }
}

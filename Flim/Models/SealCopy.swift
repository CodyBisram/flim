import Foundation
import CoreGraphics

/// 1.7.1's words for every seal (docs/SEALS_1_7_1.md, section 2): the ring line pressed into it,
/// the line its card says once it is earned, the line that says how to get it, and which progress
/// form its card draws. 1.7 only. The 1.6 strings (`ProfileBadgeKind.explanation`, `howToEarn`)
/// stay as they were for the 1.6 path.
///
/// Every "how to get it" line describes the server's real predicate (`_ratchet_badges`), never
/// names a person or a roll, and never uses an em dash. The app's name reaches this copy only
/// through `AppInfo.appName`.
struct SealCopy: Equatable {
    /// The ring line, already upper case. Spotlight's carries the ISO week it was earned, so read
    /// rings through `SealCopy.ring(_:earnedAt:)`, which fills that in.
    let ring: String
    /// The name's type size inside the seal, in the seal's 100-unit space, where the full name
    /// would not clear the inner rule at 12.5.
    let nameSize: CGFloat?
    /// What the seal was for, on its card once earned (yours or someone else's).
    let earned: String
    /// How to get it, on its card while not earned. nil for the four that are never shown blind:
    /// Founder, Founding Crew, Founding 100 and Spotlight.
    let howTo: String?
    /// On someone else's card, for a seal you don't hold and can't work towards (Founding 100
    /// and Spotlight). The other closed seals say nothing there.
    let othersLine: String?
    /// How the card shows your progress while it is not earned.
    let progress: SealProgressForm

    static let defaultNameSize: CGFloat = 12.5

    /// The ring with Spotlight's week filled in ("WK 44"). Earned dates are read in the phone's
    /// own calendar week, ISO numbering, the way the team names Spotlight weeks.
    static func ring(_ kind: ProfileBadgeKind, earnedAt: Date?) -> String {
        guard kind == .spotlight else { return of(kind).ring }
        guard let earnedAt else { return "A WEEK" }
        return "WK \(Calendar(identifier: .iso8601).component(.weekOfYear, from: earnedAt))"
    }

    /// The order seals are listed in, inside each tier: the spec's table, top to bottom. The
    /// Seals sheet sorts on tier first, then this, so a seal never moves as progress changes.
    static let catalogue: [ProfileBadgeKind] = [
        .founder, .foundingCrew, .founding100,
        .frontRow, .packedHouse, .coverToCover, .openDoor, .oneYear, .fullSet, .spotlight,
        .patron, .darkroom, .firstIn, .keptOne, .regular, .recruiter, .feedback, .bugCatcher,
        .fullRoll, .rollMaker, .broughtSomeone, .wellMet, .fullHouse, .spotter, .inFrame, .goodCompany,
        .firstLight, .shared, .joinedIn, .chippedIn, .chimedIn, .saidIt, .tenFrames,
    ]

    /// Tier first (Founding, Gold, Silver, Bronze, Accent), then `catalogue` order.
    static func sorted(_ kinds: [ProfileBadgeKind]) -> [ProfileBadgeKind] {
        kinds.sorted { a, b in
            if a.tier.sortRank != b.tier.sortRank { return a.tier.sortRank < b.tier.sortRank }
            return (catalogue.firstIndex(of: a) ?? Int.max) < (catalogue.firstIndex(of: b) ?? Int.max)
        }
    }

    static func of(_ kind: ProfileBadgeKind) -> SealCopy {
        let app = AppInfo.appName
        switch kind {
        case .founder:
            return SealCopy(ring: "BUILT \(app.uppercased())", nameSize: nil,
                            earned: "Built \(app).", howTo: nil, othersLine: nil, progress: .none)
        case .foundingCrew:
            return SealCopy(ring: "FOUNDING CREW", nameSize: nil,
                            earned: "Part of the crew that got \(app) off the ground.",
                            howTo: nil, othersLine: nil, progress: .none)
        case .founding100:
            return SealCopy(ring: "FOUNDING 100", nameSize: nil,
                            earned: "One of the first hundred people on \(app).", howTo: nil,
                            othersLine: "Only the first hundred got this one.", progress: .none)
        case .frontRow:
            return SealCopy(ring: "5 FIRSTS", nameSize: nil,
                            earned: "First to open the reveal, on five different rolls.",
                            howTo: "Be first to open the reveal on five different rolls with other people in them.",
                            othersLine: nil, progress: .count(unit: "rolls"))
        case .packedHouse:
            return SealCopy(ring: "ROLL OF 10", nameSize: 9,
                            earned: "Shot into a roll that reached ten photographers.",
                            howTo: "Shoot into a roll that grows to ten photographers.",
                            othersLine: nil, progress: .closestRoll)
        case .coverToCover:
            return SealCopy(ring: "10 ROLLS", nameSize: 8.5,
                            earned: "Shot into ten rolls before they developed.",
                            howTo: "Shoot into ten different rolls. Each one counts when it develops.",
                            othersLine: nil, progress: .count(unit: "rolls"))
        case .openDoor:
            return SealCopy(ring: "10 JOINED", nameSize: 11.5,
                            earned: "Invited ten people who joined \(app).",
                            howTo: "Invite ten people who join \(app).",
                            othersLine: nil, progress: .count(unit: "joined"))
        case .oneYear:
            return SealCopy(ring: "A YEAR ON", nameSize: 9.5,
                            earned: "Still shooting a year after joining.",
                            howTo: "Shoot a frame a year or more after you joined.",
                            othersLine: nil, progress: .date)
        case .fullSet:
            return SealCopy(ring: "20 SEALS", nameSize: nil,
                            earned: "Held twenty other seals at once.",
                            howTo: "Earn twenty other seals. Spotlight, Feedback and Bug Catcher don't count.",
                            othersLine: nil, progress: .bar(unit: "seals"))
        case .spotlight:
            return SealCopy(ring: "WK", nameSize: nil,
                            earned: "A frame chosen for Spotlight.", howTo: nil,
                            othersLine: "The team chooses Spotlight each week.", progress: .none)
        case .patron:
            return SealCopy(ring: "5 JOINED", nameSize: nil,
                            earned: "Invited five people who joined \(app).",
                            howTo: "Invite five people who join \(app).",
                            othersLine: nil, progress: .count(unit: "joined"))
        case .darkroom:
            return SealCopy(ring: "ALL REVEALS", nameSize: nil,
                            earned: "Opened the reveal on every roll joined.",
                            howTo: "Open the reveal on every roll you're in once it develops.",
                            othersLine: nil, progress: .allOf)
        case .firstIn:
            return SealCopy(ring: "FIRST OPEN", nameSize: nil,
                            earned: "First to open the reveal on a roll.",
                            howTo: "Be first to open the reveal on a roll with other people in it.",
                            othersLine: nil, progress: .oneStep)
        case .keptOne:
            return SealCopy(ring: "10 KEPT", nameSize: nil,
                            earned: "Let ten frames develop and kept them to yourself.",
                            howTo: "Let ten frames develop without posting them.",
                            othersLine: nil, progress: .count(unit: "kept"))
        case .regular:
            return SealCopy(ring: "7 DAYS", nameSize: nil,
                            earned: "Opened \(app) on seven different days.",
                            howTo: "Open \(app) on seven different days.",
                            othersLine: nil, progress: .count(unit: "days"))
        case .recruiter:
            return SealCopy(ring: "3 STAYED", nameSize: nil,
                            earned: "Invited three people still shooting a month later.",
                            howTo: "Invite three people who are still shooting a month after they join.",
                            othersLine: nil, progress: .count(unit: "still shooting"))
        case .feedback:
            return SealCopy(ring: "CHANGED \(app.uppercased())", nameSize: nil,
                            earned: "Sent feedback that changed \(app).",
                            howTo: "Send feedback in Settings. When it changes \(app), the team gives you this.",
                            othersLine: nil, progress: .givenByTeam)
        case .bugCatcher:
            return SealCopy(ring: "FOUND A BUG", nameSize: 10.5,
                            earned: "Found a bug the team fixed.",
                            howTo: "Report a bug with Send feedback in Settings. When the team fixes it, they give you this.",
                            othersLine: nil, progress: .givenByTeam)
        case .fullRoll:
            return SealCopy(ring: "CAME BACK", nameSize: nil,
                            earned: "Shot into a roll early, then came back to it.",
                            howTo: "Shoot into a roll in its first 6 hours, then again 6 hours or more after it started. It counts when the roll develops.",
                            othersLine: nil,
                            progress: .twoSteps("Shoot into a roll in its first 6 hours",
                                                "Come back to it 6 hours or more after it started"))
        case .rollMaker:
            return SealCopy(ring: "STARTED", nameSize: 10.5,
                            earned: "Started a roll that got its first frame.",
                            howTo: "Start a roll and get a frame into it. Anyone's frame counts, yours too.",
                            othersLine: nil,
                            progress: .twoSteps("Start a roll", "Get a frame into it"))
        case .broughtSomeone:
            return SealCopy(ring: "INVITED", nameSize: nil,
                            earned: "Invited someone who joined \(app).",
                            howTo: "Invite someone who joins \(app).",
                            othersLine: nil, progress: .oneStep)
        case .wellMet:
            return SealCopy(ring: "REACTION", nameSize: nil,
                            earned: "Someone reacted to one of your frames in a roll.",
                            howTo: "Get a reaction on one of your frames in a roll.",
                            othersLine: nil, progress: .oneStep)
        case .fullHouse:
            return SealCopy(ring: "ROLL OF 5", nameSize: 10.5,
                            earned: "Shot into a roll that reached five photographers.",
                            howTo: "Shoot into a roll that grows to five photographers.",
                            othersLine: nil, progress: .closestRoll)
        case .spotter:
            return SealCopy(ring: "A TAG", nameSize: nil,
                            earned: "Tagged someone in one of your frames.",
                            howTo: "Tag someone in one of your frames.",
                            othersLine: nil, progress: .oneStep)
        case .inFrame:
            return SealCopy(ring: "TAGGED", nameSize: nil,
                            earned: "Tagged in someone's frame.",
                            howTo: "Get tagged in someone's frame.",
                            othersLine: nil, progress: .oneStep)
        case .goodCompany:
            return SealCopy(ring: "10 FRIENDS", nameSize: 8,
                            earned: "Made ten friends on \(app).",
                            howTo: "Have ten friends on \(app).",
                            othersLine: nil, progress: .count(unit: "friends"))
        case .firstLight:
            return SealCopy(ring: "FIRST FRAME", nameSize: nil,
                            earned: "Shot a first frame.", howTo: "Shoot your first frame.",
                            othersLine: nil, progress: .oneStep)
        case .shared:
            return SealCopy(ring: "POSTED", nameSize: nil,
                            earned: "Posted a frame to the feed.", howTo: "Post a frame to the feed.",
                            othersLine: nil, progress: .oneStep)
        case .joinedIn:
            return SealCopy(ring: "JOINED ONE", nameSize: nil,
                            earned: "Joined a roll someone else started.",
                            howTo: "Join a roll someone else started.",
                            othersLine: nil, progress: .oneStep)
        case .chippedIn:
            return SealCopy(ring: "SHOT IN ONE", nameSize: 12,
                            earned: "Shot into a roll someone else started.",
                            howTo: "Shoot into a roll someone else started.",
                            othersLine: nil, progress: .oneStep)
        case .chimedIn:
            return SealCopy(ring: "REACTED", nameSize: nil,
                            earned: "Reacted to someone's frame in a roll.",
                            howTo: "React to someone else's frame in a roll.",
                            othersLine: nil, progress: .oneStep)
        case .saidIt:
            return SealCopy(ring: "A CAPTION", nameSize: nil,
                            earned: "Wrote a caption on a frame.",
                            howTo: "Write a caption when you post a frame.",
                            othersLine: nil, progress: .oneStep)
        case .tenFrames:
            return SealCopy(ring: "10 FRAMES", nameSize: 11.5,
                            earned: "Shot ten frames.", howTo: "Shoot ten frames.",
                            othersLine: nil, progress: .count(unit: "frames"))
        }
    }

    /// The word in the middle of the seal: its name, except Founding 100 (the holder's number)
    /// and Founding Crew ("Crew": the full name doesn't clear the inner ring at seal size; the
    /// card uses the full name).
    static func sealName(_ kind: ProfileBadgeKind, signupNumber: Int?) -> String {
        switch kind {
        case .founding100: return signupNumber.map { "No \($0)" } ?? "100"
        case .foundingCrew: return "Crew"
        default: return kind.label
        }
    }

    /// The date pressed under the name: "SEP 2026", or the year alone for Founding 100. English
    /// month names whatever the phone's language, like the rest of the seal: the ring fit is
    /// measured against these strings.
    static func sealDate(_ kind: ProfileBadgeKind, earnedAt: Date?) -> String? {
        guard let earnedAt else { return nil }
        if kind == .founding100 { return SealDates.year.string(from: earnedAt) }
        return SealDates.monthYear.string(from: earnedAt).uppercased()
    }

    /// "Earned Sep 2026" on the card ("Earned 2025" for Founding 100).
    static func earnedLine(_ kind: ProfileBadgeKind, earnedAt: Date) -> String {
        if kind == .founding100 { return "Earned \(SealDates.year.string(from: earnedAt))" }
        return "Earned \(SealDates.monthYear.string(from: earnedAt))"
    }
}

/// How a card shows progress on a seal not yet earned (spec section 3).
enum SealProgressForm: Equatable {
    /// Closed or chosen by the team: no task and no progress.
    case none
    /// Ticks, one per step (every count is ten or fewer), and "6 of 10 kept".
    case count(unit: String)
    /// One bar (Full Set's twenty would read as noise in ticks).
    case bar(unit: String)
    /// Dots, one per photographer, and "Your closest roll has 3 of 5 photographers."
    case closestRoll
    /// A bar of ticks, one per roll that counts, and "7 of 9 reveals opened."
    case allOf
    /// A two-line checklist.
    case twoSteps(String, String)
    /// Twelve month ticks and "You'll hit a year on March 20, 2027."
    case date
    /// The instruction alone.
    case oneStep
    /// GIVEN BY THE TEAM and the instruction.
    case givenByTeam

    /// Whether the server reports progress for this form at all.
    var hasProgress: Bool {
        switch self {
        case .none, .oneStep, .givenByTeam: return false
        default: return true
        }
    }
}

/// One row of `own_seal_progress()`: how far the signed-in account is on one seal it hasn't
/// earned. `current` and `target` come from the same predicates as the ratchet, so the seal is
/// earned exactly when `current` reaches `target`. Still Shooting carries `dueAt` (the first
/// anniversary) and 0/0.
struct SealProgress: Equatable {
    let current: Int
    let target: Int
    let dueAt: Date?

    init(current: Int, target: Int, dueAt: Date? = nil) {
        self.current = current
        self.target = target
        self.dueAt = dueAt
    }

    /// The rows keyed by badge id. Ids this build doesn't know are dropped, and the first row for
    /// an id wins.
    static func index(_ rows: [SealProgressRow]) -> [String: SealProgress] {
        var out: [String: SealProgress] = [:]
        for row in rows where ProfileBadgeKind(rawValue: row.badgeId) != nil && out[row.badgeId] == nil {
            out[row.badgeId] = SealProgress(current: max(0, row.current), target: max(0, row.target), dueAt: row.dueAt)
        }
        return out
    }
}

/// The wire shape of `own_seal_progress()`: `(badge_id text, current int, target int,
/// due_at timestamptz)`. The timestamp is parsed by hand (`ChapterTimestamp`) so a bare
/// `JSONDecoder` in tests and the Supabase client's decoder agree.
struct SealProgressRow: Decodable, Equatable {
    let badgeId: String
    let current: Int
    let target: Int
    let dueAt: Date?

    enum CodingKeys: String, CodingKey {
        case badgeId = "badge_id"
        case current, target
        case dueAt = "due_at"
    }

    init(badgeId: String, current: Int, target: Int, dueAt: Date?) {
        self.badgeId = badgeId
        self.current = current
        self.target = target
        self.dueAt = dueAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        badgeId = try c.decode(String.self, forKey: .badgeId)
        current = (try? c.decodeIfPresent(Int.self, forKey: .current)) ?? 0
        target = (try? c.decodeIfPresent(Int.self, forKey: .target)) ?? 0
        if let raw = try? c.decodeIfPresent(String.self, forKey: .dueAt) {
            dueAt = ChapterTimestamp.parse(raw)
        } else {
            dueAt = nil
        }
    }
}

/// What a progress form draws and says, worked out from the form and the row. Pure, so every
/// form is tested without a view.
enum SealProgressText {
    /// Whether there is anything to show yet. Counts, rolls and steps need at least one done;
    /// the date form needs its date; the reveals share shows from its first developed roll, even
    /// at none opened ("0 of 3 reveals opened."). Nothing shows for a seal you haven't started:
    /// the card says how to get it and stops, and the sheet shows no tag.
    static func isStarted(_ form: SealProgressForm, _ progress: SealProgress?) -> Bool {
        guard let progress, form.hasProgress else { return false }
        switch form {
        case .date: return progress.dueAt != nil
        case .allOf: return progress.target > 0
        default: return progress.current > 0 && progress.target > 0
        }
    }

    /// The short tag under a blind seal in the sheet: "6 OF 10", "1 OF 2", "MAR 2027", or
    /// "READY" once the year is up. nil until started.
    static func tag(_ form: SealProgressForm, _ progress: SealProgress?, now: Date = .now) -> String? {
        guard isStarted(form, progress), let progress else { return nil }
        switch form {
        case .date:
            guard let due = progress.dueAt else { return nil }
            return due > now ? SealDates.monthYear.string(from: due).uppercased() : "READY"
        case .twoSteps:
            return "\(min(progress.current, 2)) OF 2"
        default:
            return "\(min(progress.current, progress.target)) OF \(progress.target)"
        }
    }

    /// The tag as VoiceOver should say it.
    static func spokenTag(_ form: SealProgressForm, _ progress: SealProgress?, now: Date = .now) -> String? {
        guard isStarted(form, progress), let progress else { return nil }
        switch form {
        case .date:
            return caption(form, progress, now: now)
        default:
            return tag(form, progress, now: now)?.lowercased()
        }
    }

    /// The counter under ticks or a bar, in two parts so the unit can sit in the lighter ink:
    /// ("6 of 10", "kept").
    static func countParts(_ unit: String, _ progress: SealProgress) -> (lead: String, unit: String) {
        ("\(min(progress.current, progress.target)) of \(progress.target)", unit)
    }

    /// The whole caption a started form shows under its marks.
    static func caption(_ form: SealProgressForm, _ progress: SealProgress?, now: Date = .now) -> String? {
        guard isStarted(form, progress), let progress else { return nil }
        switch form {
        case .count(let unit), .bar(let unit):
            let parts = countParts(unit, progress)
            return "\(parts.lead) \(parts.unit)"
        case .closestRoll:
            return "Your closest roll has \(min(progress.current, progress.target)) of \(progress.target) photographers."
        case .allOf:
            return "\(min(progress.current, progress.target)) of \(progress.target) reveals opened."
        case .date:
            guard let due = progress.dueAt else { return nil }
            // The server sends the anniversary even once it has passed (an account over a year
            // old with no frame since): then the next frame earns it.
            return due > now
                ? "You'll hit a year on \(SealDates.monthDayYear.string(from: due)). Shoot a frame any time after that."
                : "It's been a year. Shoot a frame to earn it."
        case .twoSteps(let first, let second):
            let done = min(progress.current, 2)
            return "\(first): \(done >= 1 ? "done" : "not yet"). \(second): \(done >= 2 ? "done" : "not yet")."
        case .none, .oneStep, .givenByTeam:
            return nil
        }
    }

    /// How many marks the form draws and how many are filled. Ticks for counts and the roll
    /// share, dots for the closest roll, twelve months for the date. A share of more than twenty
    /// rolls draws as a bar (`fraction`) instead: ticks that thin read as a smear.
    static func marks(_ form: SealProgressForm, _ progress: SealProgress, now: Date = .now,
                      calendar: Calendar = .current) -> (total: Int, filled: Int) {
        switch form {
        case .date:
            guard let due = progress.dueAt,
                  let start = calendar.date(byAdding: .year, value: -1, to: due) else { return (12, 0) }
            let months = calendar.dateComponents([.month], from: start, to: now).month ?? 0
            return (12, min(12, max(0, months)))
        case .twoSteps:
            return (2, min(2, max(0, progress.current)))
        default:
            return (max(0, progress.target), min(max(0, progress.current), max(0, progress.target)))
        }
    }

    /// The filled share of a bar, 0 to 1.
    static func fraction(_ progress: SealProgress) -> Double {
        guard progress.target > 0 else { return 0 }
        return min(1, max(0, Double(progress.current) / Double(progress.target)))
    }

    /// Whether an all-of form draws a bar rather than ticks (more than twenty rolls).
    static func allOfDrawsBar(_ progress: SealProgress) -> Bool { progress.target > 20 }
}

/// 1.7.1's one-seal rule: the chosen list is one id. Choosing replaces whatever was there, never
/// appends; a stored second choice from 1.7.0 is ignored by everything that reads it.
enum SealChoice {
    static func choosing(_ id: String) -> [String] { [id] }

    /// The seal a stored choice puts on the page: its first id, or nil for no choice (the server
    /// then shows the rarest).
    static func chosen(from stored: [String]?) -> String? { stored?.first }
}

/// The seal's date formats: English month names in the phone's time zone.
enum SealDates {
    static let monthYear: DateFormatter = make("MMM yyyy")
    static let monthDayYear: DateFormatter = make("MMMM d, yyyy")
    static let year: DateFormatter = make("yyyy")

    private static func make(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter
    }
}

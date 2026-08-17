import Foundation

/// A profile's permanent identity: the signup number, earned badges, and film stats. This is
/// the FLIM inversion of Lapse's profile chips ("Star sign", "0 friends 😢"): the number is
/// unfakeable and permanent, badges only ever show what was actually earned, and the stats only
/// ever go up.
///
/// Sourced from `profiles.signup_ordinal` (the number) and the `profile_badges` /
/// `profile_film_stats` RPCs (badges and stats), see `FeedService.fetchProfileBadges` and
/// `FeedService.fetchProfileFilmStats`. Built in `UserPageView.load()`. Either RPC failing
/// degrades quietly: the number always comes from the profile row alone and never depends on
/// them, see that call site.
struct ProfileIdentity: Equatable {
    /// The permanent signup number, e.g. the 37th account ever created. Never edited, never
    /// reused, and rendered as quiet typography rather than a chip: see `FrameNumberLabel`.
    var signupNumber: Int
    /// Only ever the badges this account has actually earned, oldest first. There is
    /// deliberately no locked/greyed state anywhere in the UI for the rest of the catalog: a
    /// visible locked badge turns a profile into a to-do list.
    var badges: [ProfileBadge]
    var frameCount: Int
    var rollCount: Int
    /// The date of this account's very first frame, from `profile_film_stats.shooting_since`.
    /// `nil` for a zero-photo account (never an error condition), backs the "since <Month Year>"
    /// clause in the stats line; that clause is simply omitted when this is `nil`.
    var shootingSince: Date?

    /// Whether the film-stats line has anything to say. A brand-new account has zero frames and
    /// zero rolls, and "0 frames · 0 rolls" reads as a deficit exactly like Lapse's crying-emoji
    /// friend count, so the line is omitted entirely rather than shown at zero.
    var hasStats: Bool { frameCount > 0 || rollCount > 0 }
}

/// One earned achievement stamp, dated to the month it was earned so it reads as a record
/// ("shot this in August") rather than a trophy.
struct ProfileBadge: Identifiable, Equatable {
    let id: String
    let kind: ProfileBadgeKind
    let earnedAt: Date
}

/// The catalog of stamps a profile can carry, exactly the nine `badge_id`s `profile_badges` can
/// return; raw values match those strings so a row decodes straight into a case. A case existing
/// here does NOT mean it renders anywhere for an account that hasn't earned it — every call site
/// only ever iterates a profile's own `badges` array, never this `allCases`.
///
/// Seven of these are earned automatically. The last two, `foundingCrew` and `testRoll`, are
/// granted by hand and never computed, so they arrive as a surprise rather than something you can
/// see coming.
///
/// No explanation below may name another person or say which roll a badge came from: badges are
/// permanent, so a handle or a roll reference baked into one would sit on a profile forever. This
/// is why `broughtSomeone` in particular never says who was invited, the backend deliberately
/// stores no such reference to begin with.
enum ProfileBadgeKind: String, CaseIterable {
    case firstLight = "first_light"
    case fullRoll = "full_roll"
    case darkroom = "darkroom"
    case founding100 = "founding_100"
    case firstIn = "first_in"
    case rollMaker = "roll_maker"
    case broughtSomeone = "brought_someone"
    case foundingCrew = "founding_crew"
    case testRoll = "test_roll"

    /// Uppercased with generous tracking at the call site; stored here in title case so it also
    /// reads correctly wherever it's used sentence-style (e.g. inside `explanation`).
    var label: String {
        switch self {
        case .firstLight: return "First Light"
        case .fullRoll: return "Full Roll"
        case .darkroom: return "Darkroom"
        case .founding100: return "Founding 100"
        case .firstIn: return "First In"
        case .rollMaker: return "Roll Maker"
        case .broughtSomeone: return "Brought Someone"
        case .foundingCrew: return "Founding Crew"
        case .testRoll: return "Test Roll"
        }
    }

    /// Shown when someone taps the stamp. Locked badges never appear anywhere, so this tap is
    /// the only way to learn what an earned one means.
    var explanation: String {
        switch self {
        case .firstLight:
            return "Your very first frame."
        case .fullRoll:
            // "a roll", never "this roll": the stamp is not attached to any particular roll, and
            // the backend deliberately stores no reference to one.
            return "You shot into a roll before its midpoint and again after, instead of dumping it all at once and moving on."
        case .darkroom:
            // Frozen permanently by the ratchet once earned, so this reads as a thing that
            // happened, not an ongoing streak that could still slip. See profile_badges' own
            // comment in the migration for the ratchet.
            return "You opened every reveal, for every roll you were ever part of."
        case .founding100:
            return "One of the first hundred people here."
        case .firstIn:
            return "First to open the reveal on a roll."
        case .rollMaker:
            return "You started a roll, and people actually shot into it."
        case .broughtSomeone:
            // Not "and they stuck around": the predicate only proves they signed up, and nothing
            // measures whether they stayed. Copy must not claim more than the data does.
            return "You invited someone, and they joined."
        case .foundingCrew:
            return "Part of the crew that got this off the ground."
        case .testRoll:
            return "You were here while we were still testing."
        }
    }

    /// Shown alongside `explanation`, but only to someone looking at another profile's stamp for
    /// a badge they don't hold themselves; see `ProfileStampView`. Never shown for a badge the
    /// viewer already has, at that point "how to earn this" is pointless.
    ///
    /// Six of these describe real, repeatable product behaviour, written as an instruction. The
    /// other three are NOT earnable by ordinary action, and this deliberately does not pretend
    /// otherwise: `founding100` is a closed window (say what it was, not how to get it),
    /// `foundingCrew` and `testRoll` are handed out by hand (say so plainly, never phrase either
    /// as something to go do). A fake instruction here would send people chasing something that
    /// doesn't exist.
    var howToEarn: String {
        switch self {
        case .firstLight:
            return "Shoot your first frame."
        case .fullRoll:
            // Deliberately not "shoot a lot": the badge rewards coming back to a roll, not
            // volume. See the module comment on `fullRoll`'s intent.
            return "Shoot into a roll early, then come back and shoot into it again before it develops."
        case .darkroom:
            return "Open every reveal, for every roll you're part of."
        case .founding100:
            return "Went to the first hundred people here. That window's closed."
        case .firstIn:
            return "Be the first to open a roll's reveal."
        case .rollMaker:
            return "Start a roll, and get people to shoot into it."
        case .broughtSomeone:
            return "Invite someone, and have them join."
        case .foundingCrew:
            return "Given by hand to the crew that got this off the ground, not something you can earn."
        case .testRoll:
            return "Given by hand to early testers, not something you can earn."
        }
    }
}

/// Decodes the single row `profile_film_stats(uuid)` returns. See
/// `FeedService.fetchProfileFilmStats`.
struct ProfileFilmStats: Decodable {
    let framesShot: Int
    let rollsDeveloped: Int
    /// `nil` for a zero-photo account; not an error condition.
    let shootingSince: Date?

    enum CodingKeys: String, CodingKey {
        case framesShot = "frames_shot"
        case rollsDeveloped = "rolls_developed"
        case shootingSince = "shooting_since"
    }
}

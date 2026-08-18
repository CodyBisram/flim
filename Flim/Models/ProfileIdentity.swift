import SwiftUI

/// A profile's permanent identity: the signup number, earned badges, and film stats. This is
/// the FLIM inversion of Lapse's profile chips ("Star sign", "0 friends 😢"): the number is
/// unfakeable and permanent, badges only ever show what was actually earned, and the stats only
/// ever go up.
///
/// Sourced from `profiles.signup_ordinal` (the number) and the `profile_badges` RPC (badges),
/// see `FeedService.fetchProfileBadges`. Built in `UserPageView.load()`. That RPC failing
/// degrades quietly: the number always comes from the profile row alone and never depends on
/// it, see that call site.
///
/// This used to also carry frame/roll counts and a "shooting since" date, rendered as a film
/// stats line beneath the stamps. That line was cut: it duplicated the social counts row right
/// below it ("40 shared · 47 followers · 47 following" already says how much this account has
/// shared), so it told an overlapping fact twice. `profile_film_stats` and
/// `FeedService.fetchProfileFilmStats` still exist for a future caller, they're just not fetched
/// on this page anymore, see `UserPageView.load()`.
struct ProfileIdentity: Equatable {
    /// The permanent signup number, e.g. the 37th account ever created. Never edited, never
    /// reused, and rendered as quiet typography rather than a chip: see `FrameNumberLabel`.
    var signupNumber: Int
    /// Only ever the badges this account has actually earned, oldest first. There is
    /// deliberately no locked/greyed state anywhere in the UI for the rest of the catalog: a
    /// visible locked badge turns a profile into a to-do list.
    var badges: [ProfileBadge]
}

/// One earned achievement stamp, dated to the month it was earned so it reads as a record
/// ("shot this in August") rather than a trophy.
struct ProfileBadge: Identifiable, Equatable {
    let id: String
    let kind: ProfileBadgeKind
    let earnedAt: Date
}

/// The catalog of stamps a profile can carry, exactly the twenty-two `badge_id`s
/// `profile_badges` can return; raw values match those strings so a row decodes straight into a
/// case. A case existing here does NOT mean it renders anywhere for an account that hasn't earned
/// it — every profile-facing call site only ever iterates a profile's own `badges` array, never
/// this `allCases`. `BadgePickerSheet` is the one deliberate exception: it iterates `allCases` to
/// show the locked rest of the catalog, see its own module comment for why that's the opposite
/// rule on purpose.
///
/// Most of these are earned automatically. `founder` and `foundingCrew` are granted by hand and
/// never computed, so they arrive as a surprise rather than something you can see coming; `tier`
/// below is what actually encodes that distinction visually, see its own comment.
///
/// There was a third hand-granted case, `testRoll` ("Tester"), retired in
/// `2026-08-18_nine_more_badges.sql`. It said the same thing `foundingCrew` says, more thinly —
/// being here during testing IS being part of the crew that got this off the ground — and split
/// one honour across two pills. Its six holders were migrated onto `foundingCrew`, keeping their
/// original `earned_at`, so nobody lost a stamp or had its date rewritten.
///
/// No explanation below may name another person or say which roll a badge came from: badges are
/// permanent, so a handle or a roll reference baked into one would sit on a profile forever. This
/// is why `broughtSomeone` in particular never says who was invited, the backend deliberately
/// stores no such reference to begin with. `fullHouse` and `packedHouse` in particular must never
/// read as personal to the reader either: each one's `earned_at` is the moment a roll crossed its
/// contributor threshold, the same timestamp for every contributor of that roll, including
/// someone who arrived after the threshold was already crossed — see their cases below for how
/// that shapes the copy.
enum ProfileBadgeKind: String, CaseIterable {
    case firstLight = "first_light"
    case fullRoll = "full_roll"
    case darkroom = "darkroom"
    case founding100 = "founding_100"
    case firstIn = "first_in"
    case rollMaker = "roll_maker"
    case broughtSomeone = "brought_someone"
    case joinedIn = "joined_in"
    case chippedIn = "chipped_in"
    case shared = "shared"
    case wellMet = "well_met"
    case fullHouse = "full_house"
    case foundingCrew = "founding_crew"
    case frontRow = "front_row"
    case packedHouse = "packed_house"
    case patron = "patron"
    case coverToCover = "cover_to_cover"
    case keptOne = "kept_one"
    case regular = "regular"
    case oneYear = "one_year"
    case fullSet = "full_set"
    case founder = "founder"
    case openDoor = "open_door"
    // The small, frequent ones. A catalogue whose cheapest badge is "shoot your first frame" has
    // nothing to offer on day three, so these mark the ordinary things a person does in their
    // first fortnight and keeps doing: reacting, tagging, being tagged, captioning, being
    // followed, and simply shooting a few more frames.
    case chimedIn = "chimed_in"
    case inFrame = "in_frame"
    case spotter = "spotter"
    case saidIt = "said_it"
    case tenFrames = "ten_frames"
    case goodCompany = "good_company"

    /// Whether an account that doesn't already hold this could ever go and get it.
    ///
    /// False for exactly three: `founder` and `foundingCrew` are handed out by a person and have
    /// no predicate at all, and `founding100`'s window shut at the hundredth signup — if you do
    /// not already hold it, your ordinal is past 100 and nothing you do changes that. Everything
    /// else is reachable by ordinary use.
    ///
    /// `BadgePickerSheet`'s locked catalog filters on this, so the collection screen only ever
    /// lists things you can actually go and earn. Showing a stranger a gold pill captioned "given
    /// by hand, not something you can earn" is worse than showing nothing: it advertises a closed
    /// door. Deliberately keyed on the case rather than on `tier`, so re-tiering the catalogue for
    /// colour reasons can never silently change which badges are advertised as reachable.
    var isEarnable: Bool {
        switch self {
        case .founder, .foundingCrew, .founding100: return false
        default: return true
        }
    }

    /// Which of the three ways this badge is obtained, and therefore how its pill renders. See
    /// `ProfileBadgeTier`'s own comment for why this is keyed on HOW rather than how rare a badge
    /// currently is.
    var tier: ProfileBadgeTier {
        switch self {
        // The closed set. Nothing new can ever enter this rung.
        case .founder, .foundingCrew, .founding100:
            return .founding
        // The hardest things in the catalogue. Each one is many of something.
        case .fullSet, .frontRow, .packedHouse, .coverToCover, .openDoor:
            return .gold
        // Real effort, but a single determined stretch rather than a campaign.
        case .patron, .darkroom, .firstIn, .keptOne, .regular, .oneYear:
            return .silver
        // You did something that needed other people.
        case .fullRoll, .rollMaker, .broughtSomeone, .wellMet, .fullHouse, .spotter, .inFrame,
             .goodCompany:
            return .bronze
        // You used FLIM. Deliberately not metal: these are the steady drumbeat, and casting them
        // in bronze would make bronze mean nothing.
        case .firstLight, .shared, .joinedIn, .chippedIn, .chimedIn, .saidIt, .tenFrames:
            return .accent
        }
    }

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
        // Not "Brought Someone": that truncates to "BROUGHT SO…" at pill size on device. "Plus
        // One" is short enough to never truncate and still reads as "you brought someone in".
        case .broughtSomeone: return "Plus One"
        case .joinedIn: return "Joined In"
        case .chippedIn: return "Chipped In"
        case .shared: return "Shared"
        case .wellMet: return "Well Met"
        case .fullHouse: return "Full House"
        case .foundingCrew: return "Founding Crew"
        case .frontRow: return "Front Row"
        case .packedHouse: return "Packed House"
        case .patron: return "Patron"
        case .coverToCover: return "Cover to Cover"
        case .keptOne: return "Kept One"
        case .regular: return "Regular"
        case .oneYear: return "One Year"
        case .fullSet: return "Full Set"
        case .founder: return "Founder"
        case .openDoor: return "Open Door"
        case .chimedIn: return "Chimed In"
        case .inFrame: return "In Frame"
        case .spotter: return "Spotter"
        case .saidIt: return "Said It"
        case .tenFrames: return "Ten Frames"
        case .goodCompany: return "Good Company"
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
            // measures whether they stayed. Copy must not claim more than the data does. Phrased
            // to match the "Plus One" label rather than the old "Brought Someone" one.
            return "You brought someone along, and they joined."
        case .joinedIn:
            return "You joined a roll someone else started."
        case .chippedIn:
            return "You shot into a roll you didn't start."
        case .shared:
            // Common (roughly two thirds of accounts), so this reads as a plain fact, not a
            // triumph, unlike the rarer badges around it.
            return "You posted a frame to the feed."
        case .wellMet:
            return "Someone else reacted to one of your photos."
        case .fullHouse:
            // Never "when you joined" or anything else that reads as personal timing: earned_at
            // is the moment the roll's FIFTH contributor's first photo landed, one shared instant
            // for every contributor of that roll, including someone who arrived sixth or later.
            // This describes the roll filling up, not the reader's own arrival.
            return "A roll you shot into filled up with five or more photographers."
        case .foundingCrew:
            return "Part of the crew that got this off the ground."
        case .frontRow:
            return "First to open the reveal, on five different rolls."
        case .packedHouse:
            // Same rule as `fullHouse` above: describes the roll crossing ten contributors, not
            // the reader's own arrival, since everyone in that roll shares this exact timestamp.
            return "A roll you shot into grew to ten or more photographers."
        case .patron:
            return "Five people you invited joined."
        case .coverToCover:
            return "You shot into ten rolls before they developed."
        case .keptOne:
            return "Ten of your frames developed, and you kept every one to yourself."
        case .regular:
            return "Active on seven different days."
        case .oneYear:
            return "A year since you joined \(AppInfo.appName)."
        case .fullSet:
            return "Ten other badges, held at once."
        case .founder:
            return "Built \(AppInfo.appName)."
        case .openDoor:
            return "Ten people you invited joined."
        case .chimedIn:
            return "You reacted to someone else's photo."
        case .inFrame:
            return "Someone tagged you in a photo."
        case .spotter:
            return "You tagged someone in one of yours."
        case .saidIt:
            return "You wrote a caption."
        case .tenFrames:
            return "Ten frames shot."
        case .goodCompany:
            return "Someone followed you."
        }
    }

    /// Shown alongside `explanation`, both to someone looking at another profile's pill for a
    /// badge they don't hold themselves (see `ProfileBadgePill`), and to every locked row in
    /// `BadgePickerSheet`'s own catalog. Never shown for a badge the viewer already has, at that
    /// point "how to earn this" is pointless.
    ///
    /// Most of these describe real, repeatable product behaviour, written as an instruction. Four
    /// are NOT earnable by ordinary action, and this deliberately does not pretend otherwise:
    /// `founding100` is a closed window (say what it was, not how to get it); `foundingCrew`,
    /// `testRoll`, and `founder` are handed out by hand (say so plainly, never phrase any of them
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
        case .joinedIn:
            return "Join a roll someone else started."
        case .chippedIn:
            return "Shoot into a roll you didn't start."
        case .shared:
            return "Post a frame to the feed."
        case .wellMet:
            return "Shoot something, and have someone else react to it."
        case .fullHouse:
            return "Shoot into a roll that grows to five or more photographers."
        case .foundingCrew:
            return "Given by hand to the crew that got this off the ground, not something you can earn."
        case .frontRow:
            return "Be first to open the reveal, on five different rolls."
        case .packedHouse:
            return "Shoot into a roll that grows to ten or more photographers."
        case .patron:
            return "Invite people until five of them join."
        case .coverToCover:
            return "Shoot into ten different rolls before they develop."
        case .keptOne:
            return "Let ten frames develop without sharing any of them."
        case .regular:
            return "Show up on seven different days."
        case .oneYear:
            return "Keep your account for a year."
        case .fullSet:
            return "Earn ten other badges."
        case .founder:
            return "Given by hand to whoever built \(AppInfo.appName), not something you can earn."
        case .openDoor:
            return "Invite people until ten of them join."
        case .chimedIn:
            return "React to someone else's photo."
        case .inFrame:
            return "Get tagged in someone's photo."
        case .spotter:
            return "Tag someone in one of your photos."
        case .saidIt:
            return "Write a caption on a frame."
        case .tenFrames:
            return "Shoot ten frames."
        case .goodCompany:
            return "Have someone follow you."
        }
    }
}

/// How a badge ranks, and therefore how its pill is struck. Five rungs, in descending order:
/// `founding`, `gold`, `silver`, `bronze`, `accent`.
///
/// THE ONE RULE: a badge's rung is assigned by hand, in `ProfileBadgeKind.tier`, and is never
/// computed from live holder counts. A rarity-driven ladder would silently restrike a stamp as
/// the app grows, and a permanent record must not drift. `founding_100` is the clearest case for
/// this: it sits on the top rung while every account still holds it, because it is the one badge
/// that gets rarer with time rather than commoner, and it should not be demoted today only to be
/// promoted at ten thousand users.
///
/// The bottom rung is deliberately not metal. If every badge were a medal, none would read as
/// one; `accent` is the steady drumbeat of ordinary use, and casting it in bronze would leave
/// bronze meaning nothing. It also keeps the viewer's chosen accent colour present on profiles,
/// which a pure medal ladder loses entirely.
enum ProfileBadgeTier {
    /// The closed set: `founder`, `foundingCrew`, `founding100`. Nothing new can ever enter.
    case founding
    /// Many of something: five reveals won, ten invitees, ten rolls, ten badges.
    case gold
    /// One determined stretch rather than a campaign.
    case silver
    /// You did something that needed other people.
    case bronze
    /// You used FLIM. Not metal, on purpose.
    case accent

    /// True for every rung that is struck from metal, i.e. everything but `accent`. Metal pills
    /// carry dark text on a bright gradient; `accent` keeps the tinted wash it always had.
    var isMetal: Bool { self != .accent }

    /// The two stops of the pill's fill, lighter above darker, which is what reads as a struck
    /// surface catching light from above rather than a flat swatch of colour. For `accent` both
    /// stops are the same faint wash: it is not pretending to be metal.
    func gradient(accent: Color) -> [Color] {
        switch self {
        case .founding: return [FlimTheme.badgeGoldLight, FlimTheme.badgeGold]
        case .gold:     return [FlimTheme.badgeGold, FlimTheme.badgeGoldDeep]
        case .silver:   return [FlimTheme.badgeSilverLight, FlimTheme.badgeSilver]
        case .bronze:   return [FlimTheme.badgeBronzeLight, FlimTheme.badgeBronze]
        case .accent:   return [accent.opacity(0.18), accent.opacity(0.13)]
        }
    }

    /// Text colour: near-black on metal, which is what every solid-accent control in the app
    /// already does; the accent itself on the tinted wash.
    func foreground(accent: Color) -> Color {
        isMetal ? FlimTheme.badgeInk : accent
    }

    /// The hairline along the pill's edge. On metal this is a bright rim, the single detail that
    /// does most of the work of making a flat capsule read as a struck object.
    func rim(accent: Color) -> Color {
        switch self {
        case .founding: return .white.opacity(0.55)
        case .gold:     return .white.opacity(0.38)
        case .silver:   return .white.opacity(0.45)
        case .bronze:   return .white.opacity(0.28)
        case .accent:   return accent.opacity(0.45)
        }
    }

    /// A soft coloured glow beneath the pill, and only on the top rung. Reserved rather than
    /// spread across every metal tier: if gold, silver and bronze all glowed, the founding pills
    /// would stop being the thing your eye lands on first.
    func glow(accent: Color) -> Color {
        self == .founding ? FlimTheme.badgeGold.opacity(0.5) : .clear
    }

    /// Kept for the one place that still asks whether a pill is filled or washed: see
    /// `BadgePillLabel`'s muted (locked catalogue) branch.
    var isSolidFill: Bool { isMetal }

    /// The rung's own hue, for anything that needs one flat colour rather than the gradient.
    func hue(accent: Color) -> Color {
        switch self {
        case .founding, .gold: return FlimTheme.badgeGold
        case .silver:          return FlimTheme.badgeSilver
        case .bronze:          return FlimTheme.badgeBronze
        case .accent:          return accent
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

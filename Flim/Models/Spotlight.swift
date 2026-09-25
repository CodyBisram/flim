import Foundation

// Spotlight (1.6): the week's frames, not a place. People put one frame a week up from their
// own post's menu, only the team sees what was put up, and the few chosen arrive in everyone's
// feed as one short strip. Everything here is either a decoded server shape or a pure rule, so
// the decisions are tested once instead of trusted inline in a view. See
// docs/SPOTLIGHT_1_6_PLAN.md for the plan and its edge cases.
//
// The client never does the week math. The server names the week (`week_key`, a plain
// "YYYY-MM-DD" string, never parsed as a midnight-UTC instant) and returns its bounds; the only
// date arithmetic below turns that string into words.

/// One chosen frame, as `spotlight_published` / `spotlight_frames` return it inside a week's
/// `frames` array. Paths come through the posts join at read time; nothing is copied.
struct SpotlightFrame: Decodable, Identifiable, Hashable {
    let postId: UUID
    let photoId: UUID
    let userId: UUID
    let username: String?
    let displayName: String?
    let avatarPath: String?
    let thumbPath: String?
    let feedPath: String?
    let storagePath: String
    let postCreatedAt: Date
    let chosenAt: Date?

    var id: UUID { postId }
    var handle: String { "@\(username ?? "someone")" }

    /// What a 118pt frame signs and caches under: the thumbnail, else the mid-size rendition.
    /// Never `storagePath`: a master through a card-sized frame is the egress mistake the
    /// strip, the sheet and the shelf must not make. nil means no small rendition exists, and
    /// the cell paints its well instead.
    var cardPath: String? { thumbPath ?? feedPath }

    enum CodingKeys: String, CodingKey {
        case username
        case postId = "post_id"
        case photoId = "photo_id"
        case userId = "user_id"
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case thumbPath = "thumb_path"
        case feedPath = "feed_path"
        case storagePath = "storage_path"
        case postCreatedAt = "post_created_at"
        case chosenAt = "chosen_at"
    }
}

/// One published week: the strip, a row in the sheet of past weeks, or a card on a shelf.
struct SpotlightWeek: Decodable, Identifiable, Equatable {
    /// "YYYY-MM-DD", the week's Monday, kept as the server's string. Labels come from it via
    /// `SpotlightWeekLabel`, never from a `Date` decoded at midnight UTC.
    let weekKey: String
    let publishedAt: Date
    var frames: [SpotlightFrame]

    var id: String { weekKey }

    enum CodingKeys: String, CodingKey {
        case frames
        case weekKey = "week_key"
        case publishedAt = "published_at"
    }

    /// The frames this viewer may see right now: the server already dropped blocks, but a block
    /// made this session lands locally first. A week whose frames are all filtered is hidden
    /// by its caller (see `visible(_:blocked:)`).
    func visibleFrames(blocked: Set<UUID>) -> [SpotlightFrame] {
        frames.filter { !blocked.contains($0.userId) }
    }

    /// Weeks with at least one frame left for this viewer, each trimmed to those frames.
    static func visible(_ weeks: [SpotlightWeek], blocked: Set<UUID>) -> [SpotlightWeek] {
        weeks.compactMap { week in
            let frames = week.visibleFrames(blocked: blocked)
            guard !frames.isEmpty else { return nil }
            var trimmed = week
            trimmed.frames = frames
            return trimmed
        }
    }

    /// Drops every frame matching `gone` and any week left empty. Deletes and blocks prune
    /// through here, on every cache that holds weeks.
    static func pruned(_ weeks: [SpotlightWeek], removing gone: (SpotlightFrame) -> Bool) -> [SpotlightWeek] {
        weeks.compactMap { week in
            var trimmed = week
            trimmed.frames.removeAll(where: gone)
            return trimmed.frames.isEmpty ? nil : trimmed
        }
    }
}

/// The own-post menu's state, from `own_spotlight_entry()`: this week's bounds, whether the
/// account may put anything up (false inside a covered window), this week's entry if any, and
/// the entry still waiting in the most recent closed week the team has not published yet.
/// Never carries `chosen_at`.
struct OwnSpotlightEntry: Decodable, Equatable {
    let weekKey: String
    let weekStartsAt: Date
    let weekClosesAt: Date
    let canPutUp: Bool
    var postId: UUID?
    var photoId: UUID?
    var postCreatedAt: Date?
    var putUpAt: Date?
    /// The caller's entry in the most recent closed, unpublished week: it can still come down
    /// until the team publishes that week. Optional on the wire (absent before the server
    /// learns to send it), so an older server simply reads as nothing pending.
    var pendingWeekKey: String? = nil
    var pendingPostId: UUID? = nil
    var pendingPhotoId: UUID? = nil

    enum CodingKeys: String, CodingKey {
        case weekKey = "week_key"
        case weekStartsAt = "week_starts_at"
        case weekClosesAt = "week_closes_at"
        case canPutUp = "can_put_up"
        case postId = "post_id"
        case photoId = "photo_id"
        case postCreatedAt = "post_created_at"
        case putUpAt = "put_up_at"
        case pendingWeekKey = "pending_week_key"
        case pendingPostId = "pending_post_id"
        case pendingPhotoId = "pending_photo_id"
    }

    /// The same bounds with no entry this week: what a take-down leaves behind. The closed
    /// week's pending entry is untouched.
    var cleared: OwnSpotlightEntry {
        var next = self
        next.postId = nil
        next.photoId = nil
        next.postCreatedAt = nil
        next.putUpAt = nil
        return next
    }

    /// The same, with the closed week's pending entry taken down instead.
    var clearedPending: OwnSpotlightEntry {
        var next = self
        next.pendingWeekKey = nil
        next.pendingPostId = nil
        next.pendingPhotoId = nil
        return next
    }

    /// Whether this post is the entry this week or the one still waiting on its week's publish.
    func holds(postId: UUID) -> Bool { self.postId == postId || pendingPostId == postId }

    /// The same, by photo id: a Darkroom delete knows nothing else.
    func holds(photoIdIn ids: Set<UUID>) -> Bool {
        if let photoId, ids.contains(photoId) { return true }
        if let pendingPhotoId, ids.contains(pendingPhotoId) { return true }
        return false
    }
}

/// `put_up_for_spotlight`'s single row: the entry as it now stands, and what it swapped out.
struct SpotlightPutUpResult: Decodable, Equatable {
    let weekKey: String
    let weekStartsAt: Date
    let weekClosesAt: Date
    let postId: UUID
    let putUpAt: Date
    let replacedPostId: UUID?
    let replacedPostCreatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case weekKey = "week_key"
        case weekStartsAt = "week_starts_at"
        case weekClosesAt = "week_closes_at"
        case postId = "post_id"
        case putUpAt = "put_up_at"
        case replacedPostId = "replaced_post_id"
        case replacedPostCreatedAt = "replaced_post_created_at"
    }
}

// MARK: - Week labels

/// Words for a week, built from the `week_key` string. A Spotlight is always named by its week
/// ("the week of September 14"), never by a weekday.
///
/// The string is read as GREGORIAN calendar components and formatted in the same Gregorian
/// calendar and zone it is placed in, so the day named is the day the string says in every
/// zone on earth and under every calendar a phone can be set to. Decoding "2026-09-14" as
/// midnight UTC and formatting it locally is exactly how Los Angeles would read "September
/// 13"; building it in the phone's own calendar is how a Persian or Islamic calendar would
/// read it as month 9 of that calendar. The `calendar` a caller passes contributes only its
/// time zone.
enum SpotlightWeekLabel {
    static func components(_ weekKey: String) -> DateComponents? {
        let parts = weekKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// A Gregorian calendar in `zone`, whatever calendar the phone is set to.
    static func gregorian(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    private static func format(_ weekKey: String, _ template: String, calendar: Calendar) -> String? {
        guard var parts = components(weekKey) else { return nil }
        let gregorian = gregorian(in: calendar.timeZone)
        // Noon in the zone: the named day, whatever the zone's offset.
        parts.hour = 12
        guard let date = gregorian.date(from: parts) else { return nil }
        return SpotlightDateFormatters.formatter(template, zone: gregorian.timeZone).string(from: date)
    }

    /// "September 14". Falls back to the raw key rather than inventing a date.
    static func monthDay(_ weekKey: String, calendar: Calendar = .current) -> String {
        format(weekKey, "MMMM d", calendar: calendar) ?? weekKey
    }

    /// "Sep 14", the shelf's compact meta.
    static func shortMonthDay(_ weekKey: String, calendar: Calendar = .current) -> String {
        format(weekKey, "MMM d", calendar: calendar) ?? weekKey
    }

    /// "the week of September 14", mid-sentence.
    static func phrase(_ weekKey: String, calendar: Calendar = .current) -> String {
        "the week of \(monthDay(weekKey, calendar: calendar))"
    }

    /// "The week of September 14", starting a line.
    static func sentence(_ weekKey: String, calendar: Calendar = .current) -> String {
        "The week of \(monthDay(weekKey, calendar: calendar))"
    }

    /// "The week of Sep 14", the shelf card's meta.
    static func shortSentence(_ weekKey: String, calendar: Calendar = .current) -> String {
        "The week of \(shortMonthDay(weekKey, calendar: calendar))"
    }

    /// "THE WEEK OF SEPTEMBER 14", the sheet's row rule.
    static func rule(_ weekKey: String, calendar: Calendar = .current) -> String {
        sentence(weekKey, calendar: calendar).uppercased()
    }
}

// MARK: - The own-post menu

/// Which Spotlight item the own-post menu shows for one post. Three server states (nothing up,
/// this post up, another post up) plus the published case, the refusals the client can know
/// ahead of time, and hidden. Hidden while the entry is unknown: showing "Put it up" then would
/// silently swap out a frame the menu did not know was up.
enum SpotlightMenuItem: Equatable {
    case hidden
    case putUp
    case takeDown
    /// Another frame is up this week; this one would replace it. `fromDay` names the day the
    /// replaced frame was posted ("today", "yesterday", else the weekday), from the server's
    /// `post_created_at`, filed by the 04:00 day.
    case swap(fromDay: String)
    /// Put up in a week that has closed but is not published yet: it can still come down
    /// until the team publishes that week.
    case takeDownPending(weekKey: String)
    case disabled(reason: String)
    /// Your own frame, chosen and published. Taking it out is final; the badge stays.
    case takeOut(weekKey: String)

    static let taggedReason = "Frames with people tagged can't go up"
    static let notPhotographerReason = "Only frames you shot can go up"
    static let earlierWeekReason = "Only this week's frames can go up"

    /// - Parameters:
    ///   - chosenWeekKey: set when this post is one of the viewer's own published frames.
    ///   - isPhotographer: whether the viewer shot the photo; nil while unknown, which offers
    ///     the item and lets the server's `not_photographer` refusal speak if it must.
    static func resolve(post: Post, viewerId: UUID?, entry: OwnSpotlightEntry?,
                        chosenWeekKey: String?, isTagged: Bool, isPhotographer: Bool?,
                        now: Date = .now, calendar: Calendar = .current) -> SpotlightMenuItem {
        guard let viewerId, post.isOwned(by: viewerId) else { return .hidden }
        if let chosenWeekKey { return .takeOut(weekKey: chosenWeekKey) }
        // Consent holds until publish: the closed week's frame can come down whatever this
        // week allows (a covered window included).
        if let entry, entry.pendingPostId == post.id, let pendingWeek = entry.pendingWeekKey {
            return .takeDownPending(weekKey: pendingWeek)
        }
        guard let entry, entry.canPutUp else { return .hidden }
        // The bounds are the server's. An earlier week's post says why it cannot go up; one
        // past the close means the entry itself is stale, so nothing is offered until it is
        // read again.
        if post.createdAt < entry.weekStartsAt { return .disabled(reason: earlierWeekReason) }
        guard post.createdAt < entry.weekClosesAt else { return .hidden }
        if entry.postId == post.id { return .takeDown }
        if isTagged { return .disabled(reason: taggedReason) }
        if isPhotographer == false { return .disabled(reason: notPhotographerReason) }
        if entry.postId != nil {
            // Another frame is up but the entry does not say when it was posted: offering
            // "Put it up" would silently swap it out, so offer nothing until it is known.
            guard let replacedAt = entry.postCreatedAt else { return .hidden }
            return .swap(fromDay: dayWord(of: replacedAt, now: now, calendar: calendar))
        }
        return .putUp
    }

    /// "today", "yesterday", else the weekday ("Tuesday"), for the day a post files under,
    /// through the feed's 04:00 boundary on both sides.
    static func dayWord(of date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let day = FeedUnit.dayKey(for: date, calendar: calendar)
        let today = FeedUnit.dayKey(for: now, calendar: calendar)
        if day == today { return "today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "yesterday"
        }
        return weekday(of: date, calendar: calendar)
    }

    /// The day a post files under, as a weekday name ("Tuesday"), through the feed's own 04:00
    /// boundary so a 01:00 post reads as the night before, the way the feed shows it.
    static func weekday(of date: Date, calendar: Calendar = .current) -> String {
        let day = FeedUnit.dayKey(for: date, calendar: calendar)
        return SpotlightDateFormatters.formatter("EEEE", zone: calendar.timeZone)
            .string(from: day.addingTimeInterval(12 * 3600))
    }
}

/// Spotlight's date formatters, built once per pattern and zone rather than once per label:
/// Gregorian, `en_US_POSIX`, never mutated after they are cached, so a cached one is safe to
/// format with from any thread.
enum SpotlightDateFormatters {
    private static let lock = NSLock()
    private static var cache: [String: DateFormatter] = [:]

    static func formatter(_ pattern: String, zone: TimeZone) -> DateFormatter {
        let key = "\(pattern)|\(zone.identifier)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        let formatter = DateFormatter()
        formatter.calendar = SpotlightWeekLabel.gregorian(in: zone)
        formatter.timeZone = zone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        cache[key] = formatter
        return formatter
    }
}

/// What the capsule's slot says once a put-up has landed: a plain put-up, or a swap that names
/// the frame it replaced. No Undo: a frame can be taken down from its menu any time until the
/// week closes, so a few seconds of door would protect nothing.
enum SpotlightPutUpNotice {
    /// - Parameters:
    ///   - replacedPostId: the frame the server says this put-up took down, if any.
    ///   - replacedAt: when that frame was posted, from the server, else from the menu's entry.
    static func text(postId: UUID, replacedPostId: UUID?, replacedAt: Date?, now: Date = .now,
                     calendar: Calendar = .current) -> String {
        guard let replacedPostId, replacedPostId != postId else {
            return "Up for Spotlight. Only the team at \(AppInfo.appName) sees it."
        }
        guard let replacedAt else { return "Swapped into Spotlight. Your earlier frame came down." }
        let day = SpotlightMenuItem.dayWord(of: replacedAt, now: now, calendar: calendar)
        return "Swapped into Spotlight. Your frame from \(day) came down."
    }
}

/// Why "Tag people" is off for one of your own posts: a frame up for Spotlight this week, or
/// one already chosen, cannot be tagged (a tagged friend never agreed to be shown to everyone).
/// nil when tagging is open.
enum SpotlightTagLock {
    static let upThisWeek = "Take it down from Spotlight to tag people"
    static let chosen = "Frames put up for Spotlight can't be tagged"

    static func reason(postId: UUID, entry: OwnSpotlightEntry?, chosen: [UUID: String]) -> String? {
        if chosen[postId] != nil { return Self.chosen }
        if entry?.postId == postId { return upThisWeek }
        return nil
    }
}

/// Why "Edit caption" is off for one of your own posts: the server refuses a caption change on
/// a frame that is up this week, or chosen (`in_spotlight`), because the team chose it with the
/// caption it had. nil when editing is open.
enum SpotlightCaptionLock {
    static let upThisWeek = "Take it down from Spotlight to edit the caption"
    static let chosen = "Frames put up for Spotlight can't be edited"

    static func reason(postId: UUID, entry: OwnSpotlightEntry?, chosen: [UUID: String]) -> String? {
        if chosen[postId] != nil { return Self.chosen }
        if entry?.postId == postId { return upThisWeek }
        return nil
    }
}

/// What the capsule says in place of "Up for Spotlight" when the server refuses, keyed by the
/// refusal's name (`PostgrestError.message` under code P0001).
enum SpotlightRefusal {
    static let weekClosedPutUp = "This week closed before your frame went up."
    static let weekClosedTakeDown = "This week has closed, so it can't come down now."
    static let cantGoUp = "This frame can't go up."
    static let putUpNetwork = "Couldn't put it up. Check your connection and try again."
    static let takeDownNetwork = "Couldn't take it down. Check your connection and try again."
    static let takeOutNetwork = "Couldn't take it out. Check your connection and try again."
    static let openNetwork = "Couldn't open that photo. Check your connection and try again."
    static let taggedOnSpotlight = "Frames put up for Spotlight can't be tagged."
    /// A caption save the server refused with `in_spotlight` (the menu did not know yet).
    static let captionOnSpotlight = "Frames put up for Spotlight can't be edited."
    static let gone = "That photo isn't there anymore."

    enum Action { case putUp, takeDown, takeOut }

    /// `refusal` is the server's name when it refused by name, nil for anything else (offline,
    /// a timeout, a server error), which reads as a connection problem. Returns nil when there
    /// is nothing to say: a take-down the server cannot find is already down, and the caller
    /// only reads the entry again.
    static func message(refusal: String?, action: Action) -> String? {
        switch (refusal, action) {
        case ("not_found", .takeDown): return nil
        case ("week_closed", .putUp): return weekClosedPutUp
        case ("week_closed", _): return weekClosedTakeDown
        default: break
        }
        switch refusal {
        case "tagged": return SpotlightMenuItem.taggedReason
        case "not_photographer": return SpotlightMenuItem.notPhotographerReason
        case "hidden", "covered", "not_found", "not_signed_in": return cantGoUp
        default:
            switch action {
            case .putUp: return putUpNetwork
            case .takeDown: return takeDownNetwork
            case .takeOut: return takeOutNetwork
            }
        }
    }
}

// MARK: - The strip's place in the feed

/// Where a published week's strip sits among the feed's units. Pure over the units, the
/// publish instant and whether more pages exist; the strip itself never enters `feed.feed` or
/// the unit list (dedupe, the ledger, straddle completion, seeding and index-based paging all
/// depend on those holding posts and nothing else).
enum SpotlightPlacement: Equatable {
    /// Above this unit: the first unit older than the publish instant.
    case beforeUnit(String)
    /// Below the last unit: the window is fully loaded and every unit is newer.
    case afterLast
    /// Its place is below a page not loaded yet. Not rendered, so it can never appear above
    /// posts that later pages would put above it.
    case notYet

    /// `units` in feed order (newest first).
    static func place(units: [FeedUnit], publishedAt: Date, hasMoreFeed: Bool) -> SpotlightPlacement {
        if let older = units.first(where: { $0.newestAt < publishedAt }) { return .beforeUnit(older.id) }
        return hasMoreFeed ? .notYet : .afterLast
    }
}

/// The caught-up block's position, mirrored from the feed so the strip rule can be pure.
enum SpotlightSeam: Equatable {
    case none
    case top
    case after(String)
}

/// Where a strip actually renders, once the caught-up block is taken into account. The seam
/// separates what is new from what was already seen, and an unseen strip is new: when its own
/// place falls on the seen side, it sits just above the block instead. Snapshotted with the
/// ledger, so marking it seen never moves it.
enum SpotlightSlot: Equatable {
    /// Above everything, including a caught-up block at the top.
    case top
    /// In that unit's row, above its card.
    case beforeUnit(String)
    /// In that unit's row, after its card, above the caught-up block that follows it.
    case aboveCaughtUpBlock(afterUnit: String)
    /// Below the last unit.
    case afterLast
    case hidden

    static func slot(placement: SpotlightPlacement, seam: SpotlightSeam,
                     unitIds: [String], unseen: Bool) -> SpotlightSlot {
        // Before anything that could hide it: an unseen strip over a caught-up feed is new
        // wherever its own place falls, so it shows at this reload instead of waiting on a page
        // and later dropping in above someone who is already reading.
        if unseen, seam == .top { return .top }
        let position: Int
        switch placement {
        case .notYet:
            return .hidden
        case .afterLast:
            position = unitIds.count
        case .beforeUnit(let id):
            guard let index = unitIds.firstIndex(of: id) else { return .hidden }
            position = index
        }
        if unseen {
            switch seam {
            case .top:
                return .top
            case .after(let seamId):
                if let seamIndex = unitIds.firstIndex(of: seamId), position > seamIndex {
                    return .aboveCaughtUpBlock(afterUnit: seamId)
                }
            case .none:
                break
            }
        }
        if position >= unitIds.count { return unitIds.isEmpty ? .top : .afterLast }
        return .beforeUnit(unitIds[position])
    }

    /// Every strip week's slot, as the feed snapshots them. A full snapshot (a reload, the
    /// 04:00 boundary, "New posts") places every week, and is the ONLY pass that may lift an
    /// unseen strip over the seam. A grow-only pass (paging, a straddle completion, a delete or
    /// a block taking an anchor away) keeps every slot that still has its anchor and places
    /// the rest at their own place: a strip waiting on an unloaded page is older than every
    /// unit loaded at the snapshot, so lifting it when its page lands would drop it in above
    /// someone already reading.
    static func snapshot(previous: [String: SpotlightSlot], weeks: [SpotlightWeek], units: [FeedUnit],
                         seam: SpotlightSeam, hasMoreFeed: Bool, seen: Set<String>,
                         growOnly: Bool) -> [String: SpotlightSlot] {
        let unitIds = units.map(\.id)
        var next = growOnly ? previous : [:]
        for week in weeks {
            if growOnly, let existing = next[week.weekKey], isAnchored(existing, unitIds: unitIds) { continue }
            let placement = SpotlightPlacement.place(units: units, publishedAt: week.publishedAt,
                                                     hasMoreFeed: hasMoreFeed)
            next[week.weekKey] = slot(placement: placement, seam: seam, unitIds: unitIds,
                                      unseen: !growOnly && !seen.contains(week.weekKey))
        }
        return next
    }

    /// Whether a held slot still points at something that renders. `.hidden` is never kept by
    /// a grow-only pass: it is the "waiting on an unloaded page" state that paging resolves.
    static func isAnchored(_ slot: SpotlightSlot, unitIds: [String]) -> Bool {
        switch slot {
        case .hidden: return false
        case .top, .afterLast: return true
        case .beforeUnit(let id), .aboveCaughtUpBlock(let id): return unitIds.contains(id)
        }
    }
}

// MARK: - Activity

enum SpotlightActivity {
    /// The Activity rows the viewer's own chosen frames make: one per published week, dated at
    /// the publish instant.
    static func ownFrames(in weeks: [SpotlightWeek], ownId: UUID) -> [(week: SpotlightWeek, frame: SpotlightFrame)] {
        weeks.flatMap { week in
            week.frames.filter { $0.userId == ownId }.map { (week, $0) }
        }
    }

    /// The same rows, counted after `since`, so the bell and the tab dot agree with the list.
    static func unreadCount(weeks: [SpotlightWeek], ownId: UUID, since: Date) -> Int {
        ownFrames(in: weeks, ownId: ownId).filter { $0.week.publishedAt > since }.count
    }
}

// MARK: - Per-account local marks

/// Whether this account has seen the first-time sheet. Per account, injectable, like
/// `ActivitySeenMark`: a second account on the phone gets its own explanation.
enum SpotlightFirstTime {
    static var store: UserDefaults = .standard

    static func key(userId: UUID) -> String { "spotlightFirstTimeSeen.\(userId.uuidString)" }

    static func hasSeen(userId: UUID) -> Bool { store.bool(forKey: key(userId: userId)) }

    static func markSeen(userId: UUID) { store.set(true, forKey: key(userId: userId)) }
}

/// The one quiet line under the sort deck's "Posted to your page" banner that says a post can
/// go up for Spotlight, once per account and only for a post that could: the account's own
/// shot, nobody tagged, posted inside this week's bounds while the account may put anything up.
/// Per account and injectable, like `SpotlightFirstTime`.
enum SpotlightPostedHint {
    static var store: UserDefaults = .standard
    static let text = "You can put it up for Spotlight from its menu."

    static func key(userId: UUID) -> String { "spotlightPostedHintShown.\(userId.uuidString)" }

    static func hasShown(userId: UUID) -> Bool { store.bool(forKey: key(userId: userId)) }

    static func markShown(userId: UUID) { store.set(true, forKey: key(userId: userId)) }

    /// - Parameters:
    ///   - photoOwnerId: who shot the posted photo (`photos.user_id`).
    ///   - entry: this week's entry; nil while unknown, which says nothing rather than guess.
    static func shouldShow(userId: UUID, photoOwnerId: UUID, isTagged: Bool,
                           entry: OwnSpotlightEntry?, postedAt: Date) -> Bool {
        guard !hasShown(userId: userId), photoOwnerId == userId, !isTagged,
              let entry, entry.canPutUp else { return false }
        return postedAt >= entry.weekStartsAt && postedAt < entry.weekClosesAt
    }
}

/// Which published weeks this account has seen in the feed, for the strip's "new" pill.
enum SpotlightSeenMark {
    static var store: UserDefaults = .standard
    /// A year of weeks is plenty; older keys age out of the list.
    static let cap = 60

    static func key(userId: UUID) -> String { "spotlightSeenWeeks.\(userId.uuidString)" }

    static func seen(userId: UUID?) -> Set<String> {
        guard let userId else { return [] }
        return Set(store.stringArray(forKey: key(userId: userId)) ?? [])
    }

    static func mark(_ weekKey: String, userId: UUID?) {
        guard let userId else { return }
        var list = store.stringArray(forKey: key(userId: userId)) ?? []
        guard !list.contains(weekKey) else { return }
        list.append(weekKey)
        store.set(Array(list.sorted().suffix(cap)), forKey: key(userId: userId))
    }
}

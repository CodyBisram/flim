import Foundation
import Supabase

/// Someone asking to be friends: they follow you, you have not followed back
/// (`public.friend_requests`, supabase/migrations-v2).
struct V2FriendRequest: Decodable, Identifiable, Equatable {
    let id: UUID
    let username: String?
    let displayName: String?
    let avatarPath: String?
    let askedAt: Date
    let inCommon: Int

    var name: String { displayName?.isEmpty == false ? displayName! : (username ?? "someone") }

    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case askedAt = "asked_at"
        case inCommon = "in_common"
    }
}

/// v2's own server calls, against the functions and tables in supabase/migrations-v2 (applied
/// to FLIM Beta's project only). Each returns nil, or false, for a call that did not land, never
/// a stand-in value, so callers keep what they show.
enum V2Server {
    // MARK: Friends (product rule 2)

    static func friendRequests() async -> [V2FriendRequest]? {
        try? await supabase.rpc("friend_requests").execute().value
    }

    /// "Not now": the request goes from the caller's list; the asker is not told.
    static func dismissRequest(from requester: UUID, by me: UUID) async -> Bool {
        struct Row: Encodable { let user_id: UUID; let requester_id: UUID }
        do {
            try await supabase.from("friend_request_dismissals")
                .upsert(Row(user_id: me, requester_id: requester)).execute()
            return true
        } catch { return false }
    }

    static func friends(of user: UUID) async -> [UserProfile]? {
        struct Row: Decodable {
            let id: UUID
            let username: String?
            let display_name: String?
            let avatar_path: String?
        }
        guard let rows: [Row] = try? await supabase.rpc("friends_of", params: ["p_user": user]).execute().value else {
            return nil
        }
        return rows.map {
            UserProfile(id: $0.id, username: $0.username, avatarPath: $0.avatar_path, displayName: $0.display_name,
                        createdAt: .distantPast)
        }
    }

    // MARK: Put away and covers (product rule 4)

    static func setPutAway(_ putAway: Bool, postId: UUID) async -> Bool {
        struct Update: Encodable { let put_away: Bool }
        do {
            try await supabase.from("posts").update(Update(put_away: putAway))
                .eq("id", value: postId.uuidString).execute()
            return true
        } catch { return false }
    }

    /// The posts the caller put away, among these.
    static func putAwayPostIds(_ ids: [UUID]) async -> Set<UUID>? {
        guard !ids.isEmpty else { return [] }
        struct Row: Decodable { let id: UUID }
        guard let rows: [Row] = try? await supabase.from("posts").select("id")
            .in("id", values: ids.map(\.uuidString)).eq("put_away", value: true)
            .execute().value else { return nil }
        return Set(rows.map(\.id))
    }

    static func monthCover(user: UUID, monthStart: Date) async -> UUID? {
        struct Row: Decodable { let cover_photo_id: UUID? }
        let rows: [Row]? = try? await supabase.from("month_boxes").select("cover_photo_id")
            .eq("user_id", value: user.uuidString).eq("month_start", value: dayString(monthStart))
            .limit(1).execute().value
        return rows?.first?.cover_photo_id
    }

    static func setMonthCover(_ photoId: UUID, user: UUID, monthStart: Date) async -> Bool {
        struct Row: Encodable { let user_id: UUID; let month_start: String; let cover_photo_id: UUID }
        do {
            try await supabase.from("month_boxes")
                .upsert(Row(user_id: user, month_start: dayString(monthStart), cover_photo_id: photoId)).execute()
            return true
        } catch { return false }
    }

    /// Each boxed month's chosen cover the caller may see, by month (`public.month_box_covers`).
    static func monthBoxCovers(user: UUID) async -> [String: String]? {
        struct Row: Decodable { let month_start: String; let cover_path: String? }
        guard let rows: [Row] = try? await supabase.rpc("month_box_covers", params: ["p_user": user]).execute().value else {
            return nil
        }
        return Dictionary(rows.compactMap { row in row.cover_path.map { (row.month_start, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    static func monthKey(_ date: Date) -> String { dayString(date) }

    // MARK: Who is in

    /// Invites friends into a roll the caller is in; returns how many invitations went out.
    static func invite(_ users: [UUID], to roll: UUID) async -> Int? {
        struct Params: Encodable { let p_roll: UUID; let p_users: [UUID] }
        return try? await supabase.rpc("invite_to_roll", params: Params(p_roll: roll, p_users: users)).execute().value
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// Where two people stand (product rule 2), from the follows the app already holds.
enum V2Friendship: Equatable {
    case friends, asked, theyAsked, none

    @MainActor
    static func of(_ id: UUID, feed: FeedService) -> V2Friendship {
        switch (feed.isFollowing(id), feed.followsMe(id)) {
        case (true, true): .friends
        case (true, false): .asked
        case (false, true): .theyAsked
        case (false, false): .none
        }
    }

    /// The word on the button: "Add friend", "Asked", "Accept", or nothing between friends.
    var action: String? {
        switch self {
        case .friends: nil
        case .asked: "Asked"
        case .theyAsked: "Accept"
        case .none: "Add friend"
        }
    }

    /// Whether tapping does something: asking again does not.
    var canAct: Bool { self == .none || self == .theyAsked }
}

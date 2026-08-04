import Foundation

struct Roll: Codable, Identifiable, Hashable {
    /// Max members per roll. Must match the cap in the `join_roll` RPC (supabase/schema.sql).
    static let memberCap = 50

    let id: UUID
    let name: String
    let inviteCode: String
    let createdBy: UUID
    let createdAt: Date
    var coverPath: String? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case coverPath = "cover_path"
    }

    // The reveal clock starts when the roll is CREATED (not at the first shot), so everyone
    // knows the deadline up front. DEBUG shortens it so the loop is testable.
    #if DEBUG
    static let developDelay: TimeInterval = 2 * 60
    #else
    static let developDelay: TimeInterval = 12 * 3600
    #endif

    /// How long rolls take to develop, phrased for user-facing copy.
    ///
    /// Onboarding used to say "the 12-hour mark" as a string literal, which was simply false in
    /// every DEBUG build and would have gone stale the first time the delay changed. Copy that
    /// states a number the code owns should ask the code for it.
    static var developDelayPhrase: String { developDelayPhrase(for: developDelay) }

    static func developDelayPhrase(for delay: TimeInterval) -> String {
        let minutes = Int((delay / 60).rounded())
        if minutes < 60 { return minutes == 1 ? "1 minute" : "\(minutes) minutes" }
        let hours = Int((delay / 3600).rounded())
        return hours == 1 ? "1 hour" : "\(hours) hours"
    }

    /// When this roll unlocks for everyone.
    var revealAt: Date { createdAt.addingTimeInterval(Self.developDelay) }
    /// True once the reveal has passed, the roll is closed to new shots.
    var isDeveloped: Bool { isDeveloped(now: .now) }

    /// Testable seam for `isDeveloped`: whether the roll has developed as of `now`. The reveal
    /// instant itself counts as developed (`<=`), not just strictly after it.
    func isDeveloped(now: Date) -> Bool { revealAt <= now }
}

struct RollMember: Codable {
    let rollId: UUID
    let userId: UUID
    let joinedAt: Date

    enum CodingKeys: String, CodingKey {
        case rollId = "roll_id"
        case userId = "user_id"
        case joinedAt = "joined_at"
    }
}

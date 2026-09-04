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
    /// The server's fixed reveal instant: `rolls.reveal_at` (NOT NULL, backfilled at
    /// `created_at + 12h` and trigger-filled for any insert that omits it; movable only via
    /// `RollService.setRevealAt`, creator-only, and only before the roll develops). This is now
    /// the single source of truth for when a roll unlocks. Every off-app surface and every local
    /// computation reads THIS, never re-derives `createdAt + developDelay` on its own, so a roll
    /// whose reveal was extended stays consistent everywhere it's shown.
    let revealAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case inviteCode = "invite_code"
        case createdBy = "created_by"
        case createdAt = "created_at"
        case coverPath = "cover_path"
        case revealAt = "reveal_at"
    }

    // The reveal clock starts when the roll is CREATED (not at the first shot), so everyone
    // knows the deadline up front. DEBUG shortens it so the loop is testable. Used only as the
    // FALLBACK formula below (a server that hasn't sent `reveal_at` yet, or the interim local
    // `Roll` built before the server round trip's real row comes back) and for user-facing copy
    // that states the default window; the roll's actual reveal is `revealAt` above.
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

    /// Direct construction: previews, tests, and the interim local `Roll` a caller might build
    /// before a server round trip's real row comes back. `revealAt` defaults to the fallback
    /// formula (`createdAt + developDelay`) when not given, same as a decode with no column.
    init(id: UUID, name: String, inviteCode: String, createdBy: UUID, createdAt: Date,
         coverPath: String? = nil, revealAt: Date? = nil) {
        self.id = id
        self.name = name
        self.inviteCode = inviteCode
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.coverPath = coverPath
        self.revealAt = revealAt ?? createdAt.addingTimeInterval(Self.developDelay)
    }

    /// Decoded by hand so a server that hasn't sent `reveal_at` yet (rollout ordering, or simply
    /// an older cached response) fails soft into the old `created_at + developDelay` formula
    /// instead of failing the whole rolls fetch on one missing column. `createdAt` and the other
    /// fields still decode straight through the ambient decoder's own date/UUID strategies,
    /// exactly as the synthesized initializer they replace.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        inviteCode = try container.decode(String.self, forKey: .inviteCode)
        createdBy = try container.decode(UUID.self, forKey: .createdBy)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        coverPath = try container.decodeIfPresent(String.self, forKey: .coverPath)
        revealAt = try container.decodeIfPresent(Date.self, forKey: .revealAt)
            ?? createdAt.addingTimeInterval(Self.developDelay)
    }

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

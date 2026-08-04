import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class RollService {
    var rolls: [Roll] = []
    var memberCounts: [UUID: Int] = [:]
    var coverPaths: [UUID: String] = [:]   // roll id → cover thumbnail path (thumb_path preferred)
    /// Rolls whose reveal (created_at + delay) has passed, closed to new shots.
    var closedRollIds: Set<UUID> { Set(rolls.filter(\.isDeveloped).map(\.id)) }
    var isLoading = false
    var error: String?

    /// Drops everything cached for the previous account. Called on `flimAccountDidChange`.
    func resetForAccountChange() {
        rolls = []
        memberCounts = [:]
        coverPaths = [:]
        error = nil
        isLoading = false
    }

    // MARK: - Create

    func createRoll(name: String, createdBy: UUID) async throws -> Roll {
        struct InsertRoll: Encodable {
            let name: String
            let inviteCode: String
            let createdBy: UUID
            enum CodingKeys: String, CodingKey {
                case name
                case inviteCode = "invite_code"
                case createdBy = "created_by"
            }
        }

        let payload = InsertRoll(
            name: name,
            inviteCode: AuthService.randomCode(),
            createdBy: createdBy
        )

        let roll: Roll = try await supabase
            .from("rolls")
            .insert(payload)
            .select()
            .single()
            .execute()
            .value

        try await joinRollDirect(rollId: roll.id, userId: createdBy)
        rolls.insert(roll, at: 0)
        return roll
    }

    // MARK: - Join by invite code

    func joinRoll(inviteCode: String, userId: UUID) async throws -> Roll {
        struct JoinParams: Encodable { let p_code: String }

        do {
            // SECURITY DEFINER RPC does the lookup, 10-member cap, and membership
            // insert atomically, a not-yet-member can't read the rolls table directly.
            let roll: Roll = try await supabase
                .rpc("join_roll", params: JoinParams(p_code: inviteCode))
                .execute()
                .value

            if !rolls.contains(where: { $0.id == roll.id }) {
                rolls.append(roll)
            }
            return roll
        } catch {
            // Map the function's RAISE EXCEPTION messages to friendly errors.
            if let mapped = Self.mapJoinRollError("\(error)") { throw mapped }
            throw error
        }
    }

    /// Maps the `join_roll` RPC's `RAISE EXCEPTION` message text to a friendly `RollError`,
    /// or `nil` if `description` doesn't match a recognized failure (the caller then rethrows
    /// the original error as-is).
    static func mapJoinRollError(_ description: String) -> RollError? {
        let desc = description.lowercased()
        if desc.contains("roll_full") { return .full }
        if desc.contains("roll_not_found") { return .notFound }
        return nil
    }

    // MARK: - Fetch user rolls

    func fetchRolls(for userId: UUID) async throws {
        let epoch = AccountEpoch.current
        isLoading = true
        defer { isLoading = false }

        let memberRows: [RollMember] = try await supabase
            .from("roll_members")
            .select()
            .eq("user_id", value: userId.uuidString)
            .execute()
            .value

        let rollIds = memberRows.map(\.rollId.uuidString)
        guard !rollIds.isEmpty else { rolls = []; memberCounts = [:]; return }

        // Discard a response that outlived its account. The request went out under whichever
        // session was live when it started and returns THAT account's data, correctly; writing it
        // here after a switch is what silently undoes the cache reset. See AccountEpoch.
        guard AccountEpoch.isCurrent(epoch) else { return }
        rolls = try await supabase
            .from("rolls")
            .select()
            .in("id", values: rollIds)
            .order("created_at", ascending: false)
            .execute()
            .value

        await loadMemberCounts(rollIds: rollIds)
        await loadCovers(rollIds: rollIds)
    }

    /// Latest developed photo per roll → the path used for the roll cover thumbnail.
    /// Prefers `thumb_path` (the ~120px rendition) over `storage_path` (the full ~2048px stored
    /// image): the cover renders in a 54pt box, so downloading and decoding the full image for it
    /// is pure waste on a tab users hit constantly. Falls back to storage_path only when a shot
    /// has no thumb rendition. "Developed" = develops_at has passed (independent of the
    /// is_developed flag sync).
    private func loadCovers(rollIds: [String]) async {
        struct CoverRow: Decodable { let roll_id: UUID; let storage_path: String; let thumb_path: String? }
        let nowISO = ISO8601DateFormatter().string(from: Date.now)
        let rows: [CoverRow] = (try? await supabase
            .from("photos")
            .select("roll_id,storage_path,thumb_path")
            .in("roll_id", values: rollIds)
            .eq("hidden", value: false)
            .lte("develops_at", value: nowISO)
            .order("taken_at", ascending: false)
            .execute()
            .value) ?? []

        // storage_path → thumb_path, so a creator-chosen cover (stored as a storage_path) can
        // still resolve to its thumbnail rendition rather than downloading the full image.
        var thumbForStorage: [String: String] = [:]
        for row in rows { thumbForStorage[row.storage_path] = row.thumb_path }

        var covers: [UUID: String] = [:]
        for row in rows where covers[row.roll_id] == nil {
            covers[row.roll_id] = row.thumb_path ?? row.storage_path   // first per roll = latest
        }
        // A creator-chosen cover overrides the latest-developed default, resolve it to the same
        // thumbnail rendition when we have it, else the full path as a last resort.
        for roll in rolls {
            guard let chosen = roll.coverPath else { continue }
            covers[roll.id] = thumbForStorage[chosen] ?? chosen
        }
        coverPaths = covers
    }

    /// Populates `memberCounts` for the given rolls in a single query. RLS lets a member
    /// read every membership row of a roll they belong to, so the grouped count is exact.
    private func loadMemberCounts(rollIds: [String]) async {
        struct CountRow: Decodable { let roll_id: UUID }
        let rows: [CountRow] = (try? await supabase
            .from("roll_members")
            .select("roll_id")
            .in("roll_id", values: rollIds)
            .execute()
            .value) ?? []

        var counts: [UUID: Int] = [:]
        for row in rows { counts[row.roll_id, default: 0] += 1 }
        memberCounts = counts
    }

    // MARK: - Reveal presence (async "communal" signal)

    /// The group's progress through a roll's reveal: how many members have opened it, and how
    /// many there are. Async, no realtime, the roll feels shared even though everyone arrives at
    /// their own time.
    struct RevealPresence { let position: Int; let total: Int }

    /// Records that the current user opened this roll's reveal (idempotent, a duplicate insert on
    /// the PK just no-ops), then returns their position and the member total. `position` counts
    /// the current user, so the very first opener sees position 1.
    func recordRevealView(rollId: UUID, userId: UUID) async -> RevealPresence? {
        struct V: Encodable { let roll_id: UUID; let user_id: UUID }
        // A repeat open throws a 23505 on the PK; harmless, the view's already recorded.
        _ = try? await supabase.from("roll_reveal_views")
            .insert(V(roll_id: rollId, user_id: userId)).execute()

        let viewers = (try? await supabase.from("roll_reveal_views")
            .select("user_id", head: true, count: .exact)
            .eq("roll_id", value: rollId.uuidString)
            .execute().count) ?? 0
        let members = (try? await supabase.from("roll_members")
            .select("user_id", head: true, count: .exact)
            .eq("roll_id", value: rollId.uuidString)
            .execute().count) ?? 0
        guard viewers > 0 else { return nil }
        // total can't sensibly be below viewers (e.g. a just-left member); clamp so copy reads right.
        return RevealPresence(position: viewers, total: max(members, viewers))
    }

    // MARK: - Fetch members of a roll

    func fetchMembers(for rollId: UUID) async throws -> [AppUser] {
        let memberRows: [RollMember] = try await supabase
            .from("roll_members")
            .select()
            .eq("roll_id", value: rollId.uuidString)
            .execute()
            .value

        let userIds = memberRows.map(\.userId.uuidString)
        guard !userIds.isEmpty else { return [] }

        // `profiles` (not `users`), the safe-columns view every other cross-user read in this
        // app uses post column-grant hardening (see FeedService). Roll rosters only need
        // username/avatar/etc, never email/invite_code.
        return try await supabase
            .from("profiles")
            .select()
            .in("id", values: userIds)
            .execute()
            .value
    }

    /// Renames a roll (creator only, enforced by RLS) and updates the local copy.
    func renameRoll(rollId: UUID, name: String) async throws {
        struct Update: Encodable { let name: String }
        try await supabase
            .from("rolls")
            .update(Update(name: name))
            .eq("id", value: rollId.uuidString)
            .execute()
        if let i = rolls.firstIndex(where: { $0.id == rollId }) {
            let r = rolls[i]
            rolls[i] = Roll(id: r.id, name: name, inviteCode: r.inviteCode,
                            createdBy: r.createdBy, createdAt: r.createdAt, coverPath: r.coverPath)
        }
    }

    /// The creator picks a specific photo as the roll's cover (RLS: creator-only update).
    func setRollCover(rollId: UUID, path: String) async {
        struct U: Encodable { let cover_path: String }
        _ = try? await supabase.from("rolls").update(U(cover_path: path))
            .eq("id", value: rollId.uuidString).execute()
        coverPaths[rollId] = path
        if let i = rolls.firstIndex(where: { $0.id == rollId }) {
            let r = rolls[i]
            rolls[i] = Roll(id: r.id, name: r.name, inviteCode: r.inviteCode,
                            createdBy: r.createdBy, createdAt: r.createdAt, coverPath: path)
        }
    }

    /// Deletes a roll (creator only, enforced by RLS) and removes it locally.
    func deleteRoll(rollId: UUID) async throws {
        try await supabase
            .from("rolls")
            .delete()
            .eq("id", value: rollId.uuidString)
            .execute()
        rolls.removeAll { $0.id == rollId }
        memberCounts[rollId] = nil
        coverPaths[rollId] = nil
    }

    /// The current user leaves a roll, drops their membership and removes it locally.
    func leaveRoll(rollId: UUID, userId: UUID) async throws {
        try await removeMember(rollId: rollId, userId: userId)
        rolls.removeAll { $0.id == rollId }
        memberCounts[rollId] = nil
        coverPaths[rollId] = nil
    }

    /// Removes a member from a roll. RLS allows this only for the member themselves
    /// (leaving) or the roll's creator (moderation).
    func removeMember(rollId: UUID, userId: UUID) async throws {
        try await supabase
            .from("roll_members")
            .delete()
            .eq("roll_id", value: rollId.uuidString)
            .eq("user_id", value: userId.uuidString)
            .execute()
    }

    // MARK: - Helpers

    private func joinRollDirect(rollId: UUID, userId: UUID) async throws {
        struct JoinPayload: Encodable {
            let rollId: UUID
            let userId: UUID
            enum CodingKeys: String, CodingKey {
                case rollId = "roll_id"
                case userId = "user_id"
            }
        }
        try await supabase
            .from("roll_members")
            .upsert(JoinPayload(rollId: rollId, userId: userId))
            .execute()
    }
}

enum RollError: LocalizedError {
    case notFound, full

    var errorDescription: String? {
        switch self {
        case .notFound: "No roll found with that invite code."
        case .full: "This roll is full (max \(Roll.memberCap) members)."
        }
    }
}

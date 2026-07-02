import Foundation
import Observation
import Supabase

@Observable
final class RollService {
    var rolls: [Roll] = []
    var memberCounts: [UUID: Int] = [:]
    var coverPaths: [UUID: String] = [:]   // roll id → latest developed photo's storage path
    var closedRollIds: Set<UUID> = []      // rolls whose reveal has passed — no more shots
    var isLoading = false
    var error: String?

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
            // insert atomically — a not-yet-member can't read the rolls table directly.
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
            let desc = "\(error)".lowercased()
            if desc.contains("roll_full") { throw RollError.full }
            if desc.contains("roll_not_found") { throw RollError.notFound }
            throw error
        }
    }

    // MARK: - Fetch user rolls

    func fetchRolls(for userId: UUID) async throws {
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

    /// Latest developed photo per roll → its storage path, for the roll cover thumbnail.
    /// "Developed" = develops_at has passed (independent of the is_developed flag sync).
    private func loadCovers(rollIds: [String]) async {
        struct CoverRow: Decodable { let roll_id: UUID; let storage_path: String }
        let nowISO = ISO8601DateFormatter().string(from: Date.now)
        let rows: [CoverRow] = (try? await supabase
            .from("photos")
            .select("roll_id,storage_path")
            .in("roll_id", values: rollIds)
            .lte("develops_at", value: nowISO)
            .order("taken_at", ascending: false)
            .execute()
            .value) ?? []

        var covers: [UUID: String] = [:]
        for row in rows where covers[row.roll_id] == nil {
            covers[row.roll_id] = row.storage_path   // first per roll = latest (desc order)
        }
        // Any roll with a developed photo has passed its reveal → it's closed to new shots.
        closedRollIds = Set(rows.map(\.roll_id))
        // A creator-chosen cover overrides the latest-developed default.
        for roll in rolls where roll.coverPath != nil {
            covers[roll.id] = roll.coverPath
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

        return try await supabase
            .from("users")
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

    /// The current user leaves a roll — drops their membership and removes it locally.
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

import Foundation
import Observation
import Supabase

@Observable
final class RollService {
    var rolls: [Roll] = []
    var memberCounts: [UUID: Int] = [:]
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

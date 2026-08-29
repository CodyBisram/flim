import Foundation
import Observation
import Supabase

@MainActor
@Observable
final class RollService {
    var rolls: [Roll] = []
    var memberCounts: [UUID: Int] = [:]
    var coverPaths: [UUID: String] = [:]   // roll id → cover thumbnail path (thumb_path preferred)
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
        // Two round trips before anything is written, and the write INSERTS into the shared list
        // rather than updating a row by id, so a stale completion splices one account's roll into
        // another account's Rolls tab. That is content leakage, not a cosmetic staleness, which is
        // why this is guarded while a rename-by-id is not.
        let epoch = AccountEpoch.current
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
        // The roll itself is still returned: it genuinely exists server-side and the caller may
        // want to navigate to it. Only the shared list is left alone.
        guard AccountEpoch.isCurrent(epoch) else { return roll }
        rolls.insert(roll, at: 0)
        // A brand new roll is developing from this second, and the widget and shutter are the two
        // surfaces most likely to be looked at before the app is opened again.
        WidgetSync.refresh()
        return roll
    }

    // MARK: - Join by invite code

    func joinRoll(inviteCode: String, userId: UUID) async throws -> Roll {
        let epoch = AccountEpoch.current
        struct JoinParams: Encodable { let p_code: String }

        do {
            // SECURITY DEFINER RPC does the lookup, 10-member cap, and membership
            // insert atomically, a not-yet-member can't read the rolls table directly.
            let roll: Roll = try await supabase
                .rpc("join_roll", params: JoinParams(p_code: inviteCode))
                .execute()
                .value

            guard AccountEpoch.isCurrent(epoch) else { return roll }
            if !rolls.contains(where: { $0.id == roll.id }) {
                rolls.append(roll)
            }
            // Same reason as createRoll: joining is the other way a countdown starts existing.
            WidgetSync.refresh()
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

        // Every one of these guards sits immediately before a WRITE, and there is one per write,
        // because this function makes four separate network round trips. A single check near the
        // top would only cover the first, which is precisely the mistake made here first time
        // round: the guard was placed before the `rolls` query rather than before the assignment
        // that its own second round trip completes. The rule is "guard the assignment", and with
        // several awaits in a row that means several guards, not one.
        guard AccountEpoch.isCurrent(epoch) else { return }

        let rollIds = memberRows.map(\.rollId.uuidString)
        guard !rollIds.isEmpty else { rolls = []; memberCounts = [:]; return }

        let fetched: [Roll] = try await supabase
            .from("rolls")
            .select()
            .in("id", values: rollIds)
            .order("created_at", ascending: false)
            .execute()
            .value
        guard AccountEpoch.isCurrent(epoch) else { return }
        rolls = fetched

        // Two independent queries, so they run together rather than one after the other. Covers
        // are what the archive tiles are waiting on, and they were queued behind a member-count
        // query that has nothing to do with them: a full round trip of dead time before a single
        // cover could even begin to resolve. Both still guard their own writes on `epoch`.
        async let counts: Void = loadMemberCounts(rollIds: rollIds, epoch: epoch)
        async let covers: Void = loadCovers(rollIds: rollIds, epoch: epoch)
        _ = await (counts, covers)
    }

    /// Latest developed photo per roll → the path used for the roll cover thumbnail.
    /// Prefers `thumb_path` (the ~120px rendition) over `storage_path` (the full ~2048px stored
    /// image): the cover renders in a 54pt box, so downloading and decoding the full image for it
    /// is pure waste on a tab users hit constantly. Falls back to storage_path only when a shot
    /// has no thumb rendition. "Developed" = develops_at has passed (independent of the
    /// is_developed flag sync).
    /// `epoch` is the account generation captured by the caller before its first await. Each
    /// helper re-checks it immediately before writing, because each makes its own round trip.
    private func loadCovers(rollIds: [String], epoch: Int) async {
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
        guard AccountEpoch.isCurrent(epoch) else { return }
        coverPaths = covers
    }

    /// Populates `memberCounts` for the given rolls in a single query. RLS lets a member
    /// read every membership row of a roll they belong to, so the grouped count is exact.
    private func loadMemberCounts(rollIds: [String], epoch: Int) async {
        struct CountRow: Decodable { let roll_id: UUID }
        let rows: [CountRow] = (try? await supabase
            .from("roll_members")
            .select("roll_id")
            .in("roll_id", values: rollIds)
            .execute()
            .value) ?? []

        var counts: [UUID: Int] = [:]
        for row in rows { counts[row.roll_id, default: 0] += 1 }
        guard AccountEpoch.isCurrent(epoch) else { return }
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

    /// Roll members as plain ids, ordered by when they joined. Feeds `TagPhotoSheet`'s quick-tag
    /// row, which only needs ids (resolved to `UserProfile` via `FeedService.fetchProfiles`), not
    /// the full `AppUser` roster `fetchMembers` returns.
    func fetchMemberIds(for rollId: UUID) async throws -> [UUID] {
        struct Row: Decodable { let user_id: UUID }
        let rows: [Row] = try await supabase
            .from("roll_members")
            .select("user_id")
            .eq("roll_id", value: rollId.uuidString)
            .order("joined_at", ascending: true)
            .execute()
            .value
        return rows.map(\.user_id)
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
        forget(rollId)
    }

    /// The current user leaves a roll, drops their membership and removes it locally.
    func leaveRoll(rollId: UUID, userId: UUID) async throws {
        try await removeMember(rollId: rollId, userId: userId)
        forget(rollId)
    }

    /// Drops every trace of a roll this account no longer has, including the ones OUTSIDE the app.
    ///
    /// The off-app surfaces are the part that used to be missed. A roll's lock-screen card and
    /// its countdown on the home-screen tile and the shutter all outlive the roll itself unless
    /// something ends them: the widget snapshot is only rewritten on app open, a capture, or a
    /// post, and none of those is "you deleted a roll". So a deleted roll kept counting down on
    /// three surfaces at once until the app happened to be relaunched.
    private func forget(_ rollId: UUID) {
        rolls.removeAll { $0.id == rollId }
        memberCounts[rollId] = nil
        coverPaths[rollId] = nil
        RollLiveActivity.end(rollId: rollId)
        WidgetSync.refresh()
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

/// Destinations for the camera's "Send to…" picker: a partition of `rolls`, not a re-sort.
/// `rolls` arrives ordered `created_at DESC`, and that relative order is preserved within each
/// group, because a roll's usability (still open vs. developed) has nothing to do with when it
/// was created, and re-sorting by date would bury the one tappable roll under stale ones.
///
/// Returns still-open rolls first, then rolls that developed within `grace` of `now`. A roll
/// that developed longer than `grace` ago is omitted entirely.
///
/// The recently-developed group is not selectable, `Roll.isDeveloped` is permanent, so it is
/// never tappable again. It exists only so a roll someone was actively shooting into doesn't
/// silently disappear from the picker the instant it closes. Past `grace`, that information
/// stops being useful and becomes clutter, so those rows drop off too.
func rollPickerDestinations(from rolls: [Roll], now: Date, grace: TimeInterval = 24 * 60 * 60) -> [Roll] {
    let open = rolls.filter { !$0.isDeveloped(now: now) }
    let recentlyDeveloped = rolls.filter { roll in
        roll.isDeveloped(now: now) && now.timeIntervalSince(roll.revealAt) < grace
    }
    return open + recentlyDeveloped
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

import Foundation
import Observation
import Supabase

/// The Chapters shelf and recap's data: `profile_chapters` (the shelf's cards) and
/// `chapter_photos` (one month's photos, for curation and playback), keyed per profile id, never
/// globally, since the shelf is shown on every profile, not just the signed-in account's own.
///
/// FAILS SOFT on both RPCs, the same discipline as `AuthService.ownInviteQuota`: the server may
/// not have run the migration that adds `profile_chapters`/`chapter_photos` yet, and a client
/// that ships first must not crash or blank the profile over it. A failed or not-yet-deployed
/// call leaves `chaptersByProfile[profileId]` absent, which `UserPageView` reads exactly like "no
/// chapters yet": the shelf simply does not render, nothing else about the page is affected.
@MainActor
@Observable
final class ChapterService {
    /// Newest month first, per profile.
    var chaptersByProfile: [UUID: [ChapterSummary]] = [:]
    /// A month's photos, `taken_at` ascending, keyed by profile + month so two different
    /// people's Augusts, or a repeat visit to the same one, never collide.
    var photosByChapter: [ChapterKey: [ChapterPhoto]] = [:]
    /// A month's `chapter_stats`, keyed the same way as `photosByChapter`. Visibility is already
    /// resolved server-side by the time these rows arrive: the profile owner always gets every
    /// key, anyone else only the keys `chapter_public_stats` allows. That resolution is done
    /// AS the signed-in caller, though, so every write into this cache is still guarded by
    /// `AccountEpoch`, the same as `RollService.fetchRolls`: a response that lands after an
    /// account switch is internally consistent, it is just consistent with the account that is no
    /// longer signed in, and writing it now would hand the next account a cache hit on rows they
    /// were never authorized to see.
    var statsByChapter: [ChapterKey: ChapterStats] = [:]
    var isLoadingChapters: Set<UUID> = []

    struct ChapterKey: Hashable {
        let profileId: UUID
        let monthStart: Date
    }

    // Shared by every presentation of a box, so closing/reopening cannot bypass the save lock.
    private var boxSaves: [ChapterKey: UUID] = [:]

    func isSavingBox(_ key: ChapterKey) -> Bool { boxSaves[key] != nil }

    func beginBoxSave(_ key: ChapterKey) -> UUID? {
        guard boxSaves[key] == nil else { return nil }
        let token = UUID()
        boxSaves[key] = token
        return token
    }

    func finishBoxSave(_ key: ChapterKey, token: UUID) {
        guard boxSaves[key] == token else { return }
        boxSaves[key] = nil
    }

    #if DEBUG
    /// Set by `installDemoFixture`, so `fetchChapters`/`photos(for:monthStart:)` stop calling the
    /// (not-yet-real) RPCs and leave the fixture's data alone rather than overwriting it with an
    /// empty, failed-soft result on the very next `UserPageView.load()`.
    private var usesDemoFixture = false
    #endif

    func resetForAccountChange() {
        boxSaves = [:]
        chaptersByProfile = [:]
        photosByChapter = [:]
        statsByChapter = [:]
        isLoadingChapters = []
        putAwayPostIds = []
        boxCoversByProfile = [:]
        #if DEBUG
        usesDemoFixture = false
        #endif
    }

    /// Fetches (or re-fetches) the shelf for `profileId`. Safe to call every time the profile
    /// page loads, same as `UserPageView.load()`'s other per-visit reads: cheap and idempotent.
    /// The month in progress is dropped here (`ChapterSummary.completedMonths`): a chapter is a
    /// month that has ended, so the shelf gains a cover on the first of each month, not before.
    func fetchChapters(for profileId: UUID) async {
        #if DEBUG
        guard !usesDemoFixture else { return }
        #endif
        let epoch = AccountEpoch.current
        isLoadingChapters.insert(profileId)
        defer { isLoadingChapters.remove(profileId) }
        struct Params: Encodable { let p_profile_id: UUID; let p_timezone: String }
        let rows: [ChapterSummary] = (try? await supabase
            .rpc("profile_chapters", params: Params(p_profile_id: profileId, p_timezone: Self.timezone))
            .execute()
            .value) ?? []
        guard AccountEpoch.isCurrent(epoch) else { return }
        chaptersByProfile[profileId] = ChapterSummary.completedMonths(rows)
    }

    // MARK: - Month boxes (1.7, Blend 4, 12b)
    //
    // 1.7 only. Putting a shot away is `posts.put_away`, enforced on the server by
    // `post_visible_to` (every month, feed and page read goes through it), so a put-away shot
    // stays on your page and leaves everyone else's. A box's chosen cover is a `month_boxes` row;
    // `month_box_covers` hands back the ones the caller may see. Both are additive server changes
    // (supabase/migrations-v2/2026-10-30*), on FLIM Dev now and on production before 1.7 ships.

    /// Your own posts put away, as last read or written here.
    var putAwayPostIds: Set<UUID> = []
    /// Each profile's chosen box covers the caller may see, by month ("yyyy-MM-dd") to the
    /// cover's display path.
    var boxCoversByProfile: [UUID: [String: String]] = [:]

    /// The key a box's month is stored under, the same date string the month RPCs take.
    static func monthKey(_ monthStart: Date) -> String { dateOnly.string(from: monthStart) }

    /// Reads which of these posts of yours are put away. Leaves the set as it was on a failure.
    /// Whether it read: false on a failed read, which keeps what it had.
    @discardableResult
    func loadPutAway(postIds: [UUID]) async -> Bool {
        guard AppInfo.is17 else { return false }
        guard !postIds.isEmpty else { return true }
        #if DEBUG
        if usesDemoFixture { return true }
        #endif
        let epoch = AccountEpoch.current
        struct Row: Decodable { let id: UUID }
        guard let rows: [Row] = try? await supabase.from("posts").select("id")
            .in("id", values: postIds.map(\.uuidString)).eq("put_away", value: true)
            .execute().value,
              AccountEpoch.isCurrent(epoch), !Task.isCancelled else { return false }
        putAwayPostIds.subtract(postIds)
        putAwayPostIds.formUnion(rows.map(\.id))
        return true
    }

    /// Puts one of your posts away, or brings it back. Updates the set only once it landed.
    func setPutAway(_ putAway: Bool, postId: UUID) async -> Bool {
        guard AppInfo.is17 else { return false }
        let epoch = AccountEpoch.current
        struct Update: Encodable { let put_away: Bool }
        do {
            try await supabase.from("posts").update(Update(put_away: putAway), returning: .minimal)
                .eq("id", value: postId.uuidString).execute()
            guard AccountEpoch.isCurrent(epoch) else { return false }
            if putAway { putAwayPostIds.insert(postId) } else { putAwayPostIds.remove(postId) }
            return true
        } catch {
            return false
        }
    }

    /// Makes a shot your box's cover. `coverPath` is what the shelf and box draw for it.
    func setMonthCover(photoId: UUID, coverPath: String, userId: UUID, monthStart: Date) async -> Bool {
        guard AppInfo.is17 else { return false }
        let epoch = AccountEpoch.current
        struct Row: Encodable { let user_id: UUID; let month_start: String; let cover_photo_id: UUID }
        do {
            try await supabase.from("month_boxes")
                .upsert(Row(user_id: userId, month_start: Self.monthKey(monthStart), cover_photo_id: photoId),
                        returning: .minimal)
                .execute()
            guard AccountEpoch.isCurrent(epoch) else { return false }
            boxCoversByProfile[userId, default: [:]][Self.monthKey(monthStart)] = coverPath
            return true
        } catch {
            return false
        }
    }

    /// Your box's chosen cover for a month, by photo; nil when there is none or the read failed.
    /// The cover you chose for a month: `.some(nil)` when you chose none, nil when the read failed.
    func monthCoverPhotoId(userId: UUID, monthStart: Date) async -> UUID?? {
        guard AppInfo.is17 else { return nil }
        #if DEBUG
        if usesDemoFixture { return .some(nil) }
        #endif
        struct Row: Decodable { let cover_photo_id: UUID? }
        guard let rows: [Row] = try? await supabase.from("month_boxes").select("cover_photo_id")
            .eq("user_id", value: userId.uuidString).eq("month_start", value: Self.monthKey(monthStart))
            .limit(1).execute().value else { return nil }
        return .some(rows.first?.cover_photo_id ?? nil)
    }

    /// Reads the chosen covers on someone's shelf (yours included). Keeps what it had on failure.
    func loadBoxCovers(for profileId: UUID) async {
        guard AppInfo.is17 else { return }
        #if DEBUG
        guard !usesDemoFixture else { return }
        #endif
        let epoch = AccountEpoch.current
        struct Row: Decodable { let month_start: String; let cover_path: String? }
        guard let rows: [Row] = try? await supabase.rpc("month_box_covers", params: ["p_user": profileId])
            .execute().value,
              AccountEpoch.isCurrent(epoch) else { return }
        boxCoversByProfile[profileId] = Dictionary(
            rows.compactMap { row in row.cover_path.map { (row.month_start, $0) } },
            uniquingKeysWith: { first, _ in first })
    }

    /// A box's cover path: the one chosen for it, else the month's own first cover.
    func coverPath(for chapter: ChapterSummary, profileId: UUID) -> String? {
        boxCoversByProfile[profileId]?[Self.monthKey(chapter.monthStart)] ?? chapter.coverPaths.first
    }

    /// A month's photos, cached after the first fetch: opening the same month's recap twice in a
    /// session (e.g. backing out and reopening) does not refetch or redo curation.
    func photos(for profileId: UUID, monthStart: Date) async -> [ChapterPhoto] {
        let key = ChapterKey(profileId: profileId, monthStart: monthStart)
        if let cached = photosByChapter[key] { return cached }
        #if DEBUG
        guard !usesDemoFixture else { return [] }
        #endif
        let epoch = AccountEpoch.current
        struct Params: Encodable { let p_profile_id: UUID; let p_month_start: String; let p_timezone: String }
        let rows: [ChapterPhoto] = (try? await supabase
            .rpc("chapter_photos", params: Params(p_profile_id: profileId,
                                                   p_month_start: Self.dateOnly.string(from: monthStart),
                                                   p_timezone: Self.timezone))
            .execute()
            .value) ?? []
        guard AccountEpoch.isCurrent(epoch) else { return rows }
        photosByChapter[key] = rows
        return rows
    }

    /// A month's `chapter_stats`, cached after the first fetch, same discipline as
    /// `photos(for:monthStart:)`. Fails soft to an empty map on any error: the closing card
    /// simply has nothing to show, exactly as if the RPC had genuinely returned no rows.
    func stats(for profileId: UUID, monthStart: Date) async -> ChapterStats {
        let key = ChapterKey(profileId: profileId, monthStart: monthStart)
        if let cached = statsByChapter[key] { return cached }
        #if DEBUG
        guard !usesDemoFixture else { return [:] }
        #endif
        let epoch = AccountEpoch.current
        struct Params: Encodable { let p_profile_id: UUID; let p_month_start: String; let p_timezone: String }
        let rows: [ChapterStatRow] = (try? await supabase
            .rpc("chapter_stats", params: Params(p_profile_id: profileId,
                                                  p_month_start: Self.dateOnly.string(from: monthStart),
                                                  p_timezone: Self.timezone))
            .execute()
            .value) ?? []
        let map = rows.keyedByStat()
        guard AccountEpoch.isCurrent(epoch) else { return map }
        statsByChapter[key] = map
        return map
    }

    /// The signed-in account's own `chapter_public_stats`: which stat keys everyone else sees on
    /// their chapters. `nil` on any failure (column not deployed yet, offline); `[]` means
    /// "everything public", the column's own default for every account. Two paths, in order:
    /// `get_own_profile()` (a `SELECT * FROM users WHERE id = auth.uid()` RPC other services
    /// already rely on for the caller's own row) and, only if that somehow doesn't carry the
    /// column, a direct select gated by the same column-level grant the server exposes it under.
    func fetchOwnPublicStats() async -> [String]? {
        struct ProfileRow: Decodable {
            let chapterPublicStats: [String]?
            enum CodingKeys: String, CodingKey { case chapterPublicStats = "chapter_public_stats" }
        }
        if let row: ProfileRow = try? await supabase.rpc("get_own_profile").single().execute().value {
            return row.chapterPublicStats ?? []
        }
        struct SelectRow: Decodable {
            let chapterPublicStats: [String]?
            enum CodingKeys: String, CodingKey { case chapterPublicStats = "chapter_public_stats" }
        }
        if let rows: [SelectRow] = try? await supabase
            .from("users")
            .select("chapter_public_stats")
            .execute()
            .value,
           let first = rows.first {
            return first.chapterPublicStats ?? []
        }
        return nil
    }

    /// Saves the caller's own `chapter_public_stats` and returns what the server actually stored,
    /// same round-trip shape as `AuthService.setDisplayedBadges`. Throws rather than failing
    /// soft: a settings save has somewhere to report the failure to and something to retry, unlike
    /// a background read.
    func setOwnPublicStats(_ keys: [String]) async throws -> [String] {
        struct Params: Encodable { let p_keys: [String] }
        let saved: [String] = try await supabase
            .rpc("set_chapter_public_stats", params: Params(p_keys: keys))
            .execute()
            .value
        return saved
    }

    /// The zone a month is bucketed in, sent with every chapter RPC as `p_timezone`. The
    /// phone's own, read at call time: Chapters used a fixed Eastern shift server-side until
    /// 2026-09-22, which put a 2am shot on the first of the month in the wrong chapter and
    /// counted the afternoon as "night" for anyone eight hours from New York. The Darkroom's
    /// month functions have taken the same parameter since they shipped, so the two screens
    /// that describe "your month" now agree on where it begins. Unknown to the server, or
    /// absent (older builds), it falls back to America/New_York, today's answer.
    private static var timezone: String { TimeZone.current.identifier }

    private static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

#if DEBUG
extension ChapterService {
    /// Debug-only: builds a plausible Chapters shelf (a live current month plus a few closed
    /// ones) from photos already uploaded to Storage by `PhotoService.seedDemoPhotos`, so the
    /// shelf and the recap have real, loadable bytes to show before `profile_chapters` and
    /// `chapter_photos` exist server-side. Reuses the same six demo images across every synthetic
    /// month rather than uploading more: this is a layout fixture, not a data fixture. Never
    /// compiled for release.
    func installDemoFixture(profileId: UUID, from seedPhotos: [Photo]) {
        guard !seedPhotos.isEmpty else { return }
        usesDemoFixture = true
        let calendar = Calendar.current
        let now = Date.now

        // Current month first (the live, growing one), then a few closed months further back.
        let monthsBack = [0, 1, 2, 4]
        var summaries: [ChapterSummary] = []
        var photosByMonth: [ChapterKey: [ChapterPhoto]] = [:]

        for (index, back) in monthsBack.enumerated() {
            guard let monthDate = calendar.date(byAdding: .month, value: -back, to: now),
                  let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate))
            else { continue }

            let chapterPhotos: [ChapterPhoto] = seedPhotos.enumerated().map { i, photo in
                let takenAt = min(monthStart.addingTimeInterval(TimeInterval(i) * 6 * 3600), now)
                return ChapterPhoto(id: UUID(), takenAt: takenAt, thumbPath: photo.thumbPath,
                                     feedPath: photo.feedPath, storagePath: photo.storagePath,
                                     rollId: back == 0 ? photo.rollId : nil,
                                     rollName: back == 0 && photo.rollId != nil ? "Demo roll" : nil,
                                     // Every real month photo is a post; the box's put-away (12b)
                                     // works on posts, so the demo's need one too.
                                     postId: UUID())
            }.sorted { $0.takenAt < $1.takenAt }

            let rollCount = chapterPhotos.contains { $0.rollId != nil } ? 1 : 0
            let shotCount = chapterPhotos.count + index * 6   // varied counts across the shelf
            let covers = Array(seedPhotos.prefix(4)).map(\.displayPath)

            summaries.append(ChapterSummary(
                monthStart: monthStart, shotCount: shotCount, rollCount: rollCount,
                coverPaths: covers,
                firstShotAt: chapterPhotos.first?.takenAt ?? monthStart,
                lastShotAt: chapterPhotos.last?.takenAt ?? monthStart))
            photosByMonth[ChapterKey(profileId: profileId, monthStart: monthStart)] = chapterPhotos
        }

        chaptersByProfile[profileId] = ChapterSummary.completedMonths(summaries)
        for (key, chapterPhotos) in photosByMonth { photosByChapter[key] = chapterPhotos }
    }

    /// For a harness that builds its own synthetic `ChapterSummary`/`ChapterPhoto` fixtures
    /// directly (see `ChapterPreviewDemoHost`) rather than deriving them from real uploaded
    /// photos: marks this instance fixture-backed so `fetchChapters`/`photos(for:monthStart:)`
    /// never overwrite the seeded dictionaries with a failed-soft, empty RPC result.
    func markUsesDemoFixture() { usesDemoFixture = true }
}
#endif

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
    /// key, anyone else only the keys `chapter_public_stats` allows, so this cache never needs to
    /// know who's asking.
    var statsByChapter: [ChapterKey: ChapterStats] = [:]
    var isLoadingChapters: Set<UUID> = []

    struct ChapterKey: Hashable {
        let profileId: UUID
        let monthStart: Date
    }

    #if DEBUG
    /// Set by `installDemoFixture`, so `fetchChapters`/`photos(for:monthStart:)` stop calling the
    /// (not-yet-real) RPCs and leave the fixture's data alone rather than overwriting it with an
    /// empty, failed-soft result on the very next `UserPageView.load()`.
    private var usesDemoFixture = false
    #endif

    func resetForAccountChange() {
        chaptersByProfile = [:]
        photosByChapter = [:]
        statsByChapter = [:]
        isLoadingChapters = []
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
        isLoadingChapters.insert(profileId)
        defer { isLoadingChapters.remove(profileId) }
        struct Params: Encodable { let p_profile_id: UUID }
        let rows: [ChapterSummary] = (try? await supabase
            .rpc("profile_chapters", params: Params(p_profile_id: profileId))
            .execute()
            .value) ?? []
        chaptersByProfile[profileId] = ChapterSummary.completedMonths(rows)
    }

    /// A month's photos, cached after the first fetch: opening the same month's recap twice in a
    /// session (e.g. backing out and reopening) does not refetch or redo curation.
    func photos(for profileId: UUID, monthStart: Date) async -> [ChapterPhoto] {
        let key = ChapterKey(profileId: profileId, monthStart: monthStart)
        if let cached = photosByChapter[key] { return cached }
        #if DEBUG
        guard !usesDemoFixture else { return [] }
        #endif
        struct Params: Encodable { let p_profile_id: UUID; let p_month_start: String }
        let rows: [ChapterPhoto] = (try? await supabase
            .rpc("chapter_photos", params: Params(p_profile_id: profileId,
                                                   p_month_start: Self.dateOnly.string(from: monthStart)))
            .execute()
            .value) ?? []
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
        struct Params: Encodable { let p_profile_id: UUID; let p_month_start: String }
        let rows: [ChapterStatRow] = (try? await supabase
            .rpc("chapter_stats", params: Params(p_profile_id: profileId,
                                                  p_month_start: Self.dateOnly.string(from: monthStart)))
            .execute()
            .value) ?? []
        let map = rows.keyedByStat()
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
                                     rollName: back == 0 && photo.rollId != nil ? "Demo roll" : nil)
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

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
/// chapters yet" — the shelf simply does not render, nothing else about the page is affected.
@MainActor
@Observable
final class ChapterService {
    /// Newest month first, per profile.
    var chaptersByProfile: [UUID: [ChapterSummary]] = [:]
    /// A month's photos, `taken_at` ascending, keyed by profile + month so two different
    /// people's Augusts, or a repeat visit to the same one, never collide.
    var photosByChapter: [ChapterKey: [ChapterPhoto]] = [:]
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
        isLoadingChapters = []
        #if DEBUG
        usesDemoFixture = false
        #endif
    }

    /// Fetches (or re-fetches) the shelf for `profileId`. Safe to call every time the profile
    /// page loads, same as `UserPageView.load()`'s other per-visit reads: cheap, idempotent, and
    /// this is the only path that keeps the current, still-growing month's shot count current.
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
        chaptersByProfile[profileId] = rows
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

        chaptersByProfile[profileId] = summaries
        for (key, chapterPhotos) in photosByMonth { photosByChapter[key] = chapterPhotos }
    }

    /// For a harness that builds its own synthetic `ChapterSummary`/`ChapterPhoto` fixtures
    /// directly (see `ChapterPreviewDemoHost`) rather than deriving them from real uploaded
    /// photos: marks this instance fixture-backed so `fetchChapters`/`photos(for:monthStart:)`
    /// never overwrite the seeded dictionaries with a failed-soft, empty RPC result.
    func markUsesDemoFixture() { usesDemoFixture = true }
}
#endif

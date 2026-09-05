import Testing
import Foundation
@testable import Flim

/// `ChapterService`'s account-epoch guards: `fetchChapters`, `photos(for:monthStart:)`, and
/// `stats(for:monthStart:)` all resolve visibility server-side AS the signed-in caller
/// (`is_blocked_either_way`, `covered_post_visible`, the owner's own stat picks), so a response
/// that lands after `resetForAccountChange()` is internally consistent, it is just consistent
/// with an account that is no longer signed in. Writing it into the shared cache anyway would
/// hand the NEXT account a cache hit on rows they were never authorized to see, exactly the class
/// of bug `RollService.fetchRolls` and `RollRevealViewModel.loadDeck` already guard against. These
/// model the same shape without a live Supabase round trip, the way `RollServiceSnapshotTests`
/// models `RollService.fetchRolls`.
@MainActor
struct ChapterServiceEpochTests {

    @Test("a chaptersByProfile write guarded after the round trip is skipped once the account changes")
    func fetchChaptersStaleWriteIsDiscarded() {
        let service = ChapterService()
        let profileId = UUID()
        let epoch = AccountEpoch.current

        AccountEpoch.bump()   // the account switches while the RPC is still in flight
        service.resetForAccountChange()

        // fetchChapters "resumes" here; guarded exactly like the real function's write.
        let rows = [ChapterSummary(monthStart: .distantPast, shotCount: 4, rollCount: 1,
                                    coverPaths: [], firstShotAt: .distantPast, lastShotAt: .distantPast)]
        if AccountEpoch.isCurrent(epoch) {
            service.chaptersByProfile[profileId] = rows
        }

        #expect(service.chaptersByProfile[profileId] == nil)
    }

    @Test("a photosByChapter write guarded after the round trip is skipped once the account changes")
    func photosForMonthStaleWriteIsDiscarded() {
        let service = ChapterService()
        let profileId = UUID()
        let monthStart = Date.distantPast
        let key = ChapterService.ChapterKey(profileId: profileId, monthStart: monthStart)
        let epoch = AccountEpoch.current

        AccountEpoch.bump()
        service.resetForAccountChange()

        let photo = ChapterPhoto(id: UUID(), takenAt: .distantPast, thumbPath: nil, feedPath: nil,
                                  storagePath: "a.jpg", rollId: nil, rollName: nil)
        if AccountEpoch.isCurrent(epoch) {
            service.photosByChapter[key] = [photo]
        }

        #expect(service.photosByChapter[key] == nil)
    }

    @Test("a statsByChapter write guarded after the round trip is skipped once the account changes")
    func statsForMonthStaleWriteIsDiscarded() {
        let service = ChapterService()
        let profileId = UUID()
        let monthStart = Date.distantPast
        let key = ChapterService.ChapterKey(profileId: profileId, monthStart: monthStart)
        let epoch = AccountEpoch.current

        AccountEpoch.bump()
        service.resetForAccountChange()

        let row = ChapterStatRow(statKey: "streak_days", valueInt: 5)
        if AccountEpoch.isCurrent(epoch) {
            service.statsByChapter[key] = [.streakDays: row]
        }

        #expect(service.statsByChapter[key] == nil)
    }

    @Test("a fetch captured AFTER the switch is current and its write lands normally")
    func freshEpochWriteSucceeds() {
        let service = ChapterService()
        let profileId = UUID()
        AccountEpoch.bump()
        let epoch = AccountEpoch.current

        let rows = [ChapterSummary(monthStart: .distantPast, shotCount: 1, rollCount: 0,
                                    coverPaths: [], firstShotAt: .distantPast, lastShotAt: .distantPast)]
        if AccountEpoch.isCurrent(epoch) {
            service.chaptersByProfile[profileId] = rows
        }

        #expect(service.chaptersByProfile[profileId]?.count == 1)
    }

    @Test("resetForAccountChange clears every one of the three permissioned caches")
    func resetClearsAllThreeCaches() {
        let service = ChapterService()
        let profileId = UUID()
        let key = ChapterService.ChapterKey(profileId: profileId, monthStart: .distantPast)
        service.chaptersByProfile[profileId] = []
        service.photosByChapter[key] = []
        service.statsByChapter[key] = [:]

        service.resetForAccountChange()

        #expect(service.chaptersByProfile.isEmpty)
        #expect(service.photosByChapter.isEmpty)
        #expect(service.statsByChapter.isEmpty)
    }
}

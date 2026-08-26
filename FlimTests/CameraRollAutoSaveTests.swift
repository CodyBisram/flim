import Testing
import Foundation
@testable import Flim

/// `CameraRollAutoSave`'s pure logic: which developed photos are still owed a save
/// (`pendingCandidates`), and what enabling/disabling the toggle does to the watermark and the
/// ledger that back it. Nothing here touches `PHPhotoLibrary` or the network; the sweep itself
/// (`sweep(userId:photoService:)`) is exercised on-device only.
///
/// Uses an isolated `UserDefaults` suite per test, never `.standard`, matching
/// `FeedSeenStoreTests`: a value planted in a domain the app doesn't own can't poison a later
/// test run in the same simulator.
@MainActor
struct CameraRollAutoSaveTests {

    private func makeStore() -> (CameraRollAutoSave, String, UserDefaults) {
        let suiteName = "CameraRollAutoSaveTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (CameraRollAutoSave(defaults: defaults), suiteName, defaults)
    }

    private func cleanUp(_ suiteName: String) {
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    private func photo(id: UUID = UUID(), takenAt: Date, userId: UUID = UUID()) -> Photo {
        Photo(id: id, userId: userId, rollId: nil, storagePath: "u/\(id.uuidString).jpg",
              thumbPath: nil, feedPath: nil, takenAt: takenAt, developsAt: takenAt,
              isDeveloped: true, caption: nil, isSorted: true)
    }

    // MARK: - pendingCandidates

    @Test("a ledgered photo is excluded, an unledgered one is kept")
    func ledgerFiltersOutAlreadySaved() {
        let saved = photo(takenAt: .now)
        let pending = photo(takenAt: .now.addingTimeInterval(1))
        let result = CameraRollAutoSave.pendingCandidates(
            fetched: [saved, pending], ledger: [saved.id.uuidString], isRollRevealed: { _ in true })
        #expect(result.map(\.id) == [pending.id])
    }

    @Test("results are ordered oldest taken first, regardless of fetch order")
    func orderedAscendingByTakenAt() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let newest = photo(takenAt: base.addingTimeInterval(120))
        let oldest = photo(takenAt: base)
        let middle = photo(takenAt: base.addingTimeInterval(60))
        let result = CameraRollAutoSave.pendingCandidates(fetched: [newest, oldest, middle], ledger: [], isRollRevealed: { _ in true })
        #expect(result.map(\.id) == [oldest.id, middle.id, newest.id])
    }

    @Test("an empty fetch yields no candidates")
    func emptyFetchIsEmpty() {
        #expect(CameraRollAutoSave.pendingCandidates(fetched: [], ledger: [], isRollRevealed: { _ in true }).isEmpty)
    }

    @Test("a ledger of ids that aren't in the fetch changes nothing")
    func ledgerOfUnrelatedIdsIsHarmless() {
        let p = photo(takenAt: .now)
        let result = CameraRollAutoSave.pendingCandidates(fetched: [p], ledger: [UUID().uuidString], isRollRevealed: { _ in true })
        #expect(result.map(\.id) == [p.id])
    }

    @Test("a fetch that's fully ledgered leaves nothing pending")
    func fullyLedgeredFetchIsEmpty() {
        let a = photo(takenAt: .now)
        let b = photo(takenAt: .now.addingTimeInterval(1))
        let result = CameraRollAutoSave.pendingCandidates(
            fetched: [a, b], ledger: [a.id.uuidString, b.id.uuidString], isRollRevealed: { _ in true })
        #expect(result.isEmpty)
    }

    // MARK: - The reveal gate

    private func rollPhoto(rollId: UUID, takenAt: Date) -> Photo {
        let id = UUID()
        return Photo(id: id, userId: UUID(), rollId: rollId, storagePath: "u/\(id.uuidString).jpg",
                     thumbPath: nil, feedPath: nil, takenAt: takenAt, developsAt: takenAt,
                     isDeveloped: true, caption: nil, isSorted: true)
    }

    @Test("a roll shot is held back until its reveal is watched; personal shots pass regardless")
    func unrevealedRollShotIsHeldBack() {
        let watchedRoll = UUID()
        let unwatchedRoll = UUID()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let personal = photo(takenAt: base)
        let revealed = rollPhoto(rollId: watchedRoll, takenAt: base.addingTimeInterval(1))
        let held = rollPhoto(rollId: unwatchedRoll, takenAt: base.addingTimeInterval(2))
        let result = CameraRollAutoSave.pendingCandidates(
            fetched: [held, revealed, personal], ledger: [],
            isRollRevealed: { $0 == watchedRoll })
        #expect(result.map(\.id) == [personal.id, revealed.id])
    }

    @Test("a held-back roll shot is skipped, never ledgered: it becomes pending once the reveal plays")
    func heldBackShotSurfacesAfterReveal() {
        let roll = UUID()
        let shot = rollPhoto(rollId: roll, takenAt: .now)
        let before = CameraRollAutoSave.pendingCandidates(
            fetched: [shot], ledger: [], isRollRevealed: { _ in false })
        #expect(before.isEmpty)
        let after = CameraRollAutoSave.pendingCandidates(
            fetched: [shot], ledger: [], isRollRevealed: { _ in true })
        #expect(after.map(\.id) == [shot.id])
    }

    // MARK: - setEnabled: watermark + ledger semantics

    @Test("an account that never touched the toggle reads as disabled")
    func defaultIsDisabled() {
        let (store, suite, _) = makeStore(); defer { cleanUp(suite) }
        #expect(!store.isEnabled(for: UUID()))
    }

    @Test("enabling stamps the watermark to now and starts with an empty ledger")
    func enablingStampsWatermarkAndClearsLedger() {
        let (store, suite, defaults) = makeStore(); defer { cleanUp(suite) }
        let user = UUID()
        let before = Date.now

        store.setEnabled(true, for: user)

        #expect(store.isEnabled(for: user))
        let watermark = defaults.object(forKey: "cameraRollAutoSave.watermark.\(user.uuidString)") as? Date
        #expect(watermark != nil)
        if let watermark { #expect(watermark >= before) }
        #expect((defaults.stringArray(forKey: "cameraRollAutoSave.saved.\(user.uuidString)") ?? []).isEmpty)
    }

    @Test("disabling flips the flag but leaves the watermark and ledger untouched")
    func disablingLeavesWatermarkAndLedgerAlone() {
        let (store, suite, defaults) = makeStore(); defer { cleanUp(suite) }
        let user = UUID()
        let watermarkKey = "cameraRollAutoSave.watermark.\(user.uuidString)"
        let savedKey = "cameraRollAutoSave.saved.\(user.uuidString)"

        store.setEnabled(true, for: user)
        defaults.set(["some-id"], forKey: savedKey)
        let watermarkBeforeDisable = defaults.object(forKey: watermarkKey) as? Date

        store.setEnabled(false, for: user)

        #expect(!store.isEnabled(for: user))
        #expect(defaults.object(forKey: watermarkKey) as? Date == watermarkBeforeDisable)
        #expect(defaults.stringArray(forKey: savedKey) == ["some-id"])
    }

    @Test("re-enabling after a disable moves the watermark forward and clears the stale ledger")
    func reEnablingResetsBoth() async throws {
        let (store, suite, defaults) = makeStore(); defer { cleanUp(suite) }
        let user = UUID()
        let watermarkKey = "cameraRollAutoSave.watermark.\(user.uuidString)"
        let savedKey = "cameraRollAutoSave.saved.\(user.uuidString)"

        store.setEnabled(true, for: user)
        let firstWatermark = defaults.object(forKey: watermarkKey) as? Date
        defaults.set(["stale-id"], forKey: savedKey)
        store.setEnabled(false, for: user)

        // A distinguishable later instant, not just a second call: Date is fine-grained enough
        // that back-to-back calls could tie without any real elapsed time between them.
        try await Task.sleep(nanoseconds: 2_000_000)
        store.setEnabled(true, for: user)

        let secondWatermark = defaults.object(forKey: watermarkKey) as? Date
        #expect(firstWatermark != nil)
        #expect(secondWatermark != nil)
        if let firstWatermark, let secondWatermark {
            #expect(secondWatermark > firstWatermark, "re-enabling must move the watermark forward, not reuse the old one")
        }
        #expect((defaults.stringArray(forKey: savedKey) ?? []).isEmpty, "a stale ledger from before the disable must not survive a re-enable")
    }
}

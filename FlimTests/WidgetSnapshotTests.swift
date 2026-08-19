import Testing
import Foundation
@testable import Flim

/// The snapshot is the only thing the three home-screen surfaces know. It is written by the app
/// and read by an extension in another process, so every rule encoded in it is a rule no compiler
/// checks: the widget target is not reachable from here, and a widget that renders the wrong
/// state does not crash, it just quietly says something false on someone's home screen.
struct WidgetSnapshotTests {

    private func snapshot(unsorted: Int = 0,
                          developing: WidgetSnapshot.DevelopingRoll? = nil,
                          ready: Bool = false,
                          memories: [WidgetSnapshot.Memory] = [],
                          writtenAt: Date = .now) -> WidgetSnapshot {
        WidgetSnapshot(unsortedCount: unsorted, developingRoll: developing, readyToReveal: ready,
                       memories: memories, accent: "violet", writtenAt: writtenAt)
    }

    private func roll(startedAgo: TimeInterval, revealsIn: TimeInterval) -> WidgetSnapshot.DevelopingRoll {
        WidgetSnapshot.DevelopingRoll(id: UUID(), name: "Roommates",
                                      revealAt: Date().addingTimeInterval(revealsIn),
                                      startedAt: Date().addingTimeInterval(-startedAgo))
    }

    // MARK: - Shutter priority
    //
    // The order is the product decision: the only state ASKING for something outranks the only
    // state with a deadline, which outranks a standing count. Each test below sets up a snapshot
    // where a LOWER-priority state is also true, so it fails if the order is ever rearranged.

    @Test("ready to reveal outranks everything, including a developing roll and a full deck")
    func readyWins() {
        let s = snapshot(unsorted: 7, developing: roll(startedAgo: 3600, revealsIn: 3600), ready: true)
        #expect(s.shutterState() == .readyToReveal)
    }

    @Test("a developing roll outranks prints waiting")
    func developingBeatsUnsorted() {
        let s = snapshot(unsorted: 7, developing: roll(startedAgo: 6 * 3600, revealsIn: 6 * 3600))
        guard case .developing(let progress) = s.shutterState() else {
            Issue.record("expected .developing, got \(s.shutterState())"); return
        }
        #expect(abs(progress - 0.5) < 0.01)
    }

    @Test("a roll whose reveal has passed is not still developing")
    func elapsedRollStopsDeveloping() {
        // Reveal in the past and nothing marked ready: the shutter must fall through to the
        // count, not sit on a finished countdown forever.
        let s = snapshot(unsorted: 3, developing: roll(startedAgo: 13 * 3600, revealsIn: -3600))
        #expect(s.shutterState() == .unsorted(count: 3))
    }

    @Test("progress is clamped to 0...1 even when the dates are nonsense")
    func progressClamped() {
        let past = snapshot(developing: roll(startedAgo: 100 * 3600, revealsIn: 60))
        guard case .developing(let p) = past.shutterState() else {
            Issue.record("expected .developing"); return
        }
        #expect(p >= 0 && p <= 1)
    }

    @Test("nothing waiting is idle, not a zero badge")
    func idle() {
        #expect(snapshot().shutterState() == .idle)
    }

    // MARK: - Never written
    //
    // This is the bug that prompted the redesign. The App Group being missing from a provisioning
    // profile makes every container lookup nil, silently, and it survives a reinstall. Rendered as
    // an ordinary empty state it is indistinguishable from a brand new account, so it hid.

    @Test("the fallback snapshot reports that it was never written")
    func emptyIsNeverWritten() {
        #expect(WidgetSnapshot.empty.neverWritten)
    }

    @Test("a real snapshot saying zero is NOT the never-written state")
    func realZeroIsNotNeverWritten() {
        // The distinction the tiles rely on: "you have nothing to sort" is an answer, and must
        // not render as "this was never set up".
        #expect(!snapshot(unsorted: 0).neverWritten)
    }

    // MARK: - Memory ladder

    @Test("horizons are declared oldest first, which is the order the tile rotates in")
    func horizonOrder() {
        #expect(WidgetSnapshot.Memory.Horizon.allCases == [.yearAgo, .monthAgo, .lastWeek, .yesterday, .latest])
    }

    @Test("every horizon that looks back looks further back than the next one")
    func lookbacksDescend() {
        let offsets = WidgetSnapshot.Memory.Horizon.allCases.compactMap { $0.lookback?.offset }
        #expect(offsets == offsets.sorted(by: >), "\(offsets)")
    }

    @Test("only the newest horizon has no lookback, because it is not a date, it is whatever exists")
    func latestHasNoLookback() {
        for horizon in WidgetSnapshot.Memory.Horizon.allCases {
            #expect((horizon.lookback == nil) == (horizon == .latest), "\(horizon)")
        }
    }

    @Test("no horizon's window is wide enough to swallow the next horizon's target")
    func windowsDoNotOverlapTargets() {
        // A one-year window of ±30 days would happily match a photo from a month ago and label it
        // ONE YEAR AGO. Each window must stay clear of where the next rung is looking.
        let rungs = WidgetSnapshot.Memory.Horizon.allCases.compactMap { h -> (TimeInterval, TimeInterval)? in
            h.lookback.map { ($0.offset, $0.window) }
        }
        for (index, rung) in rungs.enumerated() where index + 1 < rungs.count {
            let next = rungs[index + 1]
            #expect(rung.0 - rung.1 > next.0 + next.1,
                    "window at offset \(rung.0) reaches the rung at \(next.0)")
        }
    }

    // MARK: - Wire shape

    @Test("a snapshot survives the round trip through the container's JSON")
    func codableRoundTrip() throws {
        let memory = WidgetSnapshot.Memory(horizon: .monthAgo, imageName: "frame-x.jpg",
                                           takenAt: Date(timeIntervalSince1970: 1_700_000_000),
                                           subtitle: "Roommates", link: WidgetLink.photo(UUID()))
        let original = snapshot(unsorted: 2, developing: roll(startedAgo: 3600, revealsIn: 3600),
                                ready: false, memories: [memory],
                                writtenAt: Date(timeIntervalSince1970: 1_700_000_001))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == original)
    }

    @Test("a roll's cover initial skips emoji and punctuation")
    func coverInitial() {
        // Roll names in this product routinely lead with an emoji, and drawing that as the cover
        // letter is drawing a picture on top of a picture.
        #expect(RollHueTile.initial(of: "🏠 Roommates") == "R")
        #expect(RollHueTile.initial(of: "Summer road trip") == "S")
        #expect(RollHueTile.initial(of: "  lake weekend") == "L")
        #expect(RollHueTile.initial(of: "24 hours") == "2")
        #expect(RollHueTile.initial(of: "🎞️") == nil)
        #expect(RollHueTile.initial(of: "") == nil)
    }

    @Test("the cover hue is stable for an id and spreads across different ones")
    func coverHue() {
        let id = UUID().uuidString
        #expect(RollHueTile.hue(id) == RollHueTile.hue(id))
        #expect((0...1).contains(RollHueTile.hue(id)))
    }

    @Test("imageNames lists exactly what the pruner must keep")
    func imageNamesTracksMemories() {
        let memories = (0..<3).map { i in
            WidgetSnapshot.Memory(horizon: .latest, imageName: "frame-\(i).jpg", takenAt: .now,
                                  subtitle: "", link: WidgetLink.camera)
        }
        #expect(snapshot(memories: memories).imageNames == ["frame-0.jpg", "frame-1.jpg", "frame-2.jpg"])
    }
}

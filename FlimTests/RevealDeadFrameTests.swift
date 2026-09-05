import Testing
import Foundation
@testable import Flim

/// What happens to the reader's position when a frame dies mid-reveal.
///
/// A frame can fail to load at any time: it was deleted between the deck's fetch and the moment
/// its image resolved, or `CachedImage` simply missed once on a plain network blip. `playedDeck`
/// is FROZEN once the deck loads (see its own doc): `skipDeadFrame` records the id in
/// `deadFrameIds` and steps `index` around it, but never removes anything from `playedDeck`
/// itself, so the reader's position is always a valid slot in an array that never reshuffles
/// under them. A dead frame away from the reader must move nothing at all; the frame actually on
/// screen dying must always prefer stepping FORWARD, never backward, except at the very end of
/// the roll where forward has nowhere left to go.
@MainActor
struct RevealDeadFrameTests {

    private func photo(_ tag: Int) -> Photo {
        Photo(id: UUID(),
              userId: UUID(),
              rollId: UUID(),
              storagePath: "p/\(tag).jpg",
              thumbPath: nil,
              feedPath: nil,
              takenAt: Date(timeIntervalSince1970: TimeInterval(tag * 60)),
              developsAt: Date(timeIntervalSince1970: TimeInterval(tag * 60)),
              isDeveloped: true,
              caption: nil,
              isSorted: true)
    }

    /// A view model sitting on a five-frame deck at `index`, with no network involved. None of
    /// these fixtures carry a `burstGroup`, so `playedDeck` (what `skipDeadFrame`/`index` actually
    /// walk) is identical to `deck`, exactly what `loadDeck` itself would produce for a burst-free
    /// roll via `BurstGrouping.playback`.
    private func viewModel(count: Int, at index: Int) -> RollRevealViewModel {
        let photos = (0..<count).map(photo)
        let vm = RollRevealViewModel(rollId: UUID(), photos: photos)
        vm.deck = photos
        vm.playedDeck = photos
        vm.index = index
        return vm
    }

    @Test("a frame dying BEHIND the reader moves nothing at all")
    func deadFrameBehindKeepsTheSamePosition() {
        // The regression this file exists for. Deck [0,1,2,3,4] on frame 3; frame 1 fails late,
        // having been prefetched earlier and resolved after the reader moved on. `playedDeck`
        // never reshuffles, so `index` simply has no reason to move.
        let vm = viewModel(count: 5, at: 3)
        let onScreen = vm.playedDeck[3].id
        let dead = vm.playedDeck[1].id

        vm.skipDeadFrame(dead)

        #expect(vm.index == 3)
        #expect(vm.playedDeck[vm.index].id == onScreen, "the reader must still be on the same photograph")
        #expect(vm.playedDeck.count == 5, "the played list is frozen, a dead frame is recorded, never spliced out")
        #expect(vm.deadFrameIds.contains(dead))
    }

    @Test("the dying frame's own slot hands the reader the next photograph")
    func deadFrameUnderTheReaderAdvancesToTheNext() {
        // The frame you are looking at is the one that failed. Forward is the only direction that
        // ever fires here, matching the direction the reader is already headed.
        let vm = viewModel(count: 5, at: 2)
        let next = vm.playedDeck[3].id

        vm.skipDeadFrame(vm.playedDeck[2].id)

        #expect(vm.playedDeck[vm.index].id == next)
        #expect(vm.index == 3)
    }

    @Test("a frame dying AHEAD of the reader moves nothing")
    func deadFrameAheadKeepsTheIndex() {
        let vm = viewModel(count: 5, at: 1)
        let onScreen = vm.playedDeck[1].id

        vm.skipDeadFrame(vm.playedDeck[4].id)

        #expect(vm.index == 1)
        #expect(vm.playedDeck[vm.index].id == onScreen)
    }

    @Test("the last frame dying under the reader steps backward only because forward has nowhere to go")
    func deadLastFrameStepsBack() {
        let vm = viewModel(count: 5, at: 4)
        let previous = vm.playedDeck[3].id

        vm.skipDeadFrame(vm.playedDeck[4].id)

        #expect(vm.index == 3)
        #expect(vm.playedDeck[vm.index].id == previous)
        #expect(vm.playedDeck.count == 5)
    }

    @Test("a dead frame is never retargeted backward when a forward frame is still alive")
    func neverRetargetsBackwardWhenForwardSurvives() {
        // Reader on frame 2 of 6; frames 2 AND 3 die in the same beat (two failures landing close
        // together, e.g. two neighbouring pages both missing on the same network blip). Forward
        // still has frame 4 alive, so the reader must land there, never back on frame 0 or 1.
        let vm = viewModel(count: 6, at: 2)
        let forward = vm.playedDeck[4].id

        vm.skipDeadFrame(vm.playedDeck[2].id)
        vm.skipDeadFrame(vm.playedDeck[3].id)

        #expect(vm.index == 4)
        #expect(vm.playedDeck[vm.index].id == forward)
    }

    @Test("no correction can ever leave the index outside the played deck")
    func indexStaysInBoundsForEveryCombination() {
        // Exhaustive over every position and every frame that could die from it. An out-of-range
        // index here is a crash in the pager, not a cosmetic jump.
        for position in 0..<6 {
            for dying in 0..<6 {
                let vm = viewModel(count: 6, at: position)
                vm.skipDeadFrame(vm.playedDeck[dying].id)
                #expect(vm.playedDeck.indices.contains(vm.index),
                        "index \(vm.index) out of a \(vm.playedDeck.count)-frame deck (was on \(position), killed \(dying))")
            }
        }
    }

    @Test("a frame dying behind the reader does not develop a frame nobody reached")
    func theDevelopBeatIsNotBurnedOnAnUnreachedFrame() {
        // The real cost of the original bug: a wrong index marked an unreached photograph as
        // already developed and it never got its beat.
        let vm = viewModel(count: 5, at: 3)
        vm.reduceMotion = true          // develop resolves synchronously, no animation to await
        let unreached = vm.playedDeck[4].id
        vm.skipDeadFrame(vm.playedDeck[1].id)

        #expect(!vm.developedFrameIds.contains(unreached),
                "frame 4 was never reached and must keep its develop beat")
    }

    @Test("killing the only frame empties the reveal instead of leaving a bad index")
    func lastFrameStandingEmptiesTheDeck() {
        let vm = viewModel(count: 1, at: 0)

        vm.skipDeadFrame(vm.playedDeck[0].id)

        #expect(vm.deck.isEmpty)
        #expect(vm.isEmpty)
        #expect(vm.playedDeck.count == 1, "the played list itself is still frozen even once empty of survivors")
    }

    @Test("a frame that is not in the deck is ignored")
    func unknownFrameIsANoOp() {
        // Two failures can report for the same photo, or one can arrive after the deck reloaded.
        let vm = viewModel(count: 3, at: 1)
        vm.skipDeadFrame(UUID())

        #expect(vm.playedDeck.count == 3)
        #expect(vm.index == 1)
        #expect(vm.deadFrameIds.isEmpty)
    }

    @Test("the same frame dying twice is a no-op the second time")
    func doubleReportIsIdempotent() {
        // Two mounted pages (or a retry) can both report the same dead photo.
        let vm = viewModel(count: 5, at: 3)
        let dead = vm.playedDeck[1].id

        vm.skipDeadFrame(dead)
        let indexAfterFirst = vm.index
        vm.skipDeadFrame(dead)

        #expect(vm.index == indexAfterFirst)
        #expect(vm.deck.count == 4, "removed from the save-all deck exactly once")
    }

    @Test("save all's deck loses a dead frame even though the played list keeps it")
    func deckPrunesWhilePlayedDeckStaysWhole() {
        let vm = viewModel(count: 4, at: 0)
        let dead = vm.playedDeck[2].id

        vm.skipDeadFrame(dead)

        #expect(!vm.deck.contains { $0.id == dead })
        #expect(vm.playedDeck.contains { $0.id == dead },
                "the pager's own array is frozen: a dead frame is recorded, not spliced out")
    }

    /// `RollRevealView.revealPager`'s own `selection` never stores a position; it stores the
    /// PHOTO ID the reader is looking at, and every place it needs to know a position (feeding
    /// `viewModel.moved(to:)`, seeding the rack scroll) resolves it fresh with exactly this
    /// lookup. Production never actually reassigns `playedDeck` wholesale once loaded (it is
    /// frozen, see its own doc), but this pins the contract the whole fix leans on: a deck
    /// refresh, whenever or however one might reach `playedDeck`, can reorder or grow the array
    /// in any way at all and the reader's own photo is still exactly one `firstIndex(where:)`
    /// away, never a stale position naming something else.
    @Test("looking up the viewed photo by id survives an arbitrary reshuffle of the played list")
    func idLookupSurvivesAnyReorderOfThePlayedList() {
        let vm = viewModel(count: 5, at: 2)
        let viewingId = vm.playedDeck[vm.index].id

        var reordered = vm.playedDeck.shuffled()
        reordered.append(photo(99))
        vm.playedDeck = reordered

        let newIndex = vm.playedDeck.firstIndex(where: { $0.id == viewingId })
        #expect(newIndex != nil, "the id the reader was viewing must still be locatable")
        if let newIndex {
            #expect(vm.playedDeck[newIndex].id == viewingId)
        }
    }
}

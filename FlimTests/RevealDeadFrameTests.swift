import Testing
import Foundation
@testable import Flim

/// What happens to the reader's position when a frame dies mid-reveal.
///
/// A frame can fail to load at any time: it was deleted between the deck's fetch and the moment its
/// image resolved. `skipDeadFrame` takes it out of the deck, which SHIFTS every frame after it down
/// one slot. The reader's index is positional, so it has to be corrected or the reveal silently
/// jumps to a photograph nobody paged to, AND burns that photograph's once-ever develop beat on the
/// way past. The develop-once-on-first-reach contract is the whole ceremony, so this is pinned.
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

    /// A view model sitting on a five-frame deck at `index`, with no network involved.
    private func viewModel(count: Int, at index: Int) -> RollRevealViewModel {
        let photos = (0..<count).map(photo)
        let vm = RollRevealViewModel(rollId: UUID(), photos: photos)
        vm.deck = photos
        vm.index = index
        return vm
    }

    @Test("a frame dying BEHIND the reader does not move the reader")
    func deadFrameBehindKeepsTheSamePhotograph() {
        // The regression this file exists for. Deck [0,1,2,3,4] on frame 3; frame 1 fails late,
        // having been prefetched earlier and resolved after the reader moved on. Removing it makes
        // the deck [0,2,3,4], where frame 3 now lives at slot 2. An uncorrected index of 3 would
        // name frame 4: a silent jump forward.
        let vm = viewModel(count: 5, at: 3)
        let onScreen = vm.deck[3].id
        let dead = vm.deck[1].id

        vm.skipDeadFrame(dead)

        #expect(vm.deck.count == 4)
        #expect(vm.deck[vm.index].id == onScreen, "the reader must still be on the same photograph")
    }

    @Test("the dying frame's own slot hands the reader the next photograph")
    func deadFrameUnderTheReaderAdvancesToTheNext() {
        // The frame you are looking at is the one that failed. The next frame slides into this
        // slot, and landing there is right: there is nothing else to show.
        let vm = viewModel(count: 5, at: 2)
        let next = vm.deck[3].id

        vm.skipDeadFrame(vm.deck[2].id)

        #expect(vm.deck[vm.index].id == next)
    }

    @Test("a frame dying AHEAD of the reader moves nothing")
    func deadFrameAheadKeepsTheIndex() {
        let vm = viewModel(count: 5, at: 1)
        let onScreen = vm.deck[1].id

        vm.skipDeadFrame(vm.deck[4].id)

        #expect(vm.index == 1)
        #expect(vm.deck[vm.index].id == onScreen)
    }

    @Test("the last frame dying under the reader clamps rather than running off the end")
    func deadLastFrameClamps() {
        // The case the original clamp was written for, and it must keep working.
        let vm = viewModel(count: 5, at: 4)

        vm.skipDeadFrame(vm.deck[4].id)

        #expect(vm.deck.count == 4)
        #expect(vm.index == 3)
        #expect(vm.deck.indices.contains(vm.index))
    }

    @Test("no correction can ever leave the index outside the deck")
    func indexStaysInBoundsForEveryCombination() {
        // Exhaustive over every position and every frame that could die from it. An out-of-range
        // index here is a crash in the pager, not a cosmetic jump.
        for position in 0..<6 {
            for dying in 0..<6 {
                let vm = viewModel(count: 6, at: position)
                vm.skipDeadFrame(vm.deck[dying].id)
                #expect(vm.deck.indices.contains(vm.index),
                        "index \(vm.index) out of a \(vm.deck.count)-frame deck (was on \(position), killed \(dying))")
            }
        }
    }

    @Test("a frame dying behind the reader does not develop a frame nobody reached")
    func theDevelopBeatIsNotBurnedOnAnUnreachedFrame() {
        // The real cost of the bug: `skipDeadFrame` calls `develop(at: index)`, so a wrong index
        // marks an unreached photograph as already developed and it never gets its beat.
        let vm = viewModel(count: 5, at: 3)
        vm.reduceMotion = true          // develop resolves synchronously, no animation to await
        let unreached = vm.deck[4].id
        vm.skipDeadFrame(vm.deck[1].id)

        #expect(!vm.developedFrameIds.contains(unreached),
                "frame 4 was never reached and must keep its develop beat")
    }

    @Test("killing the only frame empties the reveal instead of leaving a bad index")
    func lastFrameStandingEmptiesTheDeck() {
        let vm = viewModel(count: 1, at: 0)

        vm.skipDeadFrame(vm.deck[0].id)

        #expect(vm.deck.isEmpty)
        #expect(vm.isEmpty)
    }

    @Test("a frame that is not in the deck is ignored")
    func unknownFrameIsANoOp() {
        // Two failures can report for the same photo, or one can arrive after the deck reloaded.
        let vm = viewModel(count: 3, at: 1)
        vm.skipDeadFrame(UUID())

        #expect(vm.deck.count == 3)
        #expect(vm.index == 1)
    }
}
